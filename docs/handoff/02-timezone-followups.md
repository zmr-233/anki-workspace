# Handoff 02 — 时区支持：真机验收已通过，后续待办

> ⚠️ **已被 `03-workspace-restructure.md` 取代。** §3.1（提交）已全部完成；
> §3.2（`minilints`）的**诊断是错的**，正确分析见 03；§4（环境现状）里
> "bind mount 重启失效"已不再成立 —— bind mount 已删除。
> **功能层面的待办 §3.3 仍然有效**，尚未开工。

**日期**：2026-07-27
**本 session 完成**：rsdroid AAR 构建 → AnkiDroid 构建（修 1 处漂移）→ Oppo Find N6 真机验收 → AnkiWeb 同步验证
**状态**：**功能已在真机跑通并验证，全部改动仍未提交**

- 设计与分析：`docs/design/01-TIMEZONE-DESIGN.md`
- 上一份交接（环境搭建、代码编写）：`docs/handoff/01-timezone-support.md`（其"下一步操作序列"已全部执行完，仅供追溯）
- **Android 构建/真机调试的操作细节全部移到 `docs/claude/01-android-device-debugging.md`**，
  本文不再重复。下一个 session **动 Android 之前先读那篇**。

---

## 1. 验收结果

测试数据是一副 `crt` 回拨 30 天的 collection：3 张逾期 + 5 张今日到期 + 7 张明日到期，
所以"今天"的到期数 = **8**；日号 −1 → 3；日号 +1 → 15。

### 1.1 真机（Oppo Find N6，Android 16）

| # | 场景 | 设备时区 | `schedTimezone` | 待复习 | 结论 |
|---|---|---|---|---|---|
| 1 | 基线 | Asia/Shanghai | 未设置 | **8** | 推入的集合正确加载，arm64 后端可用 |
| 2 | **对照组** | America/Los_Angeles | 未设置 | **3** | ⚠️ 复现了本项目要修的 bug；也证明该测试对时区敏感 |
| 3 | **核心验收** | America/Los_Angeles | `Asia/Shanghai` + 4:30 | **8** | ✅ 设备时区不再影响日界 |
| 4 | 恢复 | Asia/Shanghai | `Asia/Shanghai` + 4:30 | **8** | ✅ |

场景 2 → 3 是**在设备时区保持洛杉矶不变**的情况下，仅通过应用内新设置项完成的，
数字当场从 3 回到 8。

从设备拉回的 collection（含 WAL）经核对：`rolloverMinute = 30`、
`schedTimezone = "Asia/Shanghai"`、`localOffset = -480`（钉住时区的偏移，
而非洛杉矶的 +420）—— 即 AnkiWeb 镜像逻辑生效。

同一份设备 collection 在桌面用 pylib 跨 `America/Los_Angeles` / `Asia/Shanghai` /
`Pacific/Kiritimati` (UTC+14) / `Pacific/Midway` (UTC−11) / `Europe/London` /
`Australia/Sydney` 六个宿主时区计算，`today=30`、`due=8` 全部一致。

### 1.2 AnkiWeb（真实服务器，非参考实现）

用 `env.secret` 里的专用空账号。

| 检查 | 结果 |
|---|---|
| 手机首次上传（全量） | ✅ 成功 |
| 带两个新 key 的集合 `sync_status` | ✅ `NO_CHANGES` —— **没有触发全量同步**，验证设计文档 §2.2 |
| 桌面改成 `Europe/Berlin` + 45 并上传 | ✅ 普通同步；`localOffset` 自动变 −120（CEST，DST 正确） |
| 手机同步后设置项显示 | ✅ `Europe/Berlin` / `45` —— **两个新 key 经 AnkiWeb 完整往返** |
| 改回 `Asia/Shanghai` + 30 再往返 | ✅ 待复习回到 8 |

这把设计文档里"AnkiWeb 只当 JSON 存 config、不做 key 白名单"的**分析**，
变成了对闭源 AnkiWeb 的**实测**。

### 1.3 新 UI（由人肉眼确认）

两项都出现在「设置 → 复习」，都能正常设置。
**反馈：时区列表太长、不好找**（`ZoneId.getAvailableZoneIds()` 全量约 600 项，无搜索框）。

---

## 2. 本 session 新增/修改的文件

### 2.1 `03-Anki-Android-Backend-Dev`

| 文件 | 改动 | 性质 |
|---|---|---|
| `build_rust/src/main.rs` | 新增 `ANDROID_ARCHS` 环境变量支持（逗号分隔，接受 ABI 名或 Rust triple），`add_android_rust_targets()` 返回值改 `Vec<String>`，新增 `android_target_triple()` | **与时区功能无关的构建改进**，可单独提 upstream |
| `Cargo.lock` | 随 anki 引入 `chrono-tz` 自动更新 | 附带 |
| `.gitmodules` / `anki` gitlink | 上一 session 已改 | — |

原因：Linux 上不带 `ALL_ARCHS` 只建 x86_64（装 arm64 真机必崩），而 `ALL_ARCHS=1`
在非 macOS 上直接 panic。详见 `docs/claude/01-android-device-debugging.md` §3。

### 2.2 `02-AnkiDroid-Dev`

上一 session 的 8 个文件**编译通过、真机验证通过，无需修改**。
交接 01 §4.2 担心的 `ListPreference.entries` 平台类型赋值**不是问题**
（Java 数组在 Kotlin 里是 `Array<(out) CharSequence!>`，接受 `Array<String>`）。

本 session 新增 1 处：

| 文件 | 改动 |
|---|---|
| `libanki/.../libanki/Deck.kt:138` | `Order.toDisplayString()` 补 `RELATIVE_OVERDUENESS` 分支 → `translations.decksRelativeOverdueness()` |

这是**唯一**的 25.09.2 → 26.05 漂移：26.05 的 `decks.proto` 给
`Deck.Filtered.SearchTerm.Order` 加了 `RELATIVE_OVERDUENESS = 10`，
`when` 表达式不再穷尽。**属于"AnkiDroid 采纳 26.05 后端"的改动，不属于时区功能**，
建议拆成独立 commit / PR。

### 2.3 `scripts/android-env.sh`

**删掉了 `export PROTOC=/usr/bin/protoc`**，并写明原因。
这一行会让 rsdroid 的 Java 生成代码引用比 runtime 新的 protobuf API，
产生 51 个极具误导性的 `cannot find symbol`。**不要加回去**（详见调试手册 §2）。

### 2.4 `docs/`

- `docs/claude/01-android-device-debugging.md`（新）
- `docs/handoff/02-timezone-followups.md`（本文）

---

## 3. 待办

### 3.1 提交（**全部改动仍未提交**）

三个仓库都是脏的：

```
01-Anki-Dev   14 files  +457/−26   （已 fmt/lint/test 通过）
02-AnkiDroid-Dev  9 files          （8 staged + Deck.kt unstaged）
03-...-Backend-Dev  4 files
```

建议的 commit 切分：

| commit | 内容 |
|---|---|
| 01: feat | rslib + proto + 桌面 UI 的时区支持 |
| 02: fix | `Deck.kt` 的 `RELATIVE_OVERDUENESS`（采纳 26.05 后端） |
| 02: feat | AnkiDroid 时区 UI + `CollectionPreferences` + `BootService` |
| 02: build | `BackendDependencies.kt` / `build.gradle` 的 `local_backend_path` |
| 03: build | `build_rust` 的 `ANDROID_ARCHS` |
| 03: chore | `.gitmodules` + gitlink |

### 3.2 `minilints` 阻塞（**需要你决定，两个 session 都没代改**）

```
Author gh, at the domain siid.sh NOT found in list
```

git 邮箱不在 `01-Anki-Dev/CONTRIBUTORS` 里。仓库既有状态、与本次改动无关，
但它让 ninja 在 19/33 处提前停止，所以 `just check` 永远红。要提 upstream PR 就必须补。

### 3.3 功能层面的缺口

| 项 | 说明 | 优先级 |
|---|---|---|
| **时区选择器难用** | 用户实测反馈。600 项无搜索的 `ListPreference`。桌面侧同样是全量下拉。考虑加搜索框，或按 `ZoneId.systemDefault()` / 常用区置顶 | 高（唯一的实测可用性问题） |
| **AnkiDroid 侧无测试** | `setDayOffsetMinute()` / `setSchedulingTimezone()` 上挂着 `@NeedsTest` 但没写。rslib 侧有 11 个测试，Kotlin 侧 0 个 | 高（提 PR 必须） |
| **只建了 arm64-v8a** | 发版需 `ANDROID_ARCHS=armeabi-v7a,x86,arm64-v8a,x86_64`，且要 `RELEASE=1` | 中 |
| **字符串只有英文** | 新增的 3 条 AnkiDroid 字符串未翻译，中文机上显示英文 | 中 |
| **首次启用的一次性 ±1 天跳变无提示** | 设计文档已记录，仍**没有做 UI 确认弹窗** | 中 |
| `BootService` legacy 路径 | 用设备时区构造 Calendar，钉了调度时区后会不一致。已加注释。`DayRolloverAlarm` 走后端 `dayCutoff`，不受影响 | 低（已知取舍） |
| AnkiWeb 分钟精度 | AnkiWeb 日界永远在整点，t0 非整点时网页版最多差 59 分钟。**已确认接受** | 低 |
| `creationOffset` | 按决策 B 不动 | 低（不做） |

### 3.4 一个与本项目无关、但值得记一笔的发现

桌面 pylib 对真实 AnkiWeb 做**全量下载**时失败：

```
SyncError: HttpError { code: 400, context: "missing original size" }
```

来自 `rslib/src/sync/http_client/io_monitor.rs:128` —— 客户端要求响应带
`anki-original-size` 头，AnkiWeb 的下载响应没有。

**已确认与本次改动无关**：我们的 diff 在 `rslib/src/sync/` 下只动了
`collection/tests.rs`（加测试），没碰任何传输层代码。**增量同步和手机端全量上传都正常。**
未进一步排查是 26.05 客户端与 AnkiWeb 的既有不兼容，还是脚本调用姿势问题
（已按 `qt/aqt/sync.py` 的 `close_for_full_sync()` 顺序试过，仍失败）。

---

## 4. 环境现状

| 项 | 状态 |
|---|---|
| bind mount | ✅ 有效（**重启后失效**，跑 `scripts/mount-anki.sh`） |
| rsdroid AAR | ✅ 已构建（arm64-v8a，debug） |
| AnkiDroid APK | ✅ 已构建并安装到真机 |
| 真机 | ✅ 装着 `com.ichi2.anki.debug`，里面是 **TZ Test 测试集合**（非真实数据） |
| 真机时区 | ✅ 已恢复 Asia/Shanghai，自动时区已重新打开 |
| AnkiWeb 测试账号 | ⚠️ `env.secret` 里那个账号现在存着 TZ Test 集合，`schedTimezone=Asia/Shanghai` + `rolloverMinute=30` |

### 复现测试数据的脚本

本 session 的临时脚本写在 scratchpad 里（会随 session 清掉）。要重跑真机验收，
需要重新生成一份 `crt` 回拨的 collection —— 关键点（`days_elapsed` 钳 0、
`set_due_date` 不收负数、`deck_due_tree` 根节点已聚合）都记在
`docs/claude/01-android-device-debugging.md` §8。**建议下个 session 把它固化成
`scripts/make-tz-test-collection.py`**，别再靠 scratchpad。
