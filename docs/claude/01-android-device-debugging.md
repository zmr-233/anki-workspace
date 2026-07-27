# Android 构建与真机调试手册

适用于 `02-AnkiDroid-Dev` / `03-Anki-Android-Backend-Dev`，真机为 Oppo Find N6。
跨 session 复用，不绑定任何功能分支。凡标 ⚠️ 的都是**实际踩过**的坑。

---

## 1. `PROTOC` 绝对不要导出 ⚠️⚠️

`01-Anki-Dev/.cargo/config.toml` 和 `03-.../.cargo/config.toml` 都已把 `PROTOC` pin 到
anki 自带的 protoc（**31.1**）。而 cargo 的 `[env]` 条目**不会覆盖已经设置的环境变量**
（除非 `force = true`）。

所以一旦 shell 里 `export PROTOC=/usr/bin/protoc`（系统的 **35.1**），
`rslib-bridge/build.rs` 就会用 35.1 生成 Java，而 `rsdroid` 依赖的是
`protobuf-kotlin-lite 4.33.5`。结果：

```
error: cannot find symbol
  com.google.protobuf.Internal.throwCannotGetNumberOfUnrecognized()
... 51 errors
```

这个报错**完全不提 protobuf 版本**，极易被误判成"proto 版本漂移"。
`scripts/android-env.sh` 故意不设 `PROTOC` 并写了注释，**不要加回去**。

修复后需要强制重新生成（`PROTOC` 变化不触发 cargo 重跑 build script）：

```bash
rm -rf rsdroid/build/generated/source/backend
touch anki/out/rslib/proto/descriptors.bin   # build.rs 的 rerun-if-changed 目标
```

判断生成对不对，不要靠猜：

```bash
grep -rl "throwCannotGetNumberOfUnrecognized" rsdroid/build/generated/source/backend/ | wc -l   # 必须是 0
```

---

## 2. 只建需要的架构

`build_rust` 在 Linux 上不带 `ALL_ARCHS` 时**只建 x86_64**（`add_android_rust_targets()`），
装到 arm64 真机会 `UnsatisfiedLinkError`。而 `ALL_ARCHS=1` 在非 macOS 上直接
`panic!("Must be on macOS to do a multi-arch build.")`（`build_robolectric_jni()`）。

fork 里给 `03/build_rust/src/main.rs` 加了 `ANDROID_ARCHS`（逗号分隔，接受 ABI 名或 Rust triple）：

```bash
. $WORKSPACE/scripts/android-env.sh
cd $WORKSPACE/03-Anki-Android-Backend-Dev
ANDROID_ARCHS=arm64-v8a ./build.sh
```

产物 `rsdroid/build/outputs/aar/rsdroid-release.aar`（约 19 MB，
内含 `jni/arm64-v8a/librsdroid.so` 43 MB，debug）。

⚠️ 换架构时 `build_android_jni()` 会 `remove_dir_all(jniLibs)`，
**多次跑不同 `ANDROID_ARCHS` 不会累积**，要多架构必须一次列全。

不设 `RELEASE=1` 时是 debug 构建：`.so` 大得多、跑得慢，但功能验证足够，编译快很多。

---

## 3. AnkiDroid 侧

```bash
. $WORKSPACE/scripts/android-env.sh
cd $WORKSPACE/02-AnkiDroid-Dev
./gradlew :AnkiDroid:assembleDebug --console=plain
```

`local.properties` 的 `local_backend=true` + `local_backend_path=03-Anki-Android-Backend-Dev`
让它用本地 AAR（上游硬编码 `../Anki-Android-Backend`，fork 里已改成可配置）。

⚠️ **只有 arm64-v8a 的 APK 可用**。`assembleDebug` 产出 12 个 APK（3 flavour × 4 abi），
arm64 那 3 个 ≈ 95 MB，其余 ≈ 51 MB —— 后者不含 `librsdroid.so`，装上去必崩。
挑 `full` flavour（无 Play 服务依赖）：

```
AnkiDroid/build/outputs/apk/full/debug/AnkiDroid-full-arm64-v8a-debug.apk
```

debug 包的 applicationId 是 `com.ichi2.anki.debug`（`applicationIdSuffix ".debug"`），
与正式版数据隔离，可以放心装。

---

## 4. Oppo Find N6 专项 ⚠️

设备：`3B163A00VKK00000` / PLP110 / Android 16 / SDK 36 / arm64-v8a。

### 4.1 双屏，screencap 必须指定 display

不带 `-d` 时的警告会被**写进 PNG 文件开头**，导致文件损坏且报错极具迷惑性
（"not a valid PNG ... Detected: JSON/text"）。

| display id | 尺寸 | 是 |
|---|---|---|
| `4630946317637160339` | 2248×2480 | 内屏（展开） |
| `4630946165954792596` | 1140×2616 | 外屏 |

```bash
ssh local 'adb exec-out screencap -p -d 4630946317637160339 > /tmp/s.png'
```

display id 用 `adb shell dumpsys SurfaceFlinger --display-id` 取，**换机/重启后会变，别硬记**。

截图很大，读之前先裁剪省 token：

```python
from PIL import Image
Image.open('s.png').crop((0, 0, 1200, 400)).save('s-crop.png')
```

### 4.2 ColorOS 拦掉的 adb 能力 ⚠️

| 命令 | 结果 |
|---|---|
| `adb shell appops set … MANAGE_EXTERNAL_STORAGE allow` | ❌ `uid 2000 does not have MANAGE_APP_OPS_MODES` |
| `adb shell cmd time_zone_detector suggest_manual_time_zone --zone_id X` | ❌ `uid 2000 does not have SUGGEST_MANUAL_TIME_AND_ZONE` |
| `adb shell cmd time_zone_detector set_auto_detection_enabled true\|false` | ✅ |
| `adb install / am start / am force-stop / pull / push /sdcard/…` | ✅ |
| `adb exec-out screencap -d <id>` | ✅ |

**推论：改系统时区、授「所有文件访问」权限，只能由人在设置里点。** 见 §5。

关自动时区（`set_auto_detection_enabled false`）**必须先做**，
否则设置里的手动时区项是灰的。测完 `… true` 恢复，设备会自动跳回正确时区。

### 4.3 首次启动

AnkiDroid 首次启动会跳到系统的「所有文件访问」设置页
（`com.android.settings/.Settings$AppManageExternalStorageActivity`），adb 授不了，需要人点。
之后 collection 落在 `/sdcard/AnkiDroid/collection.anki2`（不是 scoped 的 `Android/data/…`）。

---

## 5. 把人当成测试的一环

真机验证里有一类操作做不了（改系统时区、授权、点应用内 UI）。
硬用 `adb shell input tap` + `uiautomator dump` 去点 ColorOS 的 UI 很脆。
把这些步骤派给人，用 `AskUserQuestion` 收结果。

| CC 做 | 人做 |
|---|---|
| 构建、安装、`force-stop`/`am start` | 系统设置里的操作（时区、权限） |
| push/pull collection、读 SQLite、截图 | 应用内多步 UI 导航 |
| 用桌面 pylib 做交叉验证与预测 | 报告肉眼观察到的数字 / 报错文案 |

**把选项写成互斥的预期结果**，而不是"好了/没好"——这样答案本身就是测量：

> 回到牌组列表后，顶部显示多少张待复习？
> - 8 张 —— 调度时区已钉住，符合预期
> - 3 张 —— 没生效，仍跟着设备时区走
> - 15 张 —— 日号反而前进了一天
> - 其它数字 / 报错了

同时用一个 multiSelect 问题收「CC 看不到的东西」（UI 是否可用、有无异常），一次交互拿两类信息。

**派活前先把设备摆到位**（应用已重启到目标页、时区自动检测已关），让人只做那一件事。
派完立刻用 adb 独立核验，不要只信口头结论。

---

## 6. 读设备上的 collection：WAL 陷阱 ⚠️

AnkiDroid 用 WAL 模式，刚写的改动全在 `collection.anki2-wal` 里，
**只拉主文件会读到旧数据**，而且 `am force-stop` **不会** checkpoint。

现象：应用行为明明变了，但拉下来的 config 表里新 key 还是 `<absent>` —— 极具误导性。

两个文件一起拉到同一目录，sqlite 打开时会自动重放 WAL：

```bash
ssh local 'mkdir -p /tmp/rt
  adb pull /sdcard/AnkiDroid/collection.anki2     /tmp/rt/collection.anki2
  adb pull /sdcard/AnkiDroid/collection.anki2-wal /tmp/rt/collection.anki2-wal'
scp -q local:'/tmp/rt/*' "$SP/rt/"
```

反向**推入**前必须先 `am force-stop`，并删掉 `-wal` / `-shm`：

```bash
adb shell am force-stop com.ichi2.anki.debug
adb shell rm -f /sdcard/AnkiDroid/collection.anki2-wal /sdcard/AnkiDroid/collection.anki2-shm
adb push local-collection.anki2 /sdcard/AnkiDroid/collection.anki2
```

---

## 7. 用桌面 pylib 做交叉验证

`01-Anki-Dev` 的 pylib 跑的是**同一份 rslib 源码**，可以直接用来
（a）预演真机行为、（b）事后独立核验从设备拉下来的 collection。

```bash
cd 01-Anki-Dev
PYTHONPATH=$PWD/out/pylib TZ=Asia/Shanghai out/pyenv/bin/python your_script.py
```

⚠️ 必须带 `PYTHONPATH=out/pylib`，否则 `ImportError: cannot import name 'ankiweb_pb2'`
（生成的 protobuf 在 `out/pylib` 而非源码树）。

`TZ=<zone>` 能直接改变 rslib 看到的"设备时区"，**在桌面上就能模拟换时区**，
适合先跑一遍再上真机。

### 造对时间敏感的测试数据 ⚠️

`days_elapsed` **下限被钳到 0**。新建 collection 的 `crt` 就是今天，
所以**任何时区变化都看不出效果**，会误判成"改动没生效"。
必须把 `crt` 整天数回拨（保持一天内的时刻不变，`creationOffset` 才仍正确）：

```python
col.db.execute("update col set crt = crt - ?", 30 * 86400)
col.close()
col = Collection(path)      # 必须重开
```

- `col.sched.set_due_date(ids, "N")` **不接受负数**。造逾期卡要先设 `"0"`，
  再逐张 `card.due += -1; col.update_card(card)`
- `col.sched.deck_due_tree()` 的**根节点已聚合子节点**，`sum` 时只遍历 `tree.children`，否则翻倍

### 先跑对照组

验证"X 之后 Y 不变"时，**必须先证明不做 X 时 Y 会变**，否则"没变"可能只是测试不敏感。

---

## 8. 后台长构建

首次 rsdroid 构建（含 Rust 交叉编译）十几分钟，AnkiDroid 首次约 6 分钟；
增量下分别约 1 分钟和 2.5 分钟。不要用前台阻塞式调用。

```bash
# 起
. $WORKSPACE/scripts/android-env.sh; cd $WORKSPACE/03-Anki-Android-Backend-Dev
ANDROID_ARCHS=arm64-v8a nohup ./build.sh > /tmp/rsdroid-build.log 2>&1 & echo started

# 等（Bash run_in_background，退出即通知）
until grep -qE "Build complete|FAILURE:|BUILD FAILED|panicked" /tmp/rsdroid-build.log
do sleep 10; done; tail -25 /tmp/rsdroid-build.log
```

⚠️ **grep 模式必须同时覆盖成功和失败标记**，否则构建崩了会一声不响：

```
grep -E --line-buffered "^\*\*\*|error\[E|^error:|FAILURE|BUILD SUCCESSFUL|BUILD FAILED|panicked|Build complete"
```

⚠️ 包装脚本时注意**退出码要透传**。`script.sh > log 2>&1; echo done; tail log`
这种写法整体退出码来自 `tail`，永远是 0，会把失败的构建报成成功。
