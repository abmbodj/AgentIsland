// Run: swiftc -parse-as-library macos/AgentIsland/SessionTitles.swift macos/Tests/SessionTitlesTests.swift -o /tmp/agent-island-title-tests && /tmp/agent-island-title-tests
import Foundation

@main
struct SessionTitlesTests {
    static func main() {
        let suite = "AgentIsland.SessionTitlesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let titles = SessionTitles(defaults: defaults)
        titles.load()
        assert(titles.title(for: ["codex:one"], fallback: "project") == "project")
        titles.save("  Fix login  \n", for: ["codex:one", "chat:7"])
        assert(titles.title(for: ["codex:one"], fallback: "new project") == "Fix login")
        assert(titles.title(for: ["claude:one"], fallback: "other") == "other")
        let restored = SessionTitles(defaults: defaults)
        restored.load()
        assert(restored.title(for: ["codex:one"], fallback: "project") == "Fix login")
        assert(restored.title(for: ["codex:later", "chat:7"], fallback: "project") == "project", "Temporary chat numbers must not survive restart")
        titles.save("Before agent starts", for: ["chat:8"])
        titles.link(temporary: "chat:8", session: "codex:started")
        let migrated = SessionTitles(defaults: defaults)
        migrated.load()
        assert(migrated.title(for: ["codex:started"], fallback: "project") == "Before agent starts")
        assert(migrated.title(for: ["claude:new", "chat:8"], fallback: "unrelated") == "unrelated")
        titles.save("Saved after identification", for: ["chat:8"])
        let duringEdit = SessionTitles(defaults: defaults)
        duringEdit.load()
        assert(duringEdit.title(for: ["codex:started"], fallback: "project") == "Saved after identification")
        restored.save(" \n ", for: ["codex:one", "chat:7"])
        assert(restored.title(for: ["codex:one", "chat:7"], fallback: "project") == "project")
        restored.save(String(repeating: "🙂", count: 200), for: ["long"])
        assert(restored.title(for: ["long"], fallback: "").count == 120)
        restored.save("First\nSecond\tpart", for: ["single-line"])
        assert(restored.title(for: ["single-line"], fallback: "") == "First Second part")
        print("Session title persistence checks passed")
    }
}
