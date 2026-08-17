// WhalePet — 鲸鱼娘桌面宠物
// 无边框透明置顶窗，播放 dsh-pet 插件的帧动画；可拖动、点击出对话气泡。
// 对话直连 DeepSeek API（key 读自 ~/.whalepet.conf），语音输入用 macOS 原生
// SFSpeechRecognizer（中文），回复用 AVSpeechSynthesizer 朗读。
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

/// Read DEEPSEEK_API_KEY from ~/.whalepet.conf (`KEY=value` lines), falling
/// back to the process environment.
func loadAPIKey() -> String? {
    let path = NSHomeDirectory() + "/.whalepet.conf"
    if let text = try? String(contentsOfFile: path, encoding: .utf8) {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces) == "DEEPSEEK_API_KEY" {
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
        }
    }
    return ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]
}

final class PetView: NSImageView {
    var onDragStateChange: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onToggleChat: (() -> Void)?
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
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出鲸鱼娘", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.popUp(positioning: nil, at: event.locationInWindow, in: self)
    }

    @objc private func chatAction(_ sender: Any?) { onToggleChat?() }
}

/// Borderless bubble panel that can still become key for text input.
final class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

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

    private var history: [ChatMessage] = []
    private let synthesizer = AVSpeechSynthesizer()
    private var speechEnabled = true

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

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

        buildBubble()

        if let screen = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: screen.maxX - petSize - 40, y: screen.minY + 40))
        }
        window.orderFrontRegardless()

        play("idle")
        timer = Timer.scheduledTimer(withTimeInterval: fps, repeats: true) { [weak self] _ in
            self?.tick()
        }
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
            nextAmbient = Date().addingTimeInterval(.random(in: 25...60))
            play(ambientActions.randomElement()!)
        }
    }

    // MARK: - Chat

    private func appendLine(_ who: String, _ text: String) {
        let line = "\(who)：\(text)\n"
        transcript.textStorage?.append(NSAttributedString(string: line))
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
        let body = ChatRequest(model: "deepseek-chat",
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
        guard speechEnabled else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.52
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
