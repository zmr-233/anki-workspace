#!/usr/bin/env bash
# 从构建好的 anki 树打出 anki-plus-bin 的 release tarball。
# 本机和 CI 用同一个脚本，保证 PKGBUILD 拿到的东西完全一致。
#
#   tools/make-release-tarball.sh <anki-tree> <pkgver> [outdir]
#
# <anki-tree> 必须先用 RELEASE=2 构建过：
#   cd <anki-tree> && rm -f out/build.ninja && RELEASE=2 just wheels
#
# 那个 rm 不是多余的：构建 profile 在 configure 阶段就烘进了 out/build.ninja，
# 而 ninja 不把环境变量当输入。只改 RELEASE 会让 out/env 变化触发重编译，
# 但仍然按旧 profile 编，产物落在 out/rust/debug/ 而不是 release-lto/，
# 表面上「构建成功」。下面的 _rsbridge.so 体积检查就是为了拦住这种情况。

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

[[ $# -ge 2 ]] || die "用法: $0 <anki-tree> <pkgver> [outdir]"

_tree=$(readlink -f "$1")
_pkgver=$2
_outdir=$(readlink -f "${3:-$PWD}")
_arch=x86_64
_name="anki-plus-bin-$_pkgver-$_arch"

[[ -d $_tree ]] || die "anki 树不存在: $_tree"

_wheeldir="$_tree/out/wheels"
_anki_whl=$(ls "$_wheeldir"/anki-*-cp310-abi3-manylinux_*_$_arch.whl 2>/dev/null | head -1)
_aqt_whl=$(ls "$_wheeldir"/aqt-*-py3-none-any.whl 2>/dev/null | head -1)
[[ -f ${_anki_whl:-} ]] || die "找不到 anki wheel，先构建 $_tree（看 $_wheeldir）"
[[ -f ${_aqt_whl:-} ]] || die "找不到 aqt wheel，先构建 $_tree（看 $_wheeldir）"

# 上游资源在 26.05 之后从 qt/launcher/lin/ 搬到了这里，目录名带 cookiecutter 花括号，
# 但文件内容是字面量，可以直接装
_share="$_tree/qt/installer/linux-template/{{ cookiecutter.format }}/{{ cookiecutter.app_name }}"
[[ -d $_share ]] || die "找不到桌面资源目录，上游可能又搬家了: $_share"

_stage=$(mktemp -d)
_probe=$(mktemp -d)
trap 'rm -rf "$_stage" "$_probe"' EXIT
mkdir -p "$_stage/$_name/wheels" "$_stage/$_name/share"

cp "$_anki_whl" "$_aqt_whl" "$_stage/$_name/wheels/"
for f in anki.desktop anki.png anki.xpm anki.1 anki.xml; do
    cp "$_share/$f" "$_stage/$_name/share/$f"
done

# 让 tarball 自述版本，prepare.py 就不用从文件名反推。
# ankiver 是上游 marketing 版本（26.05），wheelver 是 PEP 440 归一化后的（26.5），
# 两者不等，而 PKGBUILD 两个都要用
_ankiver=$(tr -d '[:space:]' < "$_tree/.version")
_wheelver=$(basename "$_anki_whl" | cut -d- -f2)
# AGPL：预编译包必须能指回确切的源码版本，只写仓库名不够
_srcref=$(git -C "$_tree" rev-parse HEAD)
git -C "$_tree" diff --quiet HEAD -- || die \
  "anki 树有未提交改动，$_srcref 指不准源码。先提交再打包"
cat > "$_stage/$_name/VERSION" <<EOF
pkgver=$_pkgver
ankiver=$_ankiver
wheelver=$_wheelver
srcref=$_srcref
EOF

# --- 产物自检 -------------------------------------------------------------
( cd "$_probe" && bsdtar -xf "$_anki_whl" )
_so=$(find "$_probe" -name '_rsbridge*.so' | head -1)
[[ -n $_so ]] || die "wheel 里没有 _rsbridge.so"

# debug 档约 55 MB 且带符号；release-lto 档远小于此。撞线说明 RELEASE=2 没生效
_sz=$(stat -c%s "$_so")
(( _sz < 40 * 1024 * 1024 )) || die \
  "_rsbridge.so 有 $((_sz / 1024 / 1024)) MB，像是 debug 档。删掉 out/build.ninja 再用 RELEASE=2 重建"

# 只该链 glibc / libm / libgcc。出现 libsqlite3 / libzstd / libssl 说明
# 误设了 LIBSQLITE3_SYS_USE_PKG_CONFIG / ZSTD_SYS_USE_PKG_CONFIG 或换了 TLS 后端，
# 那样产物就会被绑死在构建机的 soname 上
if ldd "$_so" | grep -Eq 'libsqlite3|libzstd|libssl|libcrypto'; then
    ldd "$_so" >&2
    die "_rsbridge.so 链到了系统库，预编译包不能这样"
fi
# --------------------------------------------------------------------------

mkdir -p "$_outdir"
_out="$_outdir/$_name.tar.zst"
tar --zstd -cf "$_out" -C "$_stage" "$_name"

echo "$_out"
sha256sum "$_out"
