import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private let server = EventServer(port: EventServer.configuredPort)
    private var controllers: [NotchWindowController] = []
    private var mouseMonitors: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) {
            NSApp.terminate(nil)
            return
        }

        server.onEvent = { [weak self] in self?.store.handle($0) }
        server.onStateRequest = { [weak self] in self?.store.debugSnapshot() ?? Data("{}".utf8) }
        server.onDemoRequest = { [weak self] in
            guard let self else { return }
            Demo.play(on: store)
        }
        server.onPeekRequest = { [weak self] in
            self?.controllers.forEach { $0.peek(for: 8) }
        }
        do {
            try server.start()
        } catch {
            NSLog("Claudebar: could not listen on port \(server.port): \(error)")
        }

        // Rebuilding tears down the window that may be hosting the menu that triggered it,
        // so hop to the next runloop turn first.
        Preferences.shared.onDisplaysChanged = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.rebuildWindows() } }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildWindows() }
        }

        rebuildWindows()
        installMouseMonitors()
        store.start()
        setUpLoginItemOnce()
    }

    /// The first time an installed copy runs, start it at login like any other menu bar
    /// app. After that it's the "Launch at login" toggle's call. Dev builds are left alone.
    private func setUpLoginItemOnce() {
        let key = "didSetUpLoginItem"
        guard Bundle.main.bundlePath.contains("/Applications/"),
              !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        Preferences.shared.launchAtLogin = true
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveSessions()
    }

    private func rebuildWindows() {
        controllers.forEach { $0.close() }
        let screens: [NSScreen]
        if Preferences.shared.allDisplays {
            screens = NSScreen.screens
        } else {
            screens = [NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main].compactMap { $0 }
        }
        controllers = screens.map { NotchWindowController(screen: $0, store: store) }
    }

    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func mouseMoved() {
        controllers.forEach { $0.mouseMoved() }
    }
}
