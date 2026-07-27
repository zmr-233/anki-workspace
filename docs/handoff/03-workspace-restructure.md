# Handoff 03 — 工作区重构：bind mount 已删除，全部改动已提交

**日期**：2026-07-27
**本 session 完成**：环境重构（消灭 bind mount）→ 三仓库提交 → workspace 仓库初始化
**状态**：**三个仓库全部干净且已提交；均未 push；CI 尚未开工**

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
| `git -C 03 submodule status` | ✅ `e10ce15… anki (heads/main)`，不再报 symlink 错 |
| anki 自身 4 个 submodule | ✅ `.git` 指针是相对路径，移动后完好 |
| `cargo metadata`（penv shell） | ✅ `anki` / `anki_proto` / `anki_io` 全部解析到新路径 |
| `./gradlew :rsdroid:tasks`（penv shell） | ✅ 配置阶段打印 `Anki commit: …`，即 `cargo metadata` 读 `anki/Cargo.toml` 成功 |
| `anki/out/*` 产物 + `.cargo/config.toml` 相对路径 | ✅ 原样存活 |

### 1.4 ⚠️ 尚未做的验证：一次完整构建

**只验证到配置/解析阶段，没有真正编译过。**
`out/build.ninja:3` 的 `builddir=` 和 **1074 个 cargo fingerprint** 里烧的是旧绝对路径，
所以下一次构建会大量重建（预计 rslib 全量 + ninja 部分）。这是移动的一次性代价，
**不要**为此删 `out/` —— 会连 yarn 和下载的 protoc 一起丢掉。

下一个 session 的第一件事应该是：

```bash
. scripts/android-env.sh
cd 01-Anki-Dev && just check                      # 顺带确认 minilints（见 §3）
cd ../03-Anki-Android-Backend-Dev && ANDROID_ARCHS=arm64-v8a ./build.sh
```

---

## 2. 提交状态：全部已提交，**均未 push**

| 仓库 | HEAD | commit 数 |
|---|---|---|
| `03-.../anki`（原 01） | `a8fc57973 feat(scheduler): pin scheduling timezone…` | 1 |
| `02-AnkiDroid-Dev` | `372ecbc feat(preferences): expose scheduling timezone…` | 3（fix / build / feat） |
| `03-Anki-Android-Backend-Dev` | `5ea5bd0 build(deps): track the zmr-233/anki-dev fork…` | 2（build / build-deps） |
| workspace（新） | `23eaf18 chore: initialise the workspace repo` | 1 |

⚠️ **所有 gitlink 指向的都是只存在于本地的 commit。** 在 push 之前，
`git clone --recurse-submodules` 和任何 CI 都会失败。push 顺序必须自底向上：
**anki → 03 → 02 → workspace**。

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

**解法（需要你决定）**：提一个动 `CONTRIBUTORS` 的 commit，把自己加进去，此后所有
commit 自动通过。**本 session 没有代做**，因为该文件开头写明：

> By adding your name to this file, you assert that any code you contribute to
> the Anki project is licensed under the BSD 3 clause license.

这是一份法律声明，得你自己签。提 upstream PR 本来也必须做这一步。

临时绕过（只为让 `just check` 变绿，不能替代上面那步）：

```bash
CONTRIBUTORS_BYPASS_EMAILS=zmr_233@outlook.com just check
```

---

## 4. workspace 仓库

拓扑 (b)：`01-Anki-Dev` 是 symlink（`120000`），02/03 是 submodule，anki 是 03 的
submodule —— **指向 anki 的 gitlink 只有一处**，不可能不一致。

已 gitignore：`env.secret`（AnkiWeb 明文账密）、`TEMP/`。
**`env.secret` 从第一个 commit 起就不在库里**，无需洗历史。

尚无 remote。

---

## 5. 待办

### 5.1 本轮遗留（按优先级）

| 项 | 说明 |
|---|---|
| **跑一次完整构建** | §1.4。重构后唯一没验证的环节 |
| **push 四个仓库** | §2。自底向上，否则 gitlink 悬空 |
| **`CONTRIBUTORS`** | §3。需要你签 |
| workspace 建 GitHub remote | 名字待定 |

### 5.2 CI（本轮明确不做）

分析结论备查，下次开工直接用：

- 依赖链串行三段 → job 形状：`build-desktop(01)` → `build-rsdroid(03)` → `build-ankidroid(02)`，
  另有 `publish-aur`(needs 01) 和汇总的 `release`
- **磁盘是首要风险**：`01` 单独就占 13G（`out/` 8.5G + `target/` 3.6G），
  GH 标准 runner 空闲约 14G，大概率爆盘。需先删 runner 预装的 SDK，或用大 runner
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
