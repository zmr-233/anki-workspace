#!/usr/bin/env bash
# 把当前的 PKGBUILD 推到 AUR。
#
#   ./publish_script.sh --tag v26.05.1     # 从 GitHub release 生成再推
#   ./publish_script.sh                    # 用已有的 PKGBUILD 推
#
# 需要 AUR 上已注册 SSH 公钥。第一次跑会 clone 出 aur/ 子目录（已 gitignore）。

set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

PKGNAME=anki-plus-bin
AUR_REMOTE="ssh://aur@aur.archlinux.org/$PKGNAME.git"

if [[ ${1:-} == --tag ]]; then
    [[ -n ${2:-} ]] || { echo "--tag 后面要跟 tag 名" >&2; exit 1; }
    python ./prepare.py --tag "$2"
fi

[[ -f PKGBUILD ]] || { echo "没有 PKGBUILD，先跑 prepare.py" >&2; exit 1; }

# .SRCINFO 必须由 PKGBUILD 生成，AUR 靠它建索引；手写必然会漂
makepkg --printsrcinfo > .SRCINFO

[[ -d aur ]] || git clone "$AUR_REMOTE" aur

cp PKGBUILD .SRCINFO aur/
pushd aur >/dev/null

git add PKGBUILD .SRCINFO
if git diff --cached --quiet; then
    echo "AUR 上已经是这个版本，无需推送"
    popd >/dev/null
    exit 0
fi

version=$(awk -F= '/^pkgver=/{print $2}' PKGBUILD)
relv=$(awk -F= '/^pkgrel=/{print $2}' PKGBUILD)
git commit -m "$PKGNAME $version-$relv"
git push

popd >/dev/null
echo "已推送 $PKGNAME $version-$relv"
