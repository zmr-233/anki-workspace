# Anki / AnkiDroid 完整时区支持 —— 重构方案

目标：让整个 collection 使用一个**用户指定的调度时区 + 分钟精度的日界时间**（`[timezone]:t0`），
与设备 OS 时区解耦，且**保持 AnkiWeb 账号同步可用**。

所有代码引用基于本工作区实际 checkout：
- `01-Anki-Dev` = `zmr-233/anki-dev`，`.version` = 26.05，HEAD `e10ce1518` (2026-07-25)
- `02-AnkiDroid-Dev` = `zmr-233/ankidroid-dev`，versionName 2.25.0alpha2，HEAD `249d24d` (2026-07-26)
- `03-Anki-Android-Backend-Dev` = upstream `ankidroid/Anki-Android-Backend`（只读克隆，待 fork）

---

## 1. 现状：Anki 如何判定"今天"

唯一入口 `rslib/src/scheduler/timing.rs:27` `sched_timing_today_v2_new()`：

```
days_elapsed = 日历天数(now @ current_offset) − 日历天数(crt @ creation_offset) − (未过 rollover ? 1 : 0)
next_day_at  = current_offset 下今天的 rollover 时刻（已过则 +1 天）
```

三个输入：

| 输入 | 存储 | 同步 | 用户可控 |
|---|---|---|---|
| `creation_utc_offset` | config `creationOffset` (i32 西偏分钟)，建库时写死 | 是 | 否 |
| `current_utc_offset` | **不存储，每次读设备 OS 时区** | — | 否 |
| `rollover_hour` | config `rollover` (u8，整点) | 是 | 仅整点 |

关键阻塞点 `rslib/src/scheduler/mod.rs:90-107`：

```rust
pub(crate) fn local_utc_offset_for_user(&mut self) -> Result<FixedOffset> {
    let config_tz = self.get_configured_utc_offset()...;
    let local_tz = TimestampSecs::now().local_utc_offset()?;
    Ok(if self.server {
        config_tz            // ← AnkiWeb 走这条：读 config
    } else {
        if config_tz != local_tz {
            self.set_configured_utc_offset(...)?;   // ← 客户端把 OS 时区覆盖写回 config
        }
        local_tz             // ← 桌面 / AnkiDroid 走这条：config 被完全无视
    })
}
```

### 三个缺口

1. **没有"调度时区"概念**。客户端硬用 OS 时区，还反向污染 config。时区 C 无处可填。
2. **rollover 只有小时精度**。`timing.rs:57-66` 硬编码 `.with_minute(0).with_second(0)`。
3. **存的是固定偏移不是 IANA 时区**。`creationOffset` / `localOffset` 都是 `i32`。当前依赖树里
   **没有 `chrono-tz`**（`Cargo.toml:65` 只有 `chrono 0.4.41` + `std,clock`）。今天能处理 DST 纯粹
   因为每次都重读 OS；要"钉住时区"就必须引入 tzdb。

### 混乱的扩散路径（不止 due counts）

同一时刻两台设备 `days_elapsed` 差 ±1，后果沿以下调用点扩散：

| 位置 | 影响 |
|---|---|
| `card.due`（复习卡是绝对天号） | 卡片一边出现一边不出现 |
| 答题写回 `due = today + ivl` | 跨设备来回 → 间隔系统性漂移 |
| `stats/today.rs:26`、`queue/builder/mod.rs:162` | 每日新卡/复习上限可能一天内重置两次 |
| `bury_and_suspend.rs:44` `unbury_on_day_rollover` + `lastUnburied` | 埋葬提前解除 / 不解除 |
| `answering/mod.rs:131` `secs_until_rollover` → `maybe_as_days` | revlog 里同一步记成"天"还是"秒"取决于设备 |
| `fsrs/memory_state.rs:508` `reviews_for_fsrs(entries, next_day_at, …)` | **FSRS 训练数据分桶随设备变**，记忆状态漂移 |
| `stats/graphs/mod.rs:50` `local_offset_secs` | 图表小时分布、日历图错位 |
| AnkiWeb (`server=true` 读 `localOffset`) | 日界由**最后一次同步的设备**决定 |

### 已排除的土办法

"给每台设备设不同的补偿 rollover" —— 数学上成立（边界瞬间与 `days_elapsed` 都能对齐，
因为 `creation_offset` 固定，rollover 未过时的 `−1` 修正恰好抵消日历日差异），但：

1. **`rollover` 是 collection config，会同步**（`sync/collection/changes.rs:214`，接收端
   `set_all_config` 整体覆盖）。无法给不同设备设不同值 —— 直接判死刑。
2. 补偿值 `<0` 或 `≥24` 时 `rollover_hour % 24`（`timing.rs:58`）折回同一日历日，产生**恒定 ±1**
   的 `days_elapsed` 偏移（已用 r_C=20 / A=UTC+8 验算两个时刻，稳定差 1）。
3. 只能整小时，每次 DST 切换要手算。

---

## 2. AnkiWeb 同步兼容性（专项分析）

**结论：这是一个纯 config 层改动，不触碰 DB schema、不触碰 sync protocol、不影响 sanity check。
AnkiWeb 同步可以保持完全正常。**

逐条核实：

### 2.1 Sanity check 不比较 due counts ✅（最大风险已排除）

- 客户端 `rslib/src/storage/sync_check.rs:47`：`counts: SanityCheckDueCounts::default()` —— 压根不算。
- 服务端 `rslib/src/sync/collection/sanity.rs:101`：`client.counts = Default::default();` —— 比较前清零。

时区差异**不可能**通过 due counts 触发 sanity check 失败。

### 2.2 不改 DB schema → 不触发 full sync ✅

`sync/collection/meta.rs:68`：只有 `scm`（schema change 时间戳）不同才 `FullSyncRequired`。
新增 config key 走 `config` 表的普通写入，不动 `scm`。

### 2.3 config 是不透明 KV，整体往返 ✅

- `sync/collection/changes.rs:216` `changed_config()` 发送**全部** config 为 `HashMap<String, Value>`
- 接收端 `changes.rs:238` `set_all_config(...)` 整体覆盖
- AnkiWeb 只当 JSON 存储，不做 key 白名单

新 key 能安全往返 AnkiWeb 和其它客户端。

### 2.4 schema11 降级保留未知 key ✅

`config/schema11.rs` 的模板 `schema11_config_as_string()` **只在建库时调用**
（唯一调用点 `storage/sqlite.rs:526`，在 `if create` 分支内）。降级走
`storage/upgrades/mod.rs:67` `downgrade_config_from_schema14()`，把 config 表整体 dump 回
`col.conf` JSON。该文件顶部注释也明确写着："When adding new config variables, you do not need
to add them here"。

### 2.5 不能动的东西 ⚠️

| 项 | 约束 |
|---|---|
| `SYNC_VERSION` | `meta.rs:153` 服务端校验 `8..=11`。必须继续报 `SYNC_VERSION_MAX = 11` |
| DB schema 版本 | 必须留在 18 |
| `sync_client_version()` (`version.rs:15`) | 格式 `anki,{ver} ({hash}),{platform}`。参考实现的 `server_meta` 不校验 `cv`，**但 AnkiWeb 闭源，可能有 UA 白名单** → 保持格式原样，不要加自定义后缀 |
| sanity check 的表计数 | 不新增/删除表 |

### 2.6 免费收益：AnkiWeb 自动跟随时区 C 🎁

`server=true` 时 AnkiWeb 读 config 的 `localOffset`（`scheduler/mod.rs:99`）。
我们只要把**"调度时区在当前时刻的等效偏移"**写进 `localOffset`（而不是 OS 偏移），
AnkiWeb 的网页复习器就自动对齐时区 C。`rollover` 本来就同步。

### 2.7 唯一无法弥合的差异 ❌

AnkiWeb 不认识 `rolloverMinute`，其日界始终落在整点。
**若 t0 非整点，网页版复习器最多与你的设备差 59 分钟。**
自己的设备之间完全一致；这只影响在 AnkiWeb 网页上复习的场景。

---

## 3. AnkiDroid 构建链（决定要 fork 什么）

**AnkiDroid 仓库内不含任何 rslib 源码或 `.proto`**（`find . -name "*.proto"` 结果为空）。
protobuf Kotlin 绑定 + rslib 的 `.so` 全部来自预编译 AAR：

- `gradle/libs.versions.toml:73` → `ankiBackend = '0.1.64-anki25.09.2'`
- `buildSrc/src/main/kotlin/com/ichi2/anki/gradle/BackendDependencies.kt:53` → `local.properties`
  里 `local_backend=true` 时切到本地构建
- `BackendDependencies.kt:64` → 路径**写死** `File(rootProject.projectDir.parentFile, "Anki-Android-Backend")`

`Anki-Android-Backend` 结构（已克隆确认）：
- `.gitmodules`: `anki` submodule → `https://github.com/ankitects/anki`，pin 在 `e64c6b1ae`
- `rslib-bridge/` 是包裹 `anki/rslib` 的 Rust crate，`rsdroid/` 产出 AAR
- `gradle.properties:22` `VERSION_NAME=0.1.66-anki26.05`

→ **必须 fork `ankidroid/Anki-Android-Backend`**，把 `anki` submodule 指向 `zmr-233/anki-dev`。

### ⚠️ 版本错配

| 组件 | 对应 anki 版本 |
|---|---|
| `01-Anki-Dev`（桌面 fork） | **26.05** |
| `03-Anki-Android-Backend` upstream HEAD | **26.05**（0.1.66） |
| `02-AnkiDroid-Dev` 的 `libs.versions.toml` pin | **25.09.2**（0.1.64） |

AnkiDroid 主线目前仍指向 25.09.2 的后端，而桌面 fork 和后端 upstream 都已到 26.05。
用 `local_backend=true` 时版本目录被绕过，但 **AnkiDroid 的 Kotlin 代码是按 25.09.2 的 proto
写的**，直接换成 26.05 后端可能出现 proto/API 漂移导致编译错误。见第 6 节决策点 A。

---

## 4. 数据模型设计

全部为**新增 config key**，不动 schema，缺失时行为与现在完全一致（向后兼容）：

| Key | 类型 | 默认（缺失时） | 含义 |
|---|---|---|---|
| `schedTimezone` | String | `""` | IANA 时区名，如 `"Asia/Shanghai"`。空 = 跟随 OS（旧行为） |
| `rolloverMinute` | u8 (0–59) | `0` | 日界的分钟部分 |

保持语义不变：
- `rollover` (u8, 0–23)：日界小时
- `creationOffset` (i32)：纪元锚点，**不动**
- `localOffset` (i32)：改为写入"调度时区在当前时刻的等效偏移"，供 AnkiWeb 使用

### 为什么不引入 `creationTimezone`

`creationOffset` 只是 `days_elapsed` 的**纪元锚点**。改动它会让所有历史 `card.due` 天号整体平移
—— 等于一次性打乱全部到期日。正确做法是保持它不变，只替换 current offset 的来源。
代价：若建库时区与调度时区差别很大，`days_elapsed` 的绝对值有个固定偏移，但因为它对所有卡片
一致、且 `due` 也是同一坐标系，**不影响任何相对关系**。

### DST 正确性要点

不能只存偏移，必须存 IANA 名，并且**对每个要转换的时间戳分别求偏移**：
`creation_secs` 用建库时刻的偏移，`now` 用当前时刻的偏移。`timing.rs` 的 `FixedOffset` 接口
可以原样保留，只是求值方式变了。

---

## 5. 改动清单

### 5.1 rslib 核心（anki-dev）

| 文件 | 改动 |
|---|---|
| `Cargo.toml` | 新增 `chrono-tz`（当前无此依赖）；注意会带入 tzdb，体积约几百 KB |
| `rslib/src/config/mod.rs:47` | `ConfigKey` 加 `SchedTimezone`、`RolloverMinute` + accessor |
| `rslib/src/scheduler/mod.rs:90-107` | **核心**：`local_utc_offset_for_user()` 优先 `schedTimezone`，用 chrono-tz 求当前时刻偏移；把该偏移写入 `localOffset`；不再用 OS 时区覆盖 |
| `rslib/src/scheduler/timing.rs:57` | `rollover_datetime()` → `.with_minute(rollover_minute)` |
| `rslib/src/scheduler/timing.rs:27,115,125,152` | 签名加 `rollover_minute: u8`；v1 / v2_legacy 分支同步处理 |
| `rslib/src/scheduler/mod.rs:58` | `timing_for_timestamp()` 传入 `rollover_minute` |
| `rslib/src/preferences.rs:47,62` | `get/set_scheduling_preferences` 读写新字段 |
| `rslib/src/backend/ankidroid.rs:15` | `sched_timing_today_legacy` 签名跟随（AnkiDroid 遗留接口） |
| `rslib/src/stats/graphs/mod.rs:50` | 已走 `local_utc_offset_for_user()`，**自动受益**，只需确认 `rollover_hour` 上报处补分钟 |

**新增单测**（`timing.rs` 的 `mod test` 已有完善的组合遍历测试，照着扩展）：
- 分钟精度 rollover 的 `next_day_at` / `days_elapsed`
- 固定 `schedTimezone` + 变化的 OS 时区 → `days_elapsed` 不变（核心回归）
- 跨 DST 边界（用有 DST 的 IANA 区如 `America/Denver` 验证，现有测试已用 MDT/MST 场景）

### 5.2 proto

`proto/anki/config.proto:113` 附近 `Scheduling` 消息新增：
```proto
string sched_timezone = N;
uint32 rollover_minute = N+1;
```
改 proto 后需 `just check` 全量构建（会重新生成 Rust/Python/TS 绑定）。

### 5.3 桌面 UI

- `qt/aqt/forms/preferences.ui`：`dayOffset` spinbox 旁加分钟 spinbox + 时区下拉（含"跟随系统"项）
- `qt/aqt/preferences.py:144,179`：读写新字段
- `ftl/core/preferences.ftl`：新增字符串（英文源在主仓库，`ftl/core-repo`/`ftl/qt-repo` 是**翻译**
  submodule，**无需 fork**）

### 5.4 AnkiDroid

- `AnkiDroid/src/main/java/com/ichi2/anki/preferences/ReviewingSettingsFragment.kt:66-92`：
  `setDayOffset()` 扩展为同时写 minute；新增时区选择 preference
- `AnkiDroid/src/main/java/com/ichi2/anki/utils/CollectionPreferences.kt:98`：加 getter/setter
- `AnkiDroid/src/main/java/com/ichi2/anki/services/BootService.kt:189-201` `getRolloverHourOfDay()`：
  目前直读 `col.config.get("rollover")`，需要补分钟
- `DayRolloverAlarm.kt` / `DayRolloverHandler.kt`：已经基于 backend 的 `next_day_at` 排程，
  改动后应自动正确，但需验证分钟精度下的闹钟对齐（`DayRolloverHandler` 依赖"日界粒度为分钟"的假设，
  见 `DayRolloverHandler.kt:73` 注释 —— 分钟精度正好落在它的假设内 ✅）

### 5.5 工作区新增

```
12-Anki-Workspace/
├── 01-Anki-Dev/                    zmr-233/anki-dev              (已有)
├── 02-AnkiDroid-Dev/               zmr-233/ankidroid-dev         (已有)
└── 03-Anki-Android-Backend-Dev/    待 fork ankidroid/Anki-Android-Backend
```

⚠️ `BackendDependencies.kt:64` 写死目录名 `Anki-Android-Backend`。两个选择：
- 改 fork 里的这一行改成读 `local.properties` 属性（推荐，本来就是自己的分支）
- 或建 symlink `Anki-Android-Backend -> 03-Anki-Android-Backend-Dev`

---

## 6. 已定决策

| 决策 | 结论 |
|---|---|
| A. 版本对齐 | **统一到 anki 26.05**。后端 fork `zmr-233/ankidroid-backend-dev` 已在 `0.1.66-anki26.05`（HEAD `307254b` "build(deps): adopt anki 26.05"） |
| B. `creationOffset` | **不动**，只替换 current offset 的来源 |
| C. 分钟精度 | **保留**。接受 AnkiWeb 网页版最多 59 分钟偏差 |
| D. PR 意向 | **保守实现**：`schedTimezone` 为空时行为与现状一致，新逻辑走 opt-in 分支 |

### 一次性副作用（需在 UI 说明）

首次启用调度时区时，若时区 C 与设备时区的日历日不同，`days_elapsed` 会一次性 ±1。
这是改变日界的固有结果，不是 bug，但用户会看到"今天"的卡片数跳变一次。

---

## 7. 实现状态

### 已完成并验证（01-Anki-Dev）

| 文件 | 改动 |
|---|---|
| `Cargo.toml` / `rslib/Cargo.toml` | 新增 `chrono-tz 0.10.4` |
| `rslib/src/config/mod.rs` | `ConfigKey::{RolloverMinute, SchedTimezone}` + 四个 accessor（分钟 clamp 到 59，空字符串视为未设置） |
| `rslib/src/scheduler/timing.rs` | `rollover_datetime()` 支持分钟；`sched_timing_today*` 全链路加 `rollover_minute`；新增 `utc_offset_for_timezone()`（IANA 名 + 时刻 → `FixedOffset`，无法识别返回 `None`） |
| `rslib/src/scheduler/mod.rs` | `local_utc_offset_for_user()` 优先解析 `schedTimezone`，并把等效偏移镜像写入 `localOffset` 供 AnkiWeb 使用 |
| `rslib/src/preferences.rs` | 读写新字段 |
| `rslib/src/backend/ankidroid.rs` | legacy 入口传 0（已确认 AnkiDroid 不再调用该 API） |
| `proto/anki/config.proto` | `Scheduling` 加 `rollover_minute = 7`、`sched_timezone = 8` |
| `qt/aqt/forms/preferences.ui` | 日界拆成时/分两个 spinbox，新增时区下拉 |
| `qt/aqt/preferences.py` | `setup_scheduling_timezone()`，用 `zoneinfo.available_timezones()` 填充；未知时区保持可选不丢弃 |
| `ftl/core/preferences.ftl` | 3 条新字符串 |

**验证结果**

| 命令 | 结果 |
|---|---|
| `just fmt` | ✅ 通过 |
| `just lint` | ✅ 通过（clippy `-Dwarnings` / mypy 300 文件 / ruff / eslint / svelte / typescript） |
| `just test` | ✅ 通过（Rust 561、Python 82 passed + 2 skipped、TS 51） |
| `just check` | ⚠️ 仅 `minilints` 失败：你的 git 邮箱 `gh@siid.sh` 不在 `CONTRIBUTORS` 里。这是仓库既有状态、与本次改动无关，但它会让 ninja 提前停止；若要提 upstream PR 也必须先补上。**是否修改 `CONTRIBUTORS` 由你决定，我没有代改。** |

新增 11 个 Rust 测试：
- `timing.rs`：分钟精度日界、DST（Denver MST/MDT）、次小时时区（Kathmandu +5:45）、未知时区回退、跨全天 24 个采样点的日界一致性
- `scheduler/mod.rs`：pinned 时区覆盖主机时区并镜像进 config、空值/未知值回退、分钟 clamp
- `sync/collection/tests.rs`：`schedTimezone` + `rolloverMinute` 通过参考同步服务器**往返存活**，且断言仍为 `NormalSyncRequired`（未触发 full sync）——这条直接验证了第 2 节的 AnkiWeb 兼容性结论

### 已改但未编译验证（02 / 03）

本机**没有 Android SDK / NDK，Rust 也只装了 `x86_64-unknown-linux-gnu` 靶子**，
无法构建 rsdroid AAR，因此以下改动是纸面正确、未经编译：

| 文件 | 改动 |
|---|---|
| `03/.gitmodules` | `anki` submodule 指向 `git@github.com:zmr-233/anki-dev.git`，branch `main` |
| `02/buildSrc/.../BackendDependencies.kt` | 抽出 `localProperty()`，新增 `backendCheckoutDir()`，支持 `local_backend_path` |
| `02/AnkiDroid/build.gradle` | 同上（该处是独立的硬编码路径） |
| `02/.../CollectionPreferences.kt` | `getDayOffsetMinute()`、`getSchedulingTimezone()` |
| `02/.../ReviewingSettingsFragment.kt` | 分钟 SliderPreference + 时区 ListPreference（`ZoneId.getAvailableZoneIds()`）；`setDayOffsetMinute()` / `setSchedulingTimezone()` |
| `02/.../BootService.kt` | legacy 通知路径补分钟；注明该路径用设备时区、与 `DayRolloverAlarm` 不同 |
| `02/res/values/10-preferences.xml`、`preferences.xml`、`xml/preferences_reviewing.xml` | 新增字符串与 preference key |

**`DayRolloverAlarm` 无需改动** —— 它经 `nextFutureCutoffMs()` 取后端的 `dayCutoff`（即 `next_day_at`），
自动跟随新的时区与分钟设置。

### 剩余步骤（需要你来做/需要 Android 环境）

1. 在 `01-Anki-Dev` 提交并推送改动到 `zmr-233/anki-dev`
2. `cd 03-Anki-Android-Backend-Dev && git submodule sync && git submodule update --init anki`，
   然后把 `anki` gitlink 移到你推送的 commit
3. 装 Android SDK + NDK，`rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android i686-linux-android`
4. 在 `03` 里 `./build.sh` 产出 AAR
5. `02-AnkiDroid-Dev/local.properties` 写入：
   ```
   local_backend=true
   local_backend_path=03-Anki-Android-Backend-Dev
   ```
6. 构建 AnkiDroid，修 Kotlin 编译漂移（25.09.2 → 26.05 的 proto/API 差异）

---

## 8. 原始决策点（已解决，留档）

### A. 版本对齐策略
桌面 fork 在 26.05，AnkiDroid 主线的后端 pin 在 25.09.2，后端 upstream 已到 26.05。
- **(推荐)** 后端 fork 基于 upstream HEAD (0.1.66-anki26.05)，submodule 指向我们的 anki-dev；
  AnkiDroid 侧修 Kotlin 编译漂移。上游已验证 Rust 侧能在 26.05 构建。
- 或：把 rslib 改动同时维护 25.09.2 / 26.05 两个分支，cherry-pick。

### B. `creationOffset` 是否也时区化
建议**不动**（理由见 4.1）。若坚持要动，需要设计一次性的 `card.due` 全量平移迁移。

### C. t0 非整点时 AnkiWeb 的 59 分钟偏差是否接受
若不接受，则 `rolloverMinute` 必须限制为 0（退化为纯时区支持）。

### D. 是否计划向上游提 PR
若计划提 PR，设计应更保守：`schedTimezone` 为空时行为逐字节等同现状，
所有新逻辑走 opt-in 分支，且不改动任何现有函数的默认语义。这会影响实现风格。
