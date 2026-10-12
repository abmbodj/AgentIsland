import SwiftUI

/// State shared between the island controller and the SwiftUI panel.
final class PanelModel: ObservableObject {
    @Published var snapshot = Snapshot()
    /// Parent sessions whose subagents are shown (collapsed by default).
    @Published var openGroups: Set<String> = []
    /// Row-level hint after a jump fell back (e.g. Automation permission declined).
    @Published var hint: [String: String] = [:]
    /// Laid-out height of the panel content, reported by SwiftUI.
    @Published var contentHeight: CGFloat = 0
    /// Only tick the elapsed-time clock while the panel is open.
    @Published var isOpen = false
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
        case ..<3600: return "\(s / 60)m \(String(format: "%02d", s % 60))s"
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

    var body: some View {
        TimelineView(.periodic(from: .now, by: model.isOpen ? 1 : 3600)) { ctx in
            VStack(alignment: .leading, spacing: 0) {
                if model.snapshot.sessions.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("No agent sessions").font(.system(size: 13, weight: .semibold)).foregroundStyle(ink)
                        Text("Start Claude Code or Codex and it appears here.").font(.system(size: 11)).foregroundStyle(secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                } else if model.snapshot.sessions.count > 7 {
                    CardArea(model: model)
                    ScrollView { rows(ctx.date) }.frame(height: 5 * 47)
                } else {
                    CardArea(model: model)
                    rows(ctx.date)
                }
                UsageStrip(usage: model.snapshot.usage, now: ctx.date)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .frame(width: IslandView.panelWidth, alignment: .top)
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
                        ForEach(model.snapshot.sessions) { s in
                            SessionRow(session: s, now: now, model: model, showAgent: Set(model.snapshot.sessions.map(\.agent)).count > 1)
                            if model.openGroups.contains(s.id) {
                                ForEach(s.subagents, id: \.id) { sub in
                                    SubagentRow(sub: sub, now: now)
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
    var showAgent: Bool
    @State private var hover = false

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
            GlyphView(agent: session.agent, state: session.state, size: 8)
                .frame(width: 8, height: 8)
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
                    if showAgent {
                        Text(Fmt.agentName(session.agent))
                            .font(.system(size: 11))
                            .foregroundStyle(muted)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(hover ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.onJump(session) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows this session's terminal")
    }
}

private struct SubagentRow: View {
    let sub: Subagent
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if sub.done {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(green)
                } else {
                    GlyphView(agent: "claude", state: .working, size: 5)
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
        .padding(.leading, 38)
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
        let agents = [("Claude", usage.claude), ("Codex", usage.codex)].compactMap { n, u in u.map { (n, $0) } }
        if !agents.isEmpty {
            HStack(spacing: 14) {
                ForEach(agents, id: \.0) { name, u in
                    HStack(spacing: 6) {
                        Text(name).foregroundStyle(muted)
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
