import AppKit
import Darwin

/// Brings a session's exact terminal tab / pane to the front. Runs AppleScript off the main
/// thread (Automation permission is requested by macOS on first use for each terminal).
enum Jumper {
    private static let queue = DispatchQueue(label: "agentisland.jump")

    enum App: String {
        case iterm = "com.googlecode.iterm2"
        case terminal = "com.apple.Terminal"
        case ghostty = "com.mitchellh.ghostty"
        case vscode = "com.microsoft.VSCode"
        case cursor = "com.todesktop.230313mzl4w4u92"
    }

    /// `done` runs on main with a short hint when the jump fell back to something less precise.
    static func jump(_ s: SessionInfo, done: @escaping (String?) -> Void) {
        queue.async {
            let hint = perform(s)
            DispatchQueue.main.async { done(hint) }
        }
    }

    private static func perform(_ s: SessionInfo) -> String? {
        let t = s.terminal
        if let pane = t.tmuxPane, let env = t.tmux, let tmux = tmuxPath {
            return jumpTmux(tmux: tmux, socket: String(env.split(separator: ",").first ?? ""), pane: pane)
        }
        let bundle = t.bundleId ?? bundleFor(program: t.program)
        let tty = t.tty.map { $0.hasPrefix("/dev/") ? $0 : "/dev/" + $0 }
        switch bundle.flatMap(App.init(rawValue:)) {
        case .iterm:
            let uuid = t.itermSession?.split(separator: ":").last.map(String.init)
            return focusITerm(uuid: uuid, tty: tty)
        case .terminal:
            return tty.flatMap(focusTerminal) ?? activate(bundle)
        case .ghostty:
            return focusGhostty(s)
        case .vscode, .cursor:
            return focusEditor(App(rawValue: bundle!)!, s)
        case nil:
            return activate(bundle) ?? activateAncestor(of: t.pids)
        }
    }

    // MARK: Looking at it already? (D35: no auto-expand, no chime)

    /// Whether the user is looking at this session right now: its app is frontmost and, where the
    /// terminal can tell us, its exact tab/pane is the selected one.
    static func isLookingAt(_ s: SessionInfo, completion: @escaping (Bool) -> Void) {
        let front = NSWorkspace.shared.frontmostApplication
        queue.async {
            let r = looking(s, front: front)
            DispatchQueue.main.async { completion(r) }
        }
    }

    private static func looking(_ s: SessionInfo, front: NSRunningApplication?) -> Bool {
        let t = s.terminal
        guard let frontID = front?.bundleIdentifier else { return false }
        if let pane = t.tmuxPane, let env = t.tmux, let tmux = tmuxPath {
            let sock = String(env.split(separator: ",").first ?? "")
            let active = run(tmux, ["-S", sock, "display-message", "-p", "-t", pane, "#{pane_active}#{window_active}#{session_attached}"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard active?.hasPrefix("11") == true, active != "110" else { return false }
            let client = (run(tmux, ["-S", sock, "list-clients", "-F", "#{client_tty}\t#{client_pid}"]) ?? "")
                .split(separator: "\n").first.map { $0.split(separator: "\t").map(String.init) }
            guard let client, client.count == 2, let app = ancestorApp(of: Int32(client[1]) ?? 0) else { return false }
            return app.bundleIdentifier == frontID && frontTabMatches(App(rawValue: frontID), tty: client[0], uuid: nil, ghosttyID: nil)
        }
        let bundle = t.bundleId ?? bundleFor(program: t.program)
        guard bundle == frontID else { return false }
        let tty = t.tty.map { $0.hasPrefix("/dev/") ? $0 : "/dev/" + $0 }
        let uuid = t.itermSession?.split(separator: ":").last.map(String.init)
        return frontTabMatches(App(rawValue: frontID), tty: tty, uuid: uuid, ghosttyID: ghosttyBindings[s.id])
    }

    /// Precise check where the terminal exposes it; app-level "frontmost" elsewhere (editors, desktop apps).
    private static func frontTabMatches(_ app: App?, tty: String?, uuid: String?, ghosttyID: String?) -> Bool {
        switch app {
        case .terminal:
            guard let tty else { return true }
            return appleScript("tell application id \"com.apple.Terminal\" to get tty of selected tab of front window").result?.stringValue == tty
        case .iterm:
            let r = appleScript("tell application id \"com.googlecode.iterm2\" to get {unique id, tty} of current session of current window").result
            return r?.atIndex(1)?.stringValue == uuid || r?.atIndex(2)?.stringValue == tty
        case .ghostty:
            guard let ghosttyID else { return true }
            return appleScript("tell application id \"com.mitchellh.ghostty\" to get id of focused terminal of selected tab of front window").result?.stringValue == ghosttyID
        default:
            return true
        }
    }

    // MARK: tmux

    private static var tmuxPath: String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func jumpTmux(tmux: String, socket: String, pane: String) -> String? {
        func tm(_ args: String...) -> String? { run(tmux, ["-S", socket] + args) }
        _ = tm("select-window", "-t", pane)
        _ = tm("select-pane", "-t", pane)
        let session = tm("display-message", "-p", "-t", pane, "#{session_name}")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clients = (tm("list-clients", "-F", "#{client_tty}\t#{client_pid}\t#{session_name}") ?? "")
            .split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }.filter { $0.count == 3 }
        guard let client = clients.first(where: { $0[2] == session }) ?? clients.first else {
            return "tmux pane selected; no attached client to show it"
        }
        if client[2] != session {
            _ = tm("switch-client", "-c", client[0], "-t", pane)
        }
        // Raise the terminal tab that hosts the tmux client.
        let app = ancestorApp(of: Int32(client[1]) ?? 0)
        switch app.flatMap({ App(rawValue: $0.bundleIdentifier ?? "") }) {
        case .iterm: return focusITerm(uuid: nil, tty: client[0])
        case .terminal: return focusTerminal(tty: client[0])
        default:
            app?.activate()
            return nil
        }
    }

    // MARK: Terminals

    private static func focusITerm(uuid: String?, tty: String?) -> String? {
        let match = [uuid.map { "unique id of s is \"\(esc($0))\"" }, tty.map { "tty of s is \"\(esc($0))\"" }]
            .compactMap { $0 }.joined(separator: " or ")
        guard !match.isEmpty else { return activate(App.iterm.rawValue) }
        return script(App.iterm, """
        tell application id "com.googlecode.iterm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if \(match) then
                            tell s to select
                            tell t to select
                            tell w to select
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "missing"
        """)
    }

    private static func focusTerminal(tty: String) -> String? {
        script(App.terminal, """
        tell application id "com.apple.Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(esc(tty))" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "missing"
        """)
    }

    // Ghostty has no tty/env id, so sessions are bound to the terminal that was focused when they started (D15).
    private static var ghosttyBindings: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "ghosttyBindings") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "ghosttyBindings") }
    }

    static func forgetGhostty(_ ids: Set<String>) {
        queue.async { ghosttyBindings = ghosttyBindings.filter { !ids.contains($0.key) } }
    }

    /// Call when a Ghostty session first appears.
    static func bindGhostty(_ s: SessionInfo) {
        queue.async {
            guard ghosttyBindings[s.id] == nil else { return }
            let q = appleScript("""
            tell application id "com.mitchellh.ghostty" to get {id, working directory} of focused terminal of selected tab of front window
            """)
            let id = q.result?.atIndex(1)?.stringValue, wd = q.result?.atIndex(2)?.stringValue
            debugLog("ghostty-bind \(s.id) focused=\(id ?? "nil") wd=\(wd ?? "nil") cwd=\(s.cwd) err=\(q.error.map(String.init) ?? "nil")")
            guard let id, let wd, realpath(wd) == realpath(s.cwd) else { return }
            ghosttyBindings[s.id] = id
        }
    }

    private static func focusGhostty(_ s: SessionInfo) -> String? {
        var id = ghosttyBindings[s.id]
        let listing: (result: NSAppleEventDescriptor?, error: Int?) = id == nil ? appleScript("""
            tell application id "com.mitchellh.ghostty" to get {id, working directory} of every terminal
            """) : (nil, nil)
        if listing.error == -1743 {
            _ = activate(App.ghostty.rawValue)
            return "Allow Automation for Agent Island in System Settings to jump to the exact tab"
        }
        if id == nil, let all = listing.result, all.numberOfItems == 2, let ids = all.atIndex(1), let wds = all.atIndex(2) {
            let matches = (1...max(1, ids.numberOfItems)).filter { realpath(wds.atIndex($0)?.stringValue ?? "") == realpath(s.cwd) }
            if matches.count == 1 { id = ids.atIndex(matches[0])?.stringValue }
        }
        guard let id else {
            _ = activate(App.ghostty.rawValue)
            return "Opened Ghostty; couldn't tell which tab"
        }
        return script(App.ghostty, """
        tell application id "com.mitchellh.ghostty"
            focus (terminal id "\(esc(id))")
            activate
        end tell
        return "ok"
        """)
    }

    private static func focusEditor(_ app: App, _ s: SessionInfo) -> String? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.rawValue) else { return nil }
        // Opening the folder focuses the editor window that has it; the companion extension then shows the terminal.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([URL(fileURLWithPath: s.cwd)], withApplicationAt: appURL, configuration: config)
        guard EditorExtension.installed(in: app) else { return "Install the editor extension for exact terminal jump" }
        let scheme = app == .cursor ? "cursor" : "vscode"
        let pids = s.terminal.pids.map(String.init).joined(separator: ",")
        if let url = URL(string: "\(scheme)://abmbodj.agent-island-jump/focus?pids=\(pids)") {
            Thread.sleep(forTimeInterval: 0.35)
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    // MARK: Helpers

    static func debugLog(_ line: String) {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["AGENT_ISLAND_RENDER"].map({ $0 + ".jumps" }) else { return }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write((line + "\n").data(using: .utf8)!)
            try? h.close()
        }
        #endif
    }

    private static func bundleFor(program: String?) -> String? {
        switch program {
        case "iTerm.app": return App.iterm.rawValue
        case "Apple_Terminal": return App.terminal.rawValue
        case "ghostty": return App.ghostty.rawValue
        default: return nil
        }
    }

    @discardableResult
    private static func activate(_ bundle: String?) -> String? {
        guard let bundle, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return "App not running" }
        app.activate()
        return nil
    }

    private static func activateAncestor(of pids: [Int32]) -> String? {
        for pid in pids {
            if let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier != nil {
                app.activate()
                return nil
            }
        }
        return pids.first.flatMap { ancestorApp(of: $0) }.map { $0.activate(); return nil } ?? "Couldn't find this session's app"
    }

    /// First GUI app among the process and its ancestors.
    private static func ancestorApp(of pid: Int32) -> NSRunningApplication? {
        var p = pid
        for _ in 0..<32 where p > 1 {
            if let app = NSRunningApplication(processIdentifier: p), app.bundleIdentifier != nil { return app }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, p]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
            p = info.kp_eproc.e_ppid
        }
        return nil
    }

    private static func realpath(_ path: String) -> String {
        guard let r = Darwin.realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }

    private static func appleScript(_ source: String) -> (result: NSAppleEventDescriptor?, error: Int?) {
        var err: NSDictionary?
        let r = NSAppleScript(source: source)?.executeAndReturnError(&err)
        return (err == nil ? r : nil, err?[NSAppleScript.errorNumber] as? Int)
    }

    /// Run a focusing script; fall back to activating the app, with a hint saying why.
    private static func script(_ app: App, _ source: String) -> String? {
        let (r, err) = appleScript(source)
        if err == -1743 {
            _ = activate(app.rawValue)
            return "Allow Automation for Agent Island in System Settings to jump to the exact tab"
        }
        if r?.stringValue != "ok" {
            _ = activate(app.rawValue)
            return r?.stringValue == "missing" ? "Tab not found; opened the app" : nil
        }
        return nil
    }
}
