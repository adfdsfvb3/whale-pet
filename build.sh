#!/bin/bash
# WhalePet 一键构建：抓取 dsh-pet 素材 → 提取透明帧 → 生成图标 → 编译 → 打包 .app
# 依赖：macOS、Xcode Command Line Tools（swiftc）、python3、npm
set -euo pipefail
cd "$(dirname "$0")"

DSH_PET_VERSION=0.1.2
APP=dist/WhalePet.app

# 1. 抓取 dsh-pet npm 包（动画素材来源，MIT 许可）
mkdir -p build
if [ ! -d build/dsh-pet ]; then
  npm pack "dsh-pet@$DSH_PET_VERSION" --pack-destination build
  mkdir -p build/dsh-pet
  tar -xzf "build/dsh-pet-$DSH_PET_VERSION.tgz" -C build/dsh-pet --strip-components 1
fi

# 2. Python 虚拟环境（帧提取依赖：av / pillow / numpy）
[ -d .venv ] || python3 -m venv .venv
.venv/bin/pip install -q av pillow numpy

# 3. 从 webm 提取透明 PNG 帧序列（抠黑底 + 量化）
mkdir -p "$APP/Contents/Resources" "$APP/Contents/MacOS"
.venv/bin/python extract_frames.py build/dsh-pet/assets/thumb "$APP/Contents/Resources/frames"

# 4. 用 idle 首帧生成 AppIcon.icns
.venv/bin/python - <<'EOF'
from PIL import Image
im = Image.open("dist/WhalePet.app/Contents/Resources/frames/idle/000.png").convert("RGBA")
im.resize((1024, 1024), Image.LANCZOS).save("build/pet-master.png")
EOF
rm -rf build/PetIcon.iconset && mkdir -p build/PetIcon.iconset
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
            "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
  set -- $spec
  sips -z "$1" "$1" build/pet-master.png --out "build/PetIcon.iconset/$2.png" >/dev/null
done
iconutil -c icns build/PetIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# 5. 编译 + 打包
swiftc -O -swift-version 5 pet.swift -o "$APP/Contents/MacOS/whalepet"
cp Info.plist "$APP/Contents/Info.plist"

echo ""
echo "构建完成：$APP"
echo "运行：open $APP"
echo "别忘了配置 API key：echo 'DEEPSEEK_API_KEY=sk-你的key' > ~/.whalepet.conf && chmod 600 ~/.whalepet.conf"
