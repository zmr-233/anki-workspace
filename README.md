# Anki Workspace

时区特化版 Anki / AnkiDroid 的开发工作区。把三个互相依赖的仓库放在一起，
让「桌面 → 后端 AAR → 安卓 APK」这条构建链在同一棵目录树里可复现。

## 布局

```
12-Anki-Workspace/                      ← 本仓库
├── 01-Anki-Dev -> 03-Anki-Android-Backend-Dev/anki    symlink，不是 submodule
├── 02-AnkiDroid-Dev/                                  submodule → zmr-233/ankidroid-dev
└── 03-Anki-Android-Backend-Dev/                       submodule → zmr-233/ankidroid-backend-dev
    └── anki/                                          submodule → zmr-233/anki-dev
        └── ftl/core-repo, ftl/qt-repo, …              上游自带的 4 个 submodule
```

克隆：

```bash
git clone --recurse-submodules <this repo>
# 已经克隆过：
git submodule update --init --recursive
```

### 为什么 `01-Anki-Dev` 是 symlink

anki 的工作树只能有**一份**，而两边都要用它：

- `03/rslib-bridge/Cargo.toml` 用 path 依赖 `../anki/rslib`
- `03/build_rust` 还要吃 anki 的**构建产物**：`anki/out/sveltekit`、
  `anki/out/ts/reviewer/*`、`anki/out/node_modules/jquery`、`anki/cargo/licenses.json`；
  `03/.cargo/config.toml` 也把 `PROTOC`/`DESCRIPTORS_BIN` 指向 `anki/out/*`

所以 `anki/` 必须是一棵**构建过的**树，不是干净 checkout。

方向不能反过来（把 `anki/` 做成 symlink 指向顶层）：git 会直接拒绝
`expected submodule path 'anki' not to be a symbolic link`，导致 03 里所有 git 命令失效。
`01-Anki-Dev` 在 workspace 层，不是任何 submodule path，做 symlink 无妨。

> 历史：2026-07-27 之前这里是一条 `mount --bind`。它需要 sudo、重启失效、
> 只在某一个 mount namespace 里可见，而且 **GitHub Actions 里根本不存在** ——
> 本地跑通不代表 CI 跑通。symlink 用零内核特性做到同一件事，且本地布局 == CI 布局。

## 构建顺序

依赖链是串行的，不能并行：

```
anki (rslib + out/ 前端产物)  →  03 rsdroid AAR  →  02 AnkiDroid APK
```

```bash
. scripts/android-env.sh          # ANDROID_HOME / NDK / JDK 21，必须先 source

cd 01-Anki-Dev            && just check
cd 03-Anki-Android-Backend-Dev && ANDROID_ARCHS=arm64-v8a ./build.sh
cd 02-AnkiDroid-Dev       && ./gradlew :AnkiDroid:assembleDebug
```

多架构发版要 `ANDROID_ARCHS=armeabi-v7a,x86,arm64-v8a,x86_64` 且 `RELEASE=1`，
**必须一次列全**（每次构建会清空 `jniLibs`，不能累积）。

## 文档

| 目录 | 内容 | 生命周期 |
|---|---|---|
| `docs/design/` | 功能的设计与分析 | 长期 |
| `docs/claude/` | 操作手册：构建、调试、环境陷阱、真机 | **跨 session 长期**，动手前先读 |
| `docs/handoff/` | 交接给下一个 session 的状态与 TODO | 按编号递增，**读编号最大的那份** |

## 未入库

- `env.secret` —— AnkiWeb 测试账号明文，已 gitignore
- `*/local.properties` —— 各仓库自己 gitignore
- `TEMP/` —— 会话草稿
