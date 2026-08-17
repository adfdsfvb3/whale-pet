// WhalePet — 鲸鱼娘桌面宠物
// 无边框透明置顶窗，播放 dsh-pet 插件的帧动画；可拖动、点击出对话气泡。
// 对话优先走本地 dsh（DeepSeek Harness）的 ACP agent —— 有完整的工具能力
// （文件/命令/子代理，沙箱限制在 ~/whale-pet/workspace）；ACP 启动失败时
// 回退到直连 DeepSeek API 的纯聊天。语音输入用 macOS 原生 SFSpeechRecognizer
// （中文），回复用 AVSpeechSynthesizer 朗读。
// 帧素材由 extract_frames.py 从 dsh-pet 的 webm 提取（12fps, 240px, 透明底）。

import AVFoundation
import Cocoa
import Speech

let fps: TimeInterval = 1.0 / 12.0
let petSize: CGFloat = 220
let bubbleSize = NSSize(width: 340, height: 300)
let loopActions = ["idle", "drag"]
let clickActions = ["happy", "shy", "angry"]
let ambientActions = ["look", "hum", "stretch", "cube", "crab"]

let systemPrompt = "你是「鲸鱼娘」，一只穿女仆装的深海鲸鱼少女，住在用户的 Mac 桌面上当宠物。说话软萌、简短（每次一两句话），偶尔带「呜」「咕噜」等语气词。始终用中文回复。"

/// Prepended to the first ACP prompt so the harness agent keeps the pet persona
/// while retaining its full tool capabilities.
let acpPersonaPrefix = "（对话设定：你是住在用户 Mac 桌面上的女仆装鲸鱼娘桌面宠物，说话软萌、用中文；工具结果照实汇报，但日常对话保持简短可爱。以下开始是用户的话。）"

let dshRepo = "/Users/miao/deepseek-harness"
let nodeBin = "/Users/miao/.nvm/versions/node/v24.16.0/bin"

struct ChatMessage: Codable {
    let role: String
    let content: String
}

struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
}

struct ChatResponse: Decodable {
    struct Choice: Decodable { let message: ChatMessage }
    let choices: [Choice]
}

/// Models routed through the local dsh ACP agent; anything else goes direct API.
let acpModels = ["deepseek-v4-pro", "deepseek-v4-flash"]
let apiModels = ["deepseek-chat", "deepseek-reasoner"]
let defaultModel = "deepseek-v4-pro"

/// Ambient idle-action cadence presets; nil disables them.
let ambientOptions: [(title: String, range: ClosedRange<Double>?)] = [
    ("关闭", nil),
    ("偶尔", 60...120),
    ("正常", 25...60),
    ("频繁", 10...25),
]
let petSizeOptions: [(title: String, size: CGFloat)] = [
    ("小（160px）", 160),
    ("中（220px）", 220),
    ("大（300px）", 300),
]

/// Curated dsh web-profile plugins offered for one-click install.
let knownPlugins: [(pkg: String, desc: String)] = [
    ("@linxin666/dsh-web-ui-all", "全家桶聚合"),
    ("dsh-pet", "网页版鲸鱼娘宠物"),
    ("@linxin666/dsh-client-ui-task-board", "任务看板"),
    ("@linxin666/dsh-client-ui-git-graph", "Git 分支图"),
    ("@linxin666/dsh-live-stats", "实时 token 统计"),
    ("@linxin666/dsh-ssh", "SSH 远程操作"),
    ("@linxin666/dsh-remote-web-ui", "手机遥控"),
    ("@linxin666/dsh-skins", "皮肤全家桶"),
    ("@linxin666/dsh-client-ui-aionui-panel", "右侧面板系统"),
]

private func confPath() -> String { NSHomeDirectory() + "/.whalepet.conf" }

/// Parse ~/.whalepet.conf (`KEY=value` lines), overlaid on the process environment.
func loadConf() -> [String: String] {
    var conf: [String: String] = [:]
    if let text = try? String(contentsOfFile: confPath(), encoding: .utf8) {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty {
                    conf[parts[0].trimmingCharacters(in: .whitespaces)] = value
                }
            }
        }
    }
    if conf["DEEPSEEK_API_KEY"] == nil {
        conf["DEEPSEEK_API_KEY"] = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]
    }
    return conf
}

/// Write ~/.whalepet.conf with owner-only permissions. Keeps only known keys.
func saveConf(_ conf: [String: String]) {
    let order = ["DEEPSEEK_API_KEY", "WHALEPET_MODEL", "WHALEPET_TTS", "WHALEPET_TTS_RATE", "WHALEPET_SIZE", "WHALEPET_AMBIENT"]
    let lines = order.compactMap { key -> String? in
        guard let value = conf[key], !value.isEmpty else { return nil }
        return "\(key)=\(value)"
    }
    try? (lines.joined(separator: "\n") + "\n").write(toFile: confPath(), atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: confPath())
}

func loadAPIKey() -> String? {
    loadConf()["DEEPSEEK_API_KEY"]
}

// MARK: - Minimal ACP (Agent Client Protocol) client over stdio ndjson

enum AcpError: Error, LocalizedError {
    case boot(String)
    case rpc(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .boot(let detail): return "dsh 启动失败：\(detail)"
        case .rpc(let detail): return detail
        case .timeout(let method): return "\(method) 超时"
        }
    }
}

/// Speaks newline-delimited JSON-RPC 2.0 with a child process. All completion
/// handlers and event callbacks fire on the main queue.
final class AcpClient {
    var onEvent: ([String: Any]) -> Void = { _ in }
    var onExit: (Int32) -> Void = { _ in }

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var buffer = Data()
    private var nextId = 0
    private let lock = NSLock()
    private var pending: [Int: (Result<[String: Any], AcpError>) -> Void] = [:]
    private var timers: [Int: DispatchWorkItem] = [:]

    func start(executable: String, arguments: [String], cwd: String, env: [String: String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = env
        let outPipe = Pipe()
        let inPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardInput = inPipe
        process.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.readAvailable(handle)
        }
        // Drain stderr so the child never blocks on a full pipe.
        errPipe.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.onExit(proc.terminationStatus) }
        }
        try process.run()
        self.process = process
        stdinHandle = inPipe.fileHandleForWriting
    }

    func call(_ method: String, _ params: [String: Any], timeout: TimeInterval = 60,
              completion: @escaping (Result<[String: Any], AcpError>) -> Void) {
        lock.lock()
        nextId += 1
        let id = nextId
        pending[id] = completion
        lock.unlock()

        let timer = DispatchWorkItem { [weak self] in
            self?.fail(id, .timeout(method))
        }
        lock.lock()
        timers[id] = timer
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timer)

        write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    func respond(_ id: Int, result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func terminate() {
        process?.terminate()
    }

    private func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var line = data
        line.append(0x0A)
        stdinHandle?.write(line)
    }

    private func fail(_ id: Int, _ error: AcpError) {
        lock.lock()
        let completion = pending.removeValue(forKey: id)
        timers.removeValue(forKey: id)?.cancel()
        lock.unlock()
        guard let completion else { return }
        DispatchQueue.main.async { completion(.failure(error)) }
    }

    private func readAvailable(_ handle: FileHandle) {
        let data = handle.availableData
        if data.isEmpty { return }
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.prefix(newline))
            buffer.removeSubrange(...newline)
        }
        lock.unlock()
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: line),
                  let message = object as? [String: Any] else { continue }
            dispatch(message)
        }
    }

    private func dispatch(_ message: [String: Any]) {
        if let id = message["id"] as? Int, message["result"] != nil || message["error"] != nil {
            lock.lock()
            let completion = pending.removeValue(forKey: id)
            timers.removeValue(forKey: id)?.cancel()
            lock.unlock()
            guard let completion else { return }
            DispatchQueue.main.async {
                if let error = message["error"] as? [String: Any] {
                    completion(.failure(.rpc(error["message"] as? String ?? "未知错误")))
                } else if let result = message["result"] as? [String: Any] {
                    completion(.success(result))
                } else {
                    completion(.success([:]))
                }
            }
            return
        }
        DispatchQueue.main.async { self.onEvent(message) }
    }
}

// MARK: - Pet view (mouse handling)

final class PetView: NSImageView {
    var onDragStateChange: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onToggleChat: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenPlugins: (() -> Void)?
    var onOpenWeb: (() -> Void)?
    private var downPoint = NSPoint.zero
    private var dragged = false

    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        dragged = true
        onDragStateChange?(true)
        let mouse = NSEvent.mouseLocation
        window?.setFrameOrigin(NSPoint(x: mouse.x - downPoint.x, y: mouse.y - downPoint.y))
    }

    override func mouseUp(with event: NSEvent) {
        onDragStateChange?(false)
        guard !dragged else { return }
        if event.clickCount >= 2 {
            onDoubleClick?()
        } else {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "对话", action: #selector(chatAction(_:)), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "设置…", action: #selector(settingsAction(_:)), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "插件…", action: #selector(pluginsAction(_:)), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "打开完整版（Web）", action: #selector(webAction(_:)), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出鲸鱼娘", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.popUp(positioning: nil, at: event.locationInWindow, in: self)
    }

    @objc private func chatAction(_ sender: Any?) { onToggleChat?() }
    @objc private func settingsAction(_ sender: Any?) { onOpenSettings?() }
    @objc private func pluginsAction(_ sender: Any?) { onOpenPlugins?() }
    @objc private func webAction(_ sender: Any?) { onOpenWeb?() }
}

/// Borderless bubble panel that can still become key for text input.
final class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Controller

final class PetController: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    private var window: NSPanel!
    private var view: PetView!
    private var bubble: BubblePanel!
    private var transcript: NSTextView!
    private var input: NSTextField!
    private var micButton: NSButton!
    private var statusLabel: NSTextField!

    private var frames: [String: [NSImage]] = [:]
    private var action = "idle"
    private var index = 0
    private var timer: Timer?
    private var nextAmbient = Date().addingTimeInterval(.random(in: 25...50))

    // Direct-API fallback state
    private var history: [ChatMessage] = []

    // ACP state
    private var acp: AcpClient?
    private var acpSession: String?
    private var acpStarting = false
    private var acpFailed = false
    private var acpPersonaSent = false
    private var queuedPrompt: String?
    private var currentReply = ""

    // Settings
    private var settingsPanel: BubblePanel?
    private var keyField: NSSecureTextField?
    private var modelPopup: NSPopUpButton?
    private var settingsHint: NSTextField?
    private var ttsCheckbox: NSButton?
    private var ttsRateSlider: NSSlider?
    private var sizePopup: NSPopUpButton?
    private var ambientPopup: NSPopUpButton?
    private var loginCheckbox: NSButton?
    private var preferredModel: String = defaultModel
    private var currentPetSize: CGFloat = petSize
    private var ambientIndex = 2  // 正常
    private var wantsAcp: Bool { acpModels.contains(preferredModel) }
    private var launchAgentPath: String { NSHomeDirectory() + "/Library/LaunchAgents/local.whalepet.plist" }

    // Plugins
    private var pluginsPanel: BubblePanel?
    private var pluginLogView: NSTextView?
    private var pluginButtons: [String: NSButton] = [:]
    private var customPluginField: NSTextField?
    private var installRunning = false
    private var webProfileDir: String { NSHomeDirectory() + "/.dsh/profiles/web" }

    private let synthesizer = AVSpeechSynthesizer()
    private var speechEnabled = true
    private var synthesizerRate: Float = 0.52

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var workspace: String {
        NSHomeDirectory() + "/whale-pet/workspace"
    }

    /// WHALEPET_SELFTEST=1 runs a headless ACP smoke test at launch: boots the
    /// agent, sends one prompt, logs the outcome to /tmp/whalepet-selftest.log
    /// and exits. Used to verify the ACP path without UI interaction.
    private let selftest = ProcessInfo.processInfo.environment["WHALEPET_SELFTEST"] == "1"
    private let selftestLog = "/tmp/whalepet-selftest.log"

    private func selftestWrite(_ text: String) {
        let line = text + "\n"
        if let handle = FileHandle(forWritingAtPath: selftestLog) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: selftestLog, contents: line.data(using: .utf8))
        }
    }

    // MARK: - App setup

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rect = NSRect(origin: .zero, size: NSSize(width: petSize, height: petSize))
        window = NSPanel(contentRect: rect,
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        view = PetView(frame: rect)
        view.imageScaling = .scaleProportionallyUpOrDown
        window.contentView = view

        view.onDragStateChange = { [weak self] dragging in
            self?.play(dragging ? "drag" : "idle")
        }
        view.onClick = { [weak self] in self?.toggleBubble() }
        view.onDoubleClick = { [weak self] in self?.play(clickActions.randomElement()!) }
        view.onToggleChat = { [weak self] in self?.toggleBubble() }
        view.onOpenSettings = { [weak self] in self?.toggleSettings() }
        view.onOpenPlugins = { [weak self] in self?.togglePlugins() }
        view.onOpenWeb = { [weak self] in self?.openFullWeb() }

        let conf = loadConf()
        preferredModel = conf["WHALEPET_MODEL"] ?? defaultModel
        speechEnabled = conf["WHALEPET_TTS"] != "0"
        synthesizerRate = Double(conf["WHALEPET_TTS_RATE"] ?? "").map { Float($0) } ?? 0.52
        if let size = Double(conf["WHALEPET_SIZE"] ?? ""), petSizeOptions.contains(where: { $0.size == CGFloat(size) }) {
            currentPetSize = CGFloat(size)
            window.setContentSize(NSSize(width: currentPetSize, height: currentPetSize))
            view.frame = NSRect(origin: .zero, size: NSSize(width: currentPetSize, height: currentPetSize))
        }
        if let ambient = Int(conf["WHALEPET_AMBIENT"] ?? ""), ambientOptions.indices.contains(ambient) {
            ambientIndex = ambient
        }

        buildBubble()

        if let screen = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: screen.maxX - petSize - 40, y: screen.minY + 40))
        }
        window.orderFrontRegardless()

        play("idle")
        timer = Timer.scheduledTimer(withTimeInterval: fps, repeats: true) { [weak self] _ in
            self?.tick()
        }

        if selftest {
            selftestWrite("selftest: boot")
            startAcpIfNeeded()
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] poll in
                guard let self else { return }
                if self.acpSession != nil {
                    poll.invalidate()
                    self.selftestWrite("selftest: session ready")
                    self.sendAcp("用一句话介绍你自己。")
                } else if self.acpFailed {
                    poll.invalidate()
                    self.selftestWrite("selftest: ACP FAILED — " + self.statusLabel.stringValue)
                    exit(1)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        acp?.terminate()
    }

    private func buildBubble() {
        bubble = BubblePanel(contentRect: NSRect(origin: .zero, size: bubbleSize),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        bubble.isOpaque = false
        bubble.backgroundColor = .clear
        bubble.hasShadow = true
        bubble.level = .floating

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: bubbleSize))
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        bubble.contentView = effect

        let scroll = NSScrollView(frame: NSRect(x: 10, y: 78, width: bubbleSize.width - 20, height: bubbleSize.height - 88))
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        transcript = NSTextView(frame: scroll.bounds)
        transcript.isEditable = false
        transcript.drawsBackground = false
        transcript.font = NSFont.systemFont(ofSize: 12)
        transcript.textContainerInset = NSSize(width: 2, height: 4)
        transcript.textContainer?.widthTracksTextView = true
        scroll.documentView = transcript
        effect.addSubview(scroll)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 12, y: 56, width: bubbleSize.width - 24, height: 16)
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        effect.addSubview(statusLabel)

        input = NSTextField(frame: NSRect(x: 10, y: 12, width: bubbleSize.width - 106, height: 36))
        input.placeholderString = "和鲸鱼娘说点什么…"
        input.delegate = self
        effect.addSubview(input)

        micButton = NSButton(frame: NSRect(x: bubbleSize.width - 92, y: 12, width: 40, height: 36))
        micButton.title = "🎤"
        micButton.bezelStyle = .rounded
        micButton.target = self
        micButton.action = #selector(toggleRecording)
        effect.addSubview(micButton)

        let send = NSButton(frame: NSRect(x: bubbleSize.width - 48, y: 12, width: 38, height: 36))
        send.title = "发送"
        send.bezelStyle = .rounded
        send.target = self
        send.action = #selector(sendMessage)
        effect.addSubview(send)

        window.addChildWindow(bubble, ordered: .above)
        positionBubble()
    }

    private func positionBubble() {
        let pet = window.frame
        var origin = NSPoint(x: pet.midX - bubbleSize.width / 2,
                             y: pet.maxY + 10)
        if let screen = NSScreen.main?.visibleFrame {
            if origin.y + bubbleSize.height > screen.maxY {
                origin.y = pet.minY - bubbleSize.height - 10
            }
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - bubbleSize.width - 4)
        }
        bubble.setFrameOrigin(origin)
    }

    private func toggleBubble() {
        if bubble.isVisible {
            bubble.orderOut(nil)
        } else {
            positionBubble()
            bubble.orderFrontRegardless()
            bubble.makeFirstResponder(input)
            if transcript.string.isEmpty {
                appendLine("鲸鱼娘", "呜？找人家什么事呀～")
            }
            startAcpIfNeeded()
        }
    }

    // MARK: - Settings panel

    private func toggleSettings() {
        if settingsPanel == nil { buildSettings() }
        guard let panel = settingsPanel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        let all = acpModels + apiModels
        keyField?.stringValue = loadConf()["DEEPSEEK_API_KEY"] ?? ""
        modelPopup?.selectItem(at: all.firstIndex(of: preferredModel) ?? 0)
        ttsCheckbox?.state = speechEnabled ? .on : .off
        ttsRateSlider?.floatValue = synthesizerRate
        sizePopup?.selectItem(at: petSizeOptions.firstIndex(where: { $0.size == currentPetSize }) ?? 1)
        ambientPopup?.selectItem(at: ambientIndex)
        loginCheckbox?.state = FileManager.default.fileExists(atPath: launchAgentPath) ? .on : .off
        settingsHint?.stringValue = "保存后立即生效；切换模型或 key 会重启 dsh agent"
        let pet = window.frame
        panel.setFrameOrigin(NSPoint(x: pet.midX - panel.frame.width / 2, y: pet.maxY + 10))
        panel.orderFrontRegardless()
    }

    private func buildSettings() {
        let size = NSSize(width: 340, height: 350)
        let panel = BubblePanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        func label(_ text: String, _ y: CGFloat) {
            let l = NSTextField(labelWithString: text)
            l.frame = NSRect(x: 12, y: y + 2, width: 88, height: 20)
            effect.addSubview(l)
        }

        label("API Key：", 306)
        let keyField = NSSecureTextField(frame: NSRect(x: 100, y: 304, width: 228, height: 26))
        keyField.placeholderString = "sk-..."
        effect.addSubview(keyField)
        self.keyField = keyField

        label("模型：", 266)
        let modelPopup = NSPopUpButton(frame: NSRect(x: 100, y: 262, width: 228, height: 28))
        modelPopup.addItems(withTitles: acpModels.map { $0 + "（dsh agent）" } + apiModels.map { $0 + "（纯聊天）" })
        effect.addSubview(modelPopup)
        self.modelPopup = modelPopup

        label("朗读：", 226)
        let ttsCheckbox = NSButton(checkboxWithTitle: "朗读回复", target: nil, action: nil)
        ttsCheckbox.frame = NSRect(x: 100, y: 226, width: 84, height: 24)
        effect.addSubview(ttsCheckbox)
        self.ttsCheckbox = ttsCheckbox
        let ttsRateSlider = NSSlider(frame: NSRect(x: 192, y: 226, width: 136, height: 24))
        ttsRateSlider.minValue = 0.4
        ttsRateSlider.maxValue = 0.65
        ttsRateSlider.toolTip = "语速（慢 ← → 快）"
        effect.addSubview(ttsRateSlider)
        self.ttsRateSlider = ttsRateSlider

        label("大小：", 186)
        let sizePopup = NSPopUpButton(frame: NSRect(x: 100, y: 182, width: 228, height: 28))
        sizePopup.addItems(withTitles: petSizeOptions.map(\.title))
        effect.addSubview(sizePopup)
        self.sizePopup = sizePopup

        label("小动作：", 146)
        let ambientPopup = NSPopUpButton(frame: NSRect(x: 100, y: 142, width: 228, height: 28))
        ambientPopup.addItems(withTitles: ambientOptions.map(\.title))
        ambientPopup.toolTip = "待机时随机小动作的频率"
        effect.addSubview(ambientPopup)
        self.ambientPopup = ambientPopup

        let loginCheckbox = NSButton(checkboxWithTitle: "开机自动启动", target: nil, action: nil)
        loginCheckbox.frame = NSRect(x: 100, y: 106, width: 160, height: 24)
        effect.addSubview(loginCheckbox)
        self.loginCheckbox = loginCheckbox

        let hint = NSTextField(labelWithString: "")
        hint.frame = NSRect(x: 12, y: 58, width: 316, height: 40)
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2
        effect.addSubview(hint)
        settingsHint = hint

        let close = NSButton(frame: NSRect(x: 158, y: 14, width: 82, height: 32))
        close.title = "关闭"
        close.bezelStyle = .rounded
        close.target = self
        close.action = #selector(toggleSettingsAction)
        effect.addSubview(close)

        let save = NSButton(frame: NSRect(x: 246, y: 14, width: 82, height: 32))
        save.title = "保存"
        save.bezelStyle = .rounded
        save.target = self
        save.action = #selector(saveSettings)
        effect.addSubview(save)

        window.addChildWindow(panel, ordered: .above)
        settingsPanel = panel
    }

    @objc private func toggleSettingsAction() { toggleSettings() }

    @objc private func saveSettings() {
        let key = (keyField?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        let all = acpModels + apiModels
        let index = max(0, min(modelPopup?.indexOfSelectedItem ?? 0, all.count - 1))
        let model = all[index]
        let conf = loadConf()
        let agentChanged = model != preferredModel || key != (conf["DEEPSEEK_API_KEY"] ?? "")

        preferredModel = model
        speechEnabled = ttsCheckbox?.state == .on
        synthesizerRate = ttsRateSlider?.floatValue ?? 0.52
        let sizeIndex = max(0, min(sizePopup?.indexOfSelectedItem ?? 1, petSizeOptions.count - 1))
        let newSize = petSizeOptions[sizeIndex].size
        ambientIndex = max(0, min(ambientPopup?.indexOfSelectedItem ?? 2, ambientOptions.count - 1))
        nextAmbient = Date().addingTimeInterval(ambientOptions[ambientIndex].range?.lowerBound ?? .infinity)

        saveConf([
            "DEEPSEEK_API_KEY": key,
            "WHALEPET_MODEL": model,
            "WHALEPET_TTS": speechEnabled ? "1" : "0",
            "WHALEPET_TTS_RATE": String(format: "%.2f", synthesizerRate),
            "WHALEPET_SIZE": String(Int(newSize)),
            "WHALEPET_AMBIENT": String(ambientIndex),
        ])

        if newSize != currentPetSize {
            currentPetSize = newSize
            window.setContentSize(NSSize(width: newSize, height: newSize))
            view.frame = NSRect(origin: .zero, size: NSSize(width: newSize, height: newSize))
        }

        setLoginItem(loginCheckbox?.state == .on)

        settingsHint?.stringValue = "已保存 ✓"
        if agentChanged {
            // key/model 都是 ACP 子进程启动时注入的，必须重启才能生效。
            acp?.terminate()
            acp = nil
            acpSession = nil
            acpStarting = false
            acpFailed = false
            acpPersonaSent = false
            if wantsAcp { startAcpIfNeeded() }
        }
    }

    // MARK: - Login item (LaunchAgent)

    private func setLoginItem(_ enabled: Bool) {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: launchAgentPath)
        guard enabled != exists else { return }
        if enabled {
            guard let executable = Bundle.main.executablePath else { return }
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            	<key>Label</key>
            	<string>local.whalepet</string>
            	<key>ProgramArguments</key>
            	<array>
            		<string>\(executable)</string>
            	</array>
            	<key>RunAtLoad</key>
            	<true/>
            </dict>
            </plist>
            """
            try? plist.write(toFile: launchAgentPath, atomically: true, encoding: .utf8)
            runQuiet("/bin/launchctl", ["bootstrap", "gui/\(getuid())", launchAgentPath])
        } else {
            runQuiet("/bin/launchctl", ["bootout", "gui/\(getuid())/local.whalepet"])
            try? fm.removeItem(atPath: launchAgentPath)
        }
    }

    private func runQuiet(_ launch: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    // MARK: - dsh plugins panel

    private func togglePlugins() {
        if pluginsPanel == nil { buildPlugins() }
        guard let panel = pluginsPanel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        refreshPluginStates()
        let pet = window.frame
        panel.setFrameOrigin(NSPoint(x: pet.midX - panel.frame.width / 2, y: pet.maxY + 10))
        panel.orderFrontRegardless()
    }

    private func buildPlugins() {
        let size = NSSize(width: 340, height: 380)
        let panel = BubblePanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        let title = NSTextField(labelWithString: "dsh 插件（web 端）")
        title.frame = NSRect(x: 12, y: 348, width: 240, height: 20)
        title.font = NSFont.boldSystemFont(ofSize: 13)
        effect.addSubview(title)

        let rowHeight: CGFloat = 26
        let docView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: rowHeight * CGFloat(knownPlugins.count)))
        for (i, plugin) in knownPlugins.enumerated() {
            let y = rowHeight * CGFloat(knownPlugins.count - 1 - i)
            let label = NSTextField(labelWithString: "\(plugin.desc)  \(plugin.pkg)")
            label.frame = NSRect(x: 4, y: y + 3, width: 218, height: 20)
            label.font = NSFont.systemFont(ofSize: 10)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            docView.addSubview(label)

            let button = NSButton(frame: NSRect(x: 226, y: y + 1, width: 88, height: 24))
            button.title = "安装"
            button.bezelStyle = .rounded
            button.font = NSFont.systemFont(ofSize: 11)
            button.target = self
            button.action = #selector(installKnownAction(_:))
            button.identifier = NSUserInterfaceItemIdentifier(plugin.pkg)
            docView.addSubview(button)
            pluginButtons[plugin.pkg] = button
        }
        let scroll = NSScrollView(frame: NSRect(x: 10, y: 100, width: 320, height: 240))
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = docView
        effect.addSubview(scroll)

        let custom = NSTextField(frame: NSRect(x: 10, y: 66, width: 208, height: 26))
        custom.placeholderString = "任意 npm 包名，如 dsh-pet@0.1.2"
        effect.addSubview(custom)
        customPluginField = custom

        let installCustom = NSButton(frame: NSRect(x: 222, y: 64, width: 52, height: 28))
        installCustom.title = "安装"
        installCustom.bezelStyle = .rounded
        installCustom.target = self
        installCustom.action = #selector(installCustomAction)
        effect.addSubview(installCustom)

        let restart = NSButton(frame: NSRect(x: 278, y: 64, width: 52, height: 28))
        restart.title = "重启web"
        restart.bezelStyle = .rounded
        restart.target = self
        restart.action = #selector(restartWebAction)
        effect.addSubview(restart)

        let logScroll = NSScrollView(frame: NSRect(x: 10, y: 8, width: 320, height: 50))
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .noBorder
        logScroll.drawsBackground = false
        let logView = NSTextView(frame: logScroll.bounds)
        logView.isEditable = false
        logView.drawsBackground = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        logView.textContainer?.widthTracksTextView = true
        logScroll.documentView = logView
        effect.addSubview(logScroll)
        pluginLogView = logView

        window.addChildWindow(panel, ordered: .above)
        pluginsPanel = panel
    }

    private func pluginLog(_ text: String) {
        guard !text.isEmpty else { return }
        pluginLogView?.textStorage?.append(NSAttributedString(string: text + "\n"))
        pluginLogView?.scrollToEndOfDocument(nil)
    }

    private func refreshPluginStates() {
        let path = webProfileDir + "/package.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deps = json["dependencies"] as? [String: Any] else { return }
        for (pkg, _) in knownPlugins {
            let installed = deps[pkg] != nil
            let button = pluginButtons[pkg]
            button?.title = installed ? "已安装" : "安装"
            button?.isEnabled = !installed
        }
    }

    @objc private func installKnownAction(_ sender: NSButton) {
        guard let pkg = sender.identifier?.rawValue else { return }
        installPlugin(pkg, attempt: 0)
    }

    @objc private func installCustomAction() {
        let pkg = (customPluginField?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        guard !pkg.isEmpty else { return }
        installPlugin(pkg, attempt: 0)
    }

    @objc private func restartWebAction() {
        pluginLog("→ 重启 dsh web……")
        runQuiet("/usr/bin/pkill", ["-f", "apps/cli/src/bin.ts web"])
        let url = URL(string: "http://127.0.0.1:3080/")!
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.bootWeb(url, attempts: 0, openWhenUp: false)
        }
    }

    /// Runs `pnpm dsh plugin --profile web add <pkg>`. pnpm 11 blocks
    /// dependency build scripts by default; the CLI records undecided
    /// packages as `allowBuilds` placeholders in the profile's
    /// pnpm-workspace.yaml, so a failed first attempt is retried once after
    /// approving the placeholders.
    private func installPlugin(_ pkg: String, attempt: Int) {
        guard !installRunning else {
            pluginLog("已有安装任务在进行，等它结束再装")
            return
        }
        installRunning = true
        pluginLog("→ pnpm dsh plugin --profile web add \(pkg)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodeBin + "/pnpm")
        process.arguments = ["dsh", "plugin", "--profile", "web", "add", pkg]
        process.currentDirectoryURL = URL(fileURLWithPath: dshRepo)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = nodeBin + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["HOME"] = NSHomeDirectory()
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            DispatchQueue.main.async { self?.pluginLog(text) }
        }
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                self.installRunning = false
                if proc.terminationStatus == 0 {
                    self.pluginLog("✓ 安装完成：\(pkg)（若 web 在运行，点「重启web」生效）")
                    self.refreshPluginStates()
                } else if attempt == 0, self.approvePendingBuilds() {
                    self.pluginLog("…已批准依赖构建脚本，重试安装")
                    self.installPlugin(pkg, attempt: 1)
                } else {
                    self.pluginLog("✗ 安装失败（退出码 \(proc.terminationStatus)）")
                }
            }
        }
        do {
            try process.run()
        } catch {
            installRunning = false
            pluginLog("✗ 无法启动 pnpm：\(error.localizedDescription)")
        }
    }

    /// Approves `allowBuilds` placeholders the dsh CLI left undecided.
    /// Returns true when something changed and a retry is worthwhile.
    @discardableResult
    private func approvePendingBuilds() -> Bool {
        let path = webProfileDir + "/pnpm-workspace.yaml"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              text.contains("set this to true or false") else { return false }
        let approved = text.replacingOccurrences(of: "set this to true or false", with: "true")
        try? approved.write(toFile: path, atomically: true, encoding: .utf8)
        return true
    }

    // MARK: - Full web UI

    /// Open the dsh web UI in the browser, booting `pnpm dsh web` first if the
    /// port is not serving yet.
    private func openFullWeb() {
        let url = URL(string: "http://127.0.0.1:3080/")!
        probeWeb(url) { [weak self] up in
            if up {
                NSWorkspace.shared.open(url)
            } else {
                self?.bootWeb(url, attempts: 0, openWhenUp: true)
            }
        }
    }

    private func probeWeb(_ url: URL, done: @escaping (Bool) -> Void) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1.5)
        request.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: request) { _, response, _ in
            DispatchQueue.main.async {
                done((response as? HTTPURLResponse)?.statusCode == 200)
            }
        }.resume()
    }

    private func bootWeb(_ url: URL, attempts: Int, openWhenUp: Bool) {
        if attempts == 0 {
            statusLabel.stringValue = "正在启动 dsh web……"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", "cd \"\(dshRepo)\" && nohup \"\(nodeBin)/pnpm\" dsh web >/tmp/dsh-web.log 2>&1 &"]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = nodeBin + ":" + (env["PATH"] ?? "/usr/bin:/bin")
            process.environment = env
            try? process.run()
        }
        guard attempts < 90 else {
            statusLabel.stringValue = "dsh web 启动超时，日志见 /tmp/dsh-web.log"
            pluginLog("✗ dsh web 启动超时，日志见 /tmp/dsh-web.log")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.probeWeb(url) { up in
                if up {
                    self?.statusLabel.stringValue = ""
                    if openWhenUp {
                        NSWorkspace.shared.open(url)
                    } else {
                        self?.pluginLog("✓ dsh web 已重启：http://127.0.0.1:3080")
                    }
                } else {
                    self?.bootWeb(url, attempts: attempts + 1, openWhenUp: openWhenUp)
                }
            }
        }
    }

    // MARK: - Animation

    private func framesFor(_ name: String) -> [NSImage] {
        if let cached = frames[name] { return cached }
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("frames/\(name)"),
              let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        let images = files.sorted().compactMap { NSImage(contentsOfFile: "\(dir.path)/\($0)") }
        frames[name] = images
        return images
    }

    private func play(_ name: String) {
        guard name != action || !loopActions.contains(name) else { return }
        action = name
        index = 0
    }

    private func tick() {
        let list = framesFor(action)
        guard !list.isEmpty else { return }
        view.image = list[index]
        index += 1
        if index >= list.count {
            if loopActions.contains(action) {
                index = 0
            } else {
                play("idle")
            }
        }
        if action == "idle", Date() > nextAmbient {
            if let range = ambientOptions[ambientIndex].range {
                nextAmbient = Date().addingTimeInterval(.random(in: range))
                play(ambientActions.randomElement()!)
            } else {
                nextAmbient = Date.distantFuture
            }
        }
    }

    // MARK: - Chat plumbing

    private func appendLine(_ who: String, _ text: String) {
        appendRaw("\(who)：\(text)\n")
    }

    private func appendRaw(_ text: String) {
        transcript.textStorage?.append(NSAttributedString(string: text))
        transcript.scrollToEndOfDocument(nil)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        sendMessage()
    }

    @objc private func sendMessage() {
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input.stringValue = ""
        appendLine("你", text)

        if wantsAcp && !acpFailed {
            if acpSession != nil {
                sendAcp(text)
            } else {
                queuedPrompt = text
                statusLabel.stringValue = "dsh 还在启动，醒来自动发送……"
                startAcpIfNeeded()
            }
        } else {
            sendDirect(text)
        }
    }

    // MARK: - ACP (dsh agent)

    private func startAcpIfNeeded() {
        guard acp == nil, !acpStarting, !acpFailed else { return }
        guard let key = loadAPIKey() else {
            statusLabel.stringValue = "没有 API key：请把 DEEPSEEK_API_KEY=sk-... 写进 ~/.whalepet.conf"
            acpFailed = true
            return
        }
        guard FileManager.default.fileExists(atPath: dshRepo + "/packages/examples/acp-demo/src/bin.ts") else {
            statusLabel.stringValue = "找不到 dsh 仓库（\(dshRepo)），回退到普通聊天"
            acpFailed = true
            return
        }
        acpStarting = true
        statusLabel.stringValue = "正在唤醒 dsh agent……"

        try? FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)

        let client = AcpClient()
        client.onEvent = { [weak self] message in self?.handleAcpEvent(message) }
        client.onExit = { [weak self] status in
            guard let self else { return }
            self.acp = nil
            self.acpSession = nil
            self.acpStarting = false
            if !self.acpFailed {
                self.acpFailed = true
                self.statusLabel.stringValue = "dsh 进程退出（代码 \(status)），回退到普通聊天"
            }
        }

        var env = ProcessInfo.processInfo.environment
        env["DEEPSEEK_API_KEY"] = key
        env["DSH_ACP_MODEL"] = preferredModel
        env["PATH"] = nodeBin + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["HOME"] = NSHomeDirectory()

        do {
            try client.start(executable: nodeBin + "/node",
                             arguments: ["--import", "tsx",
                                         "packages/examples/acp-demo/src/bin.ts",
                                         "--config", "examples/acp-agent/cordis.yml"],
                             cwd: dshRepo, env: env)
        } catch {
            statusLabel.stringValue = "dsh 启动失败，回退到普通聊天"
            acpStarting = false
            acpFailed = true
            return
        }
        acp = client

        client.call("initialize", ["protocolVersion": 1, "clientCapabilities": [:]], timeout: 120) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.statusLabel.stringValue = error.localizedDescription
                self.acpStarting = false
                self.acpFailed = true
                self.acp?.terminate()
                self.acp = nil
            case .success:
                self.client_newSession(client)
            }
        }
    }

    private func client_newSession(_ client: AcpClient) {
        client.call("session/new", ["cwd": workspace, "mcpServers": []], timeout: 120) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.statusLabel.stringValue = error.localizedDescription
                self.acpStarting = false
                self.acpFailed = true
            case .success(let payload):
                self.acpSession = payload["sessionId"] as? String
                self.acpStarting = false
                self.statusLabel.stringValue = ""
                if let queued = self.queuedPrompt {
                    self.queuedPrompt = nil
                    self.sendAcp(queued)
                }
            }
        }
    }

    private func sendAcp(_ text: String) {
        guard let session = acpSession, let acp else {
            sendDirect(text)
            return
        }
        play("look")
        statusLabel.stringValue = "dsh agent 干活中……"
        currentReply = ""

        var prompt = text
        if !acpPersonaSent {
            prompt = acpPersonaPrefix + "\n\n" + text
            acpPersonaSent = true
        }
        appendRaw("鲸鱼娘：")

        acp.call("session/prompt",
                 ["sessionId": session, "prompt": [["type": "text", "text": prompt]]],
                 timeout: 600) { [weak self] result in
            guard let self else { return }
            self.statusLabel.stringValue = ""
            switch result {
            case .success:
                self.appendRaw("\n")
                if self.selftest {
                    self.selftestWrite("selftest: REPLY — " + self.currentReply)
                    exit(0)
                }
                self.speak(self.currentReply)
                self.play("happy")
            case .failure(let error):
                self.appendRaw("（出错了：\(error.localizedDescription)）\n")
                if self.selftest {
                    self.selftestWrite("selftest: PROMPT FAILED — \(error.localizedDescription)")
                    exit(1)
                }
                self.play("angry")
            }
        }
    }

    private func handleAcpEvent(_ message: [String: Any]) {
        guard let method = message["method"] as? String else { return }
        switch method {
        case "session/update":
            guard let params = message["params"] as? [String: Any],
                  let update = params["update"] as? [String: Any],
                  update["sessionUpdate"] as? String == "agent_message_chunk",
                  let content = update["content"] as? [String: Any],
                  let text = content["text"] as? String, !text.isEmpty else { return }
            currentReply += text
            appendRaw(text)
        case "session/request_permission":
            // 沙箱已把文件/命令限制在 workspace 内，一次性权限自动允许。
            guard let id = message["id"] as? Int,
                  let params = message["params"] as? [String: Any],
                  let options = params["options"] as? [[String: Any]] else { return }
            let chosen = options.first { ($0["kind"] as? String ?? "").hasPrefix("allow") } ?? options.first
            guard let optionId = chosen?["optionId"] as? String else { return }
            acp?.respond(id, result: ["outcome": ["outcome": "selected", "optionId": optionId]])
        default:
            break
        }
    }

    // MARK: - Direct DeepSeek API fallback

    private func sendDirect(_ text: String) {
        history.append(ChatMessage(role: "user", content: text))
        play("look")

        guard let key = loadAPIKey() else {
            statusLabel.stringValue = "没有 API key：请把 DEEPSEEK_API_KEY=sk-... 写进 ~/.whalepet.conf"
            play("angry")
            return
        }

        statusLabel.stringValue = "鲸鱼娘思考中……"
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ChatRequest(model: apiModels.contains(preferredModel) ? preferredModel : "deepseek-chat",
                               messages: [ChatMessage(role: "system", content: systemPrompt)] + history.suffix(12),
                               stream: false)
        request.httpBody = try? JSONEncoder().encode(body)
        request.timeoutInterval = 60

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async { self?.handleReply(data: data, response: response, error: error) }
        }.resume()
    }

    private func handleReply(data: Data?, response: URLResponse?, error: Error?) {
        if let error {
            statusLabel.stringValue = "网络错误：\(error.localizedDescription)"
            play("angry")
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let data,
              let parsed = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let reply = parsed.choices.first?.message.content, !reply.isEmpty else {
            let snippet = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            statusLabel.stringValue = "请求失败（HTTP \(status)）\(snippet.prefix(80))"
            play("angry")
            return
        }
        statusLabel.stringValue = ""
        history.append(ChatMessage(role: "assistant", content: reply))
        appendLine("鲸鱼娘", reply)
        play("happy")
        speak(reply)
    }

    // MARK: - Speech output (TTS)

    private func speak(_ text: String) {
        guard speechEnabled, !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let clipped = text.count > 200 ? String(text.prefix(200)) + "……后面太长，人家就不念啦" : text
        let utterance = AVSpeechUtterance(string: clipped)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = synthesizerRate
        synthesizer.speak(utterance)
    }

    // MARK: - Speech input (STT)

    @objc private func toggleRecording() {
        if audioEngine.isRunning {
            stopRecording()
            return
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    self?.statusLabel.stringValue = "语音识别权限被拒：请在系统设置 → 隐私与安全性 → 语音识别里允许"
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        if granted {
                            self?.startRecording()
                        } else {
                            self?.statusLabel.stringValue = "麦克风权限被拒：请在系统设置 → 隐私与安全性 → 麦克风里允许"
                        }
                    }
                }
            }
        }
    }

    private func startRecording() {
        guard let recognizer, recognizer.isAvailable else {
            statusLabel.stringValue = "语音识别暂不可用"
            return
        }
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true

        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.input.stringValue = result.bestTranscription.formattedString
                    if result.isFinal { self.stopRecording() }
                }
                if error != nil { self.stopRecording() }
            }
        }

        let node = audioEngine.inputNode
        let format = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            recognitionRequest.append(buffer)
        }
        do {
            audioEngine.prepare()
            try audioEngine.start()
            micButton.title = "⏹"
            statusLabel.stringValue = "在听你说……（说完点 ⏹ 或直接发送）"
            play("hum")
        } catch {
            statusLabel.stringValue = "麦克风启动失败：\(error.localizedDescription)"
            stopRecording()
        }
    }

    private func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        micButton.title = "🎤"
        if statusLabel.stringValue.hasPrefix("在听你说") { statusLabel.stringValue = "" }
        if action == "hum" { play("idle") }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = PetController()
app.delegate = controller
app.run()
