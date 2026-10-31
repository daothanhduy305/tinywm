import AppKit
import StripEngine
import WindowKit

/// The menu-bar item and its menu. It shows what it is given and reports what is chosen.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
    var toggleLivePictures: () -> Void = {}
    var showPreferences: () -> Void = {}
    var showWelcome: () -> Void = {}
    var retileAll: () -> Void = {}
    var editConfig: () -> Void = {}
    var reloadConfig: () -> Void = {}
    var toggleDisplay: (String) -> Void = { _ in }
    /// Called as the menu opens, so its items can be brought up to date.
    var willOpen: () -> Void = {}
    /// Whether windows can be retiled yet: not before Accessibility access is granted.
    var canRetile: () -> Bool = { false }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let shortcutsMenu = NSMenu()
    private let displaysMenu = NSMenu()
    private let liveItem = NSMenuItem(title: "Show Live Window Pictures (Screen Recording)", action: nil, keyEquivalent: "")
    private let errorsItem = NSMenuItem(title: "Config Errors", action: nil, keyEquivalent: "")
    private let swipeWarningItem = NSMenuItem(title: "⚠︎ Trackpad Gesture Clashes with macOS", action: nil, keyEquivalent: "")
    private let loginItem = LoginMenuItem()

    init(livePictures: Bool) {
        super.init()
        statusItem.button?.image = TrayIcon.image
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.title = ""
        let menu = NSMenu()
        let preferences = item("Preferences…", #selector(preferencesChosen))
        preferences.keyEquivalent = ","
        menu.addItem(preferences)
        let shortcuts = NSMenuItem(title: "Shortcuts", action: nil, keyEquivalent: "")
        shortcuts.submenu = shortcutsMenu
        menu.addItem(shortcuts)
        let displaysItem = NSMenuItem(title: "Displays", action: nil, keyEquivalent: "")
        displaysItem.submenu = displaysMenu
        menu.addItem(displaysItem)
        menu.addItem(.separator())
        errorsItem.isHidden = true
        menu.addItem(errorsItem)
        swipeWarningItem.isHidden = true
        menu.addItem(swipeWarningItem)
        liveItem.action = #selector(livePicturesChosen)
        liveItem.target = self
        setLivePictures(livePictures)
        menu.addItem(liveItem)
        menu.addItem(item("Welcome…", #selector(welcomeChosen)))
        menu.addItem(loginItem.item)
        menu.addItem(item("Retile All Windows", #selector(retileChosen)))
        menu.addItem(item("Edit Config…", #selector(editChosen)))
        menu.addItem(item("Reload Config", #selector(reloadChosen)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit tinywm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// The text beside the icon, such as the workspace number or a missing permission.
    func setTitle(_ title: String) { statusItem.button?.title = title }

    func setLivePictures(_ on: Bool) { liveItem.state = on ? .on : .off }

    func showIssues(_ issues: [ConfigIssue]) {
        errorsItem.isHidden = issues.isEmpty
        errorsItem.submenu = disabledItems(issues.map(\.description))
    }

    /// Lists the macOS gestures that clash with tinywm's swipes or pinch.
    func showSwipeClashes(_ clashes: [String], fingers: Int, pinches: [String]) {
        swipeWarningItem.isHidden = clashes.isEmpty && pinches.isEmpty
        guard !swipeWarningItem.isHidden else { return }
        let other = fingers == 3 ? 4 : 3
        var hints: [String] = []
        if !clashes.isEmpty { hints.append("Turn it off there, or set swipe-fingers = \(other) in the config") }
        if !pinches.isEmpty { hints.append("Turn off the macOS pinch, change pinch-fingers, or set pinch-overview = off in the config") }
        let menu = disabledItems((clashes + pinches).map { "macOS uses \($0)" } + hints)
        menu.addItem(.separator())
        menu.addItem(item("Open Trackpad Settings…", #selector(trackpadSettingsChosen)))
        swipeWarningItem.submenu = menu
    }

    /// Lists every shortcut with its keys, as `keys` writes them.
    func showShortcuts(_ entries: [ShortcutRegistry.Entry], keys: (String) -> String) {
        shortcutsMenu.removeAllItems()
        addDisabledItems(entries.map { "\(keys($0.action))  \($0.title)" }, to: shortcutsMenu)
    }

    /// One item per attached screen, checked unless tinywm leaves it alone.
    func showDisplays(disabled: Set<String>) {
        displaysMenu.removeAllItems()
        for screen in NSScreen.screens {
            guard let id = Screens.uuid(of: screen) else { continue }
            let item = NSMenuItem(title: screen.localizedName, action: #selector(displayChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = disabled.contains(id) ? .off : .on
            displaysMenu.addItem(item)
        }
    }

    private func disabledItems(_ titles: [String]) -> NSMenu {
        let menu = NSMenu()
        addDisabledItems(titles, to: menu)
        return menu
    }

    private func addDisabledItems(_ titles: [String], to menu: NSMenu) {
        for title in titles {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem.refresh()
        willOpen()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action != #selector(retileChosen) || canRetile()
    }

    @objc private func livePicturesChosen() { toggleLivePictures() }
    @objc private func preferencesChosen() { showPreferences() }
    @objc private func welcomeChosen() { showWelcome() }
    @objc private func retileChosen() { retileAll() }
    @objc private func editChosen() { editConfig() }
    @objc private func reloadChosen() { reloadConfig() }
    @objc private func trackpadSettingsChosen() { SystemSetup.openTrackpadSettings() }
    @objc private func displayChosen(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { toggleDisplay(id) }
    }
}
