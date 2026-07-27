# 当前状态与待办

**更新于** 2026-07-27。这是**唯一**一份 handoff，状态变了就重写本文，不要追加 `02-`。

---

## 1. 现状

时区功能已实现、真机验收通过、四个仓库全部提交并推送。设计与验收结果见
`docs/design/01-timezone.md`；构建与调试操作见 `docs/claude/01-android-device-debugging.md`。

| 仓库 | remote | HEAD |
|---|---|---|
| `03-…/anki`（= `01-Anki-Dev`） | `zmr-233/anki-dev` | `baf44f633` |
| `02-AnkiDroid-Dev` | `zmr-233/ankidroid-dev` | `2e40605` |
| `03-Anki-Android-Backend-Dev` | `zmr-233/ankidroid-backend-dev` | `2696561` |
| workspace | `zmr-233/anki-workspace` | 见 `git log` |

**构建实测**：`just check` 40s 全绿（Rust / Python 82 passed + 2 skipped / TS 51 passed /
minilints）；`ANDROID_ARCHS=arm64-v8a ./build.sh` 51s 产出 19 MB AAR，
内含且仅含 `jni/arm64-v8a/librsdroid.so`（ELF aarch64，NDK r29）。

**CI 前提已验证**：匿名 https 递归克隆成功（浅递归 159 MB），仓库公开，CI 不需要 PAT。

---

## 2. 发行

一个 tag → 一个 release → 桌面包 + APK。版本号 `<上游 anki 版本>.<plus 序号>`，
两个产物共用同一条版本流。流水线形状和调试方式见 `README.md` 的「发版」一节。

### 2.1 桌面：AUR `anki-plus-bin`

打包目录 `04-Anki-Dev-PKGBUILD/`（**普通目录，不是 submodule**），细节见其 README。
`26.05.1-1` 已在本机构建、打包、安装、验证，并已上线
<https://aur.archlinux.org/packages/anki-plus-bin>（commit `1ac27d0`）。

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

`ankiver`（26.05）与 `wheelver`（26.5，PEP 440 归一化）不相等，PKGBUILD 两个都要用，
所以由 tarball 里的 `VERSION` 自述，不靠猜。

**与 Arch 官方 `extra/anki` PKGBUILD 的差异**（已逐条核实）——那份写给 26.05 **tag**，
而 fork 在 26.05 **之后的 main**（base `f13c15aef`）：

- `qt/launcher/lin/` 已不存在，桌面资源搬到
  `qt/installer/linux-template/{{ cookiecutter.format }}/{{ cookiecutter.app_name }}/`
  （目录名带 cookiecutter 花括号，文件内容是字面量，可直接装）
- 依赖漂移：新增 `truststore` / `packaging` / `typing_extensions` / `asgiref`
  （`flask[async]` 的 extra），`flask-cors` 上游已不再引用（全树 grep 无命中）；
  `urllib3` 被 `anki/httpclient.py` 直接 import
- 那 5 个 patch（`no-update` / `strip-*` / `no-corepack` / `reproducible-sveltekit`）
  **仍能干净 apply**。`-bin` 用不上，但将来若要做源码包可直接复用

### 2.2 Android：APK + Obtainium

applicationId `com.ichi2.anki.plus`，只出 arm64-v8a。**已在本机构建验证**：
`assembleFullRelease` 4m20s（热缓存）通过 R8，`aapt2 dump badging` 确认
`name='com.ichi2.anki.plus'` / `application-label:'Anki+'` / `native-code:'arm64-v8a'`，
`-PplusVersion=26.05.2` 得到 `versionName='26.05.2'` / `versionCode='326050200'`
（= arm64 的 ABI 乘数 3 × 1e8 + 26050200）。

- **能和商店版并存**：manifest 里 `flashcards` / `apkgfileprovider` /
  `cropper.fileprovider` / `androidx-startup` 四个 provider authority，以及
  `READ_WRITE_DATABASE` / `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` 两个自定义权限，
  **全是 `${applicationId}` 派生的**，所以不会撞 authority 导致装不上
- 代价：第三方 App 通过写死的 `com.ichi2.anki.flashcards` 找 AnkiDroid 的 API 会找不到本包
- 用 `full` flavor（上游注释写明是发 GitHub / F-Droid 用的，无 storage / camera 限制）
- 只有 arm64 那个 split 带 `.so`；另外三个是 18 MB 的空壳，不要发出去

⚠️ **gradle 默认用的是一把公开密钥**。`AnkiDroid/build.gradle` 的 release signingConfig
在 `KEYSTOREPATH` 未设时回落到仓库里的 `tools/fallback-release-keystore.jks`
（`CN=Sahil Ahmad, OU=mru`，密码 `Test@123` 就明文写在 build.gradle 里）。
所以**未经重签的 release APK 绝对不能发**。

`sign` job 用 `apksigner sign` 整体替换签名。已实测确认：旧的 `META-INF/CERT.*` 被删掉、
`verify --print-certs` 只剩新证书、`zipalign -c -P 16 4` 仍通过——签名块插在最后一个条目
之后、中央目录之前，条目偏移不变，所以 16 K 页对齐不受影响。

发行密钥 `~/.keystores/anki-plus-release.jks`（PKCS12，RSA 4096，alias `anki-plus`，
有效期到 2053），证书 SHA-256
`5E:F6:AB:43:54:73:48:5C:77:E8:7C:BE:E6:B6:03:00:BA:32:80:96:A3:5A:AB:E3:80:BD:AD:E0:88:CB:53:3D`。
`sign` job 会断言这个指纹，secret 被换掉会在 CI 里失败，而不是等用户装不上。
**这把 key 没有吊销机制**：泄露后只能换 applicationId 重新发布，所有已装用户断掉升级路径。

### 2.3 为什么 AUR 那一步是 `workflow_call` 而不是 `release: published`

GITHUB_TOKEN 创建的 release **不会触发其他 workflow**（GitHub 的防循环规则）。
靠 `release: published` 串起来的话，release 发出去了 AUR 却永远不动，而且没有任何报错。
所以 `release.yml` 显式 `uses: ./.github/workflows/publish-aur.yml`。
`publish-aur.yml` 自己保留 release 触发器，那条路只服务手工发的 release
（`publish_script.sh` 检测到无变化会直接退出，两条路同时触发也不会重复推）。

---

## 3. 待办

### 3.1 立即待办

| 项 | 谁做 |
|---|---|
| `gh secret set ANDROID_KEYSTORE_PASSWORD --env android-signing --repo zmr-233/anki-workspace` | **只能你做**，我没有这个密码 |
| 首次 dry run：`gh workflow run release.yml -f version=26.05.2` | 密码设好之后 |
| Obtainium 订阅 `https://github.com/zmr-233/anki-workspace` | 你，首次发版之后 |

### 3.2 密钥布置

| 项 | 状态 |
|---|---|
| `~/.ssh/aur_ed25519` + `Host aur.archlinux.org` 段（`IdentitiesOnly yes`） | 已建。原 ssh config 备份为 `config.bak-20260727` |
| GH environment `aur` + secret `AUR_SSH_KEY` | 已建 |
| GH environment `android-signing` + secret `ANDROID_KEYSTORE_BASE64` | 已建 |
| secret `ANDROID_KEYSTORE_PASSWORD` | **未设**，见 3.1 |

之前 AUR 访问挂在 `main_rsa` 上，而那把 key 同时用于 GitHub + 6 台服务器 + `local`。
现已分离。**但仍未按包隔离**：AUR 的 key 只认证账号，授权按 maintainer 身份走，
所以这把 key 能推该账号维护的所有包（含 `yesplaymusic-plus`）。要压到单包，
只能另开一个 AUR 账号做 co-maintainer——AUR 没有 token / deploy key 机制
（aurweb!895 在做，未合并）。

两个 environment 目前都没有 protection rule，发版全自动、零人工介入。想让每次触碰密钥
都要人点一下，在仓库设置里给对应 environment 加 required reviewer 即可，workflow 不用改。

### 3.3 CI 里从未实跑过的部分

`release.yml` 和 `publish-aur.yml` 都过了 `actionlint` + `shellcheck`，每一步的命令也都
在本机跑通过，**但整条 workflow 一次都没在 runner 上跑过**。第一次 dry run 大概率要修
一两处。已知的不确定点：

| 不确定点 | 目前的兜底 |
|---|---|
| runner 磁盘。本机 `anki/out` 12 G（含 debug + release + release-lto 三份 rust target），干净构建单 profile 约 2.7 G；android 那条另加 `03/target` 2.3 G | 各 job 先删 dotnet / ghc / boost / swift；desktop job 还删预装的 Android SDK。`03` 侧靠 `SKIP_ROBOLECTRIC=1` 省掉宿主机那份 target |
| `publish-aur.yml` 原来是 `permissions: {}`，那样 `actions/checkout` 的 token 没有 contents 权限，即使公开仓库也可能 403。已改 `contents: read`，并在 `release.yml` 的 `aur` job 显式放开（被调 workflow 的权限不能超过调用方） | dry run 跑不到 aur，要单独 `gh workflow run publish-aur.yml -f tag=v26.05.1` 验（重推同样内容是 no-op） |
| `bsdtar` 是否预装。`make-release-tarball.sh` 用它拆 wheel 做自检 | desktop job 显式 `apt-get install libarchive-tools zstd` |
| gradle 缓存冷启动耗时。本机热缓存 4m20s，冷的没测过 | `actions/setup-java` 的 `cache: gradle` |

### 3.4 arm64 桌面包（未做）

PKGBUILD 已用 `$CARCH` / `source_x86_64` 预埋，上游 `build/configure/src/python.rs:163`
也已支持 `manylinux_2_35_aarch64`。要做的是给 `release.yml` 加一个
`runs-on: ubuntu-24.04-arm` 的 desktop job，并把 `prepare.py` 里写死的 `ARCH` 常量解耦。

### 3.5 分支策略（尚未决定）

同时要做「向 upstream 提 PR」和「维护 plus 发行版」：PR 要干净地 rebase 在 upstream main 上，
发行版要长期分支。**目前四个仓库全在 `main`**。既然包名定为 `anki-plus`（后续还会加时区以外
的功能），fork 里建议分成 `dist/plus` 长期分支 + 每个特性一条 `pr/*`。

### 3.6 功能缺口

| 项 | 说明 | 优先级 |
|---|---|---|
| **时区选择器难用** | `ZoneId.getAvailableZoneIds()` 全量约 600 项、无搜索框，桌面侧同样是全量下拉 | **高**（唯一的实测可用性问题） |
| **AnkiDroid 侧无测试** | `setDayOffsetMinute()` / `setSchedulingTimezone()` 挂着 `@NeedsTest` 但没写 | **高**（提 PR 必须） |
| 字符串只有英文 | 新增的 3 条 AnkiDroid 字符串未翻译 | 中 |
| 首次启用的 ±1 天跳变无提示 | 见设计文档 §4 | 中 |

### 3.7 可单独上游的改动

`03/build_rust` 里这两个都和时区功能无关，可各自提 upstream PR：

- `ANDROID_ARCHS`：选择要编哪些 Android 靶子
- `SKIP_ROBOLECTRIC`：只出 AAR，跳过宿主机 `.so` 和 `rsdroid-testing:build`

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
- 真机装着 `com.ichi2.anki.debug`，时区已恢复 Asia/Shanghai、自动时区已重新打开。
  发行包是 `com.ichi2.anki.plus`，和它、和商店版都能并存
- 复现测试数据的脚本**还没固化**，关键点记在调试手册 §7。
  建议下次固化成 `scripts/make-tz-test-collection.py`
