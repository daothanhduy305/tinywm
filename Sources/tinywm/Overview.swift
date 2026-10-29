import AppKit
import QuartzCore
import StripEngine
import StripModel
import WindowCore
import WindowKit

/// A niri-style overview of one display: its workspaces zoom out into stacked rows of live window
/// pictures, one selection moves among them, and choosing a window zooms into its workspace.
/// The real windows do not move while it is open. `Overviews` opens one on every display.
@MainActor
final class Overview {
    private enum Phase { case closed, open, closing }

    /// Switches to the window's workspace and gives it focus.
    var activate: (String) -> Void = { _ in }
    /// A window was clicked or confirmed, or nil to cancel. The owner closes every overview.
    var chose: (String?) -> Void = { _ in }
    /// An arrow key found no window that way on this display.
    var atEdge: (Direction) -> Void = { _ in }
    /// The search bar's text changed. The owner keeps the query.
    var typed: (String) -> Void = { _ in }
    /// Esc was pressed with a query typed.
    var clearSearch: () -> Void = {}
    /// This display's search bar was clicked, so its overview should take the keys.
    var wantsKeys: () -> Void = {}
    /// The name given to a window, if any.
    var name: (String) -> String? = { _ in nil }
    /// A window was given a name, or nil to clear it.
    var renamed: (String, String?) -> Void = { _, _ in }
    var dragStarted: (String, Point, Point) -> Void = { _, _, _ in }
    var dragMoved: (Point) -> Void = { _ in }
    var dragReleased: () -> Void = {}
    var dragRightClick: () -> Bool = { false }
    var cancelDragging: () -> Bool = { false }
    var preview: Workspaces?
    var dragRows: [Int]?
    var previewID: String?
    /// Floating windows' frames, read once when the overview opens.
    private var floats: [String: Rect] = [:]
    /// Fullscreen windows' frames on this display, relative to the viewport's top-left.
    private var fullScreen: [String: Rect] = [:]
    /// Windows on a Space not shown: fullscreen windows elsewhere, or, from a fullscreen window's
    /// Space, every other window. Their pictures fade in and out in place, since zooming from or to
    /// their real frames would show them over the Space in front. Picking one switches Space.
    private var away: Set<String> = []
    var ringStyle = FocusHighlight.Style()
    var floating = OverviewFloating.vertical
    var stiffness = Spring.stiffness
    /// Pictures refresh this often while the overview is open.
    var rate = 10.0

    private let snapshots: ScreenCaptureSnapshots
    private let pictures: WindowPictures
    private let windows: AXWindows
    private let panel: OverviewPanel
    private let view = OverviewView()
    fileprivate let root = CALayer()
    private let backdrop = CALayer()
    private let dim = CALayer()
    fileprivate let ring = CALayer()
    fileprivate let marker = CALayer()
    fileprivate var drag: (id: String, press: CGPoint, grab: CGPoint, canDrag: Bool, started: Bool, drop: OverviewDrop?)?
    /// A rounded plate behind the shelf of floating windows, like the Dock.
    private let dock = CALayer()
    fileprivate var layers: [String: WindowLayer] = [:]
    /// Holds each picture and casts its shadow, which the picture's own clipping would cut off.
    /// Moves, zooms and fades in place of the picture.
    fileprivate var holders: [String: CALayer] = [:]
    /// Each window's "App — Title" line, under its picture.
    fileprivate var labels: [String: CATextLayer] = [:]
    /// The text of each label, which the search matches.
    fileprivate var titles: [String: String] = [:]
    private let searchBar = CALayer()
    private let searchField = SearchField()
    private let searchIcon = CALayer()
    private let renameField = RenameField()
    /// The window whose name is being edited.
    private var renaming: String?
    /// Keeps the rows clear of the search bar at the top.
    private static let style = OverviewStyle(top: 46)
    private var style: OverviewStyle { OverviewStyle(top: Self.style.top, floating: floating) }
    /// The windows the query matches, or nil with no query.
    private var matching: Set<String>?

    private var phase = Phase.closed
    private(set) var engine: StripEngine?
    private var screen: NSScreen?
    fileprivate var viewport = Rect(x: 0, y: 0, width: 1, height: 1)
    private var metrics = StripMetrics(viewport: Rect(x: 0, y: 0, width: 1, height: 1), gap: 0)
    fileprivate var layout: OverviewLayout?
    /// Each window's real frame when the overview opened, which is also its picture's size.
    private var real: [String: Rect] = [:]
    fileprivate var selected: String?
    /// The selection the overview opened with or the keys moved to; it comes back when the pointer leaves.
    fileprivate var home: String?
    private var previous: String?
    private var pan = 0.0
    private var token = 0
    /// Windows whose picture has faded in since the overview opened.
    private var faded: Set<String> = []

    var isOpen: Bool { phase != .closed }
    var isShowing: Bool { phase == .open }
    /// False when a search is typed and no window here matches it.
    var hasMatches: Bool { !ids.isEmpty && (matching.map { !$0.isEmpty } ?? true) }
    /// The windows whose pictures are shown.
    var ids: Set<String> { Set(layers.keys) }
    var keys: OverviewKeys {
        get { view.keys }
        set {
            view.keys = newValue
            searchField.keys = newValue
        }
    }

    init(pictures: WindowPictures, windows: AXWindows) {
        self.pictures = pictures
        self.snapshots = pictures.snapshots
        self.windows = windows
        panel = OverviewPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.animationBehavior = .none
        panel.alphaValue = 0

        view.wantsLayer = true
        view.layer?.addSublayer(root)
        root.masksToBounds = true
        root.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        backdrop.contentsGravity = .resizeAspectFill
        root.addSublayer(backdrop)
        dim.backgroundColor = NSColor(white: 0, alpha: 0.45).cgColor
        root.addSublayer(dim)
        dock.backgroundColor = NSColor(white: 0.2, alpha: 0.7).cgColor
        dock.cornerRadius = 20
        dock.cornerCurve = .continuous
        dock.borderWidth = 1
        dock.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        dock.opacity = 0
        dock.zPosition = 6
        root.addSublayer(dock)
        marker.zPosition = 9
        marker.isHidden = true
        root.addSublayer(marker)
        ring.zPosition = 10
        root.addSublayer(ring)
        // A bright, bordered pill, so it reads as a place to type rather than a caption.
        searchBar.backgroundColor = NSColor(white: 0.16, alpha: 0.92).cgColor
        searchBar.cornerRadius = 23
        searchBar.borderWidth = 2
        searchBar.shadowColor = NSColor.black.cgColor
        searchBar.shadowOpacity = 0.5
        searchBar.shadowRadius = 12
        searchBar.shadowOffset = .zero
        searchBar.zPosition = 20
        searchBar.opacity = 0
        let glass = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white])))
        searchIcon.contents = glass
        searchIcon.contentsGravity = .resizeAspect
        searchBar.addSublayer(searchIcon)
        root.addSublayer(searchBar)
        panel.contentView = view

        view.onKey = { [weak self] in self?.handle($0) }
        // Meta + R would otherwise type into the search bar when no shortcut takes it first.
        panel.onKeyDown = { [weak self] e in
            guard let self, keys.isRename(keyCode: Int(e.keyCode), flags: UInt64(e.modifierFlags.rawValue)) else { return false }
            handle(.rename)
            return true
        }
        searchField.isHidden = true
        view.addSubview(searchField)
        searchField.wantsLayer = true
        searchField.layer?.zPosition = 100
        searchField.onKey = { [weak self] in self?.handle($0) }
        searchField.onFocus = { [weak self] in
            guard let self, phase == .open else { return }
            wantsKeys()
        }
        searchField.onChange = { [weak self] text in
            guard let self, phase == .open else { return }
            typed(text)
        }
        view.onHover = { [weak self] p in
            guard let self, phase == .open, let hit = layout?.window(at: Point(x: p.x, y: p.y)) else { return }
            select(hit.id, "hover at \(Int(p.x)),\(Int(p.y))")
        }
        view.onExit = { [weak self] in
            guard let self, phase == .open else { return }
            if let home { select(home, "pointer left") }
        }
        view.onPress = { [weak self] p in
            guard let self, phase == .open, let hit = layout?.window(at: Point(x: p.x, y: p.y)), let engine else { return }
            let canDrag = !away.contains(hit.id) && engine.workspaces.strips.indices.contains(hit.workspace)
                && engine.workspaces.strips[hit.workspace].column(of: hit.id) != nil
                && layout?.rows.first(where: { $0.workspace == -1 })?.windows.contains(hit) != true
            guard let holder = holders[hit.id], holder.bounds.width > 0 else { return }
            let scale = hit.rect.width / holder.bounds.width
            guard scale > 0 else { return }
            drag = (hit.id, p, CGPoint(x: (p.x - hit.rect.center.x) / scale, y: (p.y - hit.rect.center.y) / scale), canDrag, false, nil)
        }
        view.onDrag = { [weak self] p in self?.dragged(p) }
        view.onRelease = { [weak self] p in self?.released(p) }
        renameField.isHidden = true
        view.addSubview(renameField)
        renameField.wantsLayer = true
        renameField.layer?.zPosition = 100
        renameField.onDone = { [weak self] in self?.finishRename($0) }
        view.onRightClick = { [weak self] p in
            guard let self, phase == .open else { return }
            if dragRightClick() { return }
            guard view.bounds.contains(p), let hit = layout?.window(at: Point(x: p.x, y: p.y)) else { return }
            view.showMenu(at: p) { [weak self] in
                guard let self, phase == .open, let w = layout?.window(hit.id) else { return }
                startRename(w.id, at: w.rect)
            }
        }
        view.onScroll = { [weak self] delta in
            guard let self, phase == .open, let layout else { return }
            pan = max(0, min(layout.panRange, pan - Double(delta)))
            relayout(animated: false)
        }
        snapshots.onUpdate.append { [weak self] id in self?.pictureArrived(id) }
    }

    // MARK: Opening

    /// Opens on `engine`'s display with its focused window selected. Only the active one takes
    /// keys. False when there is nothing to show.
    func open(_ engine: StripEngine, on screen: NSScreen?, active: Bool, fullScreen: [String: Rect] = [:]) -> Bool {
        // Also while closing, so the hotkey works again at once.
        guard phase != .open, pictures.available, let screen else { return false }
        let ws = engine.workspaces
        let m = engine.metrics
        let size = Size(width: m.viewport.width, height: m.viewport.height)
        floats = engine.floatFrames()
        let v = engine.viewport
        self.fullScreen = fullScreen.mapValues { Rect(x: $0.x - v.x, y: $0.y - v.y, width: $0.width, height: $0.height) }
        let probe = overviewLayout(ws, m, screen: size, style: style, floats: floats, fullScreen: self.fullScreen)
        let first = probe.windows.first?.id

        self.engine = engine
        self.screen = screen
        viewport = engine.viewport
        metrics = m
        previous = windows.focusedWindow
        let focus = ws.current.focusedWindow.flatMap { probe.window($0) != nil ? $0 : nil } ?? first
        selected = focus
        home = focus
        pan = focus.map { probe.pan(toReveal: $0, current: 0) } ?? 0
        layout = overviewLayout(ws, m, screen: size, pan: pan, style: style, floats: floats, fullScreen: self.fullScreen)
        // A fullscreen window's picture zooms out from the whole screen.
        real = overviewRealFrames(ws, m, floats: floats).merging(self.fullScreen) { a, _ in a }
        let onFullScreen = previous.map { self.fullScreen[$0] != nil } ?? false
        away = (onFullScreen ? Set(layout!.windows.map(\.id)) : Set(self.fullScreen.keys)).subtracting([previous].compactMap { $0 })
        phase = .open
        token += 1
        matching = nil
        faded = []
        showQuery("")
        searchIcon.contentsScale = screen.backingScaleFactor

        place()
        // Keys typed before the panel is key go to the app in front, so take them before the slower setup.
        panel.orderFrontRegardless()
        searchField.isHidden = false
        if active { takeKeys() } else { releaseKeys() }
        refreshBackdrop()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        removeLayers()
        // A wide row can pan under a vertical shelf, so the shelf and its plate draw above the rows.
        let shelved = Set(layout!.rows.last.flatMap { $0.workspace == -1 ? $0.windows.map(\.id) : nil } ?? [])
        for w in layout!.windows {
            guard let r = real[w.id] else { continue }
            let holder = CALayer()
            holder.bounds = CGRect(origin: .zero, size: CGSize(width: r.width, height: r.height))
            holder.position = CGPoint(x: r.center.x, y: r.center.y)
            // In window points: the holder is scaled down with the picture. The view is flipped, so a
            // positive offset casts the shadow downwards.
            holder.shadowColor = NSColor.black.cgColor
            holder.shadowOpacity = 0.5
            holder.shadowRadius = 40
            holder.shadowOffset = CGSize(width: 0, height: 12)
            holder.shadowPath = CGPath(roundedRect: holder.bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
            let layer = WindowLayer()
            layer.frame = holder.bounds
            // A faint edge keeps a light window apart from a light desktop.
            layer.borderWidth = 2
            layer.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
            pictures.show(w.id, on: layer)
            holder.addSublayer(layer)
            if away.contains(w.id) {
                holder.position = CGPoint(x: w.rect.center.x, y: w.rect.center.y)
                let scale = CGFloat(w.rect.width) / holder.bounds.width
                holder.transform = CATransform3DMakeScale(scale, scale, 1)
                holder.opacity = 0
            }
            root.addSublayer(holder)
            layers[w.id] = layer
            holders[w.id] = holder
            let label = makeLabel(w.id, scale: screen.backingScaleFactor)
            if shelved.contains(w.id) {
                holder.zPosition = 7
                label.zPosition = 8
            }
            label.frame = labelFrame(away.contains(w.id) ? w.rect : r)
            label.opacity = 0
            root.addSublayer(label)
            labels[w.id] = label
        }
        styleRing()
        ring.removeAllAnimations()
        ring.isHidden = focus == nil
        if let focus, let frame = real[focus] { ring.frame = outset(NSRect(frame)) }
        dim.opacity = 0
        dock.opacity = 0
        searchBar.removeAllAnimations()
        CATransaction.commit()
        CATransaction.flush()

        // Also stops the fade out of a close still running.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            panel.animator().alphaValue = PictureMotion.coveringAlpha
        }

        relayout(animated: true, fromModel: true)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.25
        dim.add(fade, forKey: "dim")
        dim.opacity = 1
        for label in labels.values.map { $0 as CALayer } + [dock] + away.compactMap({ holders[$0] }) {
            label.add(fade, forKey: "fade")
            label.opacity = 1
        }
        return true
    }

    // MARK: Keys and selection

    func handle(_ key: OverviewCommand) {
        guard phase == .open, let layout else { return }
        if key == .cancel, cancelDragging() { return }
        if key == .cancel, selected == nil { chose(nil); return }
        guard let selected else { return }
        let next: String?
        switch key {
        case .left: next = move(layout, selected, .left)
        case .right: next = move(layout, selected, .right)
        case .up: next = move(layout, selected, .up)
        case .down: next = move(layout, selected, .down)
        case .next: next = overviewStep(layout, from: selected, by: 1, matching: matching)
        case .previous: next = overviewStep(layout, from: selected, by: -1, matching: matching)
        case .confirm: return chose(selected)
        case .cancel: return matching == nil ? chose(nil) : clearSearch()
        case .rename: return layout.window(selected).map { startRename($0.id, at: $0.rect) } ?? ()
        }
        if let next {
            select(next)
            home = next
        }
    }

    /// The window that way, or nil after handing the keys on at an edge.
    private func move(_ layout: OverviewLayout, _ from: String, _ d: Direction) -> String? {
        let next = overviewMove(layout, from: from, d, matching: matching)
        if next == nil { atEdge(d) }
        return next
    }

    /// Makes this overview the one the keys steer. Arriving moving `d`, the selection jumps to
    /// the window at the edge the keys came in by.
    func takeKeys(entering d: Direction? = nil) {
        panel.makeKey()
        ring.opacity = 1
        searchBar.opacity = 1
        searchField.alphaValue = 1
        // A click on the field already gave it the keys.
        if searchField.currentEditor() == nil, panel.makeFirstResponder(searchField) {
            // Taking the keys selects the whole query, so the next key would replace it, as when
            // the keys move to a display that matches the search.
            searchField.currentEditor()?.selectedRange = NSRange(location: (searchField.stringValue as NSString).length, length: 0)
        }
        if let d, phase == .open, let layout, let selected, let next = overviewEntry(layout, from: selected, d, matching: matching) {
            select(next)
            home = next
        }
    }

    /// The ring and search bar on a display the keys do not steer are faint, so the bright ones
    /// show where they act.
    static let idleRing: Float = 0.35
    static let idleSearch: Float = 0.55
    func releaseKeys() {
        ring.opacity = Self.idleRing
        searchBar.opacity = Self.idleSearch
        searchField.alphaValue = CGFloat(Self.idleSearch)
    }

    /// Fades the windows `query` does not match and selects the first that does. False when
    /// nothing on this display matches.
    func filter(_ query: String) -> Bool {
        guard phase == .open, let layout else { return false }
        matching = query.isEmpty ? nil : Set(titles.filter { OverviewKeys.matches($0.value, query: query) }.keys)
        showQuery(query)
        for (id, layer) in holders {
            let opacity: Float = matching?.contains(id) ?? true ? 1 : 0.25
            layer.opacity = opacity
            labels[id]?.opacity = opacity
        }
        guard let matching else { return true }
        guard let first = layout.windows.first(where: { matching.contains($0.id) })?.id else { return false }
        select(first, "search")
        home = first
        return true
    }

    /// Opens the name field over `id`'s label, taking the keys to this display.
    private func startRename(_ id: String, at rect: Rect) {
        wantsKeys()
        renaming = id
        renameField.stringValue = name(id) ?? windows.cachedTitle(of: id) ?? ""
        renameField.frame = labelFrame(rect)
        renameField.isHidden = false
        panel.makeFirstResponder(renameField)
        renameField.currentEditor()?.selectAll(nil)
    }

    /// Saves the typed name, where an empty one clears it, or drops it for nil.
    private func finishRename(_ text: String?) {
        guard let id = renaming else { return }
        renaming = nil
        renameField.isHidden = true
        panel.makeFirstResponder(searchField)
        guard let text, let label = labels[id] else { return }
        renamed(id, text.isEmpty ? nil : text)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.string = labelText(id)
        CATransaction.commit()
    }

    /// Puts the shared query in this display's field, unless it already holds it, so the caret stays put.
    private func showQuery(_ query: String) {
        if searchField.stringValue != query { searchField.stringValue = query }
    }

    private func select(_ id: String, _ why: String = "keys") {
        guard id != selected, let layout else { return }
        Log.note("overview", "\(screen?.localizedName ?? "?") selects \(Log.name(id)) (\(why))")
        selected = id
        pan = layout.pan(toReveal: id, current: pan)
        relayout(animated: true)
    }

    /// Redraws when `engine`'s strip changes while open, so a window that closes leaves.
    func changed(_ engine: StripEngine) {
        guard phase == .open, engine === self.engine else { return }
        real = overviewRealFrames(engine.workspaces, metrics, floats: floats).merging(fullScreen) { a, _ in a }
        relayout(animated: true)
    }

    private func dragged(_ p: CGPoint) {
        guard var d = drag, d.canDrag, let layer = holders[d.id] else { return }
        let pointer = Point(x: viewport.x + p.x, y: viewport.y + p.y)
        if !d.started {
            guard hypot(p.x - d.press.x, p.y - d.press.y) >= DropStyle().threshold else { return }
            d.started = true
            drag = d
            layer.zPosition = 15
            labels[d.id]?.opacity = 0
            ring.opacity = 0
            let shown = layer.presentation() ?? layer
            let position = shown.position, transform = shown.transform
            layer.removeAllAnimations()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.position = position
            layer.transform = transform
            CATransaction.commit()
            dragStarted(d.id, pointer, Point(x: d.grab.x, y: d.grab.y))
        } else { dragMoved(pointer) }
    }

    private func released(_ p: CGPoint) {
        if drag?.started == true { dragged(p) }
        guard let d = drag else { return }
        drag = nil
        if d.started { dragReleased() } else { chose(d.id) }
    }

    // MARK: Closing

    /// Zooms into `id`'s workspace, or back to the unchanged layout for nil. With `refocus`, nil
    /// gives focus back to the window that had it before.
    func close(selecting id: String?, refocus: Bool) {
        guard phase == .open, let engine else { return }
        drag = nil
        marker.isHidden = true
        phase = .closing
        token += 1
        let mine = token
        if let id, away.contains(id) {
            // macOS slides to the window's Space, so the overview gets out of the way at once.
            activate(id)
            searchField.isHidden = true
            finishRename(nil)
            finish(mine)
            return
        }
        var targets = real
        var ringTarget = (id ?? (refocus ? previous : home)).flatMap { real[$0] }
        if let id {
            activate(id)
            targets = overviewRealFrames(engine.workspaces, engine.metrics, floats: engine.floatFrames())
            ringTarget = targets[id] ?? real[id]
        } else if refocus, let previous {
            windows.focus(previous)
        }

        var longest: CFTimeInterval = 0
        CATransaction.begin()
        // A fullscreen window on another Space fades where it is, unless it was picked.
        let fading = away.subtracting([id].compactMap { $0 })
        for (wid, layer) in holders {
            guard !fading.contains(wid), let t = targets[wid] ?? real[wid] else { continue }
            longest = max(longest, move(layer, to: CGPoint(x: t.center.x, y: t.center.y),
                                        scale: CGFloat(t.width) / layer.bounds.width))
        }
        if let ringTarget { longest = max(longest, moveRing(to: outset(NSRect(ringTarget)))) }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = dim.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = longest
        dim.add(fade, forKey: "dim")
        dim.opacity = 0
        // Labels leave quickly so they do not trail the pictures zooming in.
        let out = CABasicAnimation(keyPath: "opacity")
        out.fromValue = 1
        out.toValue = 0
        out.duration = 0.15
        for label in labels.values.map { $0 as CALayer } + [dock] {
            label.add(out, forKey: "fade")
            label.opacity = 0
        }
        searchBar.add(out, forKey: "fade")
        searchBar.opacity = 0
        searchField.isHidden = true
        finishRename(nil)
        // Faded pictures come back as they zoom into place.
        for (wid, layer) in holders where !fading.contains(wid) { layer.opacity = 1 }
        for wid in fading {
            holders[wid]?.add(out, forKey: "fade")
            holders[wid]?.opacity = 0
        }
        CATransaction.commit()

        DispatchQueue.main.asyncAfter(deadline: .now() + longest) { [weak self] in
            MainActor.assumeIsolated { self?.finish(mine) }
        }
    }

    private func finish(_ mine: Int) {
        guard phase == .closing, mine == token else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.phase == .closing, self.token == mine else { return }
                self.panel.orderOut(nil)
                self.removeLayers()
                self.engine = nil
                self.layout = nil
                self.phase = .closed
            }
        })
    }

    // MARK: Drawing

    /// Puts every picture and the ring where the current layout says. Pictures are scaled by
    /// their layer's transform, so each stays in proportion.
    fileprivate func relayout(animated: Bool, fromModel: Bool = false) {
        guard let engine else { return }
        let size = Size(width: viewport.width, height: viewport.height)
        let next = overviewLayout(preview ?? engine.workspaces, metrics, screen: size, pan: pan, style: style, floats: floats,
                                  fullScreen: fullScreen, rows: dragRows)
        layout = next
        CATransaction.begin()
        if !animated { CATransaction.setDisableActions(true) }
        // A window that closed while the overview is open loses its picture.
        for id in Set(layers.keys).subtracting(next.windows.map(\.id)).subtracting([previewID].compactMap { $0 }) {
            layers.removeValue(forKey: id)
            holders.removeValue(forKey: id)?.removeFromSuperlayer()
            labels.removeValue(forKey: id)?.removeFromSuperlayer()
        }
        if let s = selected, next.window(s) == nil { selected = home.flatMap { next.window($0) != nil ? $0 : nil } ?? next.windows.first?.id }
        if let h = home, next.window(h) == nil { home = selected }
        for w in next.windows {
            if previewID == w.id { continue }
            guard let layer = holders[w.id] else { continue }
            let centre = CGPoint(x: w.rect.center.x, y: w.rect.center.y)
            let scale = CGFloat(w.rect.width) / layer.bounds.width
            if animated { _ = move(layer, to: centre, scale: scale, fromModel: fromModel) } else {
                layer.removeAllAnimations()
                layer.position = centre
                layer.transform = CATransform3DMakeScale(scale, scale, 1)
            }
            if let label = labels[w.id] {
                let target = labelFrame(w.rect)
                let from = fromModel ? label.position : (label.presentation()?.position ?? label.position)
                label.removeAnimation(forKey: "move")
                label.frame = target
                if animated {
                    label.add(spring("position", NSValue(point: from), NSValue(point: label.position)), forKey: "move")
                }
            }
        }
        if let shelf = next.rows.first(where: { $0.workspace == -1 }) {
            dock.isHidden = false
            dock.frame = NSRect(shelf.rect)
        } else {
            dock.isHidden = true
        }
        ring.isHidden = selected == nil
        if let selected, let w = next.window(selected) {
            let target = outset(NSRect(w.rect))
            if animated { _ = moveRing(to: target, fromModel: fromModel) } else {
                ring.removeAllAnimations()
                ring.frame = target
            }
        }
        CATransaction.commit()
    }

    /// Sets the layer's final state and springs it there from where it is on screen.
    private func move(_ layer: CALayer, to centre: CGPoint, scale: CGFloat, fromModel: Bool = false) -> CFTimeInterval {
        let from = fromModel ? nil : layer.presentation()
        let fromPosition = from?.position ?? layer.position
        // Read the scale from the matrix. A key-value read of "transform.scale" can fail to cast,
        // and falling back to 1 made every picture jump to full size before shrinking back.
        let fromScale = (from ?? layer).transform.m11
        layer.removeAllAnimations()
        layer.position = centre
        layer.transform = CATransform3DMakeScale(scale, scale, 1)
        let position = spring("position", NSValue(point: fromPosition), NSValue(point: centre))
        let zoom = spring("transform.scale", NSNumber(value: Double(fromScale)), NSNumber(value: Double(scale)))
        let group = CAAnimationGroup()
        group.animations = [position, zoom]
        group.duration = max(position.duration, zoom.duration)
        layer.add(group, forKey: "move")
        return group.duration
    }

    private func moveRing(to target: NSRect, fromModel: Bool = false) -> CFTimeInterval {
        let from = fromModel ? ring.frame : (ring.presentation()?.frame ?? ring.frame)
        ring.removeAllAnimations()
        ring.frame = target
        let position = spring("position", NSValue(point: NSPoint(x: from.midX, y: from.midY)),
                              NSValue(point: NSPoint(x: target.midX, y: target.midY)))
        let size = spring("bounds.size", NSValue(size: from.size), NSValue(size: target.size))
        let group = CAAnimationGroup()
        group.animations = [position, size]
        group.duration = max(position.duration, size.duration)
        ring.add(group, forKey: "move")
        return group.duration
    }

    private func spring(_ key: String, _ from: Any, _ to: Any) -> CASpringAnimation {
        Spring.critical(key, from: from, to: to, stiffness: stiffness)
    }

    private func pictureArrived(_ id: String) {
        if id == ScreenCaptureSnapshots.wallpaperID {
            if phase != .closed { refreshBackdrop() }
            return
        }
        guard phase != .closed, !pictures.coverMode, let layer = layers[id] else { return }
        // The first new picture fades in over the old one rather than jumping. Later ones swap
        // at once: a fade on every refresh blends large pictures all the time and stutters.
        if faded.insert(id).inserted {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.2
            layer.add(fade, forKey: "picture")
        }
        layer.setPicture(snapshots.surface(of: id))
    }

    private func styleRing() {
        let color = ringStyle.color.cgColor
        marker.backgroundColor = ringStyle.color.withAlphaComponent(0.12).cgColor
        marker.borderColor = color
        marker.borderWidth = 2
        marker.cornerRadius = 10
        ring.borderWidth = ringStyle.borderWidth
        ring.borderColor = color
        ring.cornerRadius = ringStyle.cornerRadius / 2 + ringStyle.borderWidth / 2
        ring.shadowColor = color
        ring.shadowOpacity = ringStyle.glowRadius > 0 ? 0.9 : 0
        ring.shadowRadius = ringStyle.glowRadius
        ring.shadowOffset = .zero
        searchBar.borderColor = ringStyle.color.withAlphaComponent(0.85).cgColor
    }

    private func removeLayers() {
        for (_, layer) in holders { layer.removeFromSuperlayer() }
        for (_, label) in labels { label.removeFromSuperlayer() }
        layers = [:]
        holders = [:]
        labels = [:]
        titles = [:]
    }

    /// "App — Title", "Name (App)" for a named window, or just the app when there is neither.
    /// Also sets the text the search matches, which keeps a named window's title.
    private func labelText(_ id: String) -> String {
        let app = windows.pid(of: id).flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
        let title = windows.cachedTitle(of: id).flatMap { $0.isEmpty ? nil : $0 }
        let given = name(id)
        let text = given.map { g in app.map { "\(g) (\($0))" } ?? g }
            ?? [app, title].compactMap { $0 }.joined(separator: " — ")
        titles[id] = given == nil ? text : [text, title].compactMap { $0 }.joined(separator: " — ")
        return text
    }

    /// A pill with the window's label text.
    private func makeLabel(_ id: String, scale: CGFloat) -> CATextLayer {
        let label = CATextLayer()
        label.string = labelText(id)
        label.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        label.fontSize = 16
        label.foregroundColor = NSColor.white.cgColor
        label.alignmentMode = .center
        label.truncationMode = .end
        label.contentsScale = scale
        // The pill keeps it readable where it lies over the top of a stacked window below.
        label.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
        label.cornerRadius = 6
        label.zPosition = 5
        return label
    }

    /// Just under the picture, centred on it, at least wide enough for a short name.
    private func labelFrame(_ r: Rect) -> NSRect {
        let w = max(100, r.width)
        return NSRect(x: r.center.x - w / 2, y: r.maxY + 4, width: w, height: 26)
    }

    private func outset(_ r: NSRect) -> NSRect { r.insetBy(dx: -ringStyle.borderWidth, dy: -ringStyle.borderWidth) }

    /// Shows the captured desktop, which is what is really on screen, or the desktop picture's
    /// file when there is no capture, so the backdrop is ready on the first frame.
    private func refreshBackdrop() {
        // The captured desktop is what is really on screen; the picture's file can differ.
        guard let screen else { return }
        if let id = Screens.displayID(of: screen), let captured = snapshots.wallpaper(of: id) {
            backdrop.contents = captured
            return
        }
        if let url = NSWorkspace.shared.desktopImageURL(for: screen), let image = NSImage(contentsOf: url),
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            backdrop.contents = cg
        }
    }

    /// Covers the display's usable area; the viewport is in Accessibility coordinates.
    private func place() {
        let frame = Screens.appKitRect(viewport)
        panel.setFrame(frame, display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = NSRect(origin: .zero, size: frame.size)
        dim.frame = root.bounds
        let w = min(560, frame.width - 2 * Self.style.margin)
        searchBar.frame = NSRect(x: (frame.width - w) / 2, y: 20, width: w, height: 46)
        searchIcon.frame = NSRect(x: 18, y: 13, width: 20, height: 20)
        searchField.frame = NSRect(x: searchBar.frame.minX + 48, y: searchBar.frame.minY + 10, width: w - 66, height: 26)
        if let screen {
            let whole = Screens.axRect(screen.frame)
            backdrop.frame = NSRect(x: whole.x - viewport.x, y: whole.y - viewport.y, width: whole.width, height: whole.height)
        } else {
            backdrop.frame = root.bounds
        }
        CATransaction.commit()
    }
}

/// The overview on every display at once. Keys steer the active display's overview; a click on
/// any display picks that window, and every overview closes.
@MainActor
final class Overviews {
    var activate: (String) -> Void = { _ in }
    var name: (String) -> String? = { _ in nil }
    var renamed: (String, String?) -> Void = { _, _ in }
    var ringStyle = FocusHighlight.Style()
    var floating = OverviewFloating.vertical
    var keys = OverviewKeys()
    /// Fullscreen windows and their frames, which the shelf shows on their display.
    var fullScreen: () -> [String: Rect] = { [:] }

    private let pictures: WindowPictures
    private let windows: AXWindows
    private let hud: SizeHUD
    private var byDisplay: [String: Overview] = [:]
    private var active: Overview?
    private var displays: StripDisplays?
    /// The search bar's text, shared by every display.
    private var query = ""
    /// True while waiting for new pictures before opening.
    private var waiting = false
    private final class DragState {
        let source: Overview
        let id: String
        var width: Double
        let originalBounds: CGRect
        var carrier: Overview
        var candidate: (Overview, OverviewDrop)?
        var serial = 0
        var centre: Point
        var pointer: Point
        var grab: Point
        var workspaces: [ObjectIdentifier: Workspaces] = [:]
        init(source: Overview, id: String, width: Double, pointer: Point, grab: Point, bounds: CGRect) {
            self.source = source; self.id = id; self.width = width; self.carrier = source
            self.pointer = pointer; self.grab = grab; self.centre = pointer; self.originalBounds = bounds
        }
    }
    private var dragging: DragState?
    private var committing = false

    var isOpen: Bool { byDisplay.values.contains { $0.isOpen } }

    init(pictures: WindowPictures, windows: AXWindows, hud: SizeHUD) {
        self.pictures = pictures
        self.windows = windows
        self.hud = hud
    }

    /// Opens on every display, or closes onto the active display's highlighted window.
    func toggle(_ engine: StripEngine, displays: StripDisplays) {
        // Overviews still zooming closed open again.
        if byDisplay.values.contains(where: \.isShowing) {
            active?.handle(.confirm)
            return
        }
        guard !waiting else { return }
        // Pictures of on-screen windows open right over the windows, so an old one would show
        // and then jump. Wait briefly for new ones first.
        var onScreen: Set<String> = []
        if !pictures.coverMode {
            for e in displays.engines.values {
                let v = Rect(x: 0, y: 0, width: e.viewport.width, height: e.viewport.height)
                for (id, r) in overviewRealFrames(e.workspaces, e.metrics, floats: e.floatFrames())
                where r.overlap(v) != nil { onScreen.insert(id) }
            }
        }
        waiting = true
        pictures.snapshots.freshen(onScreen) { [weak self] in
            guard let self else { return }
            waiting = false
            show(engine, displays: displays)
        }
    }

    private func show(_ engine: StripEngine, displays: StripDisplays) {
        let start = CACurrentMediaTime()
        self.displays = displays
        query = ""
        byDisplay = byDisplay.filter { displays.engines[$0.key] != nil }
        active = nil
        let full = fullScreen()
        var opened: [Overview] = []
        // The active display goes first. When it has no windows, the next one to open takes the keys.
        for (id, e) in displays.engines.sorted(by: { $0.value === engine && $1.value !== engine }) {
            let o = byDisplay[id] ?? make(id)
            o.activate = activate
            o.name = name
            o.ringStyle = ringStyle
            o.floating = floating
            o.keys = keys
            let here = full.filter { displays.engine(owning: $0.value) === e }
            guard o.open(e, on: Screens.screen(id: id), active: false, fullScreen: here) else { continue }
            if active == nil, !o.ids.isEmpty { active = o }
            opened.append(o)
        }
        guard !opened.isEmpty else { return }
        if active == nil { active = opened.first }
        active?.takeKeys()
        Log.note("overview", "opened on \(opened.count) displays in \(Int((CACurrentMediaTime() - start) * 1000)) ms")
        pictures.snapshots.beginLive(opened.reduce(into: Set()) { $0.formUnion($1.ids) }, rate: opened[0].rate)
    }

    func handle(_ command: OverviewCommand) {
        if command == .cancel, dragging != nil { cancelDrag(); return }
        active?.handle(command)
    }

    func changed(_ engine: StripEngine) {
        if let dragging, !committing {
            guard let before = dragging.workspaces[ObjectIdentifier(engine)], before != engine.workspaces else { return }
            cancelDrag()
        }
        for o in byDisplay.values { o.changed(engine) }
    }

    private func make(_ id: String) -> Overview {
        let o = Overview(pictures: pictures, windows: windows)
        o.dragStarted = { [unowned self, unowned o] id, pointer, grab in startDrag(o, id, pointer, grab) }
        o.dragMoved = { [unowned self] pointer in moveDrag(pointer) }
        o.dragReleased = { [unowned self] in dropDrag() }
        o.dragRightClick = { [unowned self] in cycleDragWidth() }
        o.cancelDragging = { [unowned self] in
            guard dragging != nil else { return false }
            cancelDrag()
            return true
        }
        o.chose = { [unowned self, unowned o] window in chose(window, on: o) }
        o.atEdge = { [unowned self, unowned o] d in cross(d, from: o) }
        o.typed = { [unowned self] text in
            query = text
            search()
        }
        o.wantsKeys = { [unowned self, unowned o] in
            // While opening, before `active` is set, the field taking the keys is no click.
            guard let active, o !== active, o.isShowing else { return }
            Log.note("overview", "keys move to the clicked search bar")
            active.releaseKeys()
            self.active = o
            o.takeKeys()
        }
        o.renamed = { [unowned self] id, name in
            renamed(id, name)
            search()
        }
        o.clearSearch = { [unowned self] in
            query = ""
            search()
        }
        byDisplay[id] = o
        return o
    }

    private func startDrag(_ source: Overview, _ id: String, _ pointer: Point, _ grab: Point) {
        guard let engine = source.engine, let holder = source.holders[id], let w = engine.workspaces.workspace(of: id),
              let c = engine.workspaces.strips[w].column(of: id) else { return }
        let state = DragState(source: source, id: id, width: engine.workspaces.strips[w].columns[c].width, pointer: pointer, grab: grab, bounds: holder.bounds)
        dragging = state
        for o in byDisplay.values where o.isShowing {
            guard let engine = o.engine, let layout = o.layout else { continue }
            let ws = engine.workspaces
            state.workspaces[ObjectIdentifier(engine)] = ws
            o.dragRows = Array(Set(layout.rows.filter { $0.workspace >= 0 }.map(\.workspace) + [0, ws.strips.count - 1])).sorted()
            o.previewID = id
            o.relayout(animated: true)
        }
        moveDrag(pointer)
        fitDragScale(state)
    }

    private func fitDragScale(_ state: DragState) {
        guard let holder = state.source.holders[state.id], let layout = state.carrier.layout else { return }
        let scale = (layout.window(state.id).map { $0.rect.width / holder.bounds.width } ?? layout.scale) * 0.85
        let centre = Point(x: state.pointer.x - state.grab.x * scale, y: state.pointer.y - state.grab.y * scale)
        guard abs(holder.transform.m11 - scale) > 0.0001 || abs(state.centre.x - centre.x) > 0.01 || abs(state.centre.y - centre.y) > 0.01 else { return }
        let from = holder.presentation()?.transform.m11 ?? holder.transform.m11
        let fromPosition = holder.presentation()?.position ?? holder.position
        state.centre = centre
        let position = CGPoint(x: state.centre.x - state.carrier.viewport.x, y: state.centre.y - state.carrier.viewport.y)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        holder.transform = CATransform3DMakeScale(scale, scale, 1)
        holder.position = position
        CATransaction.commit()
        holder.add(Spring.critical("transform.scale", from: NSNumber(value: Double(from)),
                                   to: NSNumber(value: Double(scale)), stiffness: state.carrier.stiffness), forKey: "dragScale")
        holder.add(Spring.critical("position", from: NSValue(point: fromPosition), to: NSValue(point: position),
                                   stiffness: state.carrier.stiffness), forKey: "dragPosition")
    }

    private func moveDrag(_ pointer: Point) {
        guard let state = dragging, let holder = state.source.holders[state.id] else { return }
        state.pointer = pointer
        let target = byDisplay.values.first { $0.isShowing && $0.viewport.contains(pointer) }
        let carrier = target ?? state.source
        let changedCarrier = carrier !== state.carrier
        if changedCarrier {
            hud.hide()
            holder.removeFromSuperlayer()
            carrier.root.addSublayer(holder)
            state.carrier = carrier
        }
        let scale = holder.transform.m11
        state.centre = Point(x: pointer.x - state.grab.x * scale, y: pointer.y - state.grab.y * scale)
        holder.removeAnimation(forKey: "dragPosition")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        holder.position = CGPoint(x: state.centre.x - carrier.viewport.x, y: state.centre.y - carrier.viewport.y)
        CATransaction.commit()
        if changedCarrier { fitDragScale(state) }
        let drop: OverviewDrop? = target.flatMap { o in
            guard let layout = o.layout, let base = o.engine?.workspaces else { return nil }
            return overviewDrop(layout, shownWS: o.preview ?? base, base: base,
                                at: Point(x: pointer.x - o.viewport.x, y: pointer.y - o.viewport.y), dragging: state.id)
        }
        let changed = state.candidate?.0 !== target || state.candidate?.1.workspace != drop?.workspace || state.candidate?.1.target != drop?.target
        guard changed else { return }
        state.candidate = target.flatMap { o in drop.map { (o, $0) } }
        state.serial += 1
        let serial = state.serial
        if state.candidate == nil { showPreview(state, target: nil); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak state] in
            guard let self, let state, self.dragging === state, state.serial == serial else { return }
            self.showPreview(state, target: state.candidate)
        }
    }

    private func showPreview(_ state: DragState, target: (Overview, OverviewDrop)?) {
        for o in byDisplay.values where o.isShowing {
            guard let base = o.engine?.workspaces else { continue }
            if let target, o === target.0 {
                o.preview = overviewPreview(base, moving: state.id, to: (target.1.workspace, target.1.target), width: state.width, columnID: "overview-preview")
            } else if target != nil && o === state.source {
                o.preview = overviewPreview(base, moving: state.id, to: nil, width: state.width, columnID: "overview-preview")
            } else { o.preview = nil }
            o.marker.isHidden = true
            o.relayout(animated: true)
            if let target, o === target.0, let rect = o.layout?.window(state.id)?.rect {
                o.marker.frame = NSRect(rect)
                o.marker.isHidden = false
            }
        }
        fitDragScale(state)
    }

    private func cycleDragWidth() -> Bool {
        guard let state = dragging else { return false }
        guard let engine = state.carrier.engine ?? state.source.engine,
              let width = nextWidthPreset(after: state.width, engine.settings.widthPresets),
              let holder = state.source.holders[state.id] else { return true }
        let oldWidth = holder.bounds.width
        let newWidth = engine.metrics.columnWidth(width)
        state.width = width
        state.grab.x *= newWidth / oldWidth
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        holder.bounds.size.width = newWidth
        state.source.layers[state.id]?.frame = holder.bounds
        holder.shadowPath = CGPath(roundedRect: holder.bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
        CATransaction.commit()
        state.serial += 1
        showPreview(state, target: state.candidate)
        hud.show(share: width, pixels: CGSize(width: newWidth, height: holder.bounds.height), on: state.carrier.viewport)
        return true
    }

    private func clearPreview(_ state: DragState) {
        hud.hide()
        for o in byDisplay.values where o.isShowing {
            o.preview = nil
            o.dragRows = nil
            o.previewID = nil
            o.marker.isHidden = true
        }
    }

    private func cancelDrag() {
        guard let state = dragging, let holder = state.source.holders[state.id] else { return }
        dragging = nil
        state.source.drag = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        holder.bounds = state.originalBounds
        state.source.layers[state.id]?.frame = holder.bounds
        holder.shadowPath = CGPath(roundedRect: holder.bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
        CATransaction.commit()
        holder.removeFromSuperlayer()
        state.source.root.addSublayer(holder)
        holder.position = CGPoint(x: state.centre.x - state.source.viewport.x, y: state.centre.y - state.source.viewport.y)
        holder.zPosition = 0
        state.source.labels[state.id]?.opacity = 1
        state.source.ring.opacity = state.source === active ? 1 : Overview.idleRing
        clearPreview(state)
        for o in byDisplay.values where o.isShowing { o.relayout(animated: true) }
    }

    private func dropDrag() {
        guard let state = dragging else { return }
        guard let (target, drop) = state.candidate, let sourceEngine = state.source.engine, let targetEngine = target.engine else { cancelDrag(); return }
        dragging = nil
        committing = true
        if target !== state.source {
            target.holders[state.id] = state.source.holders.removeValue(forKey: state.id)
            target.layers[state.id] = state.source.layers.removeValue(forKey: state.id)
            if let label = state.source.labels.removeValue(forKey: state.id) {
                label.removeFromSuperlayer(); target.root.addSublayer(label); target.labels[state.id] = label
            }
            target.titles[state.id] = state.source.titles.removeValue(forKey: state.id)
        }
        clearPreview(state)
        target.previewID = state.id
        if target !== state.source { sourceEngine.handOver(state.id) }
        targetEngine.moveWindow(state.id, toWorkspace: drop.workspace, at: drop.target, width: state.width)
        target.previewID = nil
        target.holders[state.id]?.zPosition = 0
        target.labels[state.id]?.opacity = 1
        target.selected = state.id
        target.home = state.id
        target.ring.isHidden = false
        target.ring.opacity = target === active ? 1 : Overview.idleRing
        state.source.ring.opacity = state.source === active ? 1 : Overview.idleRing
        committing = false
        for o in byDisplay.values where o.isShowing { o.relayout(animated: true) }
    }

    /// At an edge, the keys move on to the display lying that way, if its overview is showing.
    private func cross(_ d: Direction, from o: Overview) {
        guard o === active, let id = displays?.display(toward: d, from: o.engine),
              let target = byDisplay[id], target.isShowing, target.hasMatches else { return }
        Log.note("overview", "keys move \(d) to \(id.prefix(8))")
        o.releaseKeys()
        active = target
        target.takeKeys(entering: d)
    }

    /// Filters every display. When the keys' display has no match, they move to one that does.
    private func search() {
        let found = byDisplay.values.filter { $0.isShowing }.filter { $0.filter(query) }
        guard let active, !found.contains(where: { $0 === active }), let target = found.first else { return }
        Log.note("overview", "keys move to a display matching the search")
        active.releaseKeys()
        self.active = target
        target.takeKeys()
    }

    private func chose(_ window: String?, on picked: Overview) {
        guard picked.isShowing else { return }
        hud.hide()
        if dragging != nil { cancelDrag() }
        // Only the picked display moves focus; the rest zoom back unchanged.
        picked.close(selecting: window, refocus: true)
        for o in byDisplay.values where o !== picked && o.isShowing { o.close(selecting: nil, refocus: false) }
        pictures.snapshots.endLive(after: 1.0)
    }
}
