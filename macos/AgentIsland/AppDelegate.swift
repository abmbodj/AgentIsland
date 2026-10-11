import AppKit
import ServiceManagement
import Sparkle
import SwiftUI

enum Preferences {
    static var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set { try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
    }

    /// Something of ours is installed (the core's uninstall plan is non-empty).
    static var claudeConnected: Bool {
        ((try? CoreBridge.shared.call(["op": "planUninstall"])) as? [Any])?.isEmpty == false
    }

    static var setupShown: Bool {
        get { UserDefaults.standard.bool(forKey: "setupShown") }
        set { UserDefaults.standard.set(newValue, forKey: "setupShown") }
    }
}

final class Updater {
    static let shared = Updater()
    // Sparkle makes no request unless automatic checks are on or the user asks.
    let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var automaticChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var island: IslandController!
    private var statusItem: NSStatusItem!
    private var windows: [String: NSWindow] = [:]
    private let pauseItem = NSMenuItem(title: "Pause Monitoring", action: #selector(togglePause), keyEquivalent: "")

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        island = IslandController()
        CoreBridge.shared.onSnapshot = { [weak self] snap in
            self?.island.update(snap)
            self?.pauseItem.state = snap.paused ? .on : .off
        }
        do {
            try CoreBridge.shared.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Agent Island couldn't start"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        _ = Updater.shared
        setUpStatusItem()
        if !Preferences.setupShown {
            showSetup()
        }
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarImage()
        statusItem.button?.setAccessibilityLabel("Agent Island")
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Set Up Integrations…", action: #selector(showSetup), keyEquivalent: "")
        menu.addItem(withTitle: "Remove Integrations…", action: #selector(showUninstall), keyEquivalent: "")
        let update = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        update.target = Updater.shared.controller
        menu.addItem(update)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Agent Island", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.target == nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        statusItem.menu = menu
    }

    /// A small island silhouette with one dot, drawn as a template image.
    private static func menuBarImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSBezierPath(roundedRect: NSRect(x: 1.5, y: 6, width: 15, height: 6.5), xRadius: 3.25, yRadius: 3.25).fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: NSRect(x: 11, y: 7.75, width: 3, height: 3)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    @objc private func togglePause() {
        CoreBridge.shared.send(["type": "pause", "paused": !CoreBridge.shared.latest.paused])
    }

    @objc func showSetup() {
        Preferences.setupShown = true
        present("setup", title: "Set Up Agent Island") { [weak self] in
            SetupView { self?.close("setup") }
        }
    }

    @objc private func showUninstall() {
        present("uninstall", title: "Remove Integrations") { [weak self] in
            UninstallView { self?.close("uninstall") }
        }
    }

    @objc private func showSettings() {
        present("settings", title: "Agent Island Settings") { [weak self] in
            SettingsView(openSetup: { self?.showSetup() }, openUninstall: { self?.showUninstall() })
        }
    }

    /// Regular windows (setup, settings) are the only times the app activates.
    private func present<V: View>(_ key: String, title: String, content: () -> V) {
        let w = windows[key] ?? {
            let w = NSWindow(contentViewController: NSHostingController(rootView: content()))
            w.title = title
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            windows[key] = w
            return w
        }()
        if !w.isVisible {
            w.contentViewController = NSHostingController(rootView: content())
            w.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func close(_ key: String) {
        windows[key]?.close()
    }
}
