#!/usr/bin/env python
"""把 pre-PKGBUILD 渲染成 PKGBUILD。

版本号和校验和都来自 release tarball 本身，不手抄：

    python prepare.py --tarball ../TEMP/anki-plus-bin-26.05.1-x86_64.tar.zst   # 本地产物
    python prepare.py --tag v26.05.1                                          # 从 GitHub release 拉

只用标准库，CI 里不需要先 pip install。
"""

from __future__ import annotations

import argparse
import hashlib
import io
import re
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

REPO = "zmr-233/anki-workspace"
PKGNAME = "anki-plus-bin"
ARCH = "x86_64"

HERE = Path(__file__).resolve().parent
TEMPLATE = HERE / "pre-PKGBUILD"
OUTPUT = HERE / "PKGBUILD"


def open_tar(data: bytes) -> tarfile.TarFile:
    """tarfile 的 zstd 支持是 3.14 才进标准库的，更老的 python 上退回 zstd(1)。"""
    try:
        return tarfile.open(fileobj=io.BytesIO(data), mode="r:zst")
    except tarfile.CompressionError:
        plain = subprocess.run(
            ["zstd", "-dc"], input=data, stdout=subprocess.PIPE, check=True
        ).stdout
        return tarfile.open(fileobj=io.BytesIO(plain), mode="r:")


def read_tarball(data: bytes) -> dict[str, str]:
    """从 tarball 里的 VERSION 读出 pkgver / ankiver / wheelver。"""
    with open_tar(data) as tar:
        members = [m for m in tar.getmembers() if m.name.endswith("/VERSION")]
        if not members:
            sys.exit("error: tarball 里没有 VERSION，不是 make-release-tarball.sh 产出的")
        fh = tar.extractfile(members[0])
        assert fh is not None
        body = fh.read().decode()

    fields = dict(
        line.split("=", 1) for line in body.splitlines() if "=" in line
    )
    missing = {"pkgver", "ankiver", "wheelver"} - fields.keys()
    if missing:
        sys.exit(f"error: VERSION 缺字段 {sorted(missing)}")
    return fields


def fetch(url: str) -> bytes:
    print(f"下载 {url}", file=sys.stderr)
    with urllib.request.urlopen(url) as resp:
        return resp.read()


def main() -> None:
    ap = argparse.ArgumentParser()
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--tarball", type=Path, help="本地 release tarball")
    src.add_argument("--tag", help="GitHub release tag，例如 v26.05.1")
    args = ap.parse_args()

    if args.tarball:
        data = args.tarball.read_bytes()
    else:
        ver = args.tag.lstrip("v")
        name = f"{PKGNAME}-{ver}-{ARCH}.tar.zst"
        data = fetch(f"https://github.com/{REPO}/releases/download/{args.tag}/{name}")

    fields = read_tarball(data)
    fields["sha256_x86_64"] = hashlib.sha256(data).hexdigest()

    text = TEMPLATE.read_text()
    for key, value in fields.items():
        text = text.replace(f"@{key}@", value)

    # pre-PKGBUILD 是模板，PKGBUILD 是产物；顺手提醒一句免得有人改错文件
    leftover = re.findall(r"@[a-z0-9_]+@", text)
    if leftover:
        sys.exit(f"error: 占位符没填完: {sorted(set(leftover))}")
    text = text.replace(
        "# 本文件是模板，@…@ 是占位符。不要直接编辑 PKGBUILD——它由 prepare.py 生成。",
        "# 本文件由 prepare.py 从 pre-PKGBUILD 生成，不要直接编辑。",
    )

    OUTPUT.write_text(text)
    print(
        f"PKGBUILD 已生成: pkgver={fields['pkgver']} "
        f"ankiver={fields['ankiver']} wheelver={fields['wheelver']}\n"
        f"sha256={fields['sha256_x86_64']}"
    )


if __name__ == "__main__":
    main()
