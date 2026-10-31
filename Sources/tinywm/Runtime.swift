import AppKit
import ApplicationServices
import StripEngine
import StripModel
import WindowCore
import WindowKit

/// Settings tinywm keeps in the user defaults.
enum Defaults {
    static let disabledDisplays = "disabledDisplays"
    static let livePictures = "liveWindowPictures"
    static let appWidths = "appWidths"
}

/// tinywm while it runs: everything that needs Accessibility access, built at once when access
/// is granted. Windows, displays, motion, keys, swipes and the config all start here.
@MainActor
final class Runtime {
    private(set) var config = StripConfig()
    private(set) var swipeEnabled = true
    private(set) var recognizer = SwipeRecognizer()
    private var pinch = PinchRecognizer()

    private let menu: StatusMenu
    private let configFile: ConfigFile
    private let windows = AXWindows()
    private let tracker = WindowTracker()
    private let hotkeys = Hotkeys()
    private let snapshots: ScreenCaptureSnapshots
    /// Pictures or, in cover mode, covers for every overlay.
    private let pictures: WindowPictures
    private let highlight: FocusHighlight
    private let sizeHUD = SizeHUD()
    private let overview: Overviews
    private let displays: StripDisplays
    private let release: WindowRelease
    private let arrivals: WindowArrivals
    private let persistence: LayoutPersistence
    private let focusKeeper: FocusKeeper
    private let metaKey = MetaKey()
    /// Meta + left drag moves windows; the overlay draws the picture and the drop marker.
    private let dragger: WindowDragger
    private let dragOverlay: DragOverlay
    private let lifecycle: WindowLifecycle
    private let commands: ShortcutCommands
    private let touches = Multitouch()
    private let scrollTap = ScrollTap()

    /// Each display's overlay, minimap and peek cards, by display ID.
    private var overlays: [String: (pictures: PictureMotion, minimap: MinimapPanel, cards: PeekCards)] = [:]
    private var motionDisplays: Set<String> = []
    /// Set while the overview focuses its pick; the overview already shows where it went.
    private var overviewPicking = false
    private var coveringOverlays = 0
    private var swipeAxis: SwipeRecognizer.Axis?
    private var swipeEngine: StripEngine?
    /// Contact frames handled during the swipe, and the least and most time between a frame and
    /// its handling. Contact times use their own clock, so only the spread is a delay.
    private var swipeFrames = 0
    private var swipeDelays = (least: Double.infinity, most: -Double.infinity)
    private var icons: [pid_t: NSImage] = [:]
    private var appNames: [pid_t: String] = [:]

    /// Lets the displays reach this object, which does not exist yet when they are made.
    private final class DisplayHooks {
        var attach: (StripEngine, TiledDisplay) -> Void = { _, _ in }
        var detach: (String) -> Void = { _ in }
    }

    init(menu: StatusMenu, configFile: ConfigFile) {
        self.menu = menu
        self.configFile = configFile
        Self.startLog()
        // Motion shows live window pictures unless the user turns them off; those need
        // Screen Recording access, and without it windows move at once.
        snapshots = ScreenCaptureSnapshots(windows: windows)
        pictures = WindowPictures(snapshots: snapshots, covers: CoverArt(windows: windows))
        // Set before anything asks for a picture, so cards never record the screen.
        pictures.coverMode = !UserDefaults.standard.bool(forKey: Defaults.livePictures)
        // Fetch the real desktop picture early, so the first motion already has it.
        for screen in NSScreen.screens {
            if let id = Screens.displayID(of: screen) { _ = snapshots.wallpaper(of: id) }
        }
        highlight = FocusHighlight(windows: windows)
        overview = Overviews(pictures: pictures, windows: windows, hud: sizeHUD)
        let hooks = DisplayHooks()
        let saved = UserDefaults.standard.stringArray(forKey: Defaults.disabledDisplays) ?? []
        displays = StripDisplays(windows: windows, disabled: Set(saved),
                                 configure: { hooks.attach($0, $1) }, discard: { hooks.detach($0) })
        release = WindowRelease(windows: windows, displays: { NSScreen.screens.map { Screens.axRect($0.frame) } })
        arrivals = WindowArrivals(windows: windows)
        persistence = LayoutPersistence(windows: windows, displays: displays)
        focusKeeper = FocusKeeper(windows: windows)
        dragger = WindowDragger(displays: displays, windows: windows)
        dragOverlay = DragOverlay(pictures: pictures)
        lifecycle = WindowLifecycle(windows: windows, tracker: tracker, displays: displays, arrivals: arrivals,
                                    persistence: persistence, focusKeeper: focusKeeper, dragger: dragger,
                                    snapshots: snapshots)
        commands = ShortcutCommands(windows: windows, displays: displays, overview: overview, dragger: dragger,
                                    lifecycle: lifecycle, metaKey: metaKey, hud: sizeHUD)

        hooks.attach = { [unowned self] engine, info in attach(engine, to: info) }
        hooks.detach = { [unowned self] id in detach(id) }
        start()
    }

    private func start() {
        lifecycle.rules = { [unowned self] in config.rules }
        commands.config = { [unowned self] in config }
        Log.describe = { [unowned self] id in
            MainActor.assumeIsolated {
                let app = windows.pid(of: id).map(appName) ?? "?"
                let title = windows.cachedTitle(of: id).map { "\"\($0.prefix(60))\"" } ?? (windows.pid(of: id) == nil ? "(gone)" : "")
                return "\(id) \(app) \(title)"
            }
        }
        overview.ringStyle = highlight.style
        overview.activate = { [unowned self] id in
            overviewPicking = true
            defer { overviewPicking = false }
            displays.windowFocused(id)
            windows.focus(id)
        }
        overview.name = { [unowned self] id in persistence.names[id] }
        overview.fullScreen = { [unowned self] in lifecycle.fullScreenWindows() }
        overview.renamed = { [unowned self] id, name in
            persistence.names[id] = name
            persistence.changed()
        }
        displays.appOf = { [unowned self] id in windows.bundleID(of: id) }
        displays.widths = UserDefaults.standard.dictionary(forKey: Defaults.appWidths) as? [String: Double] ?? [:]
        displays.onWidthsChanged = { UserDefaults.standard.set($0, forKey: Defaults.appWidths) }
        release.beforeRelease = { [unowned self] in persistence.saveNow(wait: true) }
        release.install()
        persistence.enabled = { [unowned self] in config.restoreLayout }

        lifecycle.focusMoved = { [unowned self] in updateHighlight() }
        lifecycle.retileAll = { [unowned self] in retileAll() }
        lifecycle.install()

        // The first read happens before displays exist, so their engines start with the configured layout.
        configFile.addMissingDefaults()
        let first = configFile.load()
        config = first.config
        pinch.fingers = config.pinchFingers
        menu.showIssues(first.issues)
        configFile.onChange = { [unowned self] in applyConfig($0) }
        highlight.showBorder = config.focusBorder
        swipeEnabled = config.swipe
        recognizer.fingers = config.swipeFingers
        scrollTap.shield.enabled = config.swipe
        scrollTap.shield.fingers = config.swipeFingers
        refreshSwipeWarning()
        overview.keys = OverviewKeys(bindings: config.bindings, meta: config.meta, rename: config.overviewRename)
        displays.settings = config.applied(to: displays.settings)
        displays.update(Screens.infos())
        menu.showDisplays(disabled: displays.disabled)
        commands.registered = { [unowned self] in showShortcuts() }
        commands.install(on: hotkeys)
        metaKey.onChange = { [unowned self] in showShortcuts() }
        dragger.clock = MacClock()
        dragger.presenter = dragOverlay
        metaKey.dragger = dragger
        metaKey.canDrag = { [unowned self] in !overview.isOpen }
        metaKey.setMode(config.meta)
        metaKey.commandTab = config.overviewOnCommandTab
        overview.floating = config.overviewFloating
        metaKey.start()
        configFile.watch()
        startSwipes()
        persistence.reading = { [unowned self] in tracker.isProbing || arrivals.isJudging }
        arrivals.waitsForMouse = { [unowned self] in !persistence.isRestoring }
        persistence.beginRestore()
        // An app that hangs would otherwise hold each call for macOS's default of 6 seconds.
        // Set on the system-wide element, the limit applies to every element.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        tracker.start()
        watchScreens()
    }

    /// Every decision goes to ~/Library/Logs/tinywm/tinywm.log, so a misplaced window can be
    /// traced afterwards.
    private static func startLog() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/tinywm/tinywm.log")
        Log.start(at: url)
        let info = ProcessInfo.processInfo
        Log.note("start", "tinywm pid \(info.processIdentifier) from \(Bundle.main.executablePath ?? "?") "
            + "macOS \(info.operatingSystemVersionString)")
    }

    /// Log lines name windows from what is already known, so writing one never waits on an app.
    private func appName(_ pid: pid_t) -> String {
        if let known = appNames[pid] { return known }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        appNames[pid] = name
        return name
    }

    // MARK: Config

    /// Applies a freshly read config to everything that follows it. Nothing here needs a restart.
    private func applyConfig(_ parsed: StripConfig.Parsed) {
        Log.note("config", "reloaded; \(parsed.issues.count) issues")
        config = parsed.config
        pinch = PinchRecognizer()
        pinch.fingers = config.pinchFingers
        menu.showIssues(parsed.issues)
        commands.reload()
        metaKey.setMode(config.meta)
        metaKey.commandTab = config.overviewOnCommandTab
        overview.floating = config.overviewFloating
        displays.settings = config.applied(to: displays.settings)
        for engine in displays.engines.values {
            let settings = config.applied(to: engine.settings)
            if settings != engine.settings { engine.settings = settings }
        }
        highlight.showBorder = config.focusBorder
        swipeEnabled = config.swipe
        recognizer.fingers = config.swipeFingers
        scrollTap.shield.enabled = config.swipe
        scrollTap.shield.fingers = config.swipeFingers
        refreshSwipeWarning()
        overview.keys = OverviewKeys(bindings: config.bindings, meta: config.meta, rename: config.overviewRename)
        showShortcuts()
        lifecycle.applyRules()
    }

    private func showShortcuts() {
        let registry = ShortcutRegistry.shared
        menu.showShortcuts(registry.entries) { [unowned self] action in
            registry.shortcut(for: action).map(metaKey.display) ?? "none"
        }
    }

    // MARK: Menu choices

    /// By default each window shows as a live picture while it moves, which records the
    /// windows. Turned off, each window shows as a card with its app's icon and title, so
    /// tinywm never records the screen. The choice takes effect at the next motion.
    func setLivePictures(_ live: Bool) {
        pictures.coverMode = !live
        // Every window needs a picture before its next move.
        if live { for e in displays.engines.values { snapshots.prime(Set(e.workspaces.strips.flatMap(\.allWindows))) } }
    }

    func toggleDisplay(_ id: String) {
        Log.note("display", "menu toggles \(id): \(displays.disabled.contains(id) ? "on" : "off")")
        if displays.disabled.contains(id) {
            displays.setEnabled(id, true)
            lifecycle.adoptWindows(on: id)
        } else {
            let released = displays.setEnabled(id, false)
            lifecycle.restore(released)
        }
        UserDefaults.standard.set(Array(displays.disabled), forKey: Defaults.disabledDisplays)
        for (id, engine) in displays.engines { overlays[id]?.pictures.viewport = engine.viewport }
        menu.showDisplays(disabled: displays.disabled)
    }

    func retileAll() {
        displays.retileAll(Screens.infos())
        for (id, engine) in displays.engines { overlays[id]?.pictures.viewport = engine.viewport }
    }

    /// Shows a menu warning when a macOS gesture clashes with tinywm's swipes or pinch.
    func refreshSwipeWarning() {
        let settings = SystemSetup.trackpadSettings()
        let clashes = swipeEnabled ? SwipeClash.clashes(fingers: recognizer.fingers, settings: settings) : []
        let pinches = config.pinchOverview ? SwipeClash.pinchClashes(fingers: config.pinchFingers, settings: settings) : []
        menu.showSwipeClashes(clashes, fingers: recognizer.fingers, pinches: pinches)
    }

    // MARK: Displays

    /// True while the screen is locked or asleep.
    private var userAway = false
    private var pendingScreens: DispatchWorkItem?
    private var settleRetile: DispatchWorkItem?

    private func watchScreens() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        // While the screen is locked or asleep, displays drop out and come back; the layout
        // waits until the user is back.
        let away: [(NotificationCenter, Notification.Name)] = [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")),
        ]
        let back: [(NotificationCenter, Notification.Name)] = [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidBecomeActiveNotification),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")),
        ]
        for (center, name) in away {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    Log.note("display", "user away: \(name.rawValue)")
                    self?.userAway = true
                }
            }
        }
        for (center, name) in back {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    Log.note("display", "user back: \(name.rawValue)")
                    self?.userAway = false
                    self?.screensChanged()
                }
            }
        }
    }

    /// A display that disappears is given a few seconds to come back before its windows move,
    /// since displays blink out while waking or when a cable wiggles. While the user is away
    /// nothing moves; the change is applied once they are back.
    private func screensChanged() {
        pendingScreens?.cancel()
        lifecycle.extendLockHold()
        let infos = Screens.infos()
        let vanished = displays.engines.keys.contains { id in !infos.contains { $0.id == id } }
        Log.note("display", "screens changed: \(infos.count) attached, vanished=\(vanished), away=\(userAway)")
        guard vanished || userAway else { return applyScreens() }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.userAway { return }
                self.applyScreens()
            }
        }
        pendingScreens = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (userAway ? 2 : 5), execute: work)
    }

    private func applyScreens() {
        displays.update(Screens.infos())
        lifecycle.extendLockHold()
        for (id, engine) in displays.engines { overlays[id]?.pictures.viewport = engine.viewport }
        menu.showDisplays(disabled: displays.disabled)
        // macOS moves windows itself for a while after a display changes, as on a new resolution,
        // so every window is written again once the displays have been quiet for a moment.
        settleRetile?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.userAway else { return }
                Log.note("display", "displays settled; retiling")
                self.retileAll()
            }
        }
        settleRetile = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Gives a new display's engine its overlay, minimap and observers.
    private func attach(_ engine: StripEngine, to info: TiledDisplay) {
        let id = info.id
        let screen: () -> NSScreen? = { Screens.screen(id: id) }
        let pictures = PictureMotion(pictures: self.pictures, windows: windows)
        pictures.screen = screen
        pictures.viewport = info.visible
        pictures.ringStyle = highlight.style
        pictures.showRing = { [unowned self] in highlight.showBorder }
        // Each display has its own pictures; nudges wait while any of them covers windows.
        pictures.onCovering = { [unowned self] on in
            coveringOverlays = max(0, coveringOverlays + (on ? 1 : -1))
            windows.holdsNudges = coveringOverlays > 0
            tracker.paused = coveringOverlays > 0
        }
        let cards = PeekCards(pictures: self.pictures)
        cards.onClick = { [unowned self] wid in
            guard let e = displays.engine(holding: wid), let column = e.strip.column(of: wid) else { return }
            e.focusColumn(column)
        }
        pictures.onActive = { [unowned self] on in
            cards.setHidden(on)
            if on { motionDisplays.insert(id) } else { motionDisplays.remove(id) }
            highlight.setSuspended(!motionDisplays.isEmpty)
            if !on { updateHighlight() }
        }
        let minimap = MinimapPanel()
        minimap.screen = screen
        minimap.icon = { [unowned self] wid in
            guard let pid = windows.pid(of: wid) else { return nil }
            if let cached = icons[pid] { return cached }
            let image = NSRunningApplication(processIdentifier: pid)?.icon
            icons[pid] = image
            return image
        }
        minimap.name = { [unowned self] wid in
            persistence.names[wid] ?? windows.pid(of: wid).flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
        }
        overlays[id] = (pictures, minimap, cards)

        engine.clock = MacClock()
        engine.presenter = pictures
        engine.observers.append { [unowned self] _ in updateHighlight() }
        engine.observers.append { [unowned self] _ in persistence.changed() }
        // Windows are captured only around motion. A new window gets one picture now so its
        // first move is not blank.
        engine.observers.append { [unowned self] e in
            snapshots.prime(Set(e.workspaces.strips.flatMap(\.allWindows)))
        }
        // A showing minimap also follows changes that move nothing, such as a window closing.
        engine.observers.append { [unowned self] e in
            guard let minimap = overlays[id]?.minimap, e.moved || minimap.isShowing, !overviewPicking else { return }
            minimap.show(e)
        }
        engine.observers.append { [unowned self] e in overview.changed(e) }
        engine.observers.append { [unowned self] e in
            cards.show(e.peeks, windows: e.peekStrip)
            overlays[id]?.pictures.showCards(e.peeks)
        }
        engine.observers.append { [unowned self] e in
            let ws = e.workspaces
            // The top empty workspace is 0, so the first one with windows is 1.
            menu.setTitle(ws.strips.count > 3 || ws.active != 1 ? " \(ws.active)" : "")
        }
    }

    private func detach(_ id: String) {
        if let ui = overlays.removeValue(forKey: id) {
            ui.pictures.close()
            ui.minimap.close()
            ui.cards.close()
        }
        motionDisplays.remove(id)
    }

    /// Puts the highlight on the strip's focused window when it really has focus. While another
    /// app is in front, such as a fullscreen game tinywm leaves alone, the border is hidden: it
    /// shows on every Space and would sit over that app.
    private func updateHighlight() {
        guard let id = windows.focusedWindow, let engine = displays.engine(holding: id),
              engine.strip.focusedWindow == id else {
            highlight.show(nil, frame: nil)
            return
        }
        highlight.show(id, frame: engine.frame(of: id))
    }

    // MARK: Swipes

    /// Trackpad swipes: sideways drags the strip under the fingers and settles on a column,
    /// up or down steps one workspace, with content following the fingers' direction.
    private func startSwipes() {
        touches.onFrame = { [unowned self] contacts, t in
            if config.pinchOverview, let event = pinch.feed(contacts, at: t), !dragger.isActive,
               (event == .pinchIn && !overview.isOpen) || (event == .spreadOut && overview.isOpen),
               let engine = displays.active(pointer: Screens.pointer()) {
                if swipeAxis != nil { handle(.cancelled) }
                overview.toggle(engine, displays: displays)
            }
            guard swipeEnabled else { return }
            for event in recognizer.feed(contacts, at: t) { handle(event) }
            if swipeAxis != nil {
                swipeFrames += 1
                let delay = CACurrentMediaTime() - t
                swipeDelays = (min(swipeDelays.least, delay), max(swipeDelays.most, delay))
            }
        }
        touches.start()
        scrollTap.start()
    }

    private func handle(_ event: SwipeRecognizer.Event) {
        switch event {
        case .began(let axis):
            swipeAxis = axis
            swipeFrames = 0
            swipeDelays = (.infinity, -.infinity)
            swipeEngine = displays.underPointer(Screens.pointer())
            if axis == .horizontal { swipeEngine?.beginSwipe() }
            else { swipeEngine?.beginVerticalSwipe() }
        case .moved(let dx, let dy):
            guard swipeAxis != nil else { return }
            if swipeAxis == .horizontal { swipeEngine?.swipe(by: dx) }
            else { swipeEngine?.swipeVertical(by: dy) }
        case .ended(let velocity):
            guard swipeAxis != nil else { return }
            let lag = swipeFrames > 1 ? Int((swipeDelays.most - swipeDelays.least) * 1000) : 0
            Log.note("swipe", "\(swipeFrames) frames, worst lag \(lag) ms")
            if swipeAxis == .horizontal {
                swipeEngine?.endSwipe(velocity: velocity)
            } else {
                swipeEngine?.endVerticalSwipe(velocity: velocity)
            }
            swipeAxis = nil
            swipeEngine = nil
        case .cancelled:
            if swipeAxis == .horizontal { swipeEngine?.endSwipe(velocity: 0) }
            else if swipeAxis == .vertical { swipeEngine?.endVerticalSwipe(velocity: 0) }
            swipeAxis = nil
            swipeEngine = nil
        }
    }
}
