import SwiftUI

private let ink = Color(nsColor: Theme.ink)
private let secondary = Color(nsColor: Theme.secondary)
private let muted = Color(nsColor: Theme.muted)
private let amber = Color(nsColor: Theme.amber)

private var easing: Animation? { Motion.quick }

// MARK: - Composer

/// Multi-line input: Return sends, Shift+Return inserts a newline. Clicking it asks the controller for
/// keyboard mode, because the island panel is never key on its own.
final class ComposerTextView: NSTextView {
    var onSend: () -> Void = {}
    var onFocus: () -> Void = {}
    var onPasteImages: ([ChatImage]) -> Void = { _ in }
    var placeholder = ""

    /// Pasting an image (a screenshot, or image files copied in Finder) attaches it instead of typing.
    override func paste(_ sender: Any?) {
        let images = ChatImage.from(.general)
        if images.isEmpty { super.paste(sender) } else { onPasteImages(images) }
    }

    // The island has no Edit menu, so ⌘V never reaches `paste:` unless the field takes it itself.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if window?.firstResponder === self, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, e.charactersIgnoringModifiers == "v" {
            paste(nil)
            return true
        }
        return super.performKeyEquivalent(with: e)
    }

    override func keyDown(with e: NSEvent) {
        if (e.keyCode == 36 || e.keyCode == 76), !e.modifierFlags.contains(.shift), !hasMarkedText() {
            onSend()
            return
        }
        super.keyDown(with: e)
    }

    override func mouseDown(with e: NSEvent) {
        onFocus()
        window?.makeFirstResponder(self)
        super.mouseDown(with: e)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: Theme.muted])
    }
}

struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focusTick: Int
    var onSend: () -> Void
    var onFocus: () -> Void
    var onPasteImages: ([ChatImage]) -> Void
    static let maxHeight: CGFloat = 120

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        var lastTick = 0
        init(_ p: ComposerField) { parent = p }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
            tv.needsDisplay = true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        let tv = ComposerTextView(frame: .zero)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: 13)
        tv.textColor = Theme.ink
        tv.insertionPointColor = Theme.ink
        tv.textContainerInset = NSSize(width: 0, height: 5)
        tv.setAccessibilityLabel("Message")
        tv.delegate = context.coordinator
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? ComposerTextView else { return }
        context.coordinator.parent = self
        tv.onSend = onSend
        tv.onFocus = onFocus
        tv.onPasteImages = onPasteImages
        if tv.placeholder != placeholder { tv.placeholder = placeholder; tv.needsDisplay = true }
        if tv.string != text { tv.string = text; tv.needsDisplay = true }
        if focusTick != context.coordinator.lastTick {
            context.coordinator.lastTick = focusTick
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let tv = nsView.documentView as? NSTextView, let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        let w = proposal.width ?? 300
        tc.containerSize = NSSize(width: w, height: CGFloat.greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let h = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2
        return CGSize(width: w, height: min(max(h, 28), Self.maxHeight))
    }
}

struct Composer: View {
    enum Mode { case new, reply }
    @ObservedObject var model: PanelModel
    let mode: Mode
    @State private var focusTick = 0

    private var running: Bool { mode == .reply && model.chatStatus == "running" }
    private var blank: Bool { model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.images.isEmpty }

    private func submit() {
        if mode == .new { model.startChat() } else { model.sendChat() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let e = model.composeError {
                Label(e, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(secondary)
                    .padding(.horizontal, 4)
                    .accessibilityLabel("Error: \(e)")
            }
            if !model.images.isEmpty { attachments }
            HStack(alignment: .bottom, spacing: 8) {
                Button { model.chooseImages() } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 2)
                .padding(.leading, -6)
                .accessibilityLabel("Attach images")
                .help("Attach images, or paste or drop them")
                ComposerField(
                    text: $model.draft,
                    placeholder: mode == .new ? "Start a new session…" : (running ? "Draft your next message…" : "Reply…"),
                    focusTick: focusTick,
                    onSend: { if !running { submit() } },
                    onFocus: {
                        if mode == .new { model.composing = true } // typing here: don't let the screen change underneath
                        model.onSummon()
                    },
                    onPasteImages: { model.attach($0) }
                )
                .frame(maxWidth: .infinity)
                Button {
                    if running { model.stopChat() } else { submit() }
                } label: {
                    Image(systemName: running ? "stop.fill" : "arrow.up")
                        .contentTransition(.symbolEffect(.replace))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(running || !blank ? Color.black : muted)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(running || !blank ? ink : Color.white.opacity(0.1)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!running && blank)
                .padding(.bottom, 2)
                .animation(Motion.quick, value: running)
                .animation(Motion.quick, value: blank)
                .accessibilityLabel(running ? "Stop" : (mode == .new ? "Start session" : "Send message"))
                .help(running ? "Stop this turn" : "Send (Return)")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.07)))
            .dropDestination(for: URL.self) { urls, _ in model.attachFiles(urls); return !urls.isEmpty }
            options
        }
        .onAppear {
            model.loadOptions(refresh: true)
            if model.summoned { focusTick += 1 }
        }
    }

    private var attachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.images) { img in
                    Image(nsImage: img.thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .topTrailing) {
                            Button { model.images.removeAll { $0.id == img.id } } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(ink, Color(white: 0.2))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 5, y: -5)
                            .accessibilityLabel("Remove image")
                        }
                        .padding(.top, 5).padding(.trailing, 5)
                        .accessibilityLabel("Attached image")
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var chipAgent: String { mode == .new ? model.composerAgent : (model.chat?.agent ?? model.composerAgent) }

    /// Which agent names the toggle shows; it gives up its labels before the folder name does.
    private enum ToggleLabels { case both, selected, none }

    private func agentToggle(_ labels: ToggleLabels) -> some View {
        HStack(spacing: 2) {
            ForEach(["claude", "codex"], id: \.self) { a in
                let on = model.composerAgent == a
                Button { model.composerAgent = a } label: {
                    HStack(spacing: 5) {
                        AgentMark(agent: a, size: 11)
                        if labels == .both || (labels == .selected && on) {
                            Text(a == "codex" ? "Codex" : "Claude").font(.system(size: 11, weight: .medium))
                        }
                    }
                    .foregroundStyle(on ? ink : secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule().fill(Color.white.opacity(on ? 0.14 : 0)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(Fmt.agentName(a))
                .accessibilityLabel(Fmt.agentName(a))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private var options: some View {
        HStack(spacing: 6) {
            if mode == .new {
                // A tight row (long mode, long model) compacts the toggle first, so the folder name stays readable.
                ViewThatFits(in: .horizontal) {
                    agentToggle(.both)
                    agentToggle(.selected)
                    agentToggle(.none)
                }
                .layoutPriority(1) // offered the leftover width before the spacer
            }
            Spacer(minLength: 0)
            TurnChips(
                agent: chipAgent,
                options: model.options[chipAgent],
                settings: model.settings(reply: mode == .reply),
                set: { model.setSettings($0, reply: mode == .reply) }
            )
            if mode == .new {
                Button { model.chooseComposerDir() } label: {
                    Chip(icon: "folder", text: model.composerDirName, menu: false)
                }
                .buttonStyle(IslandButtonStyle(radius: 6))
                .fixedSize()
                .help(model.composerDir)
                .accessibilityLabel("Working folder: \(model.composerDirName)")
                .accessibilityHint("Choose another folder")
            }
        }
        .padding(.horizontal, 2)
    }
}

private let ultracodeViolet = Color(nsColor: Theme.ultracode)

/// One composer-row chip: secondary ink at rest, a faint lift on hover (DESIGN.md: 6-8% white lifts).
/// With Ultracode on, the chip takes Claude Code's own violet and slowly breathes; Reduce Motion holds it still.
private struct Chip: View {
    var icon: String?
    let text: String
    var menu = true
    var ultracode = false
    @State private var hover = false
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The Ultracode tint; hover is its own layer so it never retargets the breath.
    private var fill: Color { ultracode ? ultracodeViolet.opacity(breathe ? 0.22 : 0.12) : .clear }
    /// The breath animates only the fill and hairline, never layout, so it can't catch the panel's own resize.
    private var breath: Animation {
        breathe ? .easeInOut(duration: 1.8).repeatForever(autoreverses: true) : Motion.quick
    }

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 10)).frame(width: 11) }
            Text(text).font(.system(size: 11, weight: ultracode ? .medium : .regular)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: menu ? 180 : 120, alignment: .leading) // only very long names truncate
            if menu { Image(systemName: "chevron.up.chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(ultracode ? ultracodeViolet.opacity(0.7) : muted) }
        }
        .foregroundStyle(ultracode ? ultracodeViolet : (hover ? ink : secondary))
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hover ? 0.08 : 0)))
        .background(RoundedRectangle(cornerRadius: 6).fill(fill).animation(breath, value: breathe))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(ultracodeViolet.opacity(ultracode ? (breathe ? 0.45 : 0.2) : 0), lineWidth: 1)
            .animation(breath, value: breathe))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Motion.quick) { hover = h } }
        .onChange(of: ultracode && !reduceMotion, initial: true) { _, on in breathe = on }
    }
}

/// Mode chip and Model chip: native menus, so items keep macOS checkmarks, sections and keyboard behaviour.
private struct TurnChips: View {
    let agent: String
    let options: AgentOptions?
    let settings: TurnSettings
    let set: (TurnSettings) -> Void

    private var models: [ModelOption] { options?.models ?? [] }
    private var current: ModelOption? { settings.model.flatMap { id in models.first { $0.id == id } } }
    private var modeID: String { settings.mode ?? (agent == "codex" ? "workspace-write" : "") }
    private var modes: [(id: String, name: String, icon: String)] {
        TurnLabels.modes(agent).filter { $0.id != "auto" || current?.auto != false }
    }
    private var mode: (id: String, name: String, icon: String) {
        TurnLabels.modes(agent).first { $0.id == modeID } ?? ("", "Default", "gearshape")
    }
    private var modelText: String {
        let parts = [settings.name ?? settings.model, settings.effort.map(TurnLabels.effort)].compactMap { $0 }
        return parts.isEmpty ? "Default" : parts.joined(separator: " · ")
    }

    private func update(_ change: (inout TurnSettings) -> Void) {
        var s = settings
        change(&s)
        set(s)
    }

    private var modelBinding: Binding<String> {
        Binding(get: { settings.model ?? "" }, set: { id in update { $0.model = id.isEmpty ? nil : id } })
    }

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                Picker("Mode", selection: Binding(get: { modeID }, set: { id in update { $0.mode = id.isEmpty ? nil : id } })) {
                    ForEach(modes, id: \.id) { Label($0.name, systemImage: $0.icon).tag($0.id) }
                }
                .pickerStyle(.inline)
            } label: {
                Chip(icon: mode.icon, text: mode.name)
            }
            .menuStyle(.button).buttonStyle(IslandButtonStyle(radius: 6)).menuIndicator(.hidden).fixedSize()
            .help("Mode")
            .accessibilityLabel("Mode: \(mode.name)")

            Menu {
                Picker("Model", selection: modelBinding) {
                    Text("Default").tag("")
                    ForEach(models.filter(\.latest)) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.inline)
                let older = models.filter { !$0.latest }
                if !older.isEmpty {
                    Menu("Older models") {
                        Picker("Older models", selection: modelBinding) {
                            ForEach(older) { Text($0.name).tag($0.id) }
                        }
                        .pickerStyle(.inline)
                    }
                }
                let levels = settings.effortLevels(in: options)
                if !levels.isEmpty {
                    Picker("Effort", selection: Binding(get: { settings.effort ?? "" }, set: { e in update { $0.effort = e.isEmpty ? nil : e } })) {
                        Text("Default").tag("")
                        ForEach(levels, id: \.self) { Text(TurnLabels.effort($0)).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
                if agent == "claude", current?.fast == true || current?.ultracode == true {
                    Divider()
                    if current?.fast == true {
                        Toggle("Fast mode", isOn: Binding(get: { settings.fast }, set: { on in update { $0.fast = on } }))
                    }
                    if current?.ultracode == true {
                        Toggle("Ultracode", isOn: Binding(get: { settings.isUltracode }, set: { on in update { $0.ultracode = on ? true : nil } }))
                    }
                }
                if models.isEmpty {
                    Text(options?.loading == true ? "Loading models…" : (options?.error ?? "Models unavailable")).disabled(true)
                }
            } label: {
                Chip(icon: settings.isUltracode ? "sparkles" : (settings.fast ? "bolt.fill" : "cpu"), text: modelText, ultracode: settings.isUltracode)
            }
            .menuStyle(.button).buttonStyle(IslandButtonStyle(radius: 6)).menuIndicator(.hidden).fixedSize()
            .help("Model and effort")
            .accessibilityLabel("Model: \(settings.name ?? settings.model ?? "Default")"
                + (settings.effort.map { ", effort \(TurnLabels.effort($0))" } ?? "") + (settings.fast ? ", fast mode" : "")
                + (settings.isUltracode ? ", Ultracode" : ""))
        }
    }
}

// MARK: - Conversation

private struct BottomKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ChatView: View {
    @ObservedObject var model: PanelModel
    @State private var follow = true
    @State private var viewport: CGFloat = 0
    @State private var wheel: Any?

    private var statusText: String {
        if model.disconnected { return "Disconnected" }
        switch model.chatStatus {
        case "running": return "Working"
        case "failed": return "Failed"
        default: return "Idle"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            CardArea(model: model)
            messages
            handoffFooter
                .padding(.horizontal, 6)
                .padding(.top, 4)
        }
        .frame(height: PanelModel.chatHeight)
    }

    @ViewBuilder private var header: some View {
        if let c = model.chat, model.confirmingDelete == c.id {
            DeleteConfirm(chat: c, model: model).padding(.bottom, 4).transition(.opacity)
        } else {
            headerBar.transition(.opacity)
        }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            BackButton { model.goBack() }
            Spacer(minLength: 0)
            if let c = model.chat {
                AgentMark(agent: c.agent, size: 12).accessibilityHidden(true)
                Text(c.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
            Text(statusText).font(.system(size: 11)).foregroundStyle(secondary)
                .accessibilityLabel("Status: \(statusText)")
            if let c = model.chat {
                Menu {
                    ForEach(HandoffDestination.choices(agent: c.agent)) { destination in
                        Button(destination.appURL == nil ? "\(destination.name) (not installed)" : destination.name) {
                            model.requestHandoff(destination)
                        }
                        .disabled(destination.appURL == nil)
                    }
                } label: {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 12)).foregroundStyle(secondary)
                        .frame(width: 28, height: 26)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(c.handoff != nil || model.disconnected)
                .accessibilityLabel("Open in…")
                .help("Continue this conversation in another app")
                Button { model.confirmingDelete = c.id } label: {
                    Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(secondary).frame(width: 28, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(IslandButtonStyle(radius: 6))
                .accessibilityLabel("Delete chat")
                .help("Delete this chat")
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 4)
    }

    @ViewBuilder private var handoffFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.chat?.handoffError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(secondary)
                    .textSelection(.enabled)
                    .accessibilityLabel("Could not open session: \(error)")
            }
            if let h = model.chat?.handoff, let destination = h.destination {
                HStack(spacing: 8) {
                    if h.status == "opened" {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Continued in \(destination.name)").font(.system(size: 12, weight: .medium))
                            Text("History through handoff · replies continue in the other app")
                                .font(.system(size: 10)).foregroundStyle(secondary)
                        }
                        Spacer(minLength: 0)
                        Button("Continue in \(destination.name)") { model.requestHandoff(destination) }
                            .buttonStyle(.borderless)
                    } else {
                        ProgressView().controlSize(.mini)
                        Text(h.status == "queued" ? "Opening \(destination.name) when finished…" : "Opening \(destination.name)…")
                            .font(.system(size: 12))
                        Spacer(minLength: 0)
                        if h.status == "queued" {
                            Button("Cancel") { model.cancelHandoff() }.buttonStyle(.borderless)
                                .accessibilityLabel("Cancel handoff")
                        }
                    }
                }
                .foregroundStyle(ink)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
            } else {
                Composer(model: model, mode: .reply)
            }
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.entries.isEmpty { empty }
                    ForEach(model.entries) { e in
                        EntryView(entry: e, needsApproval: needsApproval).transition(.rise)
                    }
                    if let q = model.chatQuestion {
                        QuestionCard(model: model, questions: q).transition(.rise)
                    } else if model.chatStatus == "running" && !model.disconnected {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Working").font(.system(size: 12)).foregroundStyle(secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    banner.transition(.rise)
                    Color.clear.frame(height: 1).id("bottom")
                        .background(GeometryReader { g in Color.clear.preference(key: BottomKey.self, value: g.frame(in: .named("chat")).minY) })
                }
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                // Only appends animate; text growing inside the last message is not a count change.
                .animation(Motion.quick, value: model.entries.count)
                .animation(Motion.quick, value: model.chatStatus)
            }
            .coordinateSpace(name: "chat")
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewport = $0 }
            .onPreferenceChange(BottomKey.self) { y in if y <= viewport + 40 { follow = true } }
            .onChange(of: model.entries) { scrollToEnd(proxy) }
            .onChange(of: model.chatStatus) { scrollToEnd(proxy) }
            .onAppear {
                scrollToEnd(proxy, animated: false)
                // Scrolling up means "let me read": stop following until the bottom is reached again.
                wheel = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
                    if e.scrollingDeltaY > 0 { follow = false }
                    return e
                }
            }
            .onDisappear { if let w = wheel { NSEvent.removeMonitor(w); wheel = nil } }
            .overlay(alignment: .bottom) {
                if !follow {
                    Button {
                        follow = true
                        scrollToEnd(proxy)
                    } label: {
                        Label("Latest", systemImage: "arrow.down")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ink)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(Capsule().fill(Color(white: 0.2)))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                    .transition(Theme.reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94)))
                    .accessibilityLabel("Scroll to latest message")
                }
            }
            .animation(Motion.quick, value: follow)
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard follow else { return }
        if animated, let a = easing {
            withAnimation(a) { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    /// A running tool is waiting on you when this chat's session has a held request.
    private var needsApproval: Bool {
        guard let sid = model.chat?.sessionId else { return false }
        return model.snapshot.sessions.contains { $0.id == sid && $0.pending.contains { $0.held } }
    }

    private var empty: some View {
        VStack(spacing: 4) {
            Text("No messages yet").font(.system(size: 13, weight: .semibold)).foregroundStyle(ink)
            Text("Your first message is on its way.").font(.system(size: 11)).foregroundStyle(secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var banner: some View {
        if model.disconnected {
            Banner(title: "Lost connection to this session", detail: "It may have ended when Agent Island restarted. Your earlier messages stay above.") {
                BannerButton(title: "Back to sessions") { model.goBack() }
            }
        } else if model.chatStatus == "failed" && model.chat?.handoff == nil {
            Banner(title: "This session stopped unexpectedly", detail: "Your last message may not have been received.") {
                BannerButton(title: "Try again") { model.retryChat() }
            }
        }
    }
}

/// The agent's AskUserQuestion: pick an option per question. One single-choice question answers on tap;
/// anything more asks for Submit. Skip declines, and the agent carries on without an answer.
private struct QuestionCard: View {
    @ObservedObject var model: PanelModel
    let questions: ChatQuestionSet

    private var immediate: Bool { questions.questions.count == 1 && questions.questions[0].multiSelect != true }
    private var ready: Bool { questions.questions.allSatisfy { !(model.questionPicks[$0.question] ?? []).isEmpty } }

    private func pick(_ q: ChatQuestionSet.Item, _ label: String) {
        if immediate { model.answerChat([q.question: label]); return }
        var s = model.questionPicks[q.question] ?? []
        if q.multiSelect == true {
            if !s.insert(label).inserted { s.remove(label) }
        } else {
            s = [label]
        }
        model.questionPicks[q.question] = s
    }

    private func submit() {
        // Keep the options' order, as a multi-select answer reads best in the order it was offered.
        model.answerChat(questions.questions.reduce(into: [:]) { out, q in
            out[q.question] = q.options.map(\.label).filter { (model.questionPicks[q.question] ?? []).contains($0) }.joined(separator: ", ")
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(questions.questions.enumerated()), id: \.offset) { _, q in
                VStack(alignment: .leading, spacing: 6) {
                    if let h = q.header, !h.isEmpty {
                        Text(h.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(muted)
                    }
                    Text(q.question).font(.system(size: 13, weight: .semibold)).foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)
                    ForEach(q.options, id: \.label) { o in
                        let on = (model.questionPicks[q.question] ?? []).contains(o.label)
                        Button { pick(q, o.label) } label: {
                            HStack(alignment: .top, spacing: 8) {
                                if !immediate {
                                    Image(systemName: q.multiSelect == true ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                                        .font(.system(size: 12)).foregroundStyle(on ? ink : muted)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(o.label).font(.system(size: 12, weight: .medium)).foregroundStyle(ink)
                                    if let d = o.description, !d.isEmpty {
                                        Text(d).font(.system(size: 11)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(on ? 0.14 : 0.07)))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            HStack(spacing: 8) {
                if !immediate {
                    Button("Submit", action: submit)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ready ? Color.black : muted)
                        .padding(.horizontal, 12).frame(height: 24)
                        .background(Capsule().fill(ready ? ink : Color.white.opacity(0.1)))
                        .disabled(!ready)
                }
                Button("Skip") { model.answerChat(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.1)))
        .accessibilityElement(children: .contain)
    }
}

private struct BannerButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(ink)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))
                .contentShape(Rectangle())
        }
        .buttonStyle(IslandButtonStyle(radius: 6))
    }
}

private struct Banner<Action: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(secondary)
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink)
            }
            Text(detail).font(.system(size: 12)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
            action
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Messages

private struct EntryView: View {
    let entry: ChatEntry
    let needsApproval: Bool

    var body: some View {
        switch entry.kind {
        case "user":
            HStack {
                Spacer(minLength: 56)
                VStack(alignment: .trailing, spacing: 3) {
                    if entry.images > 0 {
                        Label(entry.images == 1 ? "1 image" : "\(entry.images) images", systemImage: "photo")
                            .font(.system(size: 11)).foregroundStyle(secondary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
                    }
                    if !entry.text.isEmpty {
                        Text(entry.text)
                            .font(.system(size: 13))
                            .foregroundStyle(ink)
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
                    }
                    if !entry.caption.isEmpty {
                        Text(entry.caption).font(.system(size: 10)).foregroundStyle(muted).padding(.trailing, 4)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(entry.caption.isEmpty ? "You: \(entry.text)" : "You: \(entry.text). \(entry.caption)")
        case "assistant":
            AssistantText(text: entry.text)
        case "tool":
            ToolRow(entry: entry, needsApproval: needsApproval)
        case "error":
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(secondary)
                Text(entry.text).font(.system(size: 12)).foregroundStyle(secondary).textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Error: \(entry.text)")
        default:
            Text(entry.text).font(.system(size: 11)).foregroundStyle(muted).frame(maxWidth: .infinity)
        }
    }
}

private struct AssistantText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ChatBlock.parse(text).enumerated()), id: \.offset) { _, b in
                switch b {
                case .prose(let s):
                    Text(Self.inline(s))
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .foregroundStyle(ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let lang, let body):
                    CodeBlock(lang: lang, code: body)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

private struct CodeBlock: View {
    let lang: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? "code" : lang).font(.system(size: 11)).foregroundStyle(secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10))
                        Text(copied ? "Copied" : "Copy").font(.system(size: 11))
                    }
                    .foregroundStyle(copied ? ink : secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(IslandButtonStyle(radius: 5))
                .accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.top, 5)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
    }
}

private struct ToolRow: View {
    let entry: ChatEntry
    let needsApproval: Bool
    @State private var open = false

    private var waiting: Bool { entry.status == "running" && needsApproval }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(easing) { open.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(muted)
                        .frame(width: 10)
                    Text(entry.name.isEmpty ? "Tool" : entry.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ink)
                    Text(entry.input)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    if waiting {
                        Text("Needs approval").font(.system(size: 11, weight: .medium)).foregroundStyle(amber)
                    } else if entry.status == "running" {
                        ProgressView().controlSize(.mini)
                    } else if entry.status == "error" {
                        Label("Failed", systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(secondary)
                    }
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.name) \(entry.input)")
            .accessibilityValue(waiting ? "Needs approval" : entry.status == "running" ? "Running" : entry.status == "error" ? "Failed" : "Done")
            .accessibilityHint(open ? "Hides details" : "Shows details")
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    if !entry.input.isEmpty { detail("Input", entry.input) }
                    if !entry.output.isEmpty { detail("Output", entry.output) }
                    if entry.input.isEmpty && entry.output.isEmpty { Text("No details yet").font(.system(size: 11)).foregroundStyle(muted) }
                }
                .padding(.leading, 17)
                .transition(.opacity)
            }
        }
    }

    private func detail(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - New chat

struct BackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                Text("Sessions").font(.system(size: 12))
            }
            .foregroundStyle(secondary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(IslandButtonStyle(radius: 6))
        .accessibilityLabel("Back to sessions")
        .help("Back to sessions (⌘[)")
    }
}

/// The chat icon in the session list's footer.
struct NewChatButton: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        Button { model.openCompose() } label: {
            Image(systemName: "bubble.left")
                .font(.system(size: 13))
                .foregroundStyle(secondary)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(IslandButtonStyle(radius: 8))
        .accessibilityLabel("New chat")
        .help("New chat")
    }
}

/// Where a typed message starts a session. With nothing running it is the panel's home screen and keeps
/// the "no sessions" prompt; otherwise it is one step from the list.
struct NewChatView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.hasHistory {
                HStack {
                    BackButton { model.goBack() }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 4)
            }
            CardArea(model: model)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    AgentMark(agent: "claude", size: 14)
                    AgentMark(agent: "codex", size: 14)
                }
                .padding(.bottom, 6)
                .accessibilityHidden(true)
                Text(model.hasHistory ? "New session" : "No agent sessions")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ink)
                Text(model.hasHistory ? "Describe the task. The agent starts in the folder below." : "Type below to start one, or open Claude Code or Codex.")
                    .font(.system(size: 11))
                    .foregroundStyle(secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            Composer(model: model, mode: .new)
                .padding(.top, 6)
        }
    }
}

// MARK: - Deleting a chat

/// Inline confirmation in place of the row or header: no modal, nothing destructive on a single click.
struct DeleteConfirm: View {
    let chat: ChatInfo
    @ObservedObject var model: PanelModel

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Delete this chat?").font(.system(size: 12, weight: .semibold)).foregroundStyle(ink)
                Text(chat.status == "running" ? "It stops the agent and removes the conversation." : "It removes the conversation.")
                    .font(.system(size: 11)).foregroundStyle(secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { withAnimation(Motion.quick) { model.confirmingDelete = nil } } label: {
                Text("Cancel").font(.system(size: 12)).foregroundStyle(secondary).padding(.horizontal, 10).frame(height: 26).contentShape(Rectangle())
            }
            .buttonStyle(IslandButtonStyle(radius: 6))
            Button { model.deleteChat(chat) } label: {
                Text("Delete").font(.system(size: 12, weight: .semibold)).foregroundStyle(ink)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.14)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(IslandButtonStyle(radius: 6))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Delete \(chat.title)?")
    }
}

// MARK: - Session list rows for chats

/// A chat the agent's hooks haven't reported as a session (yet): same row, driven by the chat's own status.
struct ChatRow: View {
    let chat: ChatInfo
    @ObservedObject var model: PanelModel
    @State private var hover = false

    private var state: SessionState {
        switch chat.status {
        case "running": return .working
        case "failed": return .error
        default: return .idle
        }
    }

    private var status: String {
        switch chat.status {
        case "running": return "Working"
        case "failed": return "Failed"
        default: return "Idle"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            AgentBadge(agent: chat.agent, state: state, size: 16).frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
                Text(status).font(.system(size: 11)).foregroundStyle(secondary)
            }
            Spacer(minLength: 8)
            Button { model.confirmingDelete = chat.id } label: {
                Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(secondary).frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(IslandButtonStyle(radius: 6))
            .opacity(hover ? 1 : 0)
            .animation(Motion.quick, value: hover)
            .accessibilityHidden(true) // offered as an action on the row instead
            .help("Delete this chat")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(hover ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.openChat(chat) }
        .contextMenu { Button("Delete chat") { model.confirmingDelete = chat.id } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens this conversation")
        .accessibilityActions { Button("Delete chat") { model.confirmingDelete = chat.id } }
    }
}
