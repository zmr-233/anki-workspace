# 当前状态与待办

**更新于** 2026-07-27。这是**唯一**一份 handoff，状态变了就重写本文，不要追加 `02-`。

---

## 1. 现状：全绿

时区功能已实现、真机验收通过、四个仓库全部提交并推送。设计与验收结果见
`docs/design/01-timezone.md`；构建与调试操作见 `docs/claude/01-android-device-debugging.md`。

| 仓库 | remote | HEAD |
|---|---|---|
| `03-…/anki`（= `01-Anki-Dev`） | `zmr-233/anki-dev` | `baf44f633` |
| `02-AnkiDroid-Dev` | `zmr-233/ankidroid-dev` | `372ecbc` |
| `03-Anki-Android-Backend-Dev` | `zmr-233/ankidroid-backend-dev` | `049948a` |
| workspace | `zmr-233/anki-workspace` | 见 `git log` |

四个仓库均无未提交、无未推送。三层 gitlink 与远端 `main` 一致。

**构建实测**：`just check` 40s 全绿（Rust / Python 82 passed + 2 skipped / TS 51 passed / minilints）；
`ANDROID_ARCHS=arm64-v8a ./build.sh` 51s 产出 19 MB AAR，
内含且仅含 `jni/arm64-v8a/librsdroid.so`（ELF aarch64，NDK r29），
生成的 protobuf 带新时区字段，`throwCannotGetNumberOfUnrecognized` 复检为 0。

**CI 前提已验证**：用清空凭据的环境（`GIT_SSH_COMMAND=/bin/false` `GIT_TERMINAL_PROMPT=0`）
匿名 https 递归克隆成功，一路解析到 anki 自己的 4 个 submodule。
**仓库是公开的，CI 不需要 PAT。**

---

## 2. 待办

### 2.1 CI（尚未开工，分析已就绪）

依赖链串行三段，决定 job 形状：

```
build-desktop(anki)  →  build-rsdroid(03)  →  build-ankidroid(02)
publish-aur(needs anki)                       release(needs all)
```

- **磁盘风险在产物不在 checkout**：浅递归克隆实测 **159 MB**；撑爆盘的是构建产物
  （本地 `out/` 8.5G + `target/` 3.6G）。GH 标准 runner 空闲约 14G，
  需先删 runner 预装的 SDK 或用大 runner，但不必为 checkout 发愁
- 日常只建 `arm64-v8a`，打 tag 才建 4 ABI + `RELEASE=1`
- **AUR 不托管构建产物，只托管 PKGBUILD**。`04-Anki-AUR` 的 action 形状是
  「生成 PKGBUILD（`pkgver` + `source` 指向 release tarball + `sha256sums`）→
  push 到 `ssh://aur@aur.archlinux.org/…`」，需要 AUR SSH deploy key 进 secrets。
  包名要避开已有的 `anki` / `anki-bin`
- `02` 没有 submodule，靠 `local_backend_path` 找同级的 `03` —— 这条**只有 workspace
  一起 checkout 时才成立**，正是 workspace 仓库存在的理由之一

建议分阶段落地，别一次五个 job 全上：先 `build-desktop`(Linux) → AUR → AAR(arm64) → APK。

### 2.2 分支策略（尚未决定）

同时要做「向 upstream 提 PR」和「维护时区特化发行版」，两者对分支要求不同：
PR 要干净地 rebase 在 upstream main 上，发行版要长期分支。
建议 fork 里分开 `pr/timezone` 和 `dist/tz`。**目前四个仓库全在 `main`**，随时可改。

### 2.3 功能缺口

| 项 | 说明 | 优先级 |
|---|---|---|
| **时区选择器难用** | `ZoneId.getAvailableZoneIds()` 全量约 600 项、无搜索框。桌面侧同样是全量下拉。考虑加搜索，或把 `ZoneId.systemDefault()` / 常用区置顶 | **高**（唯一的实测可用性问题，用户真机反馈） |
| **AnkiDroid 侧无测试** | `setDayOffsetMinute()` / `setSchedulingTimezone()` 挂着 `@NeedsTest` 但没写。rslib 侧有 11 个测试，Kotlin 侧 0 个 | **高**（提 PR 必须） |
| 字符串只有英文 | 新增的 3 条 AnkiDroid 字符串未翻译 | 中 |
| 首次启用的 ±1 天跳变无提示 | 见设计文档 §4，仍没做 UI 确认弹窗 | 中 |

### 2.4 可单独上游的改动

`03/build_rust` 的 `ANDROID_ARCHS` 与时区功能无关，可单独提 upstream PR。

---

## 3. 一个未解的旁支发现

桌面 pylib 对**真实 AnkiWeb** 做全量下载时失败：

```
SyncError: HttpError { code: 400, context: "missing original size" }
```

来自 `rslib/src/sync/http_client/io_monitor.rs` —— 客户端要求响应带 `anki-original-size` 头，
AnkiWeb 的下载响应没有。

**已确认与时区改动无关**：diff 在 `rslib/src/sync/` 下只动了 `collection/tests.rs`。
增量同步和手机端全量上传都正常。未进一步排查是 26.05 客户端与 AnkiWeb 的既有不兼容，
还是脚本调用姿势问题（已按 `qt/aqt/sync.py` 的 `close_for_full_sync()` 顺序试过，仍失败）。

---

## 4. 环境注意

- `env.secret` 里的 AnkiWeb 测试账号目前存着 TZ Test 集合（非真实数据），
  `schedTimezone=Asia/Shanghai` + `rolloverMinute=30`
- 真机装着 `com.ichi2.anki.debug`，时区已恢复 Asia/Shanghai、自动时区已重新打开
- 复现测试数据的脚本**还没固化**。要重跑真机验收需重新生成 `crt` 回拨的 collection，
  关键点记在调试手册 §7。**建议下次固化成 `scripts/make-tz-test-collection.py`**
