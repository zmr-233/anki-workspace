# CLAUDE.md

时区特化版 Anki / AnkiDroid 工作区。布局与构建命令见 `README.md`，**先读它**。

## 在哪跑

| 操作 | 在哪跑 |
|---|---|
| 编辑、`just`、gradle、`build.sh`、cargo 交叉编译 | 你自己的 shell ✅ |
| **`adb`** | **必须 `ssh local`** |

adb 是唯一的例外：`/dev/bus/usb/*` 的 ACL 授权给 `zmr233`，你（uid 2000 `penv`）
跑 adb 会抢占 5037 端口让对面看不到设备。已污染时：
`ssh local 'adb kill-server; adb start-server; adb devices -l'`。

`ssh local` 每次都从 `$HOME` 开始，命令里必须显式 `cd`，否则会出现
`fatal: cannot change to 'anki'` 这类看起来像环境坏掉的假象。

## 动手前必读

`docs/claude/01-android-device-debugging.md`。里面的坑都是实际踩过的，
尤其 §1（`PROTOC` 绝对不要导出，会产生 51 个完全不提 protobuf 版本的 `cannot find symbol`）。

## 提交约定

- **`02-AnkiDroid-Dev` 的 commit 必须带 `Assisted-by:` trailer**，其 `AI_POLICY.md` 强制要求
- 动了任何 `Cargo.toml` 的依赖，跟一次 `just fix-minilints` 重新生成 `cargo/licenses.json`，
  否则 `just check` 会红
- push 顺序**自底向上**：anki → 03 → 02 → workspace。反了会留下悬空 gitlink，
  远端 `git clone --recurse-submodules` 直接失败
- submodule URL 协议是分离的：`.gitmodules` 用 `https://`（CI 匿名克隆），
  本地 `.git/config` 用 `git config submodule.<name>.url git@github.com:…` 覆盖成 ssh

## 环境前提（已就绪，无需重装）

Rust 四个 Android 靶子、Android SDK（platforms 34/35/36.1）、**NDK 29.0.14206865**、
cmdline-tools、**JDK 21.0.6-amzn**（shell 默认的 23 比 AGP 验证过的版本新，
`scripts/android-env.sh` 已 pin）、`toml-cli`、真机 Oppo Find N6 已授权。

## 文档纪律

`docs/handoff/` **只保留一份**。状态变了就重写那一份，不要追加 `02-`、`03-`。
其他文档同理：过时的段落直接删掉，不要写「以前是 X，现在是 Y」的补丁式叙述——
读者只需要知道现在是什么。

## 两个效率约定

- **不要跑 `pgrep -af`**：这台机器的进程环境变量极长，一条 `penv-exec` 就能刷掉整个上下文窗口。
  用 `pgrep -a` 配精确名字，或只看日志
- **把人当成测试的一环**：改系统时区、授权、点应用内 UI 这些你做不了的步骤，
  用 `AskUserQuestion` 派给用户，不要硬啃 `adb shell input tap` + `uiautomator dump`。
  做法见调试手册 §5
