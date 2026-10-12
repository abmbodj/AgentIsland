import SwiftUI

struct PlanItem: Decodable, Identifiable {
    var id: String
    var title: String
    var path: String
    var diff: String
    var note: String?
}

struct UninstallItem: Decodable, Identifiable {
    var path: String
    var drifted: Bool
    var diff: String
    var exactDiff: String
    var backupDate: Int64
    var id: String { path }
}

/// Unified diff with tinted added/removed lines. Monospaced, scrolls when long.
struct DiffView: View {
    let diff: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : String(line))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(color(line))
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(line))
                }
            }
            .textSelection(.enabled)
        }
        .frame(maxHeight: 220)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func color(_ l: Substring) -> Color {
        l.hasPrefix("@@") ? .secondary : .primary
    }

    private func background(_ l: Substring) -> Color {
        if l.hasPrefix("+++") || l.hasPrefix("---") { return .clear }
        if l.hasPrefix("+") { return Color.green.opacity(0.14) }
        if l.hasPrefix("-") { return Color.red.opacity(0.14) }
        return .clear
    }
}

private struct ChangeRow: View {
    let title: String
    let detail: String
    let diff: String?
    @Binding var isOn: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let diff {
                DisclosureGroup(isExpanded: $expanded) {
                    DiffView(diff: diff)
                } label: {
                    Text("Show changes").font(.caption)
                }
                .padding(.leading, 20)
            }
        }
    }
}

/// First-run consent: every change listed, each with its own diff, applied with one button.
struct SetupView: View {
    var onFinish: () -> Void
    @State private var items: [PlanItem] = []
    @State private var selected: Set<String> = []
    @State private var openAtLogin = true
    @State private var autoUpdate = true
    @State private var editorJump = true
    @State private var error: String?
    private let editors = EditorExtension.available

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set up Agent Island").font(.title2.weight(.semibold))
                Text("Agent Island sees your agents through their own hooks. Review each change below. You can undo all of it from the menu bar, and nothing leaves this Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if items.isEmpty {
                Text("Your agents are already connected.").foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                ChangeRow(
                    title: item.title,
                    detail: (item.path as NSString).abbreviatingWithTildeInPath + (item.note.map { "\n" + $0 } ?? ""),
                    diff: item.diff,
                    isOn: Binding(get: { selected.contains(item.id) }, set: { on in
                        if on { selected.insert(item.id) } else { selected.remove(item.id) }
                    })
                )
            }

            if !editors.isEmpty && !EditorExtension.anyInstalled {
                ChangeRow(
                    title: "Exact terminal jump in \(editors.map(\.name).joined(separator: " and "))",
                    detail: "Installs the small Agent Island Jump extension (\(EditorExtension.id)) so a click can show the right integrated terminal.",
                    diff: nil,
                    isOn: $editorJump
                )
            }

            Divider()
            ChangeRow(title: "Open at login", detail: "Starts quietly in the menu bar.", diff: nil, isOn: $openAtLogin)
            ChangeRow(
                title: "Check for updates automatically",
                detail: "The only network request Agent Island makes: a version check against GitHub Releases.",
                diff: nil,
                isOn: $autoUpdate
            )

            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Spacer()
                Button("Not Now") { onFinish() }
                    .keyboardShortcut(.cancelAction)
                Button("Set Up") { apply() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear(perform: load)
    }

    private func load() {
        items = (try? CoreBridge.shared.call(["op": "planInstall"], as: [PlanItem].self)) ?? []
        selected = Set(items.map(\.id))
    }

    private func apply() {
        do {
            _ = try CoreBridge.shared.call(["op": "applyInstall", "ids": Array(selected)])
            if editorJump && !editors.isEmpty && !EditorExtension.anyInstalled {
                try EditorExtension.install()
            }
            Preferences.openAtLogin = openAtLogin
            Updater.shared.automaticChecks = autoUpdate
            onFinish()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Removes everything Agent Island added. Exact restore when files are untouched; otherwise
/// keeps your later edits and offers the install-time backup as an alternative.
struct UninstallView: View {
    var onFinish: () -> Void
    @State private var items: [UninstallItem] = []
    @State private var error: String?
    private let hasExtension = EditorExtension.anyInstalled

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Remove Agent Island's integrations").font(.title2.weight(.semibold))
            if items.isEmpty && !hasExtension {
                Text("Nothing is installed.").foregroundStyle(.secondary)
            }
            if hasExtension {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent Island Jump extension").font(.body.weight(.medium))
                    Text("Uninstalled from \(EditorExtension.available.filter { EditorExtension.installed(in: $0.app) }.map(\.name).joined(separator: " and ")).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text((item.path as NSString).abbreviatingWithTildeInPath).font(.body.weight(.medium))
                    Text(item.drifted
                        ? "This file changed after Agent Island edited it. Only Agent Island's entries are removed; your other edits stay."
                        : "Restored exactly as it was before Agent Island edited it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    DiffView(diff: item.diff)
                }
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                if let drifted = items.first(where: \.drifted) {
                    Button("Restore Backup from \(Self.date(drifted.backupDate))") { apply("exactBackup") }
                }
                Spacer()
                Button("Cancel") { onFinish() }
                    .keyboardShortcut(.cancelAction)
                Button("Remove") { apply("surgical") }
                    .keyboardShortcut(.defaultAction)
                    .disabled(items.isEmpty && !hasExtension)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            items = (try? CoreBridge.shared.call(["op": "planUninstall"], as: [UninstallItem].self)) ?? []
        }
    }

    private func apply(_ mode: String) {
        do {
            _ = try CoreBridge.shared.call(["op": "applyUninstall", "mode": mode])
            EditorExtension.uninstall()
            onFinish()
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func date(_ secs: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(secs)).formatted(date: .abbreviated, time: .shortened)
    }
}

struct SettingsView: View {
    var openSetup: () -> Void
    var openUninstall: () -> Void
    @State private var openAtLogin = Preferences.openAtLogin
    @State private var autoUpdate = Updater.shared.automaticChecks
    @State private var connected = Preferences.claudeConnected
    @State private var codexConnected = Preferences.codexConnected
    @AppStorage("autoExpand") private var autoExpand = true
    @AppStorage("hoverDelay") private var hoverDelay = 0.35
    @AppStorage("display") private var display = "active"
    @AppStorage("chimeNeedsInput") private var chimeNeedsInput = true
    @AppStorage("chimeFinished") private var chimeFinished = true
    @AppStorage("soundNeedsInput") private var soundNeedsInput = "Glass"
    @AppStorage("soundFinished") private var soundFinished = "Tink"
    @AppStorage("soundVolume") private var soundVolume = 0.6
    @State private var hotKey = HotKey.shared.display
    @State private var recording = false
    @State private var recorder: Any?

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, v in Preferences.openAtLogin = v }
                Toggle("Check for updates automatically", isOn: $autoUpdate)
                    .onChange(of: autoUpdate) { _, v in Updater.shared.automaticChecks = v }
            }
            Section("Island") {
                Picker("Show on", selection: $display) {
                    Text("Active display").tag("active")
                    Text("Built-in display").tag("builtin")
                    ForEach(NSScreen.screens, id: \.localizedName) { s in
                        Text(s.localizedName).tag(DisplayChoice.id(s))
                    }
                    Text("All displays").tag("all")
                }
                Toggle("Expand when an agent needs you", isOn: $autoExpand)
                LabeledContent("Hover delay") {
                    HStack {
                        Slider(value: $hoverDelay, in: 0...1, step: 0.05).frame(width: 160)
                        Text("\(Int(hoverDelay * 1000)) ms").monospacedDigit().foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                    }
                }
            }
            Section("Keyboard") {
                LabeledContent("Summon the island") {
                    Button(recording ? "Press a shortcut…" : hotKey) { record() }
                        .help("Opens the island with keyboard focus: ⌘Y allow, ⌘N deny, ⌘1–9 answer, J/K move, Esc undo or close")
                }
            }
            Section("Sounds") {
                soundRow("When an agent needs you", on: $chimeNeedsInput, name: $soundNeedsInput, kind: .needsInput)
                soundRow("When a turn finishes", on: $chimeFinished, name: $soundFinished, kind: .finished)
                LabeledContent("Volume") {
                    Slider(value: $soundVolume, in: 0...1).frame(width: 160)
                }
                Text("Silent when you're already looking at that session, and never more than once every 10 seconds.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Agents") {
                LabeledContent("Claude Code") {
                    HStack {
                        Text(connected ? "Connected" : "Not connected").foregroundStyle(.secondary)
                        Button(connected ? "Review…" : "Connect…", action: openSetup)
                    }
                }
                LabeledContent("Codex") {
                    HStack {
                        Text(codexConnected ? "Connected" : "Not connected").foregroundStyle(.secondary)
                        Button(codexConnected ? "Review…" : "Connect…", action: openSetup)
                    }
                }
            }
            Section {
                Button("Remove Integrations…", action: openUninstall)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear {
            connected = Preferences.claudeConnected
            codexConnected = Preferences.codexConnected
        }
    }

    private func soundRow(_ title: String, on: Binding<Bool>, name: Binding<String>, kind: Sounds.Kind) -> some View {
        HStack {
            Toggle(title, isOn: on)
            Spacer()
            Picker("", selection: name) {
                ForEach(Sounds.choices, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 120)
            .disabled(!on.wrappedValue)
            Button { Sounds.play(kind, preview: true) } label: { Image(systemName: "speaker.wave.2") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Preview sound")
        }
    }

    /// Capture the next key chord (must include ⌘, ⌥ or ⌃) as the summon shortcut.
    private func record() {
        recording = true
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let mods = HotKey.carbonModifiers(e.modifierFlags)
            if e.keyCode == 53 { stop(); return nil } // Esc cancels
            guard e.modifierFlags.intersection([.command, .option, .control]).isEmpty == false else { return nil }
            HotKey.shared.set(keyCode: UInt32(e.keyCode), modifiers: mods)
            hotKey = HotKey.shared.display
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let r = recorder { NSEvent.removeMonitor(r) }
        recorder = nil
    }
}
