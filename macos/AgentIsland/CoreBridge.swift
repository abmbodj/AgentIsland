import Foundation
import IslandCore

// MARK: - Snapshot model (mirrors island-core's JSON)

struct Snapshot: Decodable, Equatable {
    var sessions: [SessionInfo] = []
    var attention: Int = 0
    var usage: Usage = Usage()
    var paused: Bool = false
}

struct SessionInfo: Decodable, Equatable, Identifiable {
    var id: String
    var agent: String
    var cwd: String
    var project: String
    var state: SessionState
    var activity: String
    var since: Int64
    var pending: [Attention]
    var subagents: [Subagent]
    var pid: Int32?
    var terminal: Terminal
}

enum SessionState: String, Decodable {
    case working, idle, needsInput, finished, ended, error, stale
}

struct Attention: Decodable, Equatable {
    var id: UInt64
    var tool: String
    var since: Int64
}

struct Subagent: Decodable, Equatable {
    var id: String
    var kind: String
    var activity: String
    var done: Bool
    var since: Int64
}

struct Terminal: Decodable, Equatable {
    var program: String?
    var bundleId: String?
    var tty: String?
    var tmux: String?
    var tmuxPane: String?
    var itermSession: String?
    var termSession: String?
    var pids: [Int32]
}

struct Usage: Decodable, Equatable {
    var claude: AgentUsage?
    var codex: AgentUsage?
}

struct AgentUsage: Decodable, Equatable {
    var observedAt: Int64
    var windows: [LimitWindow]
}

struct LimitWindow: Decodable, Equatable {
    var label: String
    var usedPercent: Double
    var resetsAt: Int64
}

// MARK: - Bridge over the C ABI

/// Owns the Rust core. Snapshots arrive on a core thread and are delivered on the main queue.
final class CoreBridge {
    static let shared = CoreBridge()
    var onSnapshot: ((Snapshot) -> Void)?
    private(set) var latest = Snapshot()

    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AgentIsland")
    }

    func start() throws {
        let hook = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/island-hook").path
        let config: [String: Any] = [
            "supportDir": Self.supportDir.path,
            // Test hook: point integrations at a scratch home instead of the real one.
            "home": ProcessInfo.processInfo.environment["AGENT_ISLAND_HOME"] ?? NSHomeDirectory(),
            "hookSource": hook,
        ]
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let err = Self.json(config).withCString { cfg in
            island_start(cfg, { json, ctx in
                guard let json, let ctx else { return }
                let data = Data(bytes: json, count: strlen(json))
                let me = Unmanaged<CoreBridge>.fromOpaque(ctx).takeUnretainedValue()
                DispatchQueue.main.async { me.deliver(data) }
            }, ctx)
        }
        if let err {
            let message = String(cString: err)
            island_free(err)
            throw NSError(domain: "AgentIsland", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func deliver(_ data: Data) {
        guard let snap = try? JSONDecoder().decode(Snapshot.self, from: data), snap != latest else { return }
        latest = snap
        onSnapshot?(snap)
    }

    func send(_ command: [String: Any]) {
        Self.json(command).withCString { island_send($0) }
    }

    /// Synchronous request; returns the `ok` payload or throws the `error` message.
    func call(_ request: [String: Any]) throws -> Any {
        let raw = Self.json(request).withCString { island_call($0) }
        guard let raw else { throw NSError(domain: "AgentIsland", code: 2) }
        defer { island_free(raw) }
        let obj = try JSONSerialization.jsonObject(with: Data(bytes: raw, count: strlen(raw))) as? [String: Any] ?? [:]
        if let e = obj["error"] as? String {
            throw NSError(domain: "AgentIsland", code: 3, userInfo: [NSLocalizedDescriptionKey: e])
        }
        return obj["ok"] ?? NSNull()
    }

    /// Decode an `ok` payload into a Decodable type.
    func call<T: Decodable>(_ request: [String: Any], as: T.Type) throws -> T {
        let value = try call(request)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func json(_ v: Any) -> String {
        String(data: (try? JSONSerialization.data(withJSONObject: v)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }
}
