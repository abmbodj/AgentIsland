import SwiftUI

struct PlanItem: Decodable, Identifiable {
    var id: String
    var title: String
    var path: String
    var diff: String
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
    @State private var error: String?

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
                    detail: (item.path as NSString).abbreviatingWithTildeInPath,
                    diff: item.diff,
                    isOn: Binding(get: { selected.contains(item.id) }, set: { on in
                        if on { selected.insert(item.id) } else { selected.remove(item.id) }
                    })
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Remove Agent Island's integrations").font(.title2.weight(.semibold))
            if items.isEmpty {
                Text("Nothing is installed.").foregroundStyle(.secondary)
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
                    .disabled(items.isEmpty)
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

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, v in Preferences.openAtLogin = v }
                Toggle("Check for updates automatically", isOn: $autoUpdate)
                    .onChange(of: autoUpdate) { _, v in Updater.shared.automaticChecks = v }
            }
            Section("Agents") {
                LabeledContent("Claude Code") {
                    HStack {
                        Text(connected ? "Connected" : "Not connected").foregroundStyle(.secondary)
                        Button(connected ? "Review…" : "Connect…", action: openSetup)
                    }
                }
            }
            Section {
                Button("Remove Integrations…", action: openUninstall)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { connected = Preferences.claudeConnected }
    }
}
