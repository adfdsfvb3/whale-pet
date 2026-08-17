#!/bin/bash
# WhalePet 发布打包：完整构建 → 压缩成可分发的 zip。
# 产物 dist/WhalePet-macOS.zip 可直接上传 GitHub Releases；
# 用户下载解压双击即可（未签名，首次需右键 → 打开）。
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

rm -f dist/WhalePet-macOS.zip
ditto -c -k --sequesterRsrc --keepParent dist/WhalePet.app dist/WhalePet-macOS.zip

echo ""
echo "发布包：dist/WhalePet-macOS.zip ($(du -h dist/WhalePet-macOS.zip | cut -f1))"
echo "上传：gh release create <tag> dist/WhalePet-macOS.zip --title <标题> --notes <说明>"
