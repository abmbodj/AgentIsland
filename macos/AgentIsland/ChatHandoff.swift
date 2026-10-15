import AppKit

struct ChatHandoff: Decodable, Equatable {
    var target: String
    var status: String
    var destination: HandoffDestination? { HandoffDestination(rawValue: target) }
}

struct HandoffLaunch: Decodable {
    var id: Int
    var agent: String
    var cwd: String
    var sessionId: String
    var target: String
    var bin: String
    var path: String
}

enum HandoffDestination: String, CaseIterable, Identifiable {
    case terminal, iterm, ghostty, claudeDesktop, codexDesktop
    var id: String { rawValue }
    var name: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm: return "iTerm2"
        case .ghostty: return "Ghostty"
        case .claudeDesktop: return "Claude Desktop"
        case .codexDesktop: return "Codex Desktop"
        }
    }
    var bundleID: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iterm: return "com.googlecode.iterm2"
        case .ghostty: return "com.mitchellh.ghostty"
        case .claudeDesktop: return "com.anthropic.claudefordesktop"
        case .codexDesktop: return "com.openai.codex"
        }
    }
    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    static func choices(agent: String) -> [Self] {
        [.terminal, .iterm, .ghostty, agent == "codex" ? .codexDesktop : .claudeDesktop]
    }
}

/// Launches the native saved session, never a new prompt or a copied transcript.
enum HandoffLauncher {
    private static let queue = DispatchQueue(label: "agentisland.handoff", attributes: .concurrent)

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func resumeCommand(_ launch: HandoffLaunch) -> String {
        let args = launch.agent == "claude" ? ["--resume", launch.sessionId] : ["resume", launch.sessionId]
        return "cd -- \(shellQuote(launch.cwd)) && exec /usr/bin/env \(shellQuote("PATH=" + launch.path)) " + ([launch.bin] + args).map(shellQuote).joined(separator: " ")
    }

    static func terminalScript(_ launch: HandoffLaunch, receipt: URL) -> String {
        "#!/bin/sh\n/bin/rm -f -- \"$0\"\nprintf started > " + shellQuote(receipt.path)
            + "\n(" + resumeCommand(launch) + ")\nresult=$?\nif [ -d " + shellQuote(receipt.deletingLastPathComponent().path)
            + " ]; then printf 'exited:%s' \"$result\" > " + shellQuote(receipt.path)
            + "; fi\nexit \"$result\"\n"
    }

    static func open(_ launch: HandoffLaunch, completion: @escaping (String?) -> Void) {
        let done: (String?) -> Void = { error in DispatchQueue.main.async { completion(error) } }
        guard let destination = HandoffDestination(rawValue: launch.target), let appURL = destination.appURL else {
            done("This destination is no longer installed.")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: launch.bin), FileManager.default.fileExists(atPath: launch.cwd) else {
            done("The agent or working folder is no longer available.")
            return
        }
        if destination == .codexDesktop {
            var url = URLComponents()
            url.scheme = "codex"
            url.host = "threads"
            url.path = "/" + launch.sessionId
            guard let link = url.url else { done("Could not create the session link."); return }
            NSWorkspace.shared.open([link], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                done(error?.localizedDescription)
            }
            return
        }
        if destination == .claudeDesktop {
            queue.async { done(openClaudeDesktop(launch)) }
        } else {
            openTerminal(launch, destination: destination, appURL: appURL, completion: done)
        }
    }

    /// Terminal and iTerm accept executable .command documents; Ghostty accepts startup arguments.
    /// No Apple Events permission or typing into an existing terminal is needed.
    private static func openTerminal(_ launch: HandoffLaunch, destination: HandoffDestination, appURL: URL, completion: @escaping (String?) -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("island-resume-\(UUID().uuidString)")
        let file = folder.appendingPathComponent("Resume.command")
        let receipt = folder.appendingPathComponent("status")
        let script = terminalScript(launch, receipt: receipt)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch { try? FileManager.default.removeItem(at: folder); completion(error.localizedDescription); return }
        let config = NSWorkspace.OpenConfiguration()
        let finished: (NSRunningApplication?, Error?) -> Void = { _, error in
            if let error {
                try? FileManager.default.removeItem(at: folder)
                completion("Could not open \(destination.name): \(error.localizedDescription)")
            } else {
                queue.async {
                    defer { try? FileManager.default.removeItem(at: folder) }
                    let deadline = Date().addingTimeInterval(15)
                    var started: Date?
                    while Date() < deadline {
                        let status = (try? String(contentsOf: receipt, encoding: .utf8)) ?? ""
                        if status.hasPrefix("exited:") {
                            completion("The session exited before it was ready in \(destination.name) (\(status)). You can retry or choose another app.")
                            return
                        }
                        if status == "started" {
                            if started == nil { started = Date() }
                            if Date().timeIntervalSince(started!) >= 1 { completion(nil); return }
                        }
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                    completion("\(destination.name) opened but did not start the session. Check its window, then try again.")
                }
            }
        }
        if destination == .ghostty {
            config.createsNewApplicationInstance = true
            config.arguments = ["--working-directory=" + launch.cwd, "-e", "/bin/sh", file.path]
            NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: finished)
        } else {
            NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: config, completionHandler: finished)
        }
    }

    /// Output goes to a private file so even a stalled/noisy CLI cannot block a pipe reader.
    private static func runAgent(_ bin: String, arguments: [String], launch: HandoffLaunch, timeout: TimeInterval) -> (Int32?, String) {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("island-handoff-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let output = try? FileHandle(forWritingTo: log) else { return (nil, "Could not prepare the desktop launcher.") }
        defer { try? output.close(); try? FileManager.default.removeItem(at: log) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: launch.cwd)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = URL(fileURLWithPath: bin).deletingLastPathComponent().path + ":" + launch.path
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return (nil, error.localizedDescription) }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            return (nil, "Claude Desktop did not respond in time. Try again.")
        }
        let reader = try? FileHandle(forReadingFrom: log)
        defer { try? reader?.close() }
        let data = (try? reader?.read(upToCount: 64_000)) ?? Data()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func openClaudeDesktop(_ launch: HandoffLaunch) -> String? {
        let candidates = [launch.bin, NSHomeDirectory() + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        guard let bin = candidates.first(where: {
            guard FileManager.default.isExecutableFile(atPath: $0) else { return false }
            let (status, help) = runAgent($0, arguments: ["--help"], launch: launch, timeout: 5)
            return status == 0 && help.contains("--desktop")
        }) else { return "Update Claude Code to a version with --desktop support (2.1.285 or later), then try again." }
        let (status, output) = runAgent(bin, arguments: ["--desktop", "--resume", launch.sessionId], launch: launch, timeout: 30)
        if status == 0 { return nil }
        return output.isEmpty ? "Could not resume this session in Claude Desktop." : String(output.prefix(2_000))
    }
}
