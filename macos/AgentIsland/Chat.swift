import AppKit
import SwiftUI

// MARK: - Chat model (mirrors island-core's chat.rs JSON)

struct ChatInfo: Decodable, Equatable, Identifiable {
    var id: Int
    var agent: String
    var cwd: String
    var title: String
    /// "running" | "idle" | "failed"
    var status: String
    var sessionId: String?
    var error: String?
    var handoff: ChatHandoff?
    var handoffError: String?
    var settings: TurnSettings?
}

struct ChatEntry: Decodable, Equatable, Identifiable {
    var index: Int
    /// "user" | "assistant" | "tool" | "error" | "notice"
    var kind: String
    var text: String
    var name: String
    var input: String
    var output: String
    /// Tool rows: "running" | "done" | "error"
    var status: String
    /// What changed since the last turn, e.g. "Opus 5.5 · High"; empty when nothing did.
    var caption: String
    /// User rows: how many images went with the message.
    var images: Int
    /// Edit/MultiEdit/Write rows: lines the change adds and removes.
    var added: Int
    var removed: Int
    var id: Int { index }
}

/// An AskUserQuestion the agent is waiting on (the tool's own input shape).
struct ChatQuestionSet: Decodable, Equatable {
    struct Option: Decodable, Equatable { var label: String; var description: String? }
    struct Item: Decodable, Equatable {
        var question: String
        var header: String?
        var multiSelect: Bool?
        var options: [Option]
    }
    var questions: [Item]
}

/// A pasted or uploaded image, already shrunk and encoded for the agent.
struct ChatImage: Identifiable, Equatable {
    let id = UUID()
    let thumb: NSImage
    let mediaType = "image/png"
    let data: String

    static let limit = 5
    private static let maxSide: CGFloat = 1568

    /// Decode any image data, shrink its longest side to what the model reads, and re-encode as PNG.
    static func make(_ raw: Data) -> ChatImage? {
        guard let src = NSBitmapImageRep(data: raw) else { return nil }
        var w = CGFloat(src.pixelsWide), h = CGFloat(src.pixelsHigh)
        let k = min(1, maxSide / max(w, h))
        w = max(1, (w * k).rounded()); h = max(1, (h * k).rounded())
        guard let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = src.cgImage else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) else { return nil }
        return ChatImage(thumb: NSImage(cgImage: out, size: NSSize(width: w, height: h)), data: png.base64EncodedString())
    }

    /// Images on a pasteboard: image files copied in Finder, else raw image data (a screenshot).
    static func from(_ pb: NSPasteboard) -> [ChatImage] {
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let files = urls.compactMap { try? Data(contentsOf: $0) }.compactMap(make)
        if !files.isEmpty { return files }
        // A text copy from a word processor can carry a TIFF preview; only an image-only pasteboard is an image.
        guard pb.string(forType: .string) == nil else { return [] }
        let raw = pb.data(forType: .png) ?? pb.data(forType: .tiff)
        return raw.flatMap(make).map { [$0] } ?? []
    }
}

struct ChatPermission: Decodable, Equatable { var requestId: String; var tool: String; var detail: String }

struct ChatPlan: Decodable, Equatable, Identifiable {
    var version: Int
    var markdown: String
    var status: String
    var entryIndex: Int?
    var error: String?
    var id: Int { version }
}

struct ChatTranscript: Decodable {
    var plans: [ChatPlan]?
    var approval: ChatPermission?
    var settings: TurnSettings?
    var status: String
    var error: String?
    var sessionId: String?
    var rev: Int
    var entries: [ChatEntry]
    var handoff: ChatHandoff?
    var handoffError: String?
    var question: ChatQuestionSet?
}

/// One turn's choices; nil is Default (no flag, the CLI's own config). Mirrors chat.rs `Settings`.
struct TurnSettings: Codable, Equatable {
    var model: String?
    var effort: String?
    /// Claude permission mode or Codex sandbox; Codex treats nil as workspace-write.
    var mode: String?
    var fast = false
    /// The model's display name, for chips and captions.
    var name: String?
    /// Claude Ultracode; optional so choices saved before it existed still decode (nil is off).
    var ultracode: Bool?

    var isUltracode: Bool { ultracode == true }

    var dict: [String: Any] {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self))) as? [String: Any] ?? [:]
    }
}

struct ModelOption: Decodable, Equatable, Identifiable {
    var id: String
    var name: String
    var efforts: [String]
    var auto: Bool
    var fast: Bool
    /// The newest of its family; older pinned versions sit in a submenu.
    var latest = true
    /// Claude: Ultracode can take effect with this model (the CLI's own `ultracodeAvailable`).
    var ultracode = false
}

struct AgentOptions: Decodable, Equatable {
    var models: [ModelOption]
    var error: String?
    var loading: Bool
}

enum TurnLabels {
    /// The modes the island offers, with their glyphs; Claude's list starts with Default (empty id).
    static func modes(_ agent: String) -> [(id: String, name: String, icon: String)] {
        agent == "codex"
            ? [("read-only", "Read-only", "eye"), ("workspace-write", "Workspace write", "folder"),
               ("danger-full-access", "Full access", "exclamationmark.triangle")]
            : [("", "Default", "gearshape"), ("plan", "Plan", "list.bullet.clipboard"), ("acceptEdits", "Accept edits", "pencil"),
               ("auto", "Auto", "wand.and.stars"), ("bypassPermissions", "Bypass", "exclamationmark.triangle")]
    }

    // ponytail: mirrors Settings::caption in chat.rs; keep both in step.
    static func effort(_ e: String) -> String { e == "xhigh" ? "Extra high" : e.prefix(1).uppercased() + e.dropFirst() }

    /// Effort levels, lowest first, so snapping can step down.
    static let order = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
    static func rank(_ e: String) -> Int { order.firstIndex(of: e) ?? order.count }
}

extension TurnSettings {
    /// Levels the chosen model accepts. With Default model the island can't know which model the
    /// config picks, so it offers every level the CLI's models know.
    // ponytail: a Default model with a level its configured model lacks fails that turn with the CLI's own error.
    func effortLevels(in options: AgentOptions?) -> [String] {
        let models = options?.models ?? []
        if let id = model, let m = models.first(where: { $0.id == id }) { return m.efforts }
        return Array(Set(models.flatMap(\.efforts))).sorted { TurnLabels.rank($0) < TurnLabels.rank($1) }
    }

    /// Fit these choices to what the CLI lists: an unlisted model goes back to Default, effort snaps
    /// down to the highest supported level, and Auto or Fast drop when the model lacks them.
    /// An empty list (still loading, or the CLI failed) keeps the choices as they are.
    func fitted(to options: AgentOptions?, agent: String) -> TurnSettings {
        guard let options, !options.models.isEmpty else { return self }
        var s = self
        let m = s.model.flatMap { id in options.models.first { $0.id == id } }
        if m == nil { s.model = nil }
        s.name = m?.name
        let levels = s.effortLevels(in: options)
        if let e = s.effort, !levels.contains(e) {
            s.effort = levels.last { TurnLabels.rank($0) < TurnLabels.rank(e) }
        }
        if agent == "claude" {
            if s.mode == "auto", let m, !m.auto { s.mode = nil }
            if s.fast, !(m?.fast ?? false) { s.fast = false }
            if s.isUltracode, !(m?.ultracode ?? false) { s.ultracode = nil }
        } else {
            s.fast = false
            s.ultracode = nil
            if s.mode == "workspace-write" { s.mode = nil } // Codex's default
        }
        return s
    }

    #if DEBUG
    /// Assert-based check of the fitting rules; runs once at launch in Debug builds.
    static func selfCheck() {
        let opts = AgentOptions(models: [
            ModelOption(id: "opus", name: "Opus 5.5", efforts: ["low", "medium", "high", "xhigh", "max"], auto: true, fast: true, ultracode: true),
            ModelOption(id: "old", name: "Opus 4.6", efforts: ["low", "medium", "high", "max"], auto: false, fast: false),
        ], error: nil, loading: false)
        var s = TurnSettings(model: "old", effort: "xhigh", mode: "auto", fast: true)
        s = s.fitted(to: opts, agent: "claude")
        assert(s.effort == "high" && s.mode == nil && !s.fast && s.name == "Opus 4.6", "snap down, drop auto and fast")
        assert(TurnSettings(model: "gone").fitted(to: opts, agent: "claude").model == nil, "unlisted model goes to Default")
        let loading = AgentOptions(models: [], error: nil, loading: true)
        assert(TurnSettings(model: "gone").fitted(to: loading, agent: "claude").model == "gone", "an empty list keeps choices")
        assert(TurnSettings(fast: true).fitted(to: opts, agent: "codex").fast == false, "fast never reaches Codex")
        assert(TurnSettings(model: "opus", ultracode: true).fitted(to: opts, agent: "claude").isUltracode, "Ultracode stays where available")
        assert(!TurnSettings(model: "old", ultracode: true).fitted(to: opts, agent: "claude").isUltracode, "and drops where it isn't")
    }
    #endif
}

/// A reply split into prose and fenced code, so code gets a monospaced block with a Copy button.
enum ChatBlock: Equatable {
    case prose(String)
    case code(lang: String, body: String)

    /// An unclosed fence (the reply is still streaming) renders as code already.
    static func parse(_ text: String) -> [ChatBlock] {
        var blocks: [ChatBlock] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var lang: String?
        func flushProse() {
            let s = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { blocks.append(.prose(s)) }
            prose = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                if let l = lang {
                    blocks.append(.code(lang: l, body: code.joined(separator: "\n")))
                    code = []
                    lang = nil
                } else {
                    flushProse()
                    lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
            } else if lang != nil {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if let l = lang { blocks.append(.code(lang: l, body: code.joined(separator: "\n"))) }
        flushProse()
        return blocks
    }
}

// MARK: - Model

enum Screen: Equatable { case list, compose, chat }

extension PanelModel {
    static let listWidth: CGFloat = 440
    static let chatWidth: CGFloat = 640
    static let chatHeight: CGFloat = 560

    /// Panel width: the list and new-chat screen, or the wider conversation.
    var width: CGFloat { chat != nil || planReader != nil ? Self.chatWidth : Self.listWidth }

    /// With no sessions and no chats there is nothing to list, so the new-chat screen is the home screen.
    var hasHistory: Bool { !snapshot.sessions.isEmpty || !chats.isEmpty }

    var screen: Screen {
        if chat != nil { return .chat }
        return composing || !hasHistory ? .compose : .list
    }

    var canGoBack: Bool { planReader != nil || chat != nil || (composing && hasHistory) }

    /// Slide to another screen: the direction is set first, then the change lands on the next turn
    /// of the run loop, so the outgoing screen's removal transition already knows which way to leave.
    func navigate(forward: Bool, _ change: @escaping () -> Void) {
        navForward = forward
        DispatchQueue.main.async { change() }
    }

    func openCompose() {
        navigate(forward: true) { [self] in
            loadOptions(refresh: true)
            composeError = nil
            composing = true
        }
    }

    func goBack() {
        if planReader != nil { planReader = nil; return }
        if chat != nil {
            closeChat()
        } else if composing {
            navigate(forward: false) { [self] in composing = false }
        }
    }

    /// Claude Code or Codex, remembered.
    var composerAgent: String {
        get { UserDefaults.standard.string(forKey: "composerAgent") ?? "claude" }
        set { UserDefaults.standard.set(newValue, forKey: "composerAgent"); objectWillChange.send() }
    }

    /// The folder a new chat starts in: the one you picked, else the most recent session's, else home.
    var composerDir: String {
        let fm = FileManager.default
        if let d = UserDefaults.standard.string(forKey: "composerDir"), fm.fileExists(atPath: d) { return d }
        if let s = snapshot.sessions.max(by: { $0.since < $1.since }), fm.fileExists(atPath: s.cwd) { return s.cwd }
        return NSHomeDirectory()
    }

    var composerDirName: String {
        let d = composerDir
        return d == NSHomeDirectory() ? "~" : (d as NSString).lastPathComponent
    }

    private func remembered(_ agent: String) -> TurnSettings {
        guard let d = UserDefaults.standard.data(forKey: "composerSettings.\(agent)"),
              let s = try? JSONDecoder().decode(TurnSettings.self, from: d) else { return TurnSettings() }
        return s
    }

    /// The choices for the new-chat composer, or for the open chat's next turn.
    func settings(reply: Bool) -> TurnSettings {
        let agent = reply ? (chat?.agent ?? composerAgent) : composerAgent
        let s = reply ? (replySettings ?? chat?.settings ?? remembered(agent)) : remembered(agent)
        return s.fitted(to: options[agent], agent: agent)
    }

    /// A change in either composer is also remembered as that agent's choice for new chats.
    func setSettings(_ s: TurnSettings, reply: Bool) {
        let agent = reply ? (chat?.agent ?? composerAgent) : composerAgent
        let f = s.fitted(to: options[agent], agent: agent)
        if let d = try? JSONEncoder().encode(f) { UserDefaults.standard.set(d, forKey: "composerSettings.\(agent)") }
        if reply { replySettings = f }
        objectWillChange.send()
    }

    /// Pull the model menus; the core refetches in the background when asked and an hour has passed.
    func loadOptions(refresh: Bool) {
        guard let o = try? CoreBridge.shared.call(["op": "chatOptions", "refresh": refresh], as: [String: AgentOptions].self) else { return }
        if o != options { options = o }
        if o.values.contains(where: \.loading) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.loadOptions(refresh: false) }
        }
    }

    func chooseComposerDir() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.directoryURL = URL(fileURLWithPath: composerDir)
        p.prompt = "Choose"
        // The panel never activates the app; borrow focus for the dialog only.
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url {
            UserDefaults.standard.set(u.path, forKey: "composerDir")
            objectWillChange.send()
        }
    }

    func chatFor(_ s: SessionInfo) -> ChatInfo? { chats.first { $0.sessionId == s.id } }

    /// A session row opens its chat when it has one, else jumps to the terminal.
    func tap(_ s: SessionInfo) {
        // The chat list is only polled while open, so a just-started chat may not be linked to its row yet.
        if chatFor(s) == nil { refreshChats() }
        if let c = chatFor(s) { openChat(c) } else if s.hasPlan { openSessionPlan(s) } else { onJump(s) }
    }

    func openChat(_ c: ChatInfo) {
        navigate(forward: true) { [self] in
            entries = []
            plans = []
            planReader = nil
            planFeedback = ""
            planError = nil
            rev = 0
            chatStatus = c.status
            chatError = nil
            disconnected = false
            composeError = nil
            replySettings = nil
            chatQuestion = nil
            chatApproval = nil
            questionPicks = [:]
            images = []
            loadOptions(refresh: true)
            chat = c
            pollChat()
            startPolling()
        }
    }

    /// Back to the session list; not animated when the panel is collapsing.
    func closeChat(animated: Bool = true) {
        let change = { [self] in
            chat = nil
            replySettings = nil
            chatQuestion = nil
            images = []
            entries = []
            composeError = nil
            composing = false
            disconnected = false
            confirmingDelete = nil
            refreshChats()
        }
        if animated { navigate(forward: false, change) } else { change() }
    }

    /// Touch the folder from this app first: macOS asks "allow access to this folder?" on the first read, and the
    /// agent we spawn would otherwise stall silently behind that prompt. If the read blocks, the island steps
    /// down below the prompt (`accessPrompt`) so it can be answered.
    private func withFolderAccess(_ dir: String, _ proceed: @escaping () -> Void) {
        guard !checkingAccess else { return }
        checkingAccess = true
        var done = false
        let (screen0, chat0) = (screen, chat?.id)
        DispatchQueue.global().async {
            _ = try? FileManager.default.contentsOfDirectory(atPath: dir)
            DispatchQueue.main.async { [self] in
                done = true
                checkingAccess = false
                accessPrompt = nil
                composeError = nil
                // Skip if you went back or opened another chat while the prompt was up.
                if screen == screen0 && chat?.id == chat0 { proceed() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            guard !done else { return }
            accessPrompt = dir
            composeError = "Waiting for you to allow access to \((dir as NSString).lastPathComponent) in the macOS prompt. Full Disk Access in System Settings stops these for good."
        }
    }

    /// Agents run as this app's children, so every protected folder they touch (Desktop, Downloads, …) asks
    /// macOS for Agent Island. Full Disk Access answers all of those once; it can't be requested, only granted
    /// in System Settings, so the list offers it until it's on or you say not now.
    func checkDiskAccess() {
        // The user's TCC database opens only with Full Disk Access, and trying never shows a prompt.
        let db = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        let has = FileHandle(forReadingAtPath: db) != nil
        let show = !has && !UserDefaults.standard.bool(forKey: "diskAccessDismissed")
        if needsDiskAccess != show { needsDiskAccess = show }
    }

    func openDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    func dismissDiskAccess() {
        UserDefaults.standard.set(true, forKey: "diskAccessDismissed")
        needsDiskAccess = false
    }

    /// Start a new chat from the composer.
    func startChat() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return }
        withFolderAccess(composerDir) { [self] in beginChat(text) }
    }

    private func beginChat(_ text: String) {
        do {
            let r = try CoreBridge.shared.call(["op": "chatStart", "agent": composerAgent, "cwd": composerDir, "text": text, "images": imagePayload, "settings": settings(reply: false).dict], as: ChatStarted.self)
            draft = ""
            images = []
            composeError = nil
            refreshChats()
            if let c = chats.first(where: { $0.id == r.id }) { openChat(c) }
        } catch {
            composeError = error.localizedDescription
        }
    }

    /// Send the next turn in the open chat.
    func sendChat() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = chat, c.handoff == nil, !text.isEmpty || !images.isEmpty, chatStatus != "running" else { return }
        withFolderAccess(c.cwd) { [self] in
            do {
                _ = try CoreBridge.shared.call(["op": "chatSend", "id": c.id, "text": text, "images": imagePayload, "settings": settings(reply: true).dict])
                draft = ""
                images = []
                chatStatus = "running"
                pollChat()
            } catch {
                composeError = error.localizedDescription
            }
        }
    }

    var imagePayload: [[String: String]] { images.map { ["mediaType": $0.mediaType, "data": $0.data] } }

    func attach(_ new: [ChatImage]) {
        images = Array((images + new).prefix(ChatImage.limit))
    }

    func attachFiles(_ urls: [URL]) {
        attach(urls.compactMap { try? Data(contentsOf: $0) }.compactMap(ChatImage.make))
    }

    func chooseImages() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = true
        p.prompt = "Attach"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK { attachFiles(p.urls) }
    }

    /// Answer the agent's open question (`nil` declines it).
    func answerChat(_ answers: [String: String]?) {
        guard let c = chat else { return }
        var req: [String: Any] = ["op": "chatAnswer", "id": c.id]
        if let answers { req["answers"] = answers }
        do {
            _ = try CoreBridge.shared.call(req)
            chatQuestion = nil
            chatApproval = nil
            questionPicks = [:]
        } catch {
            composeError = error.localizedDescription
        }
    }

    /// After a failed turn: send the last message again.
    func retryChat() {
        guard let c = chat, c.handoff == nil, let last = entries.last(where: { $0.kind == "user" }) else { return }
        // ponytail: retry resends the text only; images aren't kept.
        guard !last.text.isEmpty else { composeError = "Attach the image again and send it as a new message."; return }
        do {
            _ = try CoreBridge.shared.call(["op": "chatSend", "id": c.id, "text": last.text, "settings": settings(reply: true).dict])
            chatStatus = "running"
            pollChat()
        } catch {
            composeError = error.localizedDescription
        }
    }

    /// Sign the CLI back in through the browser; core then resends the turn that failed.
    func signIn() {
        guard let c = chat, chatStatus != "running" else { return }
        do {
            _ = try CoreBridge.shared.call(["op": "chatLogin", "id": c.id])
            chatStatus = "running"
            pollChat()
        } catch {
            composeError = error.localizedDescription
        }
    }

    /// Remove a chat made here (stopping it if it is running).
    func deleteChat(_ c: ChatInfo) {
        _ = try? CoreBridge.shared.call(["op": "chatDelete", "id": c.id])
        withAnimation(Motion.quick) {
            confirmingDelete = nil
            if chat?.id == c.id {
                // Not through navigate(): the poll must never see this chat open after it is gone.
                navForward = false
                chat = nil
                entries = []
                composing = false
                disconnected = false
            }
            chats.removeAll { $0.id == c.id }
        }
        refreshChats()
    }

    func stopChat() {
        guard let c = chat else { return }
        _ = try? CoreBridge.shared.call(["op": "chatStop", "id": c.id])
    }

    func refreshChats() {
        if let list = try? CoreBridge.shared.call(["op": "chatList"], as: [ChatInfo].self) {
            if list != chats { chats = list }
            if let c = chat, let updated = list.first(where: { $0.id == c.id }) {
                if chat?.handoff != updated.handoff { chat?.handoff = updated.handoff }
                if chat?.handoffError != updated.handoffError { chat?.handoffError = updated.handoffError }
                if chat?.settings != updated.settings { chat?.settings = updated.settings }
            }
        }
    }

    func pollChat() {
        guard let c = chat else { return }
        do {
            let t = try CoreBridge.shared.call(["op": "transcript", "id": c.id, "since": rev], as: ChatTranscript.self)
            if disconnected { disconnected = false }
            if chatApproval != t.approval { chatApproval = t.approval }
            if let next = t.plans?.last, next.status == "ready", (next.version > (plans.last?.version ?? 0) || plans.last?.status == "writing") { planFeedback = "" }
            if plans != (t.plans ?? []) { plans = t.plans ?? [] }
            if chat?.settings != t.settings { chat?.settings = t.settings }
            for e in t.entries {
                if e.index < entries.count { entries[e.index] = e } else { entries.append(e) }
            }
            rev = t.rev
            if chatStatus != t.status { chatStatus = t.status }
            if chatError != t.error { chatError = t.error }
            if chat?.sessionId != t.sessionId { chat?.sessionId = t.sessionId }
            if chat?.handoff != t.handoff { chat?.handoff = t.handoff }
            if chat?.handoffError != t.handoffError { chat?.handoffError = t.handoffError }
            if chatQuestion != t.question { chatQuestion = t.question; questionPicks = [:] }
        } catch {
            disconnected = true
        }
    }

    /// The core is pulled, never pushed: fast while a chat is on screen, slow for the row statuses.
    func startPolling() {
        guard pollTimer == nil else { return }
        // ponytail: fixed 80 ms pull while open; a core push channel if idle chats ever need to wake the UI.
        var tick = 0
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.isOpen || self.chats.contains(where: { $0.handoff?.status == "queued" || $0.handoff?.status == "launching" }) else { self.stopPolling(); return }
            tick += 1
            if self.chat != nil {
                self.pollChat()
            }
            if tick % 12 == 0 {
                self.refreshChats()
                self.processHandoffs()
            }
        }
    }

    func requestHandoff(_ destination: HandoffDestination) {
        guard let c = chat else { return }
        if c.handoff?.status == "opened", c.handoffError == nil, let session = snapshot.sessions.first(where: {
            $0.id == c.sessionId && [.working, .idle, .needsInput].contains($0.state) && $0.terminal.bundleId == destination.bundleID
        }) {
            onJump(session)
            return
        }
        do {
            _ = try CoreBridge.shared.call(["op": "chatHandoff", "id": c.id, "target": destination.rawValue])
            composeError = nil
            refreshChats()
            startPolling()
            processHandoffs()
        } catch { composeError = error.localizedDescription }
    }

    func cancelHandoff() {
        guard let c = chat else { return }
        do {
            _ = try CoreBridge.shared.call(["op": "chatHandoffCancel", "id": c.id])
            refreshChats()
        } catch { composeError = error.localizedDescription }
    }

    /// A core claim is atomic across controllers; continue polling queued launches when collapsed.
    func processHandoffs() {
        guard let launches = try? CoreBridge.shared.call(["op": "chatHandoffClaim"], as: [HandoffLaunch].self) else { return }
        if !launches.isEmpty { refreshChats() }
        for launch in launches {
            HandoffLauncher.open(launch) { [weak self] error in
                var request: [String: Any] = ["op": "chatHandoffFinish", "id": launch.id, "token": launch.token]
                if let error { request["error"] = error }
                _ = try? CoreBridge.shared.call(request)
                self?.refreshChats()
                self?.pollChat()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

private struct ChatStarted: Decodable { var id: Int }
