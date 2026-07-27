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

⚠️ **崩溃报告目前会发往上游的服务器**。`AcraCrashReporter.kt:168` 对非 debug 构建走
`setProductionACRAConfig`，而 `ACRA_URL` 是 `defaultConfig` 里写死的
`https://ankidroid.org/acra/report`，`HttpSenderConfigurationBuilder` 无条件 `withEnabled(true)`。
上报模式默认 `FEEDBACK_REPORT_ASK`——崩溃时弹窗，用户点「报告」就把 stack trace +
`LOGCAT` + `SHARED_PREFERENCES` PUT 到那里。上游会收到一批 versionName `26.05.2` 的报告，
而那个版本号在他们 2.x 的体系里毫无意义。修法见 3.4。

顺带一条**不是问题的差异**：`ANALYTICS_API_KEY` 在 CI 里取不到，回落到 `DUMMY_API_XXX`，
被 GA 的 ingest 拒收，所以 plus 包不发遥测。这是想要的行为。

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
| `gh secret set ANDROID_KEYSTORE_PASSWORD --env android-signing --repo zmr-233/anki-workspace` | **只能你做**，我没有这个密码。这是唯一挡着流水线跑通的东西 |
| 再跑一次 dry run 确认 `sign` 也过：`gh workflow run release.yml -f version=26.05.2` | 密码设好之后 |
| 真发版：`git tag v26.05.2 && git push origin v26.05.2` | 确认之后 |
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

### 3.3 CI 的验证程度

两个 workflow 都过 `actionlint` + `shellcheck`。六个 job 的 `run:` 脚本都在本机
**按原文**跑过一遍（从 YAML 里抽出来执行，不是照着抄一遍近似的）：`sign` 用一次性
keystore 跑完四条断言，并做了反例验证（换 key、versionName 不符都被拦下）；
`publish` 用 `gh` 桩跑通 notes 生成和 `release create` 的参数。

runner 上的实跑结果（run 30277594516，dry run，总墙钟 25m23s；desktop 和 backend 并行）：

| job | 结果 | 耗时 |
|---|---|---|
| 版本号 | ✅ | 4s |
| 桌面 wheels + tarball | ✅ 产物已下载核对：`pkgver=26.05.2` / `srcref` 对得上本地 anki HEAD | 8m34s（冷构建 wheels 7m41s） |
| rsdroid AAR | ✅ `AAR jniLibs: arm64-v8a` 断言通过 | 13m31s |
| APK | ✅ 产物已下载核对：`com.ichi2.anki.plus` / `326050200` / `26.05.2` / `Anki+` / 仅 arm64 | 11m16s |
| 重签 | ❌ 只因缺 `ANDROID_KEYSTORE_PASSWORD`（`keystore password was incorrect`）。keystore 的 base64 是好的——它已经走到验密码那一步 | — |
| 发 release / 推 AUR | ❌ dry run 不跑这两个 | — |

磁盘没成为问题：各 job 先删 dotnet / ghc / boost / swift，desktop 还删预装的
Android SDK；`03` 侧靠 `SKIP_ROBOLECTRIC=1` 省掉宿主机那份 target。

runner 上的 build-tools 是 **37.0.0**，正是下面第 3 条里改了输出措辞的那个版本。

**`publish-aur.yml` 仍未在 runner 上跑过一次**。它原来写的是 `permissions: {}`，
那样 `actions/checkout` 的 token 没有 contents 权限——它是带认证的、不会退回匿名，
公开仓库也可能 403。已改 `contents: read`，并在 `release.yml` 的 `aur` job 显式放开
（被调 workflow 的权限不能超过调用方）。要单独验：
`gh workflow run publish-aur.yml -f tag=v26.05.1`，重推同样内容是 no-op。

第一次跑出来的两个 bug 都不是配置疏忽，值得记住：

1. **`installGitHook`**——见 §5 的 `.git` 那条。本机结构性地验不出来。
2. **`yes | sdkmanager`**——我为防挂死加的，反而制造了失败：sdkmanager 许可已接受时
   不读 stdin，`yes` 吃 EPIPE 退出非零，`pipefail` 判整步失败。改成 here-string
   （有界输入，不挂死也不 broken pipe，退出码是 sdkmanager 自己的）。
3. 另有一个只在本机模拟时才发现的：`apksigner --print-certs` 的措辞在 build-tools
   36 和 37 之间变了（`Signer #1 certificate …` → `V3.0 Signer: certificate …`），
   而 job 取的是镜像里最新那个版本。已改成版本无关的匹配，并额外要求签名者唯一。

### 3.4 掐断发往上游的崩溃上报（未做）

最小改法，和 `plusVersion` 一样由构建参数驱动，不影响上游合并：

- `AnkiDroid/build.gradle`：`plusVersion` 存在时 `buildConfigField "String", "ACRA_URL", '""'`
- `AcraCrashReporter.kt`：`ACRA_URL` 为空则不挂 `HttpSender`（对话框和 toast 可以留，
  或者干脆把上报模式默认值改成 `FEEDBACK_REPORT_NEVER`）

要改 App 行为、要真机验一次崩溃路径，所以没在配 CI 的时候顺手做。

### 3.5 arm64 桌面包（未做）

PKGBUILD 已用 `$CARCH` / `source_x86_64` 预埋，上游 `build/configure/src/python.rs:163`
也已支持 `manylinux_2_35_aarch64`。要做的是给 `release.yml` 加一个
`runs-on: ubuntu-24.04-arm` 的 desktop job，并把 `prepare.py` 里写死的 `ARCH` 常量解耦。

### 3.6 分支策略（尚未决定）

同时要做「向 upstream 提 PR」和「维护 plus 发行版」：PR 要干净地 rebase 在 upstream main 上，
发行版要长期分支。**目前四个仓库全在 `main`**。既然包名定为 `anki-plus`（后续还会加时区以外
的功能），fork 里建议分成 `dist/plus` 长期分支 + 每个特性一条 `pr/*`。

### 3.7 功能缺口

| 项 | 说明 | 优先级 |
|---|---|---|
| **时区选择器难用** | `ZoneId.getAvailableZoneIds()` 全量约 600 项、无搜索框，桌面侧同样是全量下拉 | **高**（唯一的实测可用性问题） |
| **AnkiDroid 侧无测试** | `setDayOffsetMinute()` / `setSchedulingTimezone()` 挂着 `@NeedsTest` 但没写 | **高**（提 PR 必须） |
| 字符串只有英文 | 新增的 3 条 AnkiDroid 字符串未翻译 | 中 |
| 首次启用的 ±1 天跳变无提示 | 见设计文档 §4 | 中 |

### 3.8 可单独上游的改动

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

- ⚠️ **本机两个 submodule 的 `.git` 是真目录，不是 gitlink 文件**。它们当初是独立
  clone 后接进来的，而 `git clone --recurse-submodules`（CI 走的那条）产生的是**文件**。
  于是任何「把 `.git` 当目录去碰」的代码都是本机好好的、CI 必炸，而且本机怎么试都试不出来。
  `03/rsdroid/build.gradle` 的 `installGitHook` 就是这么漏到第一次 CI 才暴露的
  （`Copy` 的 `destinationDir` 落在 `.git/hooks`，`preBuild` 依赖它，等于
  `clone --recurse-submodules && ./build.sh` 从来就跑不通）。
  要在本机复现这个布局：`git worktree add` 出来的树，`.git` 同样是文件
- `env.secret` 里的 AnkiWeb 测试账号存着 TZ Test 集合（非真实数据），
  `schedTimezone=Asia/Shanghai` + `rolloverMinute=30`
- 真机装着 `com.ichi2.anki.debug`，时区已恢复 Asia/Shanghai、自动时区已重新打开。
  发行包是 `com.ichi2.anki.plus`，和它、和商店版都能并存
- 复现测试数据的脚本**还没固化**，关键点记在调试手册 §7。
  建议下次固化成 `scripts/make-tz-test-collection.py`
