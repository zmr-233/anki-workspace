# Handoff 01 — Anki/AnkiDroid 完整时区支持

> ⚠️ **已被 `02-timezone-followups.md` 取代。** 第 5 节的操作序列已全部执行完毕，
> 真机验收通过。本文仅供追溯当时的判断与预期；**当前状态与待办以 02 为准**，
> Android 构建与真机调试的操作细节见 `../claude/01-android-device-debugging.md`。

**日期**：2026-07-27
**上一 session 完成**：桌面侧（01-Anki-Dev）实现 + 验证；AnkiDroid 侧代码编写；Android 构建环境搭建
**下一 session 要做**：构建 rsdroid AAR → 构建 AnkiDroid → 真机验证

设计与分析全文见 `../design/01-TIMEZONE-DESIGN.md`（**先读它**，本文只讲状态与操作）。

---

## 0. 一句话背景

Anki 用**设备 OS 时区**判定"今天"，且日界只能设整点。多设备跨时区会导致 due 判定、每日上限、
埋葬、revlog 语义、FSRS 分桶全线错乱。本次改造引入两个 collection config：
`schedTimezone`（IANA 名）+ `rolloverMinute`，让整个 collection 用统一的调度时区和分钟级日界，
且**保持 AnkiWeb 同步可用**。

---

## 1. 环境：三个非常重要的坑

### 1.1 两个 mount namespace ⚠️

CC session 跑在用户 `penv` 下，`ssh local` 是用户 `zmr233`，**两者 mount namespace 不同**。

| 操作 | 在哪跑 |
|---|---|
| 编辑文件、`01-Anki-Dev` 的 `just` 构建/测试 | CC 自己的 shell（penv）✅ |
| **一切 Android 相关**（gradle、`./build.sh`、adb） | **必须 `ssh local`** |

原因：`03-Anki-Android-Backend-Dev/anki` 是一个 bind mount，**只在 zmr233 的 namespace 里可见**。
在 CC 自己的 shell 里 `ls 03-Anki-Android-Backend-Dev/anki` 会是空的 —— 这是正常的，不要试图"修复"。

### 1.2 `ssh local` 每次都从 `$HOME` 开始

每个 `ssh local '...'` 是全新会话，工作目录是 `/home/zmr233`。**命令里必须显式 `cd`**，
否则会出现 `fatal: cannot change to 'anki'` 这类看起来像 mount 坏掉的假象（我踩过 3 次）。

标准调用形式：

```bash
ssh local 'set -e; . /home/zmr233/01_Projects/15_Tools/12-Anki-Workspace/scripts/android-env.sh; cd $WORKSPACE/03-Anki-Android-Backend-Dev; <命令>'
```

### 1.3 adb 服务器归属

`/dev/bus/usb/...` 的 ACL 授权给 `zmr233`。若在 penv 侧跑过 `adb`，会抢占 5037 端口并让
zmr233 侧看不到设备。**不要在 CC 自己的 shell 里跑 adb**。若已经跑了：

```bash
ssh local 'adb kill-server; adb start-server; adb devices -l'
```

---

## 2. 环境已就绪清单

| 项 | 状态 |
|---|---|
| Rust targets | ✅ `aarch64-linux-android` `armv7-linux-androideabi` `x86_64-linux-android` `i686-linux-android` |
| Android SDK | ✅ `~/Android/Sdk`（platforms 34/35/36.1，build-tools 34~37） |
| **NDK 29.0.14206865** | ✅ 本次新装（03 的 `libs.versions.toml` 要求；原本只有 27.0.12077973） |
| cmdline-tools | ✅ 本次新装 `android-sdk-cmdline-tools-latest` 22.0 → `/opt/android-sdk/cmdline-tools/latest/bin` |
| JDK | ✅ 用 **21.0.6-amzn**（sdkman）。shell 默认是 23，比 AGP 8.13.2/9.0.1 验证过的版本新，已在 env 脚本里 pin 到 21 |
| `toml-cli` | ✅ `cargo install toml-cli`（`set-android-ndk-home.sh` 需要） |
| ninja | ✅ `/usr/bin/ninja`（n2 未装，非必需） |
| protoc | ✅ `/usr/bin/protoc`（libprotoc 35.1），env 脚本导出 `PROTOC` |
| **真机** | ✅ Oppo Find N6 已授权：`3B163A00VKK00000  device` / PLP110 / Android 16 / SDK 36 / **arm64-v8a** |
| bind mount | ✅ 已建立（**重启后失效**，见 2.1） |
| Gradle wrapper | ✅ 已实跑：03 的 Gradle **9.5.1** 在 **JVM 21.0.6** 下正常启动（02 用 9.6.0，未单独试） |
| cargo 解析 | ✅ 03 的 `cargo metadata` 通过，path 依赖经 bind mount 正确指到 `01-Anki-Dev/rslib`，且能看到本次改动 |

### 2.1 重启后必做

```bash
ssh local '/home/zmr233/01_Projects/15_Tools/12-Anki-Workspace/scripts/mount-anki.sh'
```

**没有**写进 `/etc/fstab` —— 那是影响启动的系统文件，留给你决定。

### 2.2 新增的辅助文件

| 文件 | 作用 |
|---|---|
| `scripts/android-env.sh` | 导出 `ANDROID_HOME` / `ANDROID_NDK_HOME` / `JAVA_HOME`(21) / `PROTOC` / PATH。用 `ANDROID_ENV_VERBOSE=1` 可打印确认 |
| `scripts/mount-anki.sh` | 幂等地重建 bind mount |
| `02-AnkiDroid-Dev/local.properties` | `sdk.dir` + `local_backend=true` + `local_backend_path=03-Anki-Android-Backend-Dev`（均已 gitignore） |
| `03-Anki-Android-Backend-Dev/local.properties` | `sdk.dir` |

---

## 3. submodule 接线（已按"公有 URL + 本地覆盖"配置好）

`03-Anki-Android-Backend-Dev/.gitmodules` 里是**公有 URL**（会提交）：

```ini
[submodule "anki"]
	path = anki
	url = https://github.com/zmr-233/anki-dev.git
	branch = main
```

本地覆盖（只在 `.git/config`，不会提交）：

```bash
git config submodule.anki.url /home/zmr233/01_Projects/15_Tools/12-Anki-Workspace/01-Anki-Dev
```

**但实际生效的是 bind mount，不是 submodule**。原因：

- `rslib-bridge/Cargo.toml` 用 path 依赖 `../anki/rslib`，bind mount 让后端直接编译**未提交的工作树**，
  改一行不用 commit + push 再 pull
- 符号链接不行：git 直接报 `expected submodule path 'anki' not to be a symbolic link`，
  03 里所有 git 命令都会挂
- 上游 pin 的 commit `e64c6b1ae` **不存在于 `zmr-233/anki-dev`**，所以
  `git submodule update --init` 无论如何都会失败

⚠️ **不要**在 03 里跑 `git submodule update --init`，会和 bind mount 打架。

---

## 4. 代码状态

### 4.1 `01-Anki-Dev` — 已完成，已验证，**未提交**

14 个文件，+457/−26。核心是 `rslib/src/scheduler/mod.rs:90` 的
`local_utc_offset_for_user()` 现在优先解析 `schedTimezone`。

验证：

| 命令 | 结果 |
|---|---|
| `just fmt` | ✅ |
| `just lint` | ✅ clippy `-Dwarnings` / mypy 300 文件 / ruff / eslint / svelte / typescript |
| `just test` | ✅ Rust **561**、Python **82 passed + 2 skipped**、TS **51** |
| `just check` | ⚠️ 仅 `minilints` 失败 —— 见 4.3 |

新增 11 个 Rust 测试，其中最关键的一个在 `rslib/src/sync/collection/tests.rs`：
两个新 config key 通过**参考同步服务器往返存活**，且设置后仍是 `NormalSyncRequired`（不触发 full sync）。
这把"AnkiWeb 兼容"从分析变成了通过的测试。

### 4.2 `02-AnkiDroid-Dev` / `03-...-Backend-Dev` — 已写，**从未编译过**

8 个文件，+148/−9（02）；`.gitmodules`（03）。

上一 session 没有 Android SDK/NDK，**这些 Kotlin/Gradle 改动一行都没编译验证过**。
预期会有编译错误，尤其是：

- `ReviewingSettingsFragment.kt` 里 `ListPreference.entries`/`entryValues` 的
  `Array<String>` → `Array<CharSequence>` 平台类型赋值
- `CollectionPreferences.kt` 用了 `scheduling.rolloverMinute` / `scheduling.schedTimezone`，
  **依赖新 AAR 里重新生成的 protobuf**，AAR 没建之前必然报 unresolved reference

### 4.3 `minilints` 阻塞（需要你决定）

```
Author gh, at the domain siid.sh NOT found in list
```

你的 git 邮箱不在 `01-Anki-Dev/CONTRIBUTORS` 里。这是仓库既有状态、与本次改动无关，
但它让 ninja 在 19/33 处提前停止，所以 `just check` 永远红。
既然定了要提 upstream PR，这一项迟早要补。**上一 session 没有代改这个文件。**

---

## 5. 下一步操作序列

### Step 1 — 建 rsdroid AAR（最可能出问题的一步）

```bash
ssh local 'set -e; . /home/zmr233/01_Projects/15_Tools/12-Anki-Workspace/scripts/android-env.sh; cd $WORKSPACE/03-Anki-Android-Backend-Dev; ./build.sh'
```

`build.sh` = `. ./set-android-ndk-home.sh` + `cargo run -p build_rust`。
注意 `set-android-ndk-home.sh` 会自己 `cargo install toml-cli`（已装）并检查
`$ANDROID_HOME/ndk/29.0.14206865` 存在（已装）。

这一步会为 4 个 Android 架构交叉编译整个 rslib（含我们新加的 `chrono-tz`）。
**首次会很久**。真机是 arm64-v8a，若只想快速验证可以考虑只建该架构。

产物应出现在：
- `rsdroid/build/outputs/aar/rsdroid-release.aar`
- `rsdroid-testing/build/libs/rsdroid-testing.jar`

### Step 2 — 建 AnkiDroid 并修编译漂移

```bash
ssh local 'set -e; . /home/zmr233/01_Projects/15_Tools/12-Anki-Workspace/scripts/android-env.sh; cd $WORKSPACE/02-AnkiDroid-Dev; ./gradlew :AnkiDroid:assembleDebug'
```

预期两类错误：
1. **本次改动自身**的 Kotlin 错误（见 4.2）
2. **版本漂移**：AnkiDroid 的 `libs.versions.toml:73` 原本 pin
   `ankiBackend = '0.1.64-anki25.09.2'`，而我们的后端基于 **anki 26.05**。
   `local_backend=true` 时版本目录被绕过，但 Kotlin 代码是按 25.09.2 的 proto 写的，
   可能有 API 差异需要修。

### Step 3 — 装到真机并验证

```bash
ssh local '. .../scripts/android-env.sh; cd $WORKSPACE/02-AnkiDroid-Dev; ./gradlew :AnkiDroid:installDebug'
```

真机验证清单：

1. 设置 → 复习 → 出现"Scheduling timezone"和"Start of next day (minutes)"
2. 设 `schedTimezone = Asia/Shanghai`、rollover 4:30
3. **改手机系统时区**到别的区 → 卡片到期数、`dayCutoff` **不应变化**（这是整个改造的核心验收点）
4. 与桌面 Anki 同步 → 设置能往返，且不触发 full sync
5. 登录 AnkiWeb 同步一次，确认账号同步正常（第 2 节 TIMEZONE-DESIGN.md 的结论）

### Step 4 — 提交

01-Anki-Dev 的改动仍未提交。提交后若要让 03 走真 submodule 而非 bind mount，
需要 push 到 `zmr-233/anki-dev` 并把 gitlink 移过去 —— 但只要还在迭代，**保持 bind mount 更方便**。

---

## 6. 已知遗留

| 项 | 说明 |
|---|---|
| AnkiWeb 分钟精度 | AnkiWeb 不认识 `rolloverMinute`，其日界永远在整点。t0 非整点时网页版最多差 59 分钟。**你已确认接受** |
| 首次启用的一次性跳变 | 若时区 C 与设备时区的日历日不同，`days_elapsed` 会一次性 ±1，用户会看到"今天"卡片数跳变一次。目前只写进文档，**没有做 UI 提示** —— 要不要在保存时弹确认待定 |
| `BootService` legacy 通知 | 该路径用设备时区构造 Calendar，pin 了调度时区后会不一致。已加注释。`DayRolloverAlarm` 走后端 `dayCutoff`，不受影响 |
| `creationOffset` | 按决策 B **不动**。改它会让所有历史 `card.due` 天号整体平移 |
