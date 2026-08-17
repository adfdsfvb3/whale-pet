# WhalePet 鲸鱼娘

一只住在 macOS 桌面上的女仆装鲸鱼娘：无边框透明悬浮窗，可以满屏拖动，能打字聊天，也能语音对话。

动画素材来自 npm 包 [dsh-pet](https://www.npmjs.com/package/dsh-pet)（MIT 许可，作者 PC2005-cloud），构建时自动下载并提取，仓库本身不包含素材文件。

## 功能

- **桌面悬浮**：透明置顶窗口，所有桌面空间可见，不占 Dock
- **拖动**：按住拖动到屏幕任意位置（拖动时播放悬空挣扎动画）
- **单击**：弹出对话气泡，和鲸鱼娘聊天
- **完整 dsh agent**：对话默认接入本地 [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 的 ACP agent —— 能读写文件、执行命令、派生子代理，和 dsh web 端是同一个"大脑"；dsh 不可用时自动回退到 DeepSeek API 纯聊天
- **语音输入**：气泡里点 🎤 说话，macOS 原生语音识别（中文）实时转文字
- **语音朗读**：回复自动用中文语音读出来（超长回复只念前 200 字）
- **双击**：随机卖萌（开心跃动 / 害羞 / 傲娇生气）
- **随机小动作**：待机时每隔 25~60 秒随机表演（东张西望、哼歌、伸懒腰、玩魔方、螃蟹走路）
- **右键菜单**：对话 / 设置 / 打开完整版（Web）/ 退出
- **设置面板**：GUI 里直接配置 API key 和模型（`deepseek-v4-pro` / `deepseek-v4-flash` 走 dsh agent，`deepseek-chat` / `deepseek-reasoner` 纯聊天），保存即生效
- **打开完整版**：一键跳到 dsh web 端（http://127.0.0.1:3080），服务没在跑会自动先启动再打开浏览器

### dsh agent 模式说明

- 需要本机已 clone 并构建 deepseek-harness（路径在 `pet.swift` 的 `dshRepo` 常量，默认 `/Users/miao/deepseek-harness`，按需修改）
- 首次打开对话框时自动拉起 ACP server 子进程（`node --import tsx packages/examples/acp-demo/src/bin.ts`），通过 stdin/stdout 上的 ndjson JSON-RPC 通信
- 模型通过 `DSH_ACP_MODEL` 环境变量注入（需要在 dsh 仓库的 `examples/acp-agent/cordis.yml` 把 `model` 一行改为 `!!js "process.env.DSH_ACP_MODEL ?? 'deepseek-v4-pro'"`，本仓库假设已打此补丁）
- **安全边界**：agent 的文件系统和命令执行被沙箱限制在 `~/whale-pet/workspace`；一次性权限请求自动允许（仅在该沙箱范围内）
- 想让她操作别的目录，直接对话里说明即可——她会先复制/移动到 workspace 内处理
- `WHALEPET_SELFTEST=1 open dist/WhalePet.app` 可无界面自测 ACP 链路（结果写 `/tmp/whalepet-selftest.log`）

## 构建

依赖：macOS、Xcode Command Line Tools（`swiftc`）、python3、npm。

```sh
./build.sh
open dist/WhalePet.app
```

构建脚本会自动完成：npm 下载 dsh-pet 素材 → 创建 Python 虚拟环境（av/pillow/numpy）→ 从 webm 提取透明 PNG 帧（240px / 12fps）→ 生成应用图标 → `swiftc` 编译 → 打包 `dist/WhalePet.app`。

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
pet.swift          应用全部源码（AppKit，单文件）：宠物动画 + 对话气泡 + ACP 客户端 + 语音
extract_frames.py  帧提取脚本：webm → 抠黑底透明 PNG 序列
test-acp.py        ACP 链路独立冒烟测试（python3 test-acp.py）
build.sh           一键构建脚本
Info.plist         app 包配置（含权限说明文案）
```

想调整人设、记忆长度、朗读语速、动作频率，直接改 `pet.swift` 顶部的常量和 `systemPrompt`，然后重新运行 `./build.sh`。

## 许可

本仓库代码以 MIT 发布。动画素材版权归 dsh-pet 作者（PC2005-cloud）所有，同样以 MIT 许可使用。
