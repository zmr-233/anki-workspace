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

**构建实测**：`just check` 40s 全绿（Rust / Python 82 passed + 2 skipped / TS 51 passed / minilints）；
`ANDROID_ARCHS=arm64-v8a ./build.sh` 51s 产出 19 MB AAR，
内含且仅含 `jni/arm64-v8a/librsdroid.so`（ELF aarch64，NDK r29）。

**CI 前提已验证**：匿名 https 递归克隆成功（浅递归 159 MB），仓库公开，CI 不需要 PAT。

---

## 2. 桌面发行：AUR `anki-plus-bin`

打包目录 `04-Anki-Dev-PKGBUILD/`（**普通目录，不是 submodule**），细节见其 README。
**已在本机构建、打包、安装、验证通过**：

- `RELEASE=2 just wheels` 173s 产出 `anki-26.5-cp310-abi3-manylinux_2_35_x86_64.whl`（11 MB）
  与 `aqt-26.5-py3-none-any.whl`（4.4 MB）
- tarball 16 MB → `anki-plus-bin-26.05.1-1-x86_64.pkg.tar.zst`，装完 52 MB
- `namcap` 对 PKGBUILD 和成品包都干净
- 功能验证：宿主时区在 `America/Los_Angeles` / `Asia/Shanghai` / `Pacific/Kiritimati` /
  `Europe/London` 之间切换，`next_day_at` 恒为 `1785184200`（= 上海次日 04:30），
  `localOffset = -480`（钉住时区的偏移，非宿主的）

包形态之所以能这么轻，是因为产物本身适合预编译分发：

| 性质 | 出处 | 后果 |
|---|---|---|
| pyo3 `abi3` + `abi3-py39` | `Cargo.toml:112` | Arch 升 python 小版本不打断 `.so` |
| Linux 上强制 `rustls` | `build/configure/src/rust.rs:138` | 不链 OpenSSL |
| sqlite / zstd 静态链入 | 不设 `*_USE_PKG_CONFIG` | `ldd` 只有 libc / libm / libgcc_s |
| `manylinux_2_35_aarch64` | `build/configure/src/python.rs:163` | arm64 上游已支持，要做时不用自己发明 |

版本号是 `<上游版本>.<plus 序号>`，本次 `26.05.1`。`ankiver`（26.05）与
`wheelver`（26.5，PEP 440 归一化）不相等，PKGBUILD 两个都要用，
所以由 tarball 里的 `VERSION` 自述，不靠猜。

### 与 Arch 官方 `extra/anki` PKGBUILD 的差异（已逐条核实）

那份 PKGBUILD 写给 26.05 **tag**，而 fork 在 26.05 **之后的 main**（base `f13c15aef`）：

- `qt/launcher/lin/` 已不存在，桌面资源搬到
  `qt/installer/linux-template/{{ cookiecutter.format }}/{{ cookiecutter.app_name }}/`
  （目录名带 cookiecutter 花括号，文件内容是字面量，可直接装）
- 依赖漂移：新增 `truststore` / `packaging` / `typing_extensions` / `asgiref`（`flask[async]` 的 extra），
  `flask-cors` 上游已不再引用（全树 grep 无命中）；`urllib3` 被 `anki/httpclient.py` 直接 import
- 那 5 个 patch（`no-update` / `strip-*` / `no-corepack` / `reproducible-sveltekit`）
  **仍能干净 apply**。`-bin` 用不上，但将来若要做源码包可直接复用

---

## 3. 待办

### 3.1 发 release（唯一的即时阻塞）

`TEMP/anki-plus-bin-26.05.1-x86_64.tar.zst` 已就绪，sha256
`28b030ff71b2d0347a9472311dd5d00596626b04a0fd1dc466914d14d19b82a5`。
PKGBUILD 的 `source` 指向本仓库的 release `v26.05.1`，**该 release 还没建**。

本机 `gh` 登录的是 `Paradox-Craft`，对 `zmr-233/anki-workspace` 只有读权限
（`{"push":false}`），所以 release 得由用户建，或换账号登录 `gh`。

### 3.2 CI（尚未开工）

```
build-desktop(anki) → 打 tarball → release      ← 这条已手工跑通，照抄即可
build-rsdroid(03)   → build-ankidroid(02) → release
release 完成         → publish-aur（04 的 publish_script.sh）
```

- 桌面这条**不需要 Arch 容器**：anki 自带的 ninja 会自己拉 node/yarn/protoc/uv，
  `ubuntu-24.04` 上 `RELEASE=2 just wheels` 就够。产物 abi3 + 静态链接，装到 Arch 上没问题
- 磁盘风险在产物不在 checkout：本地 `out/` 11 G。GH 标准 runner 空闲约 14 G，
  需先删预装 SDK 或用大 runner
- AUR 推送要把 AUR SSH deploy key 放进 secrets
- `02` 靠 `local_backend_path` 找同级的 `03`，**只有 workspace 一起 checkout 时才成立**

### 3.3 分支策略（尚未决定）

同时要做「向 upstream 提 PR」和「维护 plus 发行版」：PR 要干净地 rebase 在 upstream main 上，
发行版要长期分支。**目前四个仓库全在 `main`**。既然包名定为 `anki-plus`（后续还会加时区以外
的功能），fork 里建议分成 `dist/plus` 长期分支 + 每个特性一条 `pr/*`。

### 3.4 功能缺口

| 项 | 说明 | 优先级 |
|---|---|---|
| **时区选择器难用** | `ZoneId.getAvailableZoneIds()` 全量约 600 项、无搜索框，桌面侧同样是全量下拉 | **高**（唯一的实测可用性问题） |
| **AnkiDroid 侧无测试** | `setDayOffsetMinute()` / `setSchedulingTimezone()` 挂着 `@NeedsTest` 但没写 | **高**（提 PR 必须） |
| 字符串只有英文 | 新增的 3 条 AnkiDroid 字符串未翻译 | 中 |
| 首次启用的 ±1 天跳变无提示 | 见设计文档 §4 | 中 |

### 3.5 可单独上游的改动

`03/build_rust` 的 `ANDROID_ARCHS` 与时区功能无关，可单独提 upstream PR。

---

## 4. 一个未解的旁支发现

桌面 pylib 对**真实 AnkiWeb** 做全量下载时失败：

```
SyncError: HttpError { code: 400, context: "missing original size" }
```

来自 `rslib/src/sync/http_client/io_monitor.rs` —— 客户端要求响应带 `anki-original-size` 头，
AnkiWeb 的下载响应没有。**已确认与时区改动无关**（diff 在 `rslib/src/sync/` 下只动了
`collection/tests.rs`）。增量同步和手机端全量上传都正常。

---

## 5. 环境注意

- `env.secret` 里的 AnkiWeb 测试账号存着 TZ Test 集合（非真实数据），
  `schedTimezone=Asia/Shanghai` + `rolloverMinute=30`
- 真机装着 `com.ichi2.anki.debug`，时区已恢复 Asia/Shanghai、自动时区已重新打开
- 复现测试数据的脚本**还没固化**，关键点记在调试手册 §7。
  建议下次固化成 `scripts/make-tz-test-collection.py`
