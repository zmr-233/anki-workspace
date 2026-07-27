# Handoff 03 — 工作区重构：bind mount 已删除，全部改动已提交

**日期**：2026-07-27
**本 session 完成**：环境重构（消灭 bind mount）→ 四仓库提交与 push → workspace 仓库初始化 → 完整构建验证
**状态**：**四个仓库全部干净、已提交、已 push；完整构建已验证通过；CI 尚未开工**

- 上一份交接：`docs/handoff/02-timezone-followups.md`（§3.3 功能待办仍有效）
- 操作细节见 `docs/claude/01-android-device-debugging.md`（**§1 已重写**）
- 布局说明见仓库根的 `README.md`

---

## 1. 环境重构：bind mount 没有了

### 1.1 做了什么

```
旧：01-Anki-Dev/  (物理)          03-.../anki  ← mount --bind，需 sudo，重启失效
新：01-Anki-Dev -> 03-.../anki    03-.../anki  ← 物理工作树，同时是真 submodule
```

`scripts/mount-anki.sh` **已删除**。理由与不可反向的原因写在 `README.md` 和调试手册 §1。

### 1.2 连带失效的旧知识

| 旧说法 | 现状 |
|---|---|
| 「两个 mount namespace，一切 Android 相关必须 `ssh local`」 | **过时**。gradle / `build.sh` / cargo 全部可在 CC 自己的 shell（uid 2000）跑 |
| 「`ls 03-.../anki` 是空的，正常，别修」 | **过时**。现在有内容 |
| 「重启后要跑 `mount-anki.sh`」 | **过时**。脚本已删 |
| 「别在 CC shell 里跑 adb」 | **仍然有效**，且现在是唯一需要 `ssh local` 的操作 |

根因备查：`penv-exec` phase 2 的 `mount --make-rprivate /` 剪断了 peer group，
所以宿主后建的挂载点永远送不进 penv。**没有改 `penv-exec`** —— 重构之后不需要了。
（若将来其他项目又撞上：宿主 `/` 是 `shared:1`、`/home` 是 `shared:82`，
把 `--make-rprivate` 换成 slave+shared 可以让传播单向流入，但那是改系统文件。）

### 1.3 已实测通过

| 检查 | 结果 |
|---|---|
| `git -C 03 submodule status` | ✅ 正常解析成 `anki (heads/main)`，不再报 symlink 错 |
| anki 自身 4 个 submodule | ✅ `.git` 指针是相对路径，移动后完好 |
| `cargo metadata`（penv shell） | ✅ `anki` / `anki_proto` / `anki_io` 全部解析到新路径 |
| `./gradlew :rsdroid:tasks`（penv shell） | ✅ 配置阶段打印 `Anki commit: …`，即 `cargo metadata` 读 `anki/Cargo.toml` 成功 |
| `anki/out/*` 产物 + `.cargo/config.toml` 相对路径 | ✅ 原样存活 |

### 1.4 完整构建已验证 ✅

```bash
. scripts/android-env.sh
cd 01-Anki-Dev && just check                                  # ✅ 40s
cd ../03-Anki-Android-Backend-Dev && ANDROID_ARCHS=arm64-v8a ./build.sh   # ✅ 51s
```

产物核对：`rsdroid-release.aar` 19 MB，内含且**仅含**
`jni/arm64-v8a/librsdroid.so`（43.5 MB，ELF aarch64，NDK r29 构建）；
生成的 `anki/config/Preferences.java` + `PreferencesKt.kt` 含新的时区字段；
protobuf 版本地雷复检（`throwCannotGetNumberOfUnrecognized`）为 **0**。

`just check` 的成绩：Rust ✅、Python **82 passed + 2 skipped**、TS **51 passed**、
minilints ✅。

**迁移代价比预想小得多**，原因见调试手册 §1.2：ninja 的 `builddir` 走 symlink 仍解析、
03 的 cargo target 因为 bind mount 本来报告的就是挂载点路径而字面不变，
只有 anki 自己那层重编了约 90 个 crate。

---

## 2. 提交状态：全部已提交并已 push ✅

| 仓库 | remote | HEAD |
|---|---|---|
| `03-.../anki`（原 01） | `zmr-233/anki-dev` | `baf44f633` |
| `02-AnkiDroid-Dev` | `zmr-233/ankidroid-dev` | `372ecbc` |
| `03-Anki-Android-Backend-Dev` | `zmr-233/ankidroid-backend-dev` | `049948a` |
| workspace（新） | `zmr-233/anki-workspace` | `6db66d2` |

push 顺序是自底向上（anki → 03 → 02 → workspace），否则 gitlink 会悬空。
推完逐层核对过 `git ls-remote`，三层 gitlink 都与远端 `main` 一致 ——
`git clone --recurse-submodules` 和将来的 CI 都能解析。

**URL 协议是分离的**：`.gitmodules` 里是 `https://`（给 CI 匿名克隆），
本地 `.git/config` 用 `git config submodule.<name>.url git@github.com:…` 覆盖成 ssh。
嵌套那层（`03/.git/config` 的 `anki`）也已设 —— 它原先还指着已不存在的 `01-Anki-Dev` 路径。

AnkiDroid 的 `AI_POLICY.md` 要求 commit 带 `Assisted-by:` trailer，02 的三个 commit 已遵守。

---

## 3. `minilints`：交接 02 的诊断是错的 ⚠️

交接 02 §3.2 说「你的 git 邮箱不在 `CONTRIBUTORS` 里」。**不对。**
`tools/minilints/src/main.rs:138-151` 的真实逻辑：

```rust
last_author      = git log -1 --pretty=%ae              // HEAD 的作者
all_contributors = git log --pretty=%ae CONTRIBUTORS    // 「改过 CONTRIBUTORS 这个文件的人」
```

**它不读 CONTRIBUTORS 的文件内容**，只看「HEAD 作者有没有提交过对该文件的修改」。
当时 HEAD 是上游 commit `e10ce1518`，作者 `gh@siid.sh` —— 报错点名的是**上游作者**，
不是你。（`gh@siid.sh` 其实就在 CONTRIBUTORS 文件里，这也是当时该往下追一层的信号。）

现在 HEAD 是你的 commit，所以报错会变成 `zmr_233@outlook.com NOT found in list`。

**已解决**：`cbd4ea0b0 chore: add zmr233 to CONTRIBUTORS` 已提交并推送。
用户明确同意该文件开头的 BSD-3 声明（"By adding your name to this file, you assert
that any code you contribute to the Anki project is licensed under the BSD 3 clause
license."）。此后所有 commit 自动通过 `check_contributors`，本轮 `just check` 已实证。

### 3.1 被它盖住的第二处 minilints 失败 ⚠️

contributors 修好之后，`just check` **仍然红**，露出了原先被挡住的第二处：

```
cargo/licenses.json is out of date; run ./ninja fix:minilints
```

时区功能往 `Cargo.toml` 加了 `chrono-tz`，但没重新生成许可证清单。
交接 02 说的"仅 minilints 失败"其实是**两处**失败，前一处把后一处盖住了。

修法（CLAUDE.md 要求走 just，别直接调 `./ninja`）：

```bash
just fix-minilints      # 会自动装 cargo-deny，首次约 100s
```

结果：`cargo/licenses.json` 新增 `chrono-tz` + `phf` + `phf_shared` 三项，
`cargo-deny` 报 `advisories ok, bans ok, licenses ok, sources ok`。
已提交为 `baf44f633`。

**教训**：以后凡是动 `Cargo.toml` 的依赖，记得跟一次 `just fix-minilints`。

---

## 4. workspace 仓库

拓扑 (b)：`01-Anki-Dev` 是 symlink（`120000`），02/03 是 submodule，anki 是 03 的
submodule —— **指向 anki 的 gitlink 只有一处**，不可能不一致。

已 gitignore：`env.secret`（AnkiWeb 明文账密）、`TEMP/`。
**`env.secret` 从第一个 commit 起就不在库里**，无需洗历史。

remote：`git@github.com:zmr-233/anki-workspace.git`。

---

## 5. 待办

### 5.1 本轮遗留

**没有。** 环境重构、四仓库提交与 push、CONTRIBUTORS、完整构建验证都已完成。
下一轮从 §5.2（CI）或 §5.4（功能）开工皆可。

### 5.2 CI（本轮明确不做）

分析结论备查，下次开工直接用：

- 依赖链串行三段 → job 形状：`build-desktop(01)` → `build-rsdroid(03)` → `build-ankidroid(02)`，
  另有 `publish-aur`(needs 01) 和汇总的 `release`
- **磁盘是首要风险，但风险在产物不在 checkout**：
  `git clone --recurse-submodules --depth 1 --shallow-submodules` 实测只有 **159 MB**；
  撑爆盘的是构建产物 —— 本地 `out/` 8.5G + `target/` 3.6G。GH 标准 runner 空闲约 14G，
  仍需先删 runner 预装的 SDK 或用大 runner，但不必为 checkout 发愁
- **仓库是公开的，CI 不需要 PAT**：已用清空凭据的环境（`GIT_SSH_COMMAND=/bin/false`
  `GIT_TERMINAL_PROMPT=0`）实测匿名 https 递归克隆成功，一路解析到 anki 自己的
  4 个 submodule。克隆出来的树里 `01-Anki-Dev` symlink 正确还原、
  `03/anki/rslib/Cargo.toml` 存在、`env.secret` 不在库中
- 日常只建 `arm64-v8a`（已有 `ANDROID_ARCHS`），打 tag 才建 4 ABI + `RELEASE=1`
- **AUR 不托管构建产物**，只托管 PKGBUILD。04 的 action 是「生成 PKGBUILD →
  push 到 `ssh://aur@aur.archlinux.org/…`」，需要 AUR SSH deploy key 进 secrets。
  包名要避开已有的 `anki` / `anki-bin`
- `02` 没有 submodule，靠 `local_backend_path` 找同级的 03 —— 这条**只有 workspace
  一起 checkout 时才成立**，正是 workspace 仓库存在的理由之一

### 5.3 分支策略（尚未决定）

同时要做「提 upstream PR」和「维护时区特化发行版」，两者对分支要求不同。
建议 fork 里分开 `pr/timezone`（干净 rebase 在 upstream main 上）和 `dist/tz`（长期，CI 出 release）。
**目前四个仓库全在 `main` 上**，还没分叉，随时可以改。

### 5.4 功能层面

见交接 02 §3.3，**一项都没动**。最高优先仍是「时区选择器 600 项无搜索」（唯一的实测可用性问题）
和「AnkiDroid 侧 0 个测试」（提 PR 必须）。
