import AppKit

/// Borderless, non-activating overlay. Never key, never main, never in the Dock / ⌘Tab / Mission Control.
final class IslandPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar // above the menu bar so it can sit flush with the notch
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Where the island lives on a given screen.
struct IslandGeometry {
    let screen: NSScreen
    /// The hardware notch (screen coordinates); zero width on displays without one.
    let notch: CGRect
    var hasNotch: Bool { notch.width > 0 }

    init(screen: NSScreen) {
        self.screen = screen
        let f = screen.frame
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            let h = screen.safeAreaInsets.top
            notch = CGRect(x: f.minX + l.width, y: f.maxY - h, width: f.width - l.width - r.width, height: h)
        } else {
            // Floating pill centred in the menu bar strip.
            let bar = max(f.maxY - screen.visibleFrame.maxY, 24)
            notch = CGRect(x: f.midX, y: f.maxY - bar, width: 0, height: bar)
        }
    }
}

/// Owns the panel, follows the active screen and renders snapshots into the pill.
final class IslandController {
    private let panel = IslandPanel()
    private let pill = PillView()
    private var geometry: IslandGeometry?
    private var snapshot = Snapshot()
    /// Room on each side of the notch for wings.
    private let capacity: CGFloat = 200

    init() {
        panel.contentView = pill
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.reposition() }
        nc.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.render(animated: false) }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.reposition() }
        reposition()
    }

    func update(_ snap: Snapshot) {
        snapshot = snap
        render(animated: true)
    }

    private func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let g = IslandGeometry(screen: screen)
        if g.notch != geometry?.notch {
            geometry = g
            let w = g.notch.width + capacity * 2
            panel.setFrame(CGRect(x: g.notch.midX - w / 2, y: g.notch.minY, width: w, height: g.notch.height), display: false)
            render(animated: false)
        }
    }

    private func render(animated: Bool) {
        guard let g = geometry else { return }
        let visible = !snapshot.paused && !snapshot.sessions.isEmpty
        pill.configure(notchWidth: g.notch.width, hasNotch: g.hasNotch)
        pill.update(sessions: visible ? snapshot.sessions : [], attention: visible ? snapshot.attention : 0, animated: animated && !Theme.reduceMotion)
        #if DEBUG
        debugRender()
        #endif
        if visible || g.hasNotch {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    #if DEBUG
    /// AGENT_ISLAND_RENDER=/path.png writes the pill (over a light menu-bar stand-in) after each render.
    private func debugRender() {
        guard let path = ProcessInfo.processInfo.environment["AGENT_ISLAND_RENDER"], let layer = pill.layer else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [pill] in
            let scale: CGFloat = 2
            let size = pill.bounds.size
            guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            ctx.scaleBy(x: scale, y: scale)
            ctx.setFillColor(NSColor(white: 0.93, alpha: 1).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            layer.render(in: ctx)
            guard let img = ctx.makeImage() else { return }
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
    #endif
}
