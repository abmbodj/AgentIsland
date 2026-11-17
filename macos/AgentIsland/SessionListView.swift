import SwiftUI

private let ink = Color(nsColor: Theme.ink)
private let secondary = Color(nsColor: Theme.secondary)
private let muted = Color(nsColor: Theme.muted)
private let amber = Color(nsColor: Theme.amber)
private let green = Color(nsColor: Theme.green)

struct SessionListView: View {
    @ObservedObject var model: PanelModel
    @FocusState private var searchFocused: Bool
    /// Measured so the rows get whatever height the card and usage strip leave, and scroll past that.
    @State private var cardHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @State private var rowsHeight: CGFloat = 0
    @State private var stripHeight: CGFloat = 0
    private static let activityPreview = 4
    private static let projectPreview = 3
    fileprivate static let listViewport = "session list viewport"

    var body: some View {
        TimelineView(.periodic(from: model.isOpen ? .now : .distantFuture, by: 1)) { ctx in
            // Panel padding is 4 top + 10 bottom. Keep room to browse even with a long request.
            let available = max(0, model.listHeightLimit - 14 - headerHeight - stripHeight)
            let cardViewport = min(cardHeight, available - min(72, available / 3))
            let room = available - cardViewport
            VStack(alignment: .leading, spacing: 0) {
                ScrollView(.vertical, showsIndicators: cardHeight > cardViewport) {
                    VStack(alignment: .leading, spacing: 0) {
                        CardArea(model: model)
                        DiskAccessBanner(model: model)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
                }
                .frame(height: cardViewport)
                .id(model.current?.item.id)
                listHeader
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                let viewport = rowsHeight > 0 ? min(rowsHeight, room) : room
                ScrollViewReader { proxy in
                    ScrollView {
                        rows(ctx.date, viewport: viewport)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
                    }
                    .coordinateSpace(name: Self.listViewport)
                    .frame(height: viewport)
                    .id(model.listRoute)
                    .onAppear { restoreSearchPosition(proxy) }
                    .onChange(of: model.searchSelection) { _, _ in restoreSearchPosition(proxy) }
                }
                HStack(alignment: .center, spacing: 8) {
                    UsageStrip(usage: model.snapshot.usage, now: ctx.date)
                    Spacer(minLength: 0)
                    NewChatButton(model: model).padding(.top, 8)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stripHeight = $0 }
            }
        }
        .staticDetailWhenReduced()
    }

    private func restoreSearchPosition(_ proxy: ScrollViewProxy) {
        if model.listRoute == .search, let selection = model.searchSelection {
            proxy.scrollTo(selection)
        }
    }

    private var listHeader: some View {
        HStack(spacing: 4) {
            if model.listRoute != .activity {
                Button { model.leaveListRoute() } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(IslandButtonStyle(radius: 6))
                .accessibilityLabel("Back")
            }
            switch model.listRoute {
            case .activity:
                Text("Sessions").fontWeight(.semibold)
            case .waiting:
                Text("Needs input (\(model.sessionList.waiting.count))").fontWeight(.semibold)
            case .running:
                Text("Running (\(model.sessionList.running.count))").fontWeight(.semibold)
            case .project(let id):
                let project = model.sessionList.groups.first { $0.id == id }?.project
                Text(project?.name ?? SessionList.Project(path: id).name).fontWeight(.semibold)
            case .search:
                TextField("Search chats and projects", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onAppear { focusSearch() }
                    .onChange(of: model.summoned) { _, _ in focusSearch() }
                    .onChange(of: searchFocused) { _, focused in model.searchFieldFocused = focused }
                    .onDisappear { model.searchFieldFocused = false }
                    .accessibilityLabel("Search chats and projects")
            }
            if model.listRoute != .search {
                Spacer()
                Button { model.startSearch() } label: {
                    Image(systemName: "magnifyingglass").frame(width: 26, height: 26)
                }
                .buttonStyle(IslandButtonStyle(radius: 6))
                .accessibilityLabel("Search chats")
                .help("Search chats (⌘F)")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Color(nsColor: Theme.ink))
        .frame(minHeight: 30)
        .padding(.horizontal, 8)
    }

    private func focusSearch() {
        DispatchQueue.main.async {
            searchFocused = model.summoned && model.screen == .list && model.listRoute == .search
        }
    }

    private func rows(_ now: Date, viewport: CGFloat) -> some View {
        LazyVStack(alignment: .leading, spacing: 1) {
            switch model.listRoute {
            case .activity:
                if model.sessionList.entries.isEmpty { sectionTitle("No tracked chats") }
                let waiting = model.sessionList.waiting
                if !waiting.isEmpty {
                    sectionTitle("Needs input (\(waiting.count))")
                    ForEach(waiting.prefix(Self.activityPreview)) { entry in row(entry, now: now) }
                    if waiting.count > Self.activityPreview {
                        browseButton("View all \(waiting.count) waiting") { model.listRoute = .waiting }
                    }
                }
                let running = model.sessionList.running
                if !running.isEmpty {
                    sectionTitle("Running (\(running.count))")
                    ForEach(running.prefix(Self.activityPreview)) { entry in row(entry, now: now) }
                    if running.count > Self.activityPreview {
                        browseButton("View all \(running.count) running") { model.listRoute = .running }
                    }
                }
                if !model.sessionList.finished.isEmpty {
                    sectionTitle("Recently finished")
                    ForEach(model.sessionList.finished) { entry in
                        row(entry, now: now, completionViewport: viewport)
                    }
                }
                if !model.sessionList.groups.isEmpty {
                    sectionTitle("By project")
                    ForEach(model.sessionList.groups) { group in projectRows(group, now: now) }
                }
            case .waiting:
                if model.sessionList.waiting.isEmpty { sectionTitle("No chats need input") }
                ForEach(model.sessionList.waiting) { entry in row(entry, now: now) }
            case .running:
                if model.sessionList.running.isEmpty { sectionTitle("No running chats") }
                ForEach(model.sessionList.running) { entry in row(entry, now: now) }
            case .project(let id):
                let entries = model.sessionList.groups.first { $0.id == id }?.entries ?? []
                if entries.isEmpty { sectionTitle("No chats in this project") }
                ForEach(entries) { entry in row(entry, now: now) }
            case .search:
                if model.searchResults.isEmpty { sectionTitle("No matching chats") }
                ForEach(model.searchResults) { entry in
                    row(entry, now: now, showProvider: true)
                        .id(entry.id)
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color(nsColor: Theme.secondary))
            .padding(.horizontal, 10)
            .padding(.top, 5)
            .accessibilityAddTraits(.isHeader)
    }

    private func browseButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12))
            .foregroundStyle(Color(nsColor: Theme.ink))
            .padding(.horizontal, 10)
            .frame(minHeight: 25)
            .contentShape(Rectangle())
        }
        .buttonStyle(IslandButtonStyle(radius: 6))
    }

    @ViewBuilder
    private func projectRows(_ group: SessionList.Group, now: Date) -> some View {
        let expanded = model.expandedProject == group.id
        Button { model.expandedProject = expanded ? nil : group.id } label: {
            HStack(spacing: 7) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 12)
                Text(group.project.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let hint = group.project.hint {
                    Text(hint).font(.system(size: 11)).foregroundStyle(Color(nsColor: Theme.secondary))
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Text("\(group.entries.count)").font(.system(size: 11).monospacedDigit())
            }
            .foregroundStyle(Color(nsColor: Theme.ink))
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(IslandButtonStyle(radius: 6))
        .accessibilityLabel("\(group.project.name), \(group.entries.count) \(group.entries.count == 1 ? "chat" : "chats")\(group.project.hint.map { ", " + $0 } ?? "")")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        if expanded {
            ForEach(group.entries.prefix(Self.projectPreview)) { entry in row(entry, now: now).padding(.leading, 12) }
            if group.entries.count > Self.projectPreview {
                browseButton("Browse all \(group.entries.count)") { model.listRoute = .project(group.id) }
                    .padding(.leading, 12)
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: SessionList.Entry, now: Date, showProvider: Bool = false, completionViewport: CGFloat? = nil) -> some View {
        let selected = model.listRoute == .search && model.searchSelection == entry.id
        let project = entry.project.hint ?? entry.project.name
        let context = showProvider ? "\(project) · \(Fmt.agentName(entry.agent))" : project == entry.title ? nil : project
        let saved = entry.savedID.flatMap { id in model.chats.first { $0.id == id } }
        if let saved, model.confirmingDelete == saved.id {
            DeleteConfirm(chat: saved, model: model).transition(.opacity)
        } else if let session = entry.session.flatMap({ key in model.snapshot.sessions.first { $0.key == key } }) {
            SessionRow(session: session, state: entry.state, context: context, selected: selected, now: now,
                       model: model, openRow: { model.openListEntry(entry) })
                .modifier(FinishedVisibility(model: model, entry: entry, viewport: completionViewport))
            if model.openGroups.contains(session.key) {
                ForEach(session.subagents, id: \.id) { sub in
                    SubagentRow(sub: sub, agent: session.agent, now: now).transition(.opacity)
                }
            }
        } else if let saved {
            ChatRow(chat: saved, state: entry.state, context: context, selected: selected, model: model, openRow: { model.openListEntry(entry) })
        }
    }
}

private struct FinishedVisibility: ViewModifier {
    @ObservedObject var model: PanelModel
    let entry: SessionList.Entry
    let viewport: CGFloat?
    @State private var visible = false

    @ViewBuilder
    func body(content: Content) -> some View {
        let canAcknowledge = visible && model.isOpen && model.listRoute == .activity &&
            model.screen == .list && model.planReader == nil
        if let viewport {
            content
                .onGeometryChange(for: Bool.self) { proxy in
                    SessionList.isVisible(proxy.frame(in: .named(SessionListView.listViewport)), in: viewport)
                } action: { visible = $0 }
                .task(id: canAcknowledge ? entry.since : nil) { @MainActor in
                    guard canAcknowledge, let key = entry.session else { return }
                    do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
                    guard !Task.isCancelled, model.isOpen, model.listRoute == .activity,
                          model.screen == .list, model.planReader == nil else { return }
                    model.acknowledgeCompletion(key, since: entry.since)
                }
        } else {
            content
        }
    }
}

private struct SessionRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: SessionInfo
    let state: SessionState
    let context: String?
    let selected: Bool
    let now: Date
    @ObservedObject var model: PanelModel
    let openRow: () -> Void
    @State private var hover = false

    private var status: (String, Color) {
        switch state {
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
        let open = model.openGroups.contains(session.key)
        let running = session.subagents.filter { !$0.done }.count
        HStack(alignment: .center, spacing: 10) {
            AgentBadge(agent: session.agent, state: state, size: 16)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    SessionTitle(model: model, keys: model.titleKeys(session), title: model.title(session))
                    Spacer(minLength: 8)
                    Text(Fmt.elapsed(session.since, now: now))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(secondary)
                }
                HStack(spacing: 6) {
                    Text(model.hint[session.id] ?? status.0)
                        .font(.system(size: 11, weight: state == .needsInput ? .medium : .regular))
                        .foregroundStyle(model.hint[session.id] == nil ? status.1 : muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let context {
                        Text(context).font(.system(size: 11)).foregroundStyle(secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    PRButton(model: model, session: session)
                    if !session.subagents.isEmpty {
                        Button {
                            withAnimation(Motion.detail(reduceMotion: reduceMotion)) {
                                if open { model.openGroups.remove(session.key) } else { model.openGroups.insert(session.key) }
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
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(selected || hover ? 0.07 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(secondary.opacity(selected ? 0.6 : 0), lineWidth: 1).allowsHitTesting(false))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        // A plain tap, nothing beside it: a simultaneous press-tint DragGesture swallowed the tap on the never-key panel.
        .onTapGesture { if model.editingTitle == nil { openRow() } }
        .accessibilityElement(children: model.isEditingTitle(model.titleKeys(session)) ? .contain : .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction { if model.editingTitle == nil { openRow() } }
        .accessibilityHint(model.chatFor(session) != nil || session.transcriptPath != nil ? "Opens this conversation" : session.hasPlan ? "Opens this session’s plan" : "Shows this session's terminal")
        .contextMenu {
            Button("Rename session") { model.editTitle(keys: model.titleKeys(session), title: model.title(session)) }
            if let c = model.chatFor(session) { Button("Delete chat") { model.confirmingDelete = c.id } }
        }
        // The row is one combined element, so its PR control is offered as actions.
        .accessibilityActions {
            Button("Rename session") { model.editTitle(keys: model.titleKeys(session), title: model.title(session)) }
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
                            let remainingPercent = min(100, max(0, 100 - w.usedPercent))
                            Text("\(w.label) \(Int(remainingPercent.rounded()))%")
                                .fontWeight(remainingPercent <= 10 ? .bold : .regular)
                                .foregroundStyle(remainingPercent <= 10 ? ink : secondary)
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
            .accessibilityLabel("Usage remaining")
        }
    }
}
