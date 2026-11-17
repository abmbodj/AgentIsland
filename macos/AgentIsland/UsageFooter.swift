import SwiftUI

/// Provider limits pinned to the bottom of every expanded screen: the last reported values, never extrapolated.
/// Claude Code and Codex each get their own labelled row, so one provider's limits never read as the other's.
struct UsageFooter: View {
    let usage: Usage
    let now: Date

    var body: some View {
        VStack(spacing: 8) {
            UsageRow(agent: "claude", usage: usage.claude, now: now)
            UsageRow(agent: "codex", usage: usage.codex, now: now)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(Lift.block)).frame(height: 1).padding(.horizontal, 10)
        }
    }
}

private struct UsageRow: View {
    let agent: String
    let usage: AgentUsage?
    let now: Date

    /// Older than 15 minutes is labelled stale rather than presented as current.
    private var stale: String? {
        guard let usage, now.timeIntervalSince1970 * 1000 - Double(usage.observedAt) > 15 * 60 * 1000 else { return nil }
        return "As of \(Fmt.elapsed(usage.observedAt, now: now)) ago"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 7) {
                AgentMark(agent: agent, size: 13)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Fmt.agentName(agent)).font(.system(size: 12, weight: .medium)).foregroundStyle(ink)
                    if usage != nil {
                        Text(stale ?? "Usage left").font(.system(size: 10)).foregroundStyle(muted)
                    }
                }
            }
            .frame(width: 108, alignment: .leading)
            .accessibilityElement(children: .combine)
            if let windows = usage?.windows, !windows.isEmpty {
                ForEach(windows, id: \.label) { w in
                    Divider().frame(height: 30).overlay(Color.white.opacity(Lift.block))
                    Meter(window: w, now: now)
                }
            } else {
                Divider().frame(height: 30).overlay(Color.white.opacity(Lift.block))
                Text("Not reported yet")
                    .font(.system(size: 11)).foregroundStyle(muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(agent == "codex" ? "Codex reports its limits during a turn." : "Claude Code reports its limits through its status line.")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(Fmt.agentName(agent)) usage")
    }
}

private struct Meter: View {
    let window: LimitWindow
    let now: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var left: Double { min(100, max(0, 100 - window.usedPercent)) }
    private var low: Bool { left <= 10 }

    static func name(_ label: String) -> String {
        switch label {
        case "5h": return "5-hour"
        case "7d", "wk": return "Weekly"
        default: return label
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(Self.name(window.label)).foregroundStyle(secondary)
                Spacer(minLength: 4)
                Text("\(Int(left.rounded()))%")
                    .fontWeight(low ? .bold : .medium)
                    .foregroundStyle(ink)
                    .contentTransition(.numericText(value: left))
            }
            .font(.system(size: 11).monospacedDigit())
            Capsule()
                .fill(Color.white.opacity(Lift.raised))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        Capsule()
                            .fill(ink.opacity(low ? 1 : 0.85))
                            .frame(width: max(4, g.size.width * left / 100))
                    }
                }
            Text("Resets in \(Fmt.until(window.resetsAt, now: now))")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        // Only a changed value moves the fill; the once-a-second clock re-render does not.
        .animation(Motion.detail(reduceMotion: reduceMotion), value: left)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.name(window.label)) limit")
        .accessibilityValue("\(Int(left.rounded())) percent left, resets in \(Fmt.until(window.resetsAt, now: now))")
    }
}

extension PanelModel {
    func usageFooter(now: Date) -> UsageFooter {
        UsageFooter(usage: snapshot.usage, now: now)
    }
}

/// The footer for screens without their own clock; reset times only need minute precision.
struct LiveUsageFooter: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in model.usageFooter(now: ctx.date) }
    }
}
