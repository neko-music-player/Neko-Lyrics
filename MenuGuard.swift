import AppKit

/// The menu-bar window (settings) opens at a normal pop-up level. Our full-screen overlays sit higher so they
/// can cover the menu bar, which also put them on top of the settings. While the settings are open, any of our
/// windows above that level step down, and go back up when the settings close.
@MainActor
final class MenuGuard {
    static let shared = MenuGuard()
    private var lowered: [(window: NSWindow, level: NSWindow.Level)] = []
    private var started = false
    private var menuWindow: NSWindow?

    func start() {
        guard !started else { return }
        started = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] n in
            guard let w = n.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.keyed(w) }
        }
        nc.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] n in
            guard let w = n.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.resigned(w) }
        }
        nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] n in
            guard let w = n.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.resigned(w) }
        }
    }

    private func isMenu(_ w: NSWindow) -> Bool {
        let name: String = String(describing: type(of: w))
        return name.contains("MenuBarExtra") || name.contains("StatusBar")
    }

    private func keyed(_ w: NSWindow) {
        guard isMenu(w), menuWindow == nil else { return }
        menuWindow = w
        let ceiling: Int = w.level.rawValue
        for other in NSApp.windows where other !== w && other.isVisible && other.level.rawValue >= ceiling {
            lowered.append((other, other.level))
            other.level = NSWindow.Level(rawValue: ceiling - 1)
        }
    }

    private func resigned(_ w: NSWindow) {
        guard w === menuWindow else { return }
        menuWindow = nil
        for item in lowered { item.window.level = item.level }
        lowered = []
    }
}
