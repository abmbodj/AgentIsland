import Foundation

/// The bundled VS Code / Cursor companion extension (precise integrated-terminal jump, D14).
enum EditorExtension {
    static let id = "abmbodj.agent-island-jump"

    struct Editor {
        let name: String
        let app: Jumper.App
        let cli: String
        let extensionsDir: String
    }

    static let editors: [Editor] = [
        Editor(name: "VS Code", app: .vscode, cli: "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code", extensionsDir: ".vscode/extensions"),
        Editor(name: "Cursor", app: .cursor, cli: "/Applications/Cursor.app/Contents/Resources/app/bin/cursor", extensionsDir: ".cursor/extensions"),
    ]

    static var available: [Editor] {
        editors.filter { FileManager.default.isExecutableFile(atPath: $0.cli) }
    }

    static func installed(in app: Jumper.App) -> Bool {
        guard let e = editors.first(where: { $0.app == app }) else { return false }
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(e.extensionsDir)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).contains { $0.hasPrefix(id + "-") }
    }

    static var anyInstalled: Bool { editors.contains { installed(in: $0.app) } }

    private static var vsix: String? {
        Bundle.main.path(forResource: "agent-island-jump", ofType: "vsix")
    }

    static func install() throws {
        guard let vsix else { throw NSError(domain: "AgentIsland", code: 10, userInfo: [NSLocalizedDescriptionKey: "Extension package missing from the app"]) }
        for e in available { try run(e.cli, ["--install-extension", vsix, "--force"]) }
    }

    static func uninstall() {
        for e in available where installed(in: e.app) { try? run(e.cli, ["--uninstall-extension", id]) }
    }

    private static func run(_ cli: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
    }
}
