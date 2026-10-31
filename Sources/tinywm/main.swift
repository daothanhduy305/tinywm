import AppKit
import ApplicationServices
import StripEngine

/// Starts tinywm: shows the menu, opens Preferences on About the first time or while Accessibility
/// is missing, then builds the runtime once access is granted. Before that only the menu and Preferences work.
@MainActor
final class TinyWMApp: NSObject, NSApplicationDelegate {
    private let configFile = ConfigFile()
    private lazy var preferences = PreferencesWindow(configFile: configFile) { [unowned self] in runtime?.setLivePictures($0) }
    private var menu: StatusMenu!
    /// Nil until Accessibility access is granted.
    private var runtime: Runtime?

    func applicationDidFinishLaunching(_: Notification) {
        UserDefaults.standard.register(defaults: [Defaults.livePictures: true])
        menu = StatusMenu()
        menu.showPreferences = { [unowned self] in preferences.show() }
        configFile.onChange.append { [unowned self] in menu.showIssues($0.issues) }
        menu.showIssues(configFile.load().issues)
        configFile.watch()
        menu.retileAll = { [unowned self] in runtime?.retileAll() }
        menu.canRetile = { [unowned self] in runtime != nil }
        menu.toggleDisplay = { [unowned self] id in runtime?.toggleDisplay(id) }
        menu.willOpen = { [unowned self] in runtime?.refreshSwipeWarning() }

        // First launch, or no Accessibility yet: About lists the permissions with Grant buttons.
        let seen = UserDefaults.standard.bool(forKey: Defaults.welcomeSeen)
        UserDefaults.standard.set(true, forKey: Defaults.welcomeSeen)
        guard AXIsProcessTrusted() else {
            preferences.show(.about)
            menu.setTitle(" needs Accessibility")
            Task { @MainActor in
                while !AXIsProcessTrusted() { try? await Task.sleep(for: .seconds(2)) }
                menu.setTitle("")
                start()
            }
            return
        }
        if !seen { preferences.show(.about) }
        start()
    }

    private func start() {
        runtime = Runtime(menu: menu, configFile: configFile)
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { TinyWMApp() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
