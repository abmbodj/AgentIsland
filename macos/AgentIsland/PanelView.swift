import SwiftUI

/// State shared between the island controller and the SwiftUI panel.
final class PanelModel: ObservableObject {
    @Published var snapshot = Snapshot() {
        didSet { updatePRs(old: oldValue) }
    }
    /// Parent sessions whose subagents are shown (collapsed by default).
    @Published var openGroups: Set<String> = []
    /// Row-level hint after a jump fell back (e.g. Automation permission declined).
    @Published var hint: [String: String] = [:]
    /// Laid-out height of the panel content, reported by SwiftUI.
    @Published var contentHeight: CGFloat = 0
    /// Only tick the elapsed-time clock while the panel is open.
    @Published var isOpen = false {
        didSet {
            if isOpen && !oldValue { refreshPRs(); refreshChats(); startPolling() }
            if !isOpen { chat = nil; entries = []; composing = false; confirmingDelete = nil } // collapsing returns to the list; running chats carry on
        }
    }
    /// Open PR button state and chosen base branch, by session id.
    @Published var pr: [String: PRState] = [:]
    @Published var prBase: [String: String] = [:]
    /// Keyboard mode (⌥⌘I): the panel is key, so shortcuts and typing work.
    @Published var summoned = false
    /// Which waiting card is shown, as an index into `cards`.
    @Published var cardIndex = 0
    /// A response inside its 2 s undo window.
    @Published var staged: Staged?
    /// Brief confirmation after a response is sent ("Approved").
    @Published var receipt: String?
    /// Multi-select picks and multi-question progress, per card.
    @Published var picks: [UInt64: Set<String>] = [:]
    @Published var answered: [UInt64: [String: String]] = [:]
    @Published var freeText = ""
    // Composer chats (see Chat.swift). `chat` is the open conversation; nil shows the session list.
    @Published var chats: [ChatInfo] = []
    @Published var chat: ChatInfo?
    @Published var entries: [ChatEntry] = []
    @Published var chatStatus = "idle"
    @Published var chatError: String?
    @Published var disconnected = false
    @Published var draft = ""
    /// The new-chat screen was opened on purpose (it also shows by itself when there is nothing else to show).
    @Published var composing = false
    /// The chat whose delete is awaiting its inline confirmation.
    @Published var confirmingDelete: Int?
    /// Which way the next screen change slides; set before the change so the outgoing screen uses it too.
    @Published var navForward = true
    @Published var composeError: String?
    /// The folder macOS is asking about right now; the island lowers itself so the prompt shows.
    @Published var accessPrompt: String?
    var checkingAccess = false
    /// Each agent's model menu from the core (`chatOptions`).
    @Published var options: [String: AgentOptions] = [:]
    /// The open conversation's choices once changed there; nil means the chat's last settings.
    @Published var replySettings: TurnSettings?
    var rev = 0
    var pollTimer: Timer?
    var onJump: (SessionInfo) -> Void = { _ in }
    /// Ask the controller to enter keyboard mode (e.g. to type a free-text answer).
    var onSummon: () -> Void = {}
    /// A response was committed (after the undo window).
    var onCommitted: () -> Void = {}

    struct Staged: Equatable {
        let id: UInt64
        let button: String
        let decision: String?
        let answers: [String: String]?
        let receipt: String
        let started: Date
    }

    static let undoWindow: TimeInterval = 2

    /// Waiting items across sessions, oldest first.
    var cards: [(session: SessionInfo, item: Attention)] {
        snapshot.sessions.flatMap { s in s.pending.map { (s, $0) } }.sorted { $0.item.since < $1.item.since }
    }

    var current: (session: SessionInfo, item: Attention)? {
        let c = cards
        return c.isEmpty ? nil : c[min(cardIndex, c.count - 1)]
    }

    func move(_ delta: Int) {
        let n = cards.count
        guard n > 1, staged == nil else { return }
        cardIndex = (min(cardIndex, n - 1) + delta + n) % n
        freeText = ""
    }

    /// Start the undo window for a response; it is sent when the window closes.
    func stage(_ item: Attention, button: String, decision: String? = nil, answers: [String: String]? = nil, receipt: String) {
        guard staged == nil else { return }
        let s = Staged(id: item.id, button: button, decision: decision, answers: answers, receipt: receipt, started: Date())
        staged = s
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.undoWindow) { [weak self] in
            guard let self, self.staged == s else { return }
            self.staged = nil
            var cmd: [String: Any] = ["type": "answer", "id": s.id]
            if let d = s.decision { cmd["decision"] = d }
            if let a = s.answers { cmd["answers"] = a }
            CoreBridge.shared.send(cmd)
            self.answered[s.id] = nil
            self.picks[s.id] = nil
            self.freeText = ""
            self.receipt = s.receipt
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                if self?.receipt == s.receipt { self?.receipt = nil }
            }
            self.onCommitted()
        }
    }

    func undo() {
        staged = nil
    }

    // MARK: Responses

    func allow(_ a: Attention) { stage(a, button: "allow", decision: "allow", receipt: "Approved") }
    func deny(_ a: Attention) { stage(a, button: "deny", decision: "deny", receipt: "Denied") }
    func allowSession(_ a: Attention) {
        guard a.canAllowSession else { return }
        stage(a, button: "session", decision: "allowSession", receipt: "Allowed for this session")
    }

    /// Choose option `n` (0-based) of the card's current question.
    func pick(_ a: Attention, option n: Int) {
        guard let q = question(of: a), n < q.options.count, staged == nil else { return }
        let label = q.options[n].label
        if q.multiSelect {
            var p = picks[a.id] ?? []
            if p.contains(label) { p.remove(label) } else { p.insert(label) }
            picks[a.id] = p
        } else {
            record(a, q, label, button: "option\(n)")
        }
    }

    func submitPicks(_ a: Attention) {
        guard let q = question(of: a), let p = picks[a.id], !p.isEmpty else { return }
        record(a, q, q.options.map(\.label).filter(p.contains).joined(separator: ", "), button: "submit")
    }

    func submitFreeText(_ a: Attention) {
        let text = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let q = question(of: a), !text.isEmpty else { return }
        record(a, q, text, button: "other")
    }

    /// The question still to be answered on a (possibly multi-question) card.
    func question(of a: Attention) -> Question? {
        let done = answered[a.id] ?? [:]
        return a.questions.first { done[$0.question] == nil }
    }

    private func record(_ a: Attention, _ q: Question, _ value: String, button: String) {
        var done = answered[a.id] ?? [:]
        done[q.question] = value
        freeText = ""
        if a.questions.allSatisfy({ done[$0.question] != nil }) {
            answered[a.id] = done
            stage(a, button: button, answers: done, receipt: "Answered")
        } else {
            answered[a.id] = done
        }
    }
}

enum Fmt {
    static func elapsed(_ ms: Int64, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince1970) - Int(ms / 1000))
        switch s {
        case ..<60: return "\(s)s"
        // ponytail: whole minutes past 60 s, so peripheral vision doesn't see a ticking clock.
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return "\(s / 3600)h \(String(format: "%02d", s % 3600 / 60))m"
        default: return "\(s / 86400)d"
        }
    }

    static func until(_ ms: Int64, now: Date) -> String {
        let s = max(0, Int(ms / 1000) - Int(now.timeIntervalSince1970))
        switch s {
        case ..<3600: return "\(max(1, s / 60))m"
        case ..<86400: return "\(s / 3600)h \(s % 3600 / 60)m"
        default: return "\(s / 86400)d \(s % 86400 / 3600)h"
        }
    }

    static func agentName(_ a: String) -> String {
        a == "codex" ? "Codex" : "Claude Code"
    }
}

private let ink = Color(nsColor: Theme.ink)
private let secondary = Color(nsColor: Theme.secondary)
private let muted = Color(nsColor: Theme.muted)
private let amber = Color(nsColor: Theme.amber)
private let green = Color(nsColor: Theme.green)

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PanelView: View {
    @ObservedObject var model: PanelModel
    /// Measured so the rows get whatever height the card and usage strip leave, and scroll past that.
    @State private var cardHeight: CGFloat = 0
    @State private var rowsHeight: CGFloat = 0
    @State private var stripHeight: CGFloat = 0

    private var list: some View {
        TimelineView(.periodic(from: .now, by: model.isOpen ? 1 : 3600)) { ctx in
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) { CardArea(model: model) }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
                // Panel padding is 4 top + 10 bottom.
                let room = max(60, IslandView.panelMaxHeight - 14 - cardHeight - stripHeight)
                ScrollView {
                    rows(ctx.date)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
                }
                .frame(height: rowsHeight == 0 ? nil : min(rowsHeight, room))
                HStack(alignment: .center, spacing: 8) {
                    UsageStrip(usage: model.snapshot.usage, now: ctx.date)
                    Spacer(minLength: 0)
                    NewChatButton(model: model).padding(.top, 8)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stripHeight = $0 }
            }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            switch model.screen {
            case .chat: ChatView(model: model).transition(.screen(forward: model.navForward))
            case .compose: NewChatView(model: model).transition(.screen(forward: model.navForward))
            case .list: list.transition(.screen(forward: model.navForward))
            }
        }
        .animation(Motion.screen, value: model.screen)
        .clipped()
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .frame(width: model.width, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
        .onPreferenceChange(HeightKey.self) { h in
            if abs(h - model.contentHeight) > 0.5 { model.contentHeight = h }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private func rows(_ now: Date) -> some View {
        VStack(spacing: 1) {
            // Chats the agents' hooks haven't reported as sessions; matched ones are the session rows below.
            ForEach(model.chats.filter { c in !model.snapshot.sessions.contains { $0.id == c.sessionId } }) { c in
                if model.confirmingDelete == c.id {
                    DeleteConfirm(chat: c, model: model).transition(.opacity)
                } else {
                    ChatRow(chat: c, model: model).transition(.opacity)
                }
            }
            ForEach(model.snapshot.sessions) { s in
                if let c = model.chatFor(s), model.confirmingDelete == c.id {
                    DeleteConfirm(chat: c, model: model).transition(.opacity)
                } else {
                    SessionRow(session: s, now: now, model: model)
                }
                if model.openGroups.contains(s.id) {
                    ForEach(s.subagents, id: \.id) { sub in
                        SubagentRow(sub: sub, agent: s.agent, now: now)
                            .transition(.opacity)
                    }
                }
            }
        }
    }
}

private struct SessionRow: View {
    let session: SessionInfo
    let now: Date
    @ObservedObject var model: PanelModel
    @State private var hover = false
    @State private var pressed = false

    private var status: (String, Color) {
        switch session.state {
        case .working: return (session.activity.isEmpty ? "Working" : session.activity, secondary)
        case .needsInput: return ("Needs your input", amber)
        case .finished: return ("Done", green)
        case .idle: return ("Idle", secondary)
        case .ended: return ("Ended", muted)
        case .error: return ("Exited unexpectedly", muted)
        case .stale: return ("No activity for 30m", muted)
        }
    }

    var body: some View {
        let open = model.openGroups.contains(session.id)
        let running = session.subagents.filter { !$0.done }.count
        HStack(alignment: .center, spacing: 10) {
            AgentBadge(agent: session.agent, state: session.state, size: 16)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.project.isEmpty ? "Session" : session.project)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Fmt.elapsed(session.since, now: now))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(secondary)
                }
                HStack(spacing: 6) {
                    Text(model.hint[session.id] ?? status.0)
                        .font(.system(size: 11, weight: session.state == .needsInput ? .medium : .regular))
                        .foregroundStyle(model.hint[session.id] == nil ? status.1 : muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    PRButton(model: model, session: session)
                    if !session.subagents.isEmpty {
                        Button {
                            withAnimation(.easeOut(duration: Theme.reduceMotion ? 0 : 0.18)) {
                                if open { model.openGroups.remove(session.id) } else { model.openGroups.insert(session.id) }
                            }
                        } label: {
                            Text("↳ \(running > 0 ? running : session.subagents.count)")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(open ? ink : secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.white.opacity(open ? 0.14 : 0.07)))
                        }
                        .buttonStyle(.plain)
                        .help(open ? "Hide subagents" : "Show subagents")
                        .accessibilityLabel("\(session.subagents.count) subagents")
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(pressed ? 0.11 : hover ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        // Press tint only; the tap stays a plain onTapGesture so the subagent chip's button still wins its own clicks.
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in pressed = true }.onEnded { _ in pressed = false })
        .onTapGesture { model.tap(session) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(model.chatFor(session) == nil ? "Shows this session's terminal" : "Opens this conversation")
        .contextMenu {
            if let c = model.chatFor(session) { Button("Delete chat") { model.confirmingDelete = c.id } }
        }
        // The row is one combined element, so its PR control is offered as actions.
        .accessibilityActions {
            switch model.pr[session.id] {
            case .ready: Button("Open pull request") { model.startPR(session) }
            case .staged: Button("Undo pull request") { model.undoPR(session.id) }
            case .writing(false): Button("Cancel pull request") { model.cancelPR(session) }
            case .done(let c): Button("Open PR #\(c.number)") { if let url = URL(string: c.url) { NSWorkspace.shared.open(url) } }
            case .failed: Button("Retry pull request") { model.retryPR(session) }
            default: EmptyView()
            }
            if let c = model.chatFor(session) { Button("Delete chat") { model.confirmingDelete = c.id } }
        }
    }
}

private struct SubagentRow: View {
    let sub: Subagent
    let agent: String
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if sub.done {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(green)
                } else {
                    GlyphView(agent: agent, state: .working, size: 5)
                }
            }
            .frame(width: 8, height: 8)
            Text(sub.kind.isEmpty ? "Subagent" : sub.kind)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ink)
            Text(sub.done ? "Done" : sub.activity)
                .font(.system(size: 11))
                .foregroundStyle(secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(Fmt.elapsed(sub.since, now: now))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(muted)
        }
        .padding(.leading, 48)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .opacity(sub.done ? 0.6 : 1)
    }
}

/// One quiet line: last reported limits, never extrapolated; hidden when nothing reliable exists.
private struct UsageStrip: View {
    let usage: Usage
    let now: Date

    var body: some View {
        let agents = [("claude", usage.claude), ("codex", usage.codex)].compactMap { n, u in u.map { (n, $0) } }
        if !agents.isEmpty {
            HStack(spacing: 14) {
                ForEach(agents, id: \.0) { agent, u in
                    HStack(spacing: 6) {
                        AgentMark(agent: agent, size: 11)
                        ForEach(u.windows, id: \.label) { w in
                            Text("\(w.label) \(Int(w.usedPercent.rounded()))%")
                                .fontWeight(w.usedPercent >= 90 ? .bold : .regular)
                                .foregroundStyle(w.usedPercent >= 90 ? ink : secondary)
                            + Text(" · \(Fmt.until(w.resetsAt, now: now))").foregroundStyle(muted)
                        }
                        if now.timeIntervalSince1970 * 1000 - Double(u.observedAt) > 15 * 60 * 1000 {
                            Text("as of \(Fmt.elapsed(u.observedAt, now: now)) ago").foregroundStyle(muted)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11).monospacedDigit())
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Usage limits")
        }
    }
}
