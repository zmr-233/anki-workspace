# Anki Workspace

时区特化版 Anki / AnkiDroid 的开发工作区。三个互相依赖的仓库放在一起，
让「桌面 → 后端 AAR → 安卓 APK」这条构建链在同一棵目录树里可复现。

## 布局

```
12-Anki-Workspace/                      ← 本仓库
├── 01-Anki-Dev -> 03-Anki-Android-Backend-Dev/anki    symlink
├── 02-AnkiDroid-Dev/                                  submodule → zmr-233/ankidroid-dev
└── 03-Anki-Android-Backend-Dev/                       submodule → zmr-233/ankidroid-backend-dev
    └── anki/                                          submodule → zmr-233/anki-dev
        └── ftl/core-repo, qt/installer/*-template …   上游自带的 4 个 submodule
```

```bash
git clone --recurse-submodules git@github.com:zmr-233/anki-workspace.git
```

anki 的工作树只能有一份，而两边都要用：`03/rslib-bridge` 用 path 依赖
`../anki/rslib`，`03/build_rust` 还要吃 anki 的构建产物（`anki/out/sveltekit`、
`anki/out/ts/reviewer/*`、`anki/cargo/licenses.json`），`03/.cargo/config.toml` 的
`PROTOC` / `DESCRIPTORS_BIN` 也指向 `anki/out/*`。所以 `anki/` 必须是一棵**构建过的**树。

⚠️ 方向不可反转。把 `anki/` 做成 symlink 会让 git 直接拒绝
（`expected submodule path 'anki' not to be a symbolic link`），03 里所有 git 命令随之失效。
`01-Anki-Dev` 不是 submodule path，做 symlink 无妨。

## 构建

依赖链串行，不能并行：**anki → rsdroid AAR → AnkiDroid APK**。

```bash
. scripts/android-env.sh          # ANDROID_HOME / NDK / JDK 21，必须先 source

cd 01-Anki-Dev                     && just check
cd 03-Anki-Android-Backend-Dev     && ANDROID_ARCHS=arm64-v8a ./build.sh
cd 02-AnkiDroid-Dev                && ./gradlew :AnkiDroid:assembleDebug
```

发版需 `ANDROID_ARCHS=armeabi-v7a,x86,arm64-v8a,x86_64` 且 `RELEASE=1`，
**必须一次列全**——每次构建会清空 `jniLibs`，多次跑不同架构不会累积。

## 文档

| 目录 | 内容 |
|---|---|
| `CLAUDE.md` | 给 Claude Code session 的项目指令，动手前先读 |
| `docs/design/` | 功能的设计与分析 |
| `docs/claude/` | 操作手册：构建、调试、环境陷阱、真机 |
| `docs/handoff/` | 当前状态与待办。**只保留一份**，过时的直接删除而非追加 |

## 未入库

`env.secret`（AnkiWeb 测试账号明文）、`*/local.properties`、`TEMP/`。
