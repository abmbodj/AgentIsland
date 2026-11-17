// Run: swiftc -parse-as-library macos/AgentIsland/SessionList.swift macos/Tests/SessionListTests.swift -o /tmp/agent-island-session-list-tests && /tmp/agent-island-session-list-tests
import Foundation
import CoreGraphics

@main
struct SessionListTests {
    static func main() {
        let codex = SessionKey(agent: "codex", id: "same")
        let claude = SessionKey(agent: "claude", id: "same")
        let saved = SessionList.Saved(id: 4, agent: "codex", session: codex, title: "Saved", cwd: "/dev/Locy", state: .idle)
        let live = SessionList.Live(key: codex, title: "Café Barcode", cwd: "/dev/Locy", state: .working, since: 20)
        let other = SessionList.Live(key: claude, title: "Open session", cwd: "/other/Locy", state: .idle, since: 30)
        let list = SessionList(live: [live, other], saved: [saved])
        assert(list.entries.count == 2)
        assert(list.running.map(\.id) == [.saved(4)])
        assert(list.running.first?.title == "Café Barcode")
        assert(list.search("locy cafe").map(\.id) == [.saved(4)])
        assert(list.search("locy").count == 2)
        assert(list.search("unmatched").isEmpty)
        assert(list.search("locy").allSatisfy { $0.project.hint != nil })

        let volume = (0..<100).map { i in
            SessionList.Saved(id: i, agent: i.isMultiple(of: 2) ? "claude" : "codex", session: nil, title: "Chat \(i)", cwd: "/dev/Project \(i % 10)", state: i < 20 ? .working : .idle)
        }
        let crowded = SessionList(live: [], saved: volume)
        assert(crowded.entries.count == 100 && crowded.groups.count == 10)
        assert(crowded.running.count == 20 && crowded.groups.allSatisfy { $0.entries.count == 8 })
        assert(crowded.search("project 0").count == 10)

        let unfiled = SessionList(live: [], saved: [.init(id: 1, agent: "codex", session: nil, title: "Draft", cwd: "", state: .idle)])
        assert(unfiled.groups.first?.project.name == "No project")
        assert(unfiled.search("draft").first?.id == .saved(1))
        assert(SessionList.isVisible(CGRect(x: 0, y: 2, width: 100, height: 40), in: 80))
        assert(!SessionList.isVisible(CGRect(x: 0, y: 60, width: 100, height: 40), in: 80))
        assert(!SessionList.isVisible(CGRect(x: 0, y: -12, width: 100, height: 40), in: 80))
        let worktrees = SessionList(live: [
            .init(key: codex, title: "One", cwd: "/scratch/one", projectRoot: "/dev/Locy", state: .idle, since: 0),
            .init(key: claude, title: "Two", cwd: "/scratch/two", projectRoot: "/dev/Locy/", state: .idle, since: 0)
        ])
        assert(worktrees.groups.count == 1 && worktrees.groups[0].entries.count == 2)
        print("Session list checks passed")
    }
}
