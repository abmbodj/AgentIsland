import AppKit
import Combine

/// Borderless, non-activating overlay. Never key, never main, never in the Dock / ⌘Tab / Mission Control.
final class IslandPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar // above the menu bar so it can sit flush with the notch
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
    }

    /// Only while summoned (⌥⌘I): then the panel takes keys without activating the app.
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Where the island lives on a given screen.
struct IslandGeometry: Equatable {
    /// The hardware notch (screen coordinates); zero width on displays without one.
    let notch: CGRect
    var hasNotch: Bool { notch.width > 0 }

    init(screen: NSScreen) {
        let f = screen.frame
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            let h = screen.safeAreaInsets.top
            notch = CGRect(x: f.minX + l.width, y: f.maxY - h, width: f.width - l.width - r.width, height: h)
        } else {
            // Floating pill centred in the menu bar strip.
            let bar = max(f.maxY - screen.visibleFrame.maxY, 24)
            notch = CGRect(x: f.midX, y: f.maxY - bar, width: 0, height: bar)
        }
    }
}

/// Which display(s) show the island (D22). Stored as "active" | "builtin" | "all" | "<display id>".
enum DisplayChoice {
    static var raw: String { UserDefaults.standard.string(forKey: "display") ?? "active" }

    static func id(_ s: NSScreen) -> String {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? ""
    }

    static var builtin: NSScreen? {
        NSScreen.screens.first { CGDisplayIsBuiltin(CGDirectDisplayID(UInt32(id($0)) ?? 0)) != 0 }
    }

    /// Screens to show islands on right now. One entry (nil = follow active) unless "all".
    static func targets() -> [NSScreen?] {
        switch raw {
        case "all": return NSScreen.screens
        case "active": return [nil]
        case "builtin": return [builtin ?? NSScreen.screens.first]
        case let id: return [NSScreen.screens.first { Self.id($0) == id } ?? builtin ?? NSScreen.screens.first]
        }
    }
}

/// Owns one overlay: decides expanded/collapsed, sizes the window to the island, routes clicks.
final class IslandController {
    /// nil = follow the active screen.
    private let fixedScreen: NSScreen?
    private let panel = IslandPanel()
    let model = PanelModel()
    private lazy var view = IslandView(model: model)
    private var geometry: IslandGeometry?
    private var snapshot = Snapshot()

    // Expansion state (D23).
    private var expanded = false
    private var pinned = false
    private var autoOpened = false
    private var pointerInside = false
    private var openTimer: DispatchWorkItem?
    private var closeTimer: DispatchWorkItem?
    private var viewedTimer: DispatchWorkItem?
    private var monitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var bound: Set<String> = []
    private var heightSink: AnyCancellable?
    private var chatSink: AnyCancellable?
    private var accessSink: AnyCancellable?

    var hoverDelay: TimeInterval { UserDefaults.standard.object(forKey: "hoverDelay") as? Double ?? 0.1 }
    var autoExpand: Bool { UserDefaults.standard.object(forKey: "autoExpand") as? Bool ?? true }

    init(screen: NSScreen? = nil) {
        fixedScreen = screen
        panel.contentView = view
        view.onClick = { [weak self] in self?.clicked() }
        view.onMotionCompletion = { [weak self] in
            guard let self else { return }
            self.fitWindow(to: self.view.islandRect)
        }
        heightSink = model.$contentHeight.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { if self?.expanded == true { self?.render(animated: true) } }
        }
        chatSink = model.$chat.map { $0 != nil }.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { if self?.expanded == true { self?.render(animated: true) } }
        }
        accessSink = model.$accessPrompt.map { $0 != nil }.removeDuplicates().sink { [weak self] on in
            self?.panel.level = on ? .normal : .statusBar // system prompts sit above normal windows
        }
        model.onJump = { [weak self] s in self?.jump(s) }
        model.onSummon = { [weak self] in self?.summon() }
        model.onCommitted = { [weak self] in
            // After the last answer, hand the keyboard back (D8).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let self, self.model.summoned, self.model.chat == nil, self.model.cards.isEmpty else { return }
                self.endSummon(collapse: true)
            }
        }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            (self?.key(e) ?? false) ? nil : e
        } as Any)

        let nc = NSWorkspace.shared.notificationCenter
        observers.append((nc, nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reposition()
            self?.appActivated()
        }))
        observers.append((nc, nc.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.render(animated: false) }))
        observers.append((NotificationCenter.default, NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.reposition() }))

        // The window only ever covers the visible island, so hover comes from a tracking area and
        // the rest of the screen is untouched. Only clicks elsewhere are observed (to close a pinned panel).
        view.onHover = { [weak self] inside in self?.hover(inside) }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.clickedOutside() } as Any)
        reposition()
        #if DEBUG
        let dnc = DistributedNotificationCenter.default()
        observers.append((dnc, dnc.addObserver(forName: Self.debugName("jump"), object: nil, queue: .main) { [weak self] n in
            if let id = n.object as? String, let s = self?.snapshot.sessions.first(where: { $0.id == id }) { self?.jump(s) }
        }))
        // Tap a session row by id, as a click would.
        observers.append((dnc, dnc.addObserver(forName: Self.debugName("tap"), object: nil, queue: .main) { [weak self] n in
            if let id = n.object as? String, let s = self?.model.snapshot.sessions.first(where: { $0.id == id }) { self?.model.tap(s) }
        }))
        // Writes what the panel shows (screen, open chat, chats and session ids) as JSON to a path under /tmp.
        observers.append((dnc, dnc.addObserver(forName: Self.debugName("state"), object: nil, queue: .main) { [weak self] n in
            guard let m = self?.model, let path = n.object as? String, path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") else { return }
            let state: [String: Any] = [
                "screen": "\(m.screen)", "chat": m.chat?.id ?? -1, "chatStatus": m.chatStatus, "entries": m.entries.count,
                "chats": m.chats.map { ["id": $0.id, "sessionId": $0.sessionId ?? "", "status": $0.status] },
                "sessions": m.snapshot.sessions.map { ["id": $0.id, "cwd": $0.cwd, "state": "\($0.state)"] },
            ]
            try? JSONSerialization.data(withJSONObject: state, options: .prettyPrinted).write(to: URL(fileURLWithPath: path))
        }))
        observers.append((dnc, dnc.addObserver(forName: Self.debugName("openGroup"), object: nil, queue: .main) { [weak self] n in
            if let id = n.object as? String { self?.model.openGroups.insert(id) }
        }))
        observers.append((dnc, dnc.addObserver(forName: Self.debugName("respond"), object: nil, queue: .main) { [weak self] n in
            guard let self, let what = n.object as? String else { return }
            guard let (_, item) = self.model.current else { if what == "undo" { self.model.undo() }; return }
            switch what {
            case "allow": self.model.allow(item)
            case "deny": self.model.deny(item)
            case "session": self.model.allowSession(item)
            case "undo": self.model.undo()
            case "submit": self.model.submitPicks(item)
            case let p where p.hasPrefix("pick:"): self.model.pick(item, option: Int(p.dropFirst(5)) ?? 0)
            default: break
            }
        }))
        observers.append((dnc, dnc.addObserver(forName: Self.debugName("expand"), object: nil, queue: .main) { [weak self] n in
            self?.setExpanded((n.object as? String) != "collapse", pinned: true)
        }))
        // "agent|message": start a chat from the composer, as if typed.
        observers.append((dnc, dnc.addObserver(forName: Self.debugName("compose"), object: nil, queue: .main) { [weak self] n in
            guard let self, let raw = n.object as? String else { return }
            let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            self.setExpanded(true, pinned: true)
            self.model.composerAgent = parts[0]
            self.model.draft = parts[1]
            self.model.startChat()
        }))
        // Replace the snapshot with an empty one (the next real change overwrites it): the "no sessions" state.
        observers.append((dnc, dnc.addObserver(forName: Self.debugName("emptySnapshot"), object: nil, queue: .main) { [weak self] _ in self?.update(Snapshot()) }))
        observers.append((dnc, dnc.addObserver(forName: Self.debugName("back"), object: nil, queue: .main) { [weak self] _ in self?.model.goBack() }))
        // "confirm" asks to delete the first chat; "delete" confirms it.
        observers.append((dnc, dnc.addObserver(forName: Self.debugName("deletechat"), object: nil, queue: .main) { [weak self] n in
            guard let m = self?.model, let c = m.chats.first else { return }
            if (n.object as? String) == "delete" { m.deleteChat(c) } else { m.confirmingDelete = c.id }
        }))
        observers.append((dnc, dnc.addObserver(forName: Self.debugName("newchat"), object: nil, queue: .main) { [weak self] _ in
            self?.setExpanded(true, pinned: true)
            self?.model.openCompose()
        }))
        // Writes a PNG of the island window to a path under /tmp (no Screen Recording permission needed).
        observers.append((dnc, dnc.addObserver(forName: Self.debugName("snapshot"), object: nil, queue: .main) { [weak self] n in
            guard let path = n.object as? String, path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/"),
                  let v = self?.panel.contentView,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }))
        #endif
    }

    #if DEBUG
    /// AGENT_ISLAND_DEBUG_ID makes this build answer only to its own debug notifications (e.g. beside another build).
    private static func debugName(_ n: String) -> Notification.Name {
        .init("com.abmbodj.agentisland.debug." + n + (ProcessInfo.processInfo.environment["AGENT_ISLAND_DEBUG_ID"] ?? ""))
    }
    #endif

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observers.forEach { $0.0.removeObserver($0.1) }
        observers = []
        panel.orderOut(nil)
    }

    func update(_ raw: Snapshot) {
        let snap = withoutChatQuestions(raw)
        let previousIDs = Set(snapshot.sessions.flatMap { $0.pending.map(\.id) })
        let gone = Set(snapshot.sessions.map(\.id)).subtracting(snap.sessions.map(\.id))
        if !gone.isEmpty {
            Jumper.forgetGhostty(gone)
            bound.subtract(gone)
            model.openGroups.subtract(gone)
        }
        snapshot = snap
        model.snapshot = snap
        for s in snap.sessions where s.terminal.program == "ghostty" && s.terminal.tmux == nil && !bound.contains(s.id) {
            bound.insert(s.id)
            Jumper.bindGhostty(s)
        }
        let ids = Set(snap.sessions.flatMap { $0.pending.map(\.id) })
        if let st = model.staged, !ids.contains(st.id) { model.staged = nil } // answered elsewhere meanwhile
        model.cardIndex = min(model.cardIndex, max(0, ids.count - 1))
        // New request: open, unless the user is already looking at that session (D35).
        for s in snap.sessions where s.pending.contains(where: { !previousIDs.contains($0.id) }) && !snap.paused {
            Jumper.isLookingAt(s) { [weak self] looking in
                guard let self else { return }
                if looking {
                    // You're already there: let the agent show its own prompt (D35).
                    self.release(s)
                    return
                }
                guard self.autoExpand, !self.snapshot.paused, self.snapshot.attention > 0 else { return }
                self.autoOpened = true
                self.setExpanded(true, pinned: self.pinned)
            }
        }
        if snap.attention == 0 && autoOpened {
            autoOpened = false
            if !pinned && !pointerInside { setExpanded(false, pinned: false); return }
        }
        render(animated: true)
        if expanded { scheduleViewed() }
    }

    /// A chat made here shows its own questions in the conversation, so they get no card and don't open the island.
    private func withoutChatQuestions(_ raw: Snapshot) -> Snapshot {
        var snap = raw
        // Chats are only polled while the island is open, so a chat started since may not be linked to its session yet.
        if !model.chats.isEmpty, snap.sessions.contains(where: { s in s.pending.contains { $0.kind == "question" } && model.chatFor(s) == nil }) { model.refreshChats() }
        for i in snap.sessions.indices where model.chatFor(snap.sessions[i]) != nil {
            let mine = snap.sessions[i].pending.filter { $0.kind == "question" && (!$0.held || $0.releasable) }
            guard !mine.isEmpty else { continue }
            for a in mine where a.held { CoreBridge.shared.send(["type": "release", "id": a.id]) }
            snap.sessions[i].pending.removeAll { a in mine.contains { $0.id == a.id } }
            snap.attention = max(0, snap.attention - mine.count)
        }
        return snap
    }

    // MARK: Expansion

    private func setExpanded(_ on: Bool, pinned pin: Bool) {
        openTimer?.cancel()
        closeTimer?.cancel()
        pinned = on && pin
        if !on { autoOpened = false; model.closeChat(animated: false) }
        guard on != expanded else { render(animated: true); return }
        expanded = on
        render(animated: true)
        if on { scheduleViewed() } else { viewedTimer?.cancel() }
    }

    private func clicked() {
        if expanded {
            // Clicking the island itself (not a row) closes it.
            setExpanded(false, pinned: false)
        } else {
            setExpanded(true, pinned: true)
        }
    }

    private func clickedOutside() {
        if model.summoned { endSummon(collapse: true); return }
        if expanded && !pointerInside {
            setExpanded(false, pinned: false)
        }
    }

    // MARK: Keyboard mode (D8)

    private var previousApp: NSRunningApplication?

    func toggleSummon() {
        model.summoned ? endSummon(collapse: true) : summon()
    }

    func summon() {
        guard !model.summoned else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        model.summoned = true
        panel.allowsKey = true
        setExpanded(true, pinned: true)
        panel.makeKeyAndOrderFront(nil) // non-activating panel: our app stays in the background
    }

    func endSummon(collapse: Bool) {
        guard model.summoned else { return }
        model.summoned = false
        panel.allowsKey = false
        panel.resignKey()
        previousApp?.activate()
        if collapse { setExpanded(false, pinned: false) }
    }

    /// Shortcuts while summoned. Returns true when handled.
    private func key(_ e: NSEvent) -> Bool {
        guard model.summoned else { return false }
        // Title editing owns all keys, including Escape and approval shortcuts.
        if model.editingTitle != nil {
            if e.keyCode == 53 { model.editingTitle = nil; return true }
            if e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               let editor = panel.firstResponder as? NSTextView {
                switch e.charactersIgnoringModifiers?.lowercased() {
                case "a": editor.selectAll(nil); return true
                case "c": editor.copy(nil); return true
                case "v": editor.paste(nil); return true
                case "x": editor.cut(nil); return true
                default: break
                }
            }
            return false
        }
        let typing = panel.firstResponder is NSTextView
        let cmd = e.modifierFlags.contains(.command)
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if cmd, chars == "[", model.canGoBack { // ⌘[ : back to the session list
            model.goBack()
            return true
        }
        if e.keyCode == 53 { // Esc
            if model.staged != nil {
                model.undo()
            } else if model.canGoBack {
                // Inside a chat Esc steps back, but never throws away a draft.
                if model.planReader != nil || model.draft.isEmpty { model.goBack() } else { endSummon(collapse: false) }
            } else {
                endSummon(collapse: true)
            }
            return true
        }
        guard let (_, item) = model.current else {
            return false
        }
        if cmd, item.held {
            switch chars {
            case "y" where item.kind == "approval": model.allow(item); return true
            case "n" where item.kind == "approval": model.deny(item); return true
            case "\r": model.submitPicks(item); return true
            default: break
            }
        }
        if let n = Int(chars), (1...9).contains(n), item.held, item.kind == "question", cmd || !typing {
            model.pick(item, option: n - 1)
            return true
        }
        if !typing && !cmd {
            switch (chars, e.keyCode) {
            case ("j", _), (_, 125): model.move(1); return true   // ↓
            case ("k", _), (_, 126): model.move(-1); return true  // ↑
            default: break
            }
        }
        return false
    }

    private func hover(_ inside: Bool) {
        guard inside != pointerInside, !snapshot.paused || !inside else { return }
        pointerInside = inside
        if inside {
            closeTimer?.cancel()
            if !expanded {
                let w = DispatchWorkItem { [weak self] in self?.setExpanded(true, pinned: false) }
                openTimer = w
                DispatchQueue.main.asyncAfter(deadline: .now() + hoverDelay, execute: w)
            }
        } else {
            openTimer?.cancel()
            // An open conversation stays until Back or a click outside; hover-out must not drop it mid-turn.
            if expanded && !pinned && !autoOpened && !model.canGoBack {
                let w = DispatchWorkItem { [weak self] in self?.setExpanded(false, pinned: false) }
                closeTimer = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
            }
        }
    }

    /// Finished turns count as seen once their rows have been on screen for 1.5 s (D17).
    private func scheduleViewed() {
        viewedTimer?.cancel()
        guard snapshot.sessions.contains(where: { $0.state == .finished }) else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.expanded else { return }
            for s in self.snapshot.sessions where s.state == .finished {
                CoreBridge.shared.send(["type": "viewed", "agent": s.agent, "id": s.id])
            }
        }
        viewedTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    /// Hand held-while-away requests back to the agent's own prompt.
    private func release(_ s: SessionInfo) {
        for a in s.pending where a.held && a.releasable {
            CoreBridge.shared.send(["type": "release", "id": a.id])
        }
    }

    /// When you switch to an app, release requests from sessions you're now looking at.
    private func appActivated() {
        for s in snapshot.sessions where s.pending.contains(where: { $0.held && $0.releasable }) {
            Jumper.isLookingAt(s) { [weak self] looking in if looking { self?.release(s) } }
        }
    }

    private func jump(_ s: SessionInfo) {
        release(s)
        CoreBridge.shared.send(["type": "viewed", "agent": s.agent, "id": s.id])
        Jumper.jump(s) { [weak self] hint in
            guard let self else { return }
            #if DEBUG
            if let path = ProcessInfo.processInfo.environment["AGENT_ISLAND_RENDER"],
               let h = FileHandle(forWritingAtPath: path + ".jumps") ?? { FileManager.default.createFile(atPath: path + ".jumps", contents: nil); return FileHandle(forWritingAtPath: path + ".jumps") }() {
                h.seekToEndOfFile()
                h.write("\(s.id) \(hint ?? "ok")\n".data(using: .utf8)!)
                try? h.close()
            }
            #endif
            self.model.hint[s.id] = hint
            if hint == nil {
                self.setExpanded(false, pinned: false)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.model.hint[s.id] = nil }
            }
        }
    }

    // MARK: Layout

    private func reposition() {
        guard let screen = fixedScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let g = IslandGeometry(screen: screen)
        guard g != geometry else { return }
        geometry = g
        // Envelope: the drawing space for wings and the dropped-down panel, anchored at the screen top.
        let w = max(g.notch.width + 440, PanelModel.chatWidth + 80)
        let h = g.notch.height + min(IslandView.chatMaxHeight, screen.visibleFrame.height - 40)
        envelopeOrigin = CGPoint(x: g.notch.midX - w / 2, y: screen.frame.maxY - h)
        view.envelope = CGSize(width: w, height: h)
        view.configure(notchWidth: g.notch.width, notchHeight: g.notch.height, hasNotch: g.hasNotch)
        windowRect = .zero
        render(animated: false)
    }

    private var envelopeOrigin = CGPoint.zero
    private var windowRect = CGRect.zero

    /// Cover all scalar extrema of the current flight, including momentum after a reversal.
    /// Only the coordinator's current-generation completion can shrink to the final silhouette.
    private func fitWindow(to target: CGRect) {
        guard !target.isEmpty else {
            panel.orderOut(nil)
            windowRect = .zero
            return
        }
        let r = target.integral
        if r != windowRect {
            windowRect = r
            panel.setFrame(r.offsetBy(dx: envelopeOrigin.x, dy: envelopeOrigin.y), display: false)
            view.setBoundsOrigin(r.origin)
            view.needsLayout = true
        }
        panel.orderFrontRegardless()
    }

    private func render(animated: Bool) {
        view.render(snapshot: snapshot, expanded: expanded, animated: animated)
        fitWindow(to: view.motionRect)
        #if DEBUG
        debugRender()
        #endif
    }

    #if DEBUG
    /// AGENT_ISLAND_RENDER=/path.png writes the island (over a light stand-in backdrop) after each render.
    private func debugRender() {
        guard let path = ProcessInfo.processInfo.environment["AGENT_ISLAND_RENDER"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [view] in
            let rect = view.islandRect.insetBy(dx: -30, dy: -12).intersection(view.bounds)
            guard rect.width > 0, let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return }
            view.cacheDisplay(in: rect, to: rep)
            let img = NSImage(size: rect.size)
            img.lockFocus()
            NSColor(white: 0.62, alpha: 1).setFill()
            rect.offsetBy(dx: -rect.minX, dy: -rect.minY).fill()
            rep.draw(in: CGRect(origin: .zero, size: rect.size))
            img.unlockFocus()
            if let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
        }
    }
    #endif
}
