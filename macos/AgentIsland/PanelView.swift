import SwiftUI
import Combine

enum SessionListRoute: Hashable {
    case activity, running, project(String), search
}

/// State shared between the island controller and the SwiftUI panel.
final class PanelModel: ObservableObject {
    @Published var snapshot = Snapshot() {
        didSet {
            updatePRs(old: oldValue)
            if snapshot.sessions != oldValue.sessions { rebuildSessionList() }
        }
    }
    /// Parent sessions whose subagents are shown (collapsed by default).
    @Published var openGroups: Set<SessionKey> = []
    @Published var listRoute: SessionListRoute = .activity
    @Published var expandedProject: String?
    @Published private(set) var sessionList = SessionList()
    @Published var searchQuery = "" {
        didSet { if oldValue != searchQuery { updateSearch() } }
    }
    @Published private(set) var searchResults: [SessionList.Entry] = []
    @Published var searchSelection: SessionList.ID?
    var searchFieldFocused = false
    private var sourceBeforeSearch: SessionListRoute = .activity
    /// Row-level hint after a jump fell back (e.g. Automation permission declined).
    @Published var hint: [String: String] = [:]
    /// Laid-out height of the panel content, reported by SwiftUI.
    @Published var contentHeight: CGFloat = 0
    /// Only tick the elapsed-time clock while the panel is open.
    @Published var isOpen = false {
        didSet {
            if isOpen && !oldValue {
                SessionTitles.shared.load()
                refreshPRs()
                refreshChats()
                rebuildSessionList()
                startPolling()
                checkDiskAccess()
            }
            if !isOpen && oldValue {
                loadingChat = false; editingTitle = nil; planReader = nil; chat = nil; entries = []; composing = false; confirmingDelete = nil
                listRoute = .activity
                expandedProject = nil
                sessionList = SessionList()
                searchQuery = ""
                searchResults = []
                searchSelection = nil
            }
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
    @Published var chats: [ChatInfo] = [] {
        didSet { if chats != oldValue { rebuildSessionList() } }
    }
    @Published var chat: ChatInfo?
    @Published var chatApproval: ChatPermission?
    @Published var plans: [ChatPlan] = []
    @Published var planReader: PlanReaderSource?
    @Published var planVersion: Int?
    @Published var planFeedback = ""
    @Published var editingPlan = false
    @Published var sendingPlan = false
    @Published var planError: String?
    @Published var entries: [ChatEntry] = []
    @Published var chatStatus = "idle"
    @Published var chatError: String?
    @Published var disconnected = false
    @Published var draft = ""
    /// Images attached to the draft; sent with the next message.
    @Published var images: [ChatImage] = []
    /// The open chat's pending AskUserQuestion, and the options picked so far per question.
    @Published var chatQuestion: ChatQuestionSet?
    @Published var questionPicks: [String: Set<String>] = [:]
    /// The new-chat screen was opened on purpose (it also shows by itself when there is nothing else to show).
    @Published var composing = false
    /// The chat whose delete is awaiting its inline confirmation.
    @Published var confirmingDelete: Int?
    /// Which way the next screen change slides; set before the change so the outgoing screen uses it too.
    @Published var navForward = true
    @Published var composeError: String?
    /// The folder macOS is asking about right now; the island lowers itself so the prompt shows.
    @Published var accessPrompt: String?
    /// Full Disk Access is off and the offer to turn it on hasn't been dismissed.
    @Published var needsDiskAccess = false
    var checkingAccess = false
    /// Each agent's model menu from the core (`chatOptions`).
    @Published var options: [String: AgentOptions] = [:]
    /// The open conversation's choices once changed there; nil means the chat's last settings.
    @Published var replySettings: TurnSettings?
    @Published var loadingChat = false
    var initialChatLoads: Set<Int> = []
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

    /// A single inline title editor at a time. Never takes focus until explicitly requested.
    @Published var editingTitle: [String]?
    @Published var titleDraft = ""
    private var titleChanges: AnyCancellable?

    init() {
        // A refresh can link several titles in one pass. Read their final values together.
        titleChanges = SessionTitles.shared.objectWillChange
            .debounce(for: .milliseconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildSessionList() }
    }

    private func rebuildSessionList() {
        guard isOpen else { return }
        var savedBySession: [SessionKey: ChatInfo] = [:]
        let saved = chats.map { chat in
            let key = chat.sessionId.map { SessionKey(agent: chat.agent, id: $0) }
            if let key, savedBySession[key] == nil { savedBySession[key] = chat }
            let state: SessionState = chat.status == "running" ? .working : chat.status == "failed" ? .error : .idle
            return SessionList.Saved(id: chat.id, agent: chat.agent, session: key, title: title(chat), cwd: chat.cwd, state: state)
        }
        let live = snapshot.sessions.map { session in
            let label = title(session, saved: savedBySession[session.key])
            return SessionList.Live(key: session.key, title: label, cwd: session.cwd, projectRoot: session.projectRoot,
                                    state: session.state, since: session.since)
        }
        sessionList = SessionList(live: live, saved: saved)
        if listRoute == .search { updateSearch() }
    }

    func startSearch() {
        guard screen == .list, planReader == nil, listRoute != .search else { return }
        sourceBeforeSearch = listRoute
        listRoute = .search
        updateSearch()
        onSummon()
    }

    func leaveListRoute() {
        let destination = listRoute == .search ? sourceBeforeSearch : .activity
        listRoute = destination
        searchQuery = ""
        searchResults = []
        searchSelection = nil
        confirmingDelete = nil
    }

    private func updateSearch() {
        guard listRoute == .search else { return }
        let previous = searchResults.first { $0.id == searchSelection }
        searchResults = sessionList.search(searchQuery)
        if !searchResults.contains(where: { $0.id == searchSelection }) {
            searchSelection = previous?.session.flatMap { key in searchResults.first { $0.session == key }?.id }
                ?? searchResults.first?.id
        }
    }

    func moveSearchSelection(_ delta: Int) {
        guard !searchResults.isEmpty else { return }
        let current = searchResults.firstIndex { $0.id == searchSelection } ?? 0
        searchSelection = searchResults[min(max(0, current + delta), searchResults.count - 1)].id
    }

    func openListEntry(_ entry: SessionList.Entry) {
        if listRoute == .search { searchSelection = entry.id }
        if let session = entry.session.flatMap({ key in snapshot.sessions.first { $0.key == key } }) {
            tap(session)
        } else if let saved = chats.first(where: { $0.id == entry.savedID }) {
            openChat(saved)
        } else {
            rebuildSessionList()
        }
    }

    func acknowledgeCompletion(_ key: SessionKey, since: Int64) {
        guard snapshot.sessions.contains(where: { $0.key == key && $0.state == .finished && $0.since == since }) else { return }
        CoreBridge.shared.send(["type": "viewed", "agent": key.agent, "id": key.id, "finishedSince": since])
    }

    func titleKeys(_ session: SessionInfo) -> [String] {
        titleKeys(session, saved: chatFor(session))
    }

    private func titleKeys(_ session: SessionInfo, saved: ChatInfo?) -> [String] {
        ["\(session.agent):\(session.id)"] + (saved.map { ["chat:\($0.id)"] } ?? [])
    }

    func titleKeys(_ chat: ChatInfo) -> [String] {
        (chat.sessionId.map { ["\(chat.agent):\($0)"] } ?? []) + ["chat:\(chat.id)"]
    }

    func title(_ session: SessionInfo) -> String {
        title(session, saved: chatFor(session))
    }

    private func title(_ session: SessionInfo, saved: ChatInfo?) -> String {
        SessionTitles.shared.title(for: titleKeys(session, saved: saved), fallback: saved?.title ?? session.project)
    }

    func title(_ chat: ChatInfo) -> String {
        SessionTitles.shared.title(for: titleKeys(chat), fallback: chat.title)
    }

    func isEditingTitle(_ keys: [String]) -> Bool {
        keys.contains { editingTitle?.contains($0) == true }
    }

    func editTitle(keys: [String], title: String) {
        titleDraft = title
        editingTitle = keys
        onSummon()
    }

    func saveTitle() {
        guard let keys = editingTitle else { return }
        SessionTitles.shared.save(titleDraft, for: keys)
        editingTitle = nil
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

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PanelView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: PanelModel
    var body: some View {
        ZStack(alignment: .top) {
            switch model.screen {
            case .chat: ChatView(model: model).transition(.screen(forward: model.navForward, reduceMotion: reduceMotion))
            case .compose: NewChatView(model: model).transition(.screen(forward: model.navForward, reduceMotion: reduceMotion))
            case .list: SessionListView(model: model).transition(.screen(forward: model.navForward, reduceMotion: reduceMotion))
            }
        }
        .offset(x: model.planReader != nil && !reduceMotion ? -28 : 0)
        .opacity(model.planReader == nil ? 1 : 0)
        .allowsHitTesting(model.planReader == nil)
        .accessibilityHidden(model.planReader != nil)
        .overlay {
            if model.planReader != nil {
                PlanReader(model: model)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(x: 28)))
            }
        }
        .animation(Motion.navigation(reduceMotion: reduceMotion), value: model.screen)
        .animation(Motion.navigation(reduceMotion: reduceMotion), value: model.planReader != nil)
        .animation(nil, value: reduceMotion)
        .frame(height: model.planReader != nil ? PanelModel.chatHeight : nil)
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
}
