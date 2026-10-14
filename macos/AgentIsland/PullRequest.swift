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
private let muted = Color(nsColor: Theme.muted)

/// The Open PR control on a session row or next-step card; empty unless the branch is ready.
struct PRButton: View {
    @ObservedObject var model: PanelModel
    let session: SessionInfo

    var body: some View {
        switch model.pr[session.id] {
        case .ready(let r):
            HStack(spacing: 2) {
                chip("Open PR") { model.startPR(session) }
                    .accessibilityHint("Creates a pull request into \(model.prBase[session.id] ?? r.base) after a 2 second undo window")
                basePicker(r)
            }
        case .staged(_, let base, let started):
            Button { model.undoPR(session.id) } label: {
                HStack(spacing: 5) {
                    UndoRing(started: started)
                    Text("PR → \(base) · Undo").font(.system(size: 11, weight: .medium)).foregroundStyle(ink)
                }
                .padding(.horizontal, 7).frame(height: 20)
                .background(Capsule().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(IslandButtonStyle(radius: 10))
            .accessibilityLabel("Undo creating the pull request")
        case .writing(let cancelling):
            HStack(spacing: 6) {
                Text(cancelling ? "Cancelling…" : "Writing PR…").font(.system(size: 11)).foregroundStyle(secondary)
                if !cancelling { chip("Cancel") { model.cancelPR(session) } }
            }
        case .done(let c):
            chip("PR #\(c.number)") { if let url = URL(string: c.url) { NSWorkspace.shared.open(url) } }
                .help(c.url)
                .accessibilityHint("Opens the pull request in your browser")
        case .failed(_, let reason):
            HStack(spacing: 6) {
                Text(reason).font(.system(size: 11)).foregroundStyle(muted).lineLimit(1).truncationMode(.tail)
                chip("Retry") { model.retryPR(session) }
            }
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private func basePicker(_ r: PRReady) -> some View {
        let base = model.prBase[session.id] ?? r.base
        if r.bases.count > 1 {
            Menu {
                ForEach(r.bases, id: \.self) { b in
                    Button { model.prBase[session.id] = b } label: {
                        if b == base { Label(b, systemImage: "checkmark") } else { Text(b) }
                    }
                }
            } label: {
                Text("→ \(base)").font(.system(size: 11)).foregroundStyle(secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .accessibilityLabel("Base branch \(base)")
        } else {
            Text("→ \(base)").font(.system(size: 11)).foregroundStyle(secondary).padding(.horizontal, 4)
        }
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(ink)
                .padding(.horizontal, 8).frame(height: 20)
                .background(Capsule().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(IslandButtonStyle(radius: 10))
    }
}
