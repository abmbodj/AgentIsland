import SwiftUI

private let ink = Color(nsColor: Theme.ink)
private let secondary = Color(nsColor: Theme.secondary)
private let muted = Color(nsColor: Theme.muted)
private let amber = Color(nsColor: Theme.amber)

/// The one card that needs the user, above the session rows. Never stacked: "1 of 3" + ‹ ›.
struct CardArea: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        if let r = model.receipt, model.current == nil {
            Receipt(text: r)
        }
        if let (session, item) = model.current {
            VStack(alignment: .leading, spacing: 0) {
                if let r = model.receipt { Receipt(text: r).padding(.bottom, 4) }
                CardView(model: model, session: session, item: item, index: min(model.cardIndex, model.cards.count - 1), count: model.cards.count)
                    .id(item.id)
                    .transition(.opacity)
            }
            .padding(.bottom, 6)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.horizontal, 10).padding(.bottom, 4)
        }
    }
}

private struct Receipt: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "checkmark")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .accessibilityLabel(text)
    }
}

/// A response button. While its response is staged it becomes "Undo" with a depleting ring (D9).
private struct ResponseButton: View {
    @ObservedObject var model: PanelModel
    let id: String
    let item: Attention
    let title: String
    var shortcut: String? = nil
    var primary = false
    let action: () -> Void

    var body: some View {
        let staged = model.staged
        let mine = staged?.id == item.id && staged?.button == id
        Button {
            if mine { model.undo() } else { action() }
        } label: {
            HStack(spacing: 6) {
                if mine, let s = staged {
                    UndoRing(started: s.started)
                    Text("Undo")
                } else {
                    Text(title)
                    if let shortcut, model.summoned {
                        Text(shortcut).foregroundStyle(primary ? Color.black.opacity(0.45) : muted)
                    }
                }
            }
            .font(.system(size: 12, weight: primary ? .semibold : .medium))
            .foregroundStyle(primary && !mine ? Color.black.opacity(0.85) : ink)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(primary && !mine ? ink : Color.white.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(staged != nil && !mine)
        .opacity(staged != nil && !mine ? 0.35 : 1)
        .accessibilityLabel(mine ? "Undo" : title)
    }
}

private struct UndoRing: View {
    let started: Date
    var body: some View {
        TimelineView(.animation(minimumInterval: Theme.reduceMotion ? 0.5 : 1 / 30)) { ctx in
            let left = max(0, 1 - ctx.date.timeIntervalSince(started) / PanelModel.undoWindow)
            Circle()
                .trim(from: 0, to: left)
                .stroke(ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 11, height: 11)
        }
    }
}

private struct CardView: View {
    @ObservedObject var model: PanelModel
    let session: SessionInfo
    let item: Attention
    let index: Int
    let count: Int
    @State private var showDiff = false
    @State private var showFull = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !item.held {
                handoff
            } else if item.kind == "question" {
                question
            } else {
                approval
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Circle().fill(amber).frame(width: 6, height: 6)
            Text(session.project.isEmpty ? "Session" : session.project)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ink)
                .lineLimit(1)
            Text(item.subagent.map { "\($0) subagent" } ?? Fmt.agentName(session.agent))
                .font(.system(size: 12))
                .foregroundStyle(secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if count > 1 {
                Button { model.move(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(secondary).accessibilityLabel("Previous request")
                Text("\(index + 1) of \(count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(secondary)
                Button { model.move(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain).foregroundStyle(secondary).accessibilityLabel("Next request")
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Approval

    private var approval: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(ink)
            if !item.detail.isEmpty {
                Text(item.detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(ink)
                    .lineLimit(showFull ? 40 : 3)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                    .onTapGesture { showFull.toggle() }
            }
            if let d = item.diff {
                Button { withAnimation(.easeOut(duration: Theme.reduceMotion ? 0 : 0.18)) { showDiff.toggle() } } label: {
                    HStack(spacing: 6) {
                        Text("+\(d.added)").fontWeight(.semibold)
                        Text("−\(d.removed)").foregroundStyle(secondary)
                        Text(showDiff ? "Hide changes" : "Show changes").foregroundStyle(secondary)
                        Image(systemName: showDiff ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(secondary)
                    }
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(ink)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(d.added) lines added, \(d.removed) removed. \(showDiff ? "Hide" : "Show") changes")
                if showDiff { DiffLines(text: d.text) }
            }
            HStack(spacing: 8) {
                ResponseButton(model: model, id: "deny", item: item, title: "Deny", shortcut: "⌘N") { model.deny(item) }
                if item.canAllowSession {
                    ResponseButton(model: model, id: "session", item: item, title: "Allow for session") { model.allowSession(item) }
                }
                Spacer()
                ResponseButton(model: model, id: "allow", item: item, title: "Allow", shortcut: "⌘Y", primary: true) { model.allow(item) }
            }
        }
    }

    // MARK: Question

    @ViewBuilder private var question: some View {
        if let q = model.question(of: item) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if !q.header.isEmpty {
                        Text(q.header.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(secondary)
                    }
                    if item.questions.count > 1 {
                        Text("Question \(item.questions.firstIndex(of: q).map { $0 + 1 } ?? 1) of \(item.questions.count)")
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(muted)
                    }
                }
                Text(q.question).font(.system(size: 14, weight: .semibold)).foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 2) {
                    ForEach(Array(q.options.enumerated()), id: \.offset) { i, o in
                        OptionRow(model: model, item: item, index: i, option: o, multi: q.multiSelect)
                    }
                }
                HStack(spacing: 8) {
                    if model.summoned {
                        TextField("Type another answer", text: $model.freeText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                            .onSubmit { model.submitFreeText(item) }
                    } else {
                        Button { model.onSummon() } label: {
                            Text("Type another answer…").font(.system(size: 12)).foregroundStyle(secondary)
                                .padding(.horizontal, 8).frame(height: 28)
                        }
                        .buttonStyle(.plain)
                    }
                    if q.multiSelect {
                        Spacer()
                        ResponseButton(model: model, id: "submit", item: item, title: "Submit", shortcut: "⌘↩", primary: true) { model.submitPicks(item) }
                            .disabled((model.picks[item.id] ?? []).isEmpty)
                    }
                }
            }
        }
    }

    // MARK: Handoff

    private var handoff: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.kind == "question" ? "Asks a question in the session" : item.title)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(ink)
            Text("This agent can only be answered where it runs.").font(.system(size: 12)).foregroundStyle(secondary)
            HStack {
                Spacer()
                Button { model.onJump(session) } label: {
                    Text("Open session").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.black.opacity(0.85))
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(ink))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct OptionRow: View {
    @ObservedObject var model: PanelModel
    let item: Attention
    let index: Int
    let option: QuestionOption
    let multi: Bool
    @State private var hover = false

    var body: some View {
        let staged = model.staged
        let mine = staged?.id == item.id && staged?.button == "option\(index)"
        let picked = model.picks[item.id]?.contains(option.label) ?? false
        Button {
            if mine { model.undo() } else { model.pick(item, option: index) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Group {
                    if mine, let s = staged { UndoRing(started: s.started) } else { Text(index < 9 ? "\(index + 1)" : "") }
                }
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(secondary)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(mine ? "\(option.label) · Undo" : option.label).font(.system(size: 13, weight: .medium)).foregroundStyle(ink)
                    if !option.description.isEmpty && option.description != option.label {
                        Text(option.description).font(.system(size: 11)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                if multi && picked { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(ink) }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hover || picked || mine ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .disabled(staged != nil && !mine)
        .opacity(staged != nil && !mine ? 0.35 : 1)
        .accessibilityLabel("Option \(index + 1): \(option.label)")
    }
}

/// Monospaced hunks; added lines bright, removed lines muted. (No red/green: color is reserved.)
private struct DiffLines: View {
    let text: String
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : String(line))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(line.hasPrefix("+") ? ink : line.hasPrefix("-") ? muted : line.hasPrefix("@@") ? muted : secondary)
                        .strikethrough(line.hasPrefix("-"), color: muted.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .background(line.hasPrefix("+") ? Color.white.opacity(0.06) : .clear)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 180)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25)))
    }
}
