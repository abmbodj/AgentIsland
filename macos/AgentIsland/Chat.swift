import AppKit

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
    var id: Int { index }
}

struct ChatTranscript: Decodable {
    var status: String
    var error: String?
    var sessionId: String?
    var rev: Int
    var entries: [ChatEntry]
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

extension PanelModel {
    static let listWidth: CGFloat = 440
    static let chatWidth: CGFloat = 640
    static let chatHeight: CGFloat = 560

    /// Panel width: the list, or the wider conversation.
    var width: CGFloat { chat != nil ? Self.chatWidth : Self.listWidth }

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
        if let c = chatFor(s) { openChat(c) } else { onJump(s) }
    }

    func openChat(_ c: ChatInfo) {
        entries = []
        rev = 0
        chatStatus = c.status
        chatError = nil
        disconnected = false
        composeError = nil
        chat = c
        pollChat()
        startPolling()
    }

    func closeChat() {
        chat = nil
        entries = []
        composeError = nil
        refreshChats()
    }

    /// Start a new chat from the composer.
    func startChat() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            let r = try CoreBridge.shared.call(["op": "chatStart", "agent": composerAgent, "cwd": composerDir, "text": text], as: ChatStarted.self)
            draft = ""
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
        guard let c = chat, !text.isEmpty, chatStatus != "running" else { return }
        do {
            _ = try CoreBridge.shared.call(["op": "chatSend", "id": c.id, "text": text])
            draft = ""
            composeError = nil
            chatStatus = "running"
            pollChat()
        } catch {
            composeError = error.localizedDescription
        }
    }

    /// After a failed turn: send the last message again.
    func retryChat() {
        guard let c = chat, let last = entries.last(where: { $0.kind == "user" }) else { return }
        do {
            _ = try CoreBridge.shared.call(["op": "chatSend", "id": c.id, "text": last.text])
            chatStatus = "running"
            pollChat()
        } catch {
            composeError = error.localizedDescription
        }
    }

    func stopChat() {
        guard let c = chat else { return }
        _ = try? CoreBridge.shared.call(["op": "chatStop", "id": c.id])
    }

    func refreshChats() {
        if let list = try? CoreBridge.shared.call(["op": "chatList"], as: [ChatInfo].self), list != chats { chats = list }
    }

    func pollChat() {
        guard let c = chat else { return }
        do {
            let t = try CoreBridge.shared.call(["op": "transcript", "id": c.id, "since": rev], as: ChatTranscript.self)
            if disconnected { disconnected = false }
            for e in t.entries {
                if e.index < entries.count { entries[e.index] = e } else { entries.append(e) }
            }
            rev = t.rev
            if chatStatus != t.status { chatStatus = t.status }
            if chatError != t.error { chatError = t.error }
            if chat?.sessionId != t.sessionId { chat?.sessionId = t.sessionId }
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
            guard self.isOpen else { self.stopPolling(); return }
            tick += 1
            if self.chat != nil {
                self.pollChat()
            } else if tick % 12 == 0 {
                self.refreshChats()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

private struct ChatStarted: Decodable { var id: Int }
