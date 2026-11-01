import AppKit
import ApplicationServices
import WindowCore

/// Tracks macOS Exposé through the Dock's notifications.
@MainActor
public final class ExposeWatcher {
    public private(set) var isShowing = false
    private var observer: AXObserver?
    private var tokens: [NSObjectProtocol] = []
    private static let notifications = ["AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeShowDesktop", "AXExposeExit"]

    public init() {}

    deinit {
        MainActor.assumeIsolated {
            reset()
            for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        }
    }

    /// Clears the state when tinywm sends Esc, even if the Dock misses Exit.
    public func closed() { isShowing = false }

    public func start() {
        guard tokens.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "com.apple.dock" else { return }
                let launched = n.name == NSWorkspace.didLaunchApplicationNotification
                MainActor.assumeIsolated {
                    self?.reset()
                    if launched { self?.watch(app) }
                }
            })
        }
        if let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first { watch(dock) }
    }

    private func reset() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        isShowing = false
    }

    private func watch(_ dock: NSRunningApplication) {
        var observer: AXObserver?
        let result = AXObserverCreate(dock.processIdentifier, { _, _, notification, context in
            guard let context else { return }
            let watcher = Unmanaged<ExposeWatcher>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.received(notification as String) }
        }, &observer)
        guard result == .success, let observer else {
            Log.note("expose", "could not watch the Dock: \(result.rawValue)")
            return
        }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications {
            let result = AXObserverAddNotification(observer, app, name as CFString, context)
            guard result == .success else {
                Log.note("expose", "could not watch \(name): \(result.rawValue)")
                return
            }
        }
        self.observer = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    func received(_ notification: String) {
        guard Self.notifications.contains(notification) else { return }
        isShowing = notification != "AXExposeExit"
    }
}
