# WhalePet 鲸鱼娘

一只住在桌面上的女仆装鲸鱼娘：无边框透明悬浮窗，可以满屏拖动，能打字聊天，也能语音对话。支持 **macOS**（原生 Swift）和 **Windows**（Electron 版）。

动画素材来自 npm 包 [dsh-pet](https://www.npmjs.com/package/dsh-pet)（MIT 许可，作者 PC2005-cloud），构建时自动下载并提取，仓库本身不包含素材文件。

## 下载（一键安装）

到 [Releases](https://github.com/adfdsfvb3/whale-pet/releases) 下载：

- **macOS**：`WhalePet-macOS.zip` → 解压双击（未签名，首次 右键 → 打开）
- **Windows**：`WhalePet-Setup-1.0.0.exe` → NSIS 一键安装（未签名，SmartScreen 点"仍要运行"）

安装后：右键宠物 → 设置，粘贴自己的 DeepSeek API key 即可使用。**macOS 发布包已内置 Node.js 和 dsh agent 运行时，开箱即用，不需要安装任何开发环境**；Windows 版的 agent 模式仍需本机 checkout dsh 源码仓库（没有则自动用纯聊天模式）。

## 功能

- **桌面悬浮**：透明置顶窗口，所有桌面空间可见，不占 Dock
- **拖动**：按住拖动到屏幕任意位置（拖动时播放悬空挣扎动画）
- **单击**：弹出对话气泡，和鲸鱼娘聊天
- **完整 dsh agent**：对话默认接入本地 [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 的 ACP agent —— 能读写文件、执行命令、派生子代理，和 dsh web 端是同一个"大脑"；dsh 不可用时自动回退到 DeepSeek API 纯聊天，进程意外退出会自动重启（3 次失败才降级）
- **对话体验**：回复 markdown 渲染（代码块/加粗/行内代码）、气泡底部拖条自由缩放（300×280 ~ 900×900）、生成中可随时「停止」、一键「新对话」清空上下文
- **历史对话**：每轮自动归档到 `~/whale-pet/history/`（崩溃不丢），气泡「历史」面板可查看/继续/删除；继续时直连模式完整恢复上下文，agent 模式注入旧记录摘要
- **长时记忆**：每 3 个回合自动把对话蒸馏成记忆要点写入 `~/whale-pet/memory.md`，之后每轮对话都会带上（纯文本可手动编辑/删除）
- **语音输入**：气泡里点 🎤 说话，macOS 原生语音识别（中文）实时转文字
- **语音朗读**：回复自动用中文语音读出来（超长回复只念前 200 字）
- **连续语音对话**：设置里开启后，点一次麦克风即进入"说 → 答 → 自动继续听"的免提循环
- **双击**：随机卖萌（开心跃动 / 害羞 / 傲娇生气）
- **随机小动作**：待机时每隔 25~60 秒随机表演（东张西望、哼歌、伸懒腰、玩魔方），或满屏游走（螃蟹爬行动画；可在设置里单独开关，对话框打开时不游走）
- **位置记忆**：拖放和游走的位置自动保存，重启后回到原处
- **右键菜单**：对话 / 设置 / 插件 / 打开完整版（Web）/ 退出
- **设置面板**：API key（密文）、模型选择（`deepseek-v4-pro` / `deepseek-v4-flash` 走 dsh agent，`deepseek-chat` / `deepseek-reasoner` 纯聊天）、dsh 仓库路径、朗读开关与语速、连续语音对话、宠物大小（小/中/大）、待机小动作频率、开机自动启动——全部保存即生效，持久化在 `~/.whalepet.conf`
- **打开完整版**：一键跳到 dsh web 端（http://127.0.0.1:3080），服务没在跑会自动先启动再打开浏览器
- **插件面板**：常用 dsh web 插件一键安装（全家桶、任务看板、Git 图、皮肤、SSH 等 9 个预设 + 任意 npm 包名），自动处理 pnpm `allowBuilds` 审批重试，装完一键重启 web 生效

### dsh agent 模式说明

- **内置运行时（默认）**：发布包的 `Contents/Resources/runtime/` 里带了一个独立 node 二进制和 `pnpm deploy` 出的自包含 dsh 依赖树（约 90MB，只含 ACP 闭包），首次打开对话框时自动拉起 ACP server 子进程，通过 stdin/stdout 上的 ndjson JSON-RPC 通信
- **源码仓库（开发者后备）**：没有内置运行时时，回退到设置面板里配置的 deepseek-harness 源码仓库（`node --import tsx packages/examples/acp-demo/src/bin.ts` 方式启动）
- 模型通过 `DSH_ACP_MODEL` 环境变量注入（内置运行时的 cordis.yml 已带 `!!js "process.env.DSH_ACP_MODEL ?? 'deepseek-v4-pro'"` 补丁和 skill 插件组合）
- **安全边界**：agent 的文件系统和命令执行被沙箱限制在 `~/whale-pet/workspace`；一次性权限请求自动允许（仅在该沙箱范围内）
- 想让她操作别的目录，直接对话里说明即可——她会先复制/移动到 workspace 内处理
- `WHALEPET_SELFTEST=1 open dist/WhalePet.app` 可无界面自测 ACP 链路（结果写 `/tmp/whalepet-selftest.log`）

## 构建

### macOS 原生版

依赖：macOS、Xcode Command Line Tools（`swiftc`）、python3、npm。

```sh
./build.sh       # 构建 dist/WhalePet.app（纯聊天版，agent 需本机 dsh 源码仓库）
./release.sh     # 额外打出 dist/WhalePet-macOS.zip 发布包
./bundle.sh      # 小白版：在 build.sh 基础上内嵌 node + dsh 运行时后再打 zip
```

`bundle.sh` 额外需要一份构建过的 [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 源码（`pnpm install && pnpm run build`，路径用 `DSH_REPO` 指定，默认 `~/deepseek-harness`）。它通过 `pnpm deploy` 把 ACP 闭包（`bundle/acp-mini.package.json` 声明的 94 个 workspace 包）导出成自包含依赖树，连同 node 二进制一起塞进 `Contents/Resources/runtime/`。

构建脚本会自动完成：npm 下载 dsh-pet 素材 → 创建 Python 虚拟环境（av/pillow/numpy）→ 从 webm 提取透明 PNG 帧（240px / 12fps）→ 生成应用图标 → `swiftc` 编译 → 打包。

### Windows 版（Electron）

```sh
cd electron
npm install        # 慢的话用 ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/
npm start          # 本地调试
npm run dist:win   # 打出 NSIS 安装包到 dist-electron/
```

功能与 macOS 版对齐（宠物动画/拖动/聊天/ACP agent/设置），差异：语音输入在 Electron 的 Chromium 里通常不可用（按钮自动禁用），语音朗读依赖系统中文语音包。

## 配置 API key（必需）

聊天功能需要你自己的 [DeepSeek API key](https://platform.deepseek.com/)，两种方式任选：

- **推荐**：右键鲸鱼娘 → 设置…，在面板里粘贴 key、选模型，点保存
- 手动：

```sh
echo 'DEEPSEEK_API_KEY=sk-你的key' > ~/.whalepet.conf
chmod 600 ~/.whalepet.conf
```

配置文件 `~/.whalepet.conf` 同时保存 `WHALEPET_MODEL`（模型选择）。程序在**运行时**读取该文件或环境变量，key 不会写入代码或 app 包。**请勿把这个文件提交进仓库**（`.gitignore` 已排除 `*.conf`）。

## 系统权限

首次使用语音功能时，macOS 会弹窗请求两项权限：

- **麦克风**：用于听到你说话
- **语音识别**：用于把语音转成文字（识别由系统/苹果服务端处理）

如误点拒绝，可在 系统设置 → 隐私与安全性 → 麦克风 / 语音识别 中重新开启。

## 项目结构

```
pet.swift          macOS 原生版全部源码（AppKit，单文件）
electron/          Windows 跨平台版（Electron：main.js 主进程 + renderer/ 渲染层）
extract_frames.py  帧提取脚本：webm → 抠黑底透明 PNG 序列
test-acp.py        ACP 链路独立冒烟测试（python3 test-acp.py）
build.sh           macOS 一键构建脚本
release.sh         macOS 发布打包脚本（构建 + zip）
bundle.sh          小白版打包脚本（内嵌 node + dsh 运行时）
bundle/            打包物料（acp-mini umbrella 的 package.json）
Info.plist         app 包配置（含权限说明文案）
```

想调整人设、记忆长度、朗读语速、动作频率，直接改 `pet.swift` 顶部的常量和 `systemPrompt`，然后重新运行 `./build.sh`。

## 许可

本仓库代码以 MIT 发布。动画素材版权归 dsh-pet 作者（PC2005-cloud）所有，同样以 MIT 许可使用。
