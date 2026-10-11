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
    var onJump: (SessionInfo) -> Void = { _ in }
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
                        Text("Start Claude Code in any terminal and it appears here.").font(.system(size: 11)).foregroundStyle(secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                } else if model.snapshot.sessions.count > 7 {
                    ScrollView { rows(ctx.date) }.frame(height: 7 * 47)
                } else {
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
