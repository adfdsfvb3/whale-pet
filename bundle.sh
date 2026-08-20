#!/bin/bash
# WhalePet 小白版打包：完整构建 app → 内嵌 Node + dsh ACP 运行时 → 压缩 zip。
# 产物 dist/WhalePet-macOS.zip 开箱即用：无需安装 Node/npm/clone dsh 仓库。
#
# 构建机依赖：macOS、swiftc、python3、npm、pnpm，以及一份构建过的
# deepseek-harness 源码（pnpm install && pnpm run build 完成）。
# 可用环境变量覆盖：
#   DSH_REPO   dsh 源码仓库路径（默认 ~/deepseek-harness）
#   NODE_BIN   要打进包的 node 可执行文件（默认自动探测 nvm/Homebrew 最新版）
#   FORCE=1    忽略缓存，重新 deploy dsh 运行时
set -euo pipefail
cd "$(dirname "$0")"

DSH_REPO="${DSH_REPO:-$HOME/deepseek-harness}"
APP=dist/WhalePet.app
RUNTIME_BUILD=build/dsh-runtime

# 1. 构建 app 本体（帧素材、图标、编译）
./build.sh

# 2. 准备 dsh 运行时（pnpm deploy 出自包含依赖树，带缓存）
if [ ! -d "$DSH_REPO/packages/examples/acp-demo" ]; then
  echo "错误：找不到 dsh 源码仓库 $DSH_REPO（用 DSH_REPO=路径 指定）" >&2
  exit 1
fi
# deploy 用的迷你 umbrella：只声明 ACP 闭包，避免拖进 web/终端等无关包。
mkdir -p "$DSH_REPO/packages/bundle/acp-mini"
if ! diff -q bundle/acp-mini.package.json "$DSH_REPO/packages/bundle/acp-mini/package.json" >/dev/null 2>&1; then
  cp bundle/acp-mini.package.json "$DSH_REPO/packages/bundle/acp-mini/package.json"
  (cd "$DSH_REPO" && pnpm install --no-frozen-lockfile)
fi
if [ -n "${FORCE:-}" ] || [ ! -d "$RUNTIME_BUILD" ]; then
  rm -rf "$RUNTIME_BUILD"
  RUNTIME_ABS="$(pwd)/$RUNTIME_BUILD"
  (cd "$DSH_REPO" && pnpm --filter whalepet-acp-runtime deploy --prod --legacy "$RUNTIME_ABS")
fi

# pnpm deploy 对 vendor/ 里的包会留下指回源码仓库（或层数错误直接断裂）的符号链接，
# 在本机靠根回退解析能跑、拷走就全断。把它们全部替换成实体拷贝。
python3 bundle/materialize-links.py "$RUNTIME_BUILD/node_modules" "$DSH_REPO"

# 3. 找 node 可执行文件
if [ -z "${NODE_BIN:-}" ]; then
  for candidate in /opt/homebrew/bin/node /usr/local/bin/node "$HOME"/.nvm/versions/node/*/bin/node; do
    [ -x "$candidate" ] && NODE_BIN="$candidate"
  done
fi
[ -n "${NODE_BIN:-}" ] || { echo "错误：找不到 node（用 NODE_BIN=路径 指定）" >&2; exit 1; }
echo "使用 node：$NODE_BIN ($("$NODE_BIN" --version))"

# 4. 组装 runtime 进 app
rm -rf "$APP/Contents/Resources/runtime"
mkdir -p "$APP/Contents/Resources/runtime/dsh"
cp "$NODE_BIN" "$APP/Contents/Resources/runtime/node"
chmod +x "$APP/Contents/Resources/runtime/node"
cp -R "$RUNTIME_BUILD/node_modules" "$APP/Contents/Resources/runtime/dsh/node_modules"
cp "$RUNTIME_BUILD/package.json" "$APP/Contents/Resources/runtime/dsh/package.json"
# ACP 组合配置（含模型/skills 补丁）以 dsh 仓库里的为准
mkdir -p "$APP/Contents/Resources/runtime/dsh/acp-agent"
cp "$DSH_REPO/examples/acp-agent/cordis.yml" "$APP/Contents/Resources/runtime/dsh/acp-agent/cordis.yml"

# 5. 压缩
rm -f dist/WhalePet-macOS.zip
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/WhalePet-macOS.zip

echo ""
echo "小白版发布包：dist/WhalePet-macOS.zip ($(du -h dist/WhalePet-macOS.zip | cut -f1))"
echo "app 体积：$(du -sh "$APP" | cut -f1)（内含 node + dsh 运行时）"
echo "用户下载解压双击即可，唯一要填的是 API key（鲸鱼娘设置面板里填）。"
