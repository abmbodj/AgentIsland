import AppKit
import SwiftUI

/// A branch the core says can get a PR (`prReady`).
struct PRReady: Decodable, Equatable {
    var repo: String
    var head: String
    var base: String
    var bases: [String]
}

struct PRCreated: Decodable, Equatable {
    var url: String
    var number: Int
    /// The branch already had an open PR.
    var existing: Bool
}

enum PRState: Equatable {
    case ready(PRReady)
    /// Inside the 2 s undo window.
    case staged(PRReady, base: String, started: Date)
    case writing(cancelling: Bool)
    case done(PRCreated)
    case failed(PRReady, String)
}

extension SessionInfo {
    var isClaudeDesktop: Bool { terminal.bundleId == "com.anthropic.claudefordesktop" }

    /// The turn is over and the branch may be ready: the desktop app offered a PR, or a CLI/Codex
    /// turn ended (Finished turns become Idle once seen, so both count).
    var prEligible: Bool {
        isClaudeDesktop ? prOffer != nil && state != .working : (state == .finished || state == .idle)
    }
}

/// git, gh and the headless writer run here, never on main.
private let prQueue = DispatchQueue(label: "agentisland.pr", attributes: .concurrent)

extension PanelModel {
    /// Check eligible sessions' branches: all of them when the panel opens, or the ones that just became eligible.
    func refreshPRs(only ids: Set<String>? = nil) {
        for s in snapshot.sessions where s.prEligible && ids.map({ $0.contains(s.id) }) ?? true {
            if case .ready = pr[s.id] {} else if pr[s.id] != nil { continue } // leave in-flight, done and failed alone
            let (id, cwd, offered) = (s.id, s.cwd, s.isClaudeDesktop)
            prQueue.async {
                let r = (try? CoreBridge.shared.call(["op": "prReady", "cwd": cwd, "offered": offered], as: PRReady?.self)) ?? nil
                DispatchQueue.main.async { self.applyReady(id, r) }
            }
        }
    }

    private func applyReady(_ id: String, _ r: PRReady?) {
        if let current = pr[id] {
            guard case .ready = current else { return }
        }
        pr[id] = r.map { .ready($0) }
        if let r, !r.bases.contains(prBase[id] ?? "") { prBase[id] = r.base }
    }

    /// On every snapshot: forget sessions that started another turn or went away; check new ones.
    func updatePRs(old: Snapshot) {
        let eligible = Set(snapshot.sessions.filter(\.prEligible).map(\.id))
        for id in pr.keys where !eligible.contains(id) {
            if case .writing = pr[id] { continue }
            pr[id] = nil
        }
        let new = eligible.subtracting(old.sessions.filter(\.prEligible).map(\.id))
        if isOpen && !new.isEmpty { refreshPRs(only: new) }
    }

    func startPR(_ s: SessionInfo) {
        guard case .ready(let r) = pr[s.id] else { return }
        let base = prBase[s.id] ?? r.base
        let started = Date()
        pr[s.id] = .staged(r, base: base, started: started)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.undoWindow) { [weak self] in
            guard let self, case .staged(_, _, let t) = self.pr[s.id], t == started else { return }
            self.pr[s.id] = .writing(cancelling: false)
            let req: [String: Any] = ["op": "prCreate", "cwd": s.cwd, "agent": s.agent, "base": base, "recap": s.prOffer ?? ""]
            prQueue.async {
                let result = Result { try CoreBridge.shared.call(req, as: PRCreated.self) }
                DispatchQueue.main.async { self.finishPR(s.id, r, result) }
            }
        }
    }

    private func finishPR(_ id: String, _ r: PRReady, _ result: Result<PRCreated, Error>) {
        switch result {
        case .success(let c):
            pr[id] = .done(c)
            if !c.existing, UserDefaults.standard.bool(forKey: "openPRAfterCreate"), let url = URL(string: c.url) {
                NSWorkspace.shared.open(url)
            }
        case .failure(let e):
            let reason = e.localizedDescription
            pr[id] = reason == "Cancelled" ? .ready(r) : .failed(r, reason)
        }
    }

    func undoPR(_ id: String) {
        if case .staged(let r, _, _) = pr[id] { pr[id] = .ready(r) }
    }

    func cancelPR(_ s: SessionInfo) {
        guard case .writing(false) = pr[s.id] else { return }
        pr[s.id] = .writing(cancelling: true)
        prQueue.async { _ = try? CoreBridge.shared.call(["op": "prCancel", "cwd": s.cwd]) }
    }

    func retryPR(_ s: SessionInfo) {
        guard case .failed(let r, _) = pr[s.id] else { return }
        pr[s.id] = .ready(r)
        startPR(s)
    }
}

private let ink = Color(nsColor: Theme.ink)
private let secondary = Color(nsColor: Theme.secondary)

/// The Open PR control on a session row or next-step card; empty unless the branch is ready.
/// Rows get the compact subagent-chip size (15 pt) and stay quiet; the card matches its 28 pt buttons.
struct PRButton: View {
    @ObservedObject var model: PanelModel
    let session: SessionInfo
    var card = false

    var body: some View {
        switch model.pr[session.id] {
        case .ready(let r):
            let base = model.prBase[session.id] ?? r.base
            // One capsule: the action on the left, the base branch it targets on the right.
            HStack(spacing: 0) {
                Chip(card: card, joined: .leading) { model.startPR(session) } label: { Text("Open PR") }
                    .accessibilityLabel("Open pull request")
                    .accessibilityHint("Creates a pull request into \(base) after a 2 second undo window")
                basePicker(r, base: base)
            }
        case .staged(_, let base, let started):
            Chip(card: card) { model.undoPR(session.id) } label: {
                UndoRing(started: started)
                Text("PR → \(base) · Undo")
            }
            .accessibilityLabel("Undo creating the pull request")
        case .writing(let cancelling):
            HStack(spacing: 6) {
                Text(cancelling ? "Cancelling…" : "Writing PR…").font(.system(size: card ? 12 : 11)).foregroundStyle(secondary)
                if !cancelling {
                    Chip(card: card) { model.cancelPR(session) } label: { Text("Cancel") }
                        .accessibilityLabel("Cancel writing the pull request")
                }
            }
            .fixedSize()
        case .done(let c):
            Chip(card: card) { if let url = URL(string: c.url) { NSWorkspace.shared.open(url) } } label: {
                Text("PR #\(c.number)")
                Image(systemName: "arrow.up.right").font(.system(size: card ? 9 : 8, weight: .semibold))
            }
            .help(c.url)
            .accessibilityLabel("Pull request \(c.number)")
            .accessibilityHint("Opens it in your browser")
        case .failed(_, let reason):
            HStack(spacing: 6) {
                // Gives way first, so the row's status stays whole; the full reason is on hover.
                Text(reason).font(.system(size: card ? 12 : 11)).foregroundStyle(secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: card ? 220 : 150, alignment: .trailing)
                    .layoutPriority(-1)
                    .help(reason)
                    .accessibilityLabel("Pull request failed: \(reason)")
                Chip(card: card) { model.retryPR(session) } label: { Text("Retry") }
                    .accessibilityLabel("Retry the pull request")
            }
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private func basePicker(_ r: PRReady, base: String) -> some View {
        let label = HStack(spacing: 3) {
            // ponytail: middle-elided by character count, since the chip is fixed-size and can't truncate itself.
            Text("→ \(base.count > 22 ? base.prefix(10) + "…" + base.suffix(10) : base)").lineLimit(1)
            if r.bases.count > 1 { Image(systemName: "chevron.down").font(.system(size: card ? 8 : 7, weight: .semibold)) }
        }
        .font(.system(size: card ? 12 : 11))
        .foregroundStyle(secondary)
        if r.bases.count > 1 {
            // A real NSMenu pops without activating the app, so it works in the non-activating panel.
            Menu {
                Picker("Base branch", selection: Binding(get: { base }, set: { model.prBase[session.id] = $0 })) {
                    ForEach(r.bases, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                ChipBody(card: card, joined: .trailing) { label }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose the base branch")
            .accessibilityLabel("Base branch, \(base)")
        } else {
            ChipBody(card: card, joined: .trailing, interactive: false) { label }
                .accessibilityLabel("Into \(base)")
        }
    }
}

/// A capsule chip: compact (11 pt, subagent-chip size) in rows, 12 pt × 28 pt in cards.
/// `joined` squares the edge that butts against a neighbour, so two chips read as one split control.
private struct Chip<L: View>: View {
    let card: Bool
    var joined: Edge? = nil
    let action: () -> Void
    @ViewBuilder let label: L

    var body: some View {
        Button(action: action) { ChipBody(card: card, joined: joined) { HStack(spacing: 5) { label } } }
            .buttonStyle(IslandButtonStyle(radius: card ? 8 : 7.5))
            .fixedSize()
    }
}

private struct ChipBody<C: View>: View {
    let card: Bool
    var joined: Edge? = nil
    var interactive = true
    @ViewBuilder let content: C
    @State private var hover = false

    var body: some View {
        let r: CGFloat = card ? 8 : 7.5
        content
            .font(.system(size: card ? 12 : 11, weight: .medium))
            .foregroundStyle(hover && interactive ? ink : secondary)
            .padding(.horizontal, card ? 12 : 7)
            .frame(height: card ? 28 : 15)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: joined == .trailing ? 0 : r, bottomLeadingRadius: joined == .trailing ? 0 : r,
                    bottomTrailingRadius: joined == .leading ? 0 : r, topTrailingRadius: joined == .leading ? 0 : r)
                    .fill(Color.white.opacity(hover && interactive ? (card ? 0.16 : 0.12) : (card ? 0.1 : 0.07)))
            )
            .overlay(alignment: .leading) {
                // Hairline divider between the two halves of a split control.
                if joined == .trailing { Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1).padding(.vertical, card ? 7 : 3) }
            }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}
