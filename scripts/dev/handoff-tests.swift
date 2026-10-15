import AppKit

@main struct HandoffTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder ' \" $HOME `whoami`\nnext")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bin = root.appendingPathComponent("agent ' \" $HOME `whoami`")
        let output = root.appendingPathComponent("result")
        try "#!/bin/sh\nprintf '%s\\0' \"$PWD\" \"$@\" > \(HandoffLauncher.shellQuote(output.path))\n".write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bin.path)
        for agent in ["claude", "codex"] {
            let session = "session ' \" $HOME `whoami`\nline"
            let launch = HandoffLaunch(id: 1, agent: agent, cwd: folder.path, sessionId: session, target: "terminal", bin: bin.path, path: "/usr/bin:/bin")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", HandoffLauncher.resumeCommand(launch)]
            try p.run(); p.waitUntilExit()
            precondition(p.terminationStatus == 0)
            let values = try Data(contentsOf: output).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            precondition(values == [folder.path, agent == "claude" ? "--resume" : "resume", session], "Unsafe/lost command values: \(values)")
            let receipt = root.appendingPathComponent("status")
            let wrapper = root.appendingPathComponent("Resume.command")
            try HandoffLauncher.terminalScript(launch, receipt: receipt).write(to: wrapper, atomically: true, encoding: .utf8)
            let wrapped = Process(); wrapped.executableURL = URL(fileURLWithPath: "/bin/sh"); wrapped.arguments = [wrapper.path]
            try wrapped.run(); wrapped.waitUntilExit()
            precondition(wrapped.terminationStatus == 0)
            let status = try String(contentsOf: receipt, encoding: .utf8)
            precondition(status == "exited:0")
            precondition(!FileManager.default.fileExists(atPath: wrapper.path), "Wrapper must remove itself")
        }
        let launch = HandoffLaunch(id: 1, agent: "codex", cwd: "/missing-island-folder", sessionId: "x", target: "terminal", bin: bin.path, path: "/usr/bin:/bin")
        try FileManager.default.removeItem(at: output)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", HandoffLauncher.resumeCommand(launch)]
        try p.run(); p.waitUntilExit()
        precondition(p.terminationStatus != 0 && !FileManager.default.fileExists(atPath: output.path))
        precondition(HandoffDestination.choices(agent: "claude").map(\.rawValue) == ["terminal", "iterm", "ghostty", "claudeDesktop"])
        precondition(HandoffDestination.choices(agent: "codex").map(\.rawValue) == ["terminal", "iterm", "ghostty", "codexDesktop"])
        print("PASS: exact session arguments, cwd, shell quoting, missing folder, matching destinations")
    }
}
