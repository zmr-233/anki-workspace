# anki-plus-bin

AUR 包 `anki-plus-bin` 的打包目录。不是独立仓库——它就住在 workspace 里，
因为 release 本来就挂在 workspace 上，分开只会多一层 submodule 推送顺序的约束。

`anki-plus` 是 Anki 的特化发行版，源码在 [zmr-233/anki-dev](https://github.com/zmr-233/anki-dev)。
当前相对上游的改动：

- **调度时区与设备 OS 时区解耦** —— collection config `schedTimezone` 存 IANA 时区名，
  对每个被调度的时刻分别求偏移，因此 DST 正确
- **日界支持分钟精度** —— collection config `rolloverMinute`

两者都是普通 config，AnkiWeb 当不透明 JSON 原样往返，不触发全量同步。

这里**只管桌面 AUR 包**。AnkiDroid 的 APK 发布不在这里。

## 为什么是 `-bin`

从源码构建 Anki 要 Rust 全工作区 + node/yarn/sveltekit，AUR 用户得等几十分钟。
而产物恰好非常适合预编译分发：

- `_rsbridge.so` 是 pyo3 **abi3**（`cp310-abi3`）扩展 —— Arch 升 python 小版本不会打断它
- sqlite / zstd **静态链入**，TLS 走 **rustls** —— `ldd` 只有 `libc` / `libm` / `libgcc_s`，
  不被构建机的 soname 绑死
- `aqt` wheel 是 `py3-none-any`，架构无关

所以 tarball 里只有两个 wheel 加五个桌面资源文件，`package()` 就是 `python -m installer`。

## 文件

| 文件 | 作用 |
|---|---|
| `pre-PKGBUILD` | **模板**，含 `@pkgver@` 之类占位符。要改包定义就改这里 |
| `PKGBUILD` | `prepare.py` 的产物，**不要手改** |
| `.SRCINFO` | `makepkg --printsrcinfo` 的产物，AUR 靠它建索引 |
| `prepare.py` | 从 release tarball 取版本号和 sha256，渲染 `pre-PKGBUILD` → `PKGBUILD` |
| `publish_script.sh` | 生成 `.SRCINFO`，推到 `ssh://aur@aur.archlinux.org/anki-plus-bin.git` |
| `tools/make-release-tarball.sh` | 从构建好的 anki 树打出 release tarball，含产物自检 |

## release tarball 的约定

包名 `anki-plus-bin-<pkgver>-x86_64.tar.zst`，挂在
[anki-workspace](https://github.com/zmr-233/anki-workspace) 的 release 上
（只有 workspace 同时看得见三条构建链，一个 tag 才能代表一次完整发行）。

```
anki-plus-bin-<pkgver>-x86_64/
├── VERSION                 pkgver / ankiver / wheelver，供 prepare.py 读取
├── wheels/
│   ├── anki-<wheelver>-cp310-abi3-manylinux_2_35_x86_64.whl
│   └── aqt-<wheelver>-py3-none-any.whl
└── share/
    └── anki.{desktop,png,xpm,1,xml}
```

版本号是 `<上游版本>.<plus 序号>`，例如上游 26.05 的第一版 plus 是 `26.05.1`。
`ankiver`（26.05，上游 `.version`）和 `wheelver`（26.5，PEP 440 归一化后）**不相等**，
PKGBUILD 两个都要用，所以由 tarball 自述而不是猜。

## 出一版

```bash
# 1. 构建 wheel。那个 rm 不能省，见下面的「坑」
cd ../01-Anki-Dev && rm -f out/build.ninja && RELEASE=2 just wheels

# 2. 打 tarball（自带产物自检）
cd ../04-Anki-Dev-PKGBUILD
tools/make-release-tarball.sh ../01-Anki-Dev 26.05.1 ../TEMP

# 3. 挂到 workspace 的 release 上
gh release create v26.05.1 ../TEMP/anki-plus-bin-26.05.1-x86_64.tar.zst \
  --repo zmr-233/anki-workspace

# 4. 生成 PKGBUILD 并本地验证
python prepare.py --tag v26.05.1
makepkg -si

# 5. 推 AUR
./publish_script.sh
```

## 坑

**改 `RELEASE` 必须先删 `out/build.ninja`。** 构建 profile 在 configure 阶段就烘进了
`build.ninja`，而 ninja 不把环境变量当输入。只设 `RELEASE=2` 会让 `out/env` 变化触发重编译，
但仍按旧 profile 编，产物落在 `out/rust/debug/` 而非 `release-lto/`，
而且**构建照样报成功**。`make-release-tarball.sh` 的体积检查就是为了拦这个。
