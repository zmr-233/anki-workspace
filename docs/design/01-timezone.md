# 完整时区支持：设计与分析

让整个 collection 使用**用户指定的调度时区 + 分钟精度日界**，与设备 OS 时区解耦，
且保持 AnkiWeb 账号同步可用。已实现并通过真机验收，本文只讲设计与分析结论。

---

## 1. 问题：Anki 如何判定"今天"

唯一入口 `rslib/src/scheduler/timing.rs` `sched_timing_today_v2_new()`：

```
days_elapsed = 日历天数(now @ current_offset) − 日历天数(crt @ creation_offset) − (未过 rollover ? 1 : 0)
next_day_at  = current_offset 下今天的 rollover 时刻（已过则 +1 天）
```

| 输入 | 存储 | 用户可控 |
|---|---|---|
| `creation_utc_offset` | config `creationOffset`，建库时写死 | 否 |
| `current_utc_offset` | **不存储，每次读设备 OS 时区** | 否 |
| `rollover_hour` | config `rollover` | 仅整点 |

原本 `local_utc_offset_for_user()` 里客户端硬用 OS 时区，还把它反向写回 config；
`rollover` 硬编码 `.with_minute(0)`；存的是固定偏移而非 IANA 名。
三者叠加导致：**时区无处可填、日界只能整点、要"钉住时区"就必须引入 tzdb**。

### 为什么不能只改 due counts

同一时刻两台设备 `days_elapsed` 差 ±1，后果沿这些调用点扩散：

| 位置 | 影响 |
|---|---|
| `card.due`（复习卡是绝对天号） | 卡片一边出现一边不出现 |
| 答题写回 `due = today + ivl` | 跨设备来回 → 间隔系统性漂移 |
| `stats/today.rs`、`queue/builder/mod.rs` | 每日上限可能一天内重置两次 |
| `bury_and_suspend.rs` + `lastUnburied` | 埋葬提前解除 / 不解除 |
| `answering/mod.rs` `secs_until_rollover` | revlog 同一步记成"天"还是"秒"取决于设备 |
| `fsrs/memory_state.rs` `reviews_for_fsrs` | **FSRS 训练数据分桶随设备变**，记忆状态漂移 |
| `stats/graphs/mod.rs` | 图表小时分布、日历图错位 |
| AnkiWeb（`server=true` 读 `localOffset`） | 日界由**最后一次同步的设备**决定 |

### 已排除：给每台设备设补偿 rollover

数学上成立，但 **`rollover` 是会同步的 collection config**
（`sync/collection/changes.rs`，接收端 `set_all_config` 整体覆盖），
无法给不同设备设不同值——直接判死刑。另外补偿值 `<0` 或 `≥24` 时
`rollover_hour % 24` 会折回同一日历日，产生恒定 ±1 的 `days_elapsed` 偏移。

---

## 2. 数据模型

全部为**新增 config key**，不动 schema，缺失时行为与改动前逐字节一致：

| Key | 类型 | 默认 | 含义 |
|---|---|---|---|
| `schedTimezone` | String | `""` | IANA 时区名。空 = 跟随 OS |
| `rolloverMinute` | u32 (0–59) | `0` | 日界的分钟部分 |

语义保持不变的：`rollover`（日界小时）、`creationOffset`（纪元锚点，**不动**）、
`localOffset`（改为写入"调度时区在当前时刻的等效偏移"，供 AnkiWeb 使用）。

**为什么不引入 `creationTimezone`**：`creationOffset` 只是 `days_elapsed` 的纪元锚点，
改它会让所有历史 `card.due` 天号整体平移，等于一次性打乱全部到期日。
保持不变的代价只是 `days_elapsed` 的绝对值有个固定偏移，但它对所有卡片一致、
`due` 又是同一坐标系，**不影响任何相对关系**。

**DST**：必须存 IANA 名而非偏移，并且对每个要转换的时间戳**分别求偏移**
（`creation_secs` 用建库时刻的，`now` 用当前时刻的）。`timing.rs` 的 `FixedOffset`
接口原样保留，只是求值方式变了。无法识别的时区名返回 `None` 回退到旧行为，
这样从 tzdb 更新的客户端同步过来的 collection 仍能调度而不是报错。

---

## 3. AnkiWeb 同步兼容性

**结论：纯 config 层改动，不触碰 DB schema、不触碰 sync protocol、不影响 sanity check。**
逐条核实：

| # | 检查 | 结论 |
|---|---|---|
| 3.1 | Sanity check 是否比较 due counts | ✅ 不比较。客户端 `storage/sync_check.rs` 用 `default()`；服务端 `sync/collection/sanity.rs` 比较前清零。时区差异**不可能**触发 sanity check 失败 |
| 3.2 | 是否触发 full sync | ✅ 否。`sync/collection/meta.rs` 只有 `scm` 不同才 `FullSyncRequired`，新 config key 不动 `scm` |
| 3.3 | config 能否安全往返 | ✅ 能。`changed_config()` 发送全部 config 为 `HashMap<String, Value>`，接收端 `set_all_config` 整体覆盖，AnkiWeb 只当 JSON 存不做 key 白名单 |
| 3.4 | schema11 降级是否丢 key | ✅ 不丢。`schema11_config_as_string()` 只在建库时调用；降级走 `downgrade_config_from_schema14()` 整体 dump |

### 不能动的东西 ⚠️

| 项 | 约束 |
|---|---|
| `SYNC_VERSION` | 服务端校验 `8..=11`，必须继续报 `SYNC_VERSION_MAX = 11` |
| DB schema 版本 | 必须留在 18 |
| `sync_client_version()` | 格式 `anki,{ver} ({hash}),{platform}`。参考实现不校验，**但 AnkiWeb 闭源、可能有 UA 白名单** → 不要加自定义后缀 |
| sanity check 的表计数 | 不新增/删除表 |

### 免费收益 🎁

`server=true` 时 AnkiWeb 读 config 的 `localOffset`。把**调度时区在当前时刻的等效偏移**
写进去（而非 OS 偏移），AnkiWeb 网页复习器就自动对齐调度时区。`rollover` 本来就同步。

### 唯一无法弥合的差异 ❌

AnkiWeb 不认识 `rolloverMinute`，其日界始终落在整点。
**t0 非整点时，网页版最多与设备差 59 分钟。** 自己的设备之间完全一致。**已确认接受。**

---

## 4. 已定决策

| 决策 | 结论 |
|---|---|
| 版本对齐 | 统一到 **anki 26.05**（后端 fork 已在 `0.1.66-anki26.05`） |
| `creationOffset` | **不动**，只替换 current offset 的来源 |
| 分钟精度 | **保留**，接受 AnkiWeb 最多 59 分钟偏差 |
| 上游 PR 风格 | **保守**：`schedTimezone` 为空时行为等同现状，新逻辑全部走 opt-in 分支 |

### 一次性副作用（尚未在 UI 提示）

首次启用调度时区时，若它与设备时区的日历日不同，`days_elapsed` 会一次性 ±1，
用户会看到"今天"的卡片数跳变一次。这是改变日界的固有结果，不是 bug。

---

## 5. 验收结果

测试数据：`crt` 回拨 30 天的 collection，3 张逾期 + 5 张今日到期 + 7 张明日到期。
"今天"到期数 = **8**；日号 −1 → 3；日号 +1 → 15。

### 5.1 真机（Oppo Find N6，Android 16）

| # | 场景 | 设备时区 | `schedTimezone` | 待复习 | 结论 |
|---|---|---|---|---|---|
| 1 | 基线 | Asia/Shanghai | 未设置 | **8** | arm64 后端可用 |
| 2 | **对照组** | America/Los_Angeles | 未设置 | **3** | ⚠️ 复现了要修的 bug，也证明该测试对时区敏感 |
| 3 | **核心验收** | America/Los_Angeles | `Asia/Shanghai` + 4:30 | **8** | ✅ 设备时区不再影响日界 |
| 4 | 恢复 | Asia/Shanghai | `Asia/Shanghai` + 4:30 | **8** | ✅ |

场景 2 → 3 是在**设备时区保持洛杉矶不变**的情况下，仅靠应用内新设置项完成的，
数字当场从 3 回到 8。

从设备拉回的 collection（含 WAL）核对：`rolloverMinute = 30`、
`schedTimezone = "Asia/Shanghai"`、`localOffset = -480`（钉住时区的偏移，而非洛杉矶的 +420）
—— 即 §3 的 AnkiWeb 镜像逻辑生效。

同一份 collection 在桌面用 pylib 跨 `America/Los_Angeles` / `Asia/Shanghai` /
`Pacific/Kiritimati` (UTC+14) / `Pacific/Midway` (UTC−11) / `Europe/London` /
`Australia/Sydney` 六个宿主时区计算，`today=30`、`due=8` 全部一致。

### 5.2 AnkiWeb（真实服务器，非参考实现）

| 检查 | 结果 |
|---|---|
| 手机首次上传（全量） | ✅ |
| 带两个新 key 的集合 `sync_status` | ✅ `NO_CHANGES` —— **没有触发全量同步**，验证 §3.2 |
| 桌面改成 `Europe/Berlin` + 45 并上传 | ✅ 普通同步；`localOffset` 自动变 −120（CEST，DST 正确） |
| 手机同步后设置项显示 | ✅ `Europe/Berlin` / `45` —— **两个新 key 经 AnkiWeb 完整往返** |
| 改回 `Asia/Shanghai` + 30 再往返 | ✅ 待复习回到 8 |

这把 §3「AnkiWeb 只当 JSON 存 config、不做 key 白名单」的**分析**，
变成了对闭源 AnkiWeb 的**实测**。

### 5.3 自动化测试

rslib 新增 11 个 Rust 测试：分钟精度日界、DST（Denver MST/MDT）、次小时时区
（Kathmandu +5:45）、未知时区回退、跨全天 24 个采样点的日界一致性、
pinned 时区覆盖主机时区并镜像进 config、分钟 clamp。

其中 `sync/collection/tests.rs` 那条最关键：两个新 key 通过参考同步服务器**往返存活**，
且断言仍为 `NormalSyncRequired` —— 把 §3 的兼容性结论变成了通过的测试。

---

## 6. 已知取舍

| 项 | 说明 |
|---|---|
| `BootService` legacy 通知路径 | 用设备时区构造 Calendar，钉住调度时区后会不一致。已加注释。`DayRolloverAlarm` 走后端 `dayCutoff`，不受影响 |
| AnkiWeb 分钟精度 | 见 §3，已接受 |
| `creationOffset` | 见 §2，不做 |
