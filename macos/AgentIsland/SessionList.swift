import Foundation
import CoreGraphics

struct SessionKey: Hashable {
    let agent: String
    let id: String
}

enum SessionState: String, Decodable {
    case working, idle, needsInput, finished, ended, error, stale
}

/// The metadata needed to organize and find chats. Transcript loading lives in PanelModel.
struct SessionList {
    enum ID: Hashable {
        case session(SessionKey)
        case saved(Int)
    }

    struct Live {
        let key: SessionKey
        let title: String
        let cwd: String
        var projectRoot: String? = nil
        let state: SessionState
        let since: Int64
    }

    struct Saved {
        let id: Int
        let agent: String
        let session: SessionKey?
        let title: String
        let cwd: String
        let state: SessionState
    }

    struct Project: Identifiable, Equatable {
        let id: String
        var name: String {
            guard !id.isEmpty else { return "No project" }
            return id == "/" ? id : (id as NSString).lastPathComponent
        }
        var hint: String?

        init(path: String) {
            // Normalize separators without resolving symlinks or reading the filesystem.
            id = path.hasPrefix("/") ? "/" + path.split(separator: "/").joined(separator: "/") : ""
        }
    }

    struct Entry: Identifiable, Equatable {
        let id: ID
        let session: SessionKey?
        let savedID: Int?
        let agent: String
        let title: String
        var project: Project
        let state: SessionState
        let since: Int64
    }

    struct Group: Identifiable {
        var id: String { project.id }
        let project: Project
        let entries: [Entry]
    }

    let entries: [Entry]
    let running: [Entry]
    let finished: [Entry]
    let groups: [Group]
    private let entriesByID: [ID: Entry]

    init(live: [Live] = [], saved: [Saved] = []) {
        var bySession: [SessionKey: Saved] = [:]
        for chat in saved {
            if let key = chat.session, bySession[key] == nil { bySession[key] = chat }
        }
        let liveKeys = Set(live.map(\.key))
        let open = live.map { session in
            let chat = bySession[session.key]
            return Entry(id: chat.map { .saved($0.id) } ?? .session(session.key), session: session.key, savedID: chat?.id,
                         agent: session.key.agent, title: session.title,
                         project: Project(path: session.projectRoot ?? (session.cwd.isEmpty ? chat?.cwd ?? "" : session.cwd)),
                         state: session.state, since: session.since)
        }
        let savedOnly = saved.reversed().compactMap { chat -> Entry? in
            if let key = chat.session, liveKeys.contains(key) { return nil }
            return Entry(id: .saved(chat.id), session: chat.session, savedID: chat.id, agent: chat.agent,
                         title: chat.title, project: Project(path: chat.cwd), state: chat.state, since: 0)
        }
        let all = open + savedOnly
        var pathsByName: [String: Set<String>] = [:]
        for entry in all {
            pathsByName[entry.project.name, default: []].insert(entry.project.id)
        }
        let rows = all.map { entry in
            var row = entry
            if !row.project.id.isEmpty, (pathsByName[row.project.name]?.count ?? 0) > 1 {
                row.project.hint = row.project.id
            }
            return row
        }
        running = rows.filter { $0.state == .working }
        finished = rows.filter { $0.state == .finished }.sorted { $0.since > $1.since }
        let quiet = rows.filter { $0.state != .working && $0.state != .finished }
        entries = running + finished + quiet
        entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        groups = Dictionary(grouping: quiet, by: \.project.id).values.compactMap { rows in
            rows.first.map { Group(project: $0.project, entries: rows) }
        }.sorted {
            let comparison = $0.project.name.localizedStandardCompare($1.project.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    subscript(id: ID) -> Entry? { entriesByID[id] }

    func search(_ query: String) -> [Entry] {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            let text = entry.title + " " + entry.project.name
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    static func isVisible(_ frame: CGRect, in viewportHeight: CGFloat) -> Bool {
        frame.height > 0 && frame.minY >= -0.5 && frame.maxY <= viewportHeight + 0.5
    }
}
