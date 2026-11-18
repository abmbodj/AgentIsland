import SwiftUI

/// What a row says about its state: one label and one glyph each. Color is only for "needs you" and "done".
struct RowStatus: Equatable {
    enum Tone { case active, attention, done, quiet }
    let label: String
    let tone: Tone
    let glyph: SessionState

    init(label: String, tone: Tone, glyph: SessionState) {
        self.label = label
        self.tone = tone
        self.glyph = glyph
    }

    /// `state` can be newer than the session's own (the list applies live states first).
    init(_ s: SessionInfo, state: SessionState? = nil) {
        let state = state ?? s.state
        glyph = state
        switch state {
        case .working: (label, tone) = ("Working", .active)
        case .needsInput:
            let first = s.pending.first
            if first?.kind == "plan" || first?.tool == "ExitPlanMode" { (label, tone) = ("Plan ready", .attention) }
            else if first?.kind == "question" { (label, tone) = ("Question", .attention) }
            else if first?.kind == "approval" { (label, tone) = ("Needs approval", .attention) }
            else { (label, tone) = ("Needs you", .attention) }
        case .finished: (label, tone) = ("Done", .done)
        case .idle: (label, tone) = ("Idle", .quiet)
        case .ended: (label, tone) = ("Ended", .quiet)
        case .error: (label, tone) = ("Failed", .quiet)
        case .stale: (label, tone) = ("Stale", .quiet)
        }
    }

    /// The row's second line: what the agent is doing, or why it waits.
    static func detail(_ s: SessionInfo, state: SessionState? = nil) -> String? {
        switch state ?? s.state {
        case .working: return s.activity.isEmpty ? nil : s.activity
        case .needsInput: return s.pending.first.map { $0.title.isEmpty ? $0.tool : $0.title } ?? (s.activity.isEmpty ? nil : s.activity)
        case .error: return "Exited unexpectedly"
        case .stale: return "No activity for 30m"
        case .finished, .idle, .ended: return nil
        }
    }
}

/// The state label beside a row's time: glyph plus text, so state never rests on color alone.
/// Becoming "needs you" or "done" is announced once with a small settle; everything else crossfades.
struct StatusPill: View {
    let status: RowStatus
    let agent: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var announce = 0

    private var tint: Color {
        switch status.tone {
        case .attention: return amber
        case .done: return green
        case .active: return ink
        case .quiet: return muted
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if status.glyph == .error {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8))
            } else {
                GlyphView(agent: agent, state: status.glyph, size: 6).frame(width: 7, height: 7)
            }
            Text(status.label).contentTransition(.opacity)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, status.tone == .quiet ? 0 : 7)
        .frame(height: 20)
        .background(Capsule().fill(status.tone == .quiet ? Color.clear
                                   : status.tone == .active ? Color.white.opacity(Lift.block) : tint.opacity(0.13)))
        // A long title truncates; the state never does.
        .fixedSize()
        .keyframeAnimator(initialValue: 1.0, trigger: announce) { content, scale in
            content.scaleEffect(scale)
        } keyframes: { _ in
            KeyframeTrack {
                SpringKeyframe(1.08, duration: 0.14, spring: .snappy)
                SpringKeyframe(1.0, duration: 0.32, spring: .smooth)
            }
        }
        .animation(Motion.feedback(reduceMotion: reduceMotion), value: status)
        .onChange(of: status.tone) { _, tone in
            if !reduceMotion && (tone == .attention || tone == .done) { announce += 1 }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.label)
    }
}

/// The provider's mark on a quiet tile, the anchor every row lines up on.
struct AgentTile: View {
    let agent: String

    var body: some View {
        AgentMark(agent: agent, size: 15)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(Color.white.opacity(Lift.inset)))
    }
}

extension Fmt {
    /// A working folder as a person writes it: ~/dev/project.
    static func path(_ cwd: String) -> String {
        let home = NSHomeDirectory()
        return cwd == home ? "~" : cwd.hasPrefix(home + "/") ? "~" + cwd.dropFirst(home.count) : cwd
    }
}
