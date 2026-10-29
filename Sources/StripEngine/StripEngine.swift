import StripModel
import WindowCore

public struct StripSettings: Codable, Equatable, Sendable {
    public var gap: Double = 8
    /// New windows take a third of the screen, so three fit side by side.
    public var defaultWidth: Double = 0.333
    public var widthPresets: [Double] = [0.333, 0.5, 0.667]
    public var nudge: Double = 0.1
    public var scrollMode: ScrollMode = .fit
    /// Whether a column that would reach another display hides behind a card instead of narrowing.
    public var peekCovers = false
    public init() {}
}

/// Owns one display's strip and keeps the real windows in step with it.
@MainActor
public final class StripEngine {
    public private(set) var workspaces = Workspaces()
    /// The active workspace's strip.
    public var strip: Strip { workspaces.current }
    public var settings: StripSettings { didSet { apply() } }
    public var viewport: Rect { didSet { if !suspendApply { apply() } } }
    /// The full frames of the other displays, which no window may reach.
    public var neighbours: [Rect] = [] { didSet { if !suspendApply { apply() } } }
    /// Names this engine's display in the log.
    public var label = ""
    /// Called after every change, for UI such as the menu-bar minimap.
    public var observers: [(StripEngine) -> Void] = []
    /// Whether the last change moved any window, so UI that follows motion can skip a focus-only change.
    public private(set) var moved = false
    /// With `peekCovers`, where a card stands in for each hidden window's part on screen.
    public private(set) var peeks: [String: Rect] = [:]
    /// The width a new window takes when its app had a column before; nil means the default.
    public var rememberedWidth: (String) -> Double? = { _ in nil }
    /// The width each window took when its column asked for another, with the width asked.
    /// Its column takes that width until its share or the screen changes.
    private var refusals: [String: (asked: Double, took: Double)] = [:]
    /// Set by a command that moves the focused window, so its picture lifts while it travels.
    private var liftNext = false
    /// Each window's place on the strip as last laid out, past the screen's edges too.
    private var stripPlaces: [String: Rect] = [:]
    /// Where the workspace a window is carried to showed its windows before it arrived.
    private var arrivalPlaces: [String: Rect] = [:]
    /// The frame on another display a window arriving from it had, so it flies in from there.
    private var arrivalFrame: Rect?
    /// A window leaving for another display, whose picture flies off toward it.
    private var departing: (id: String, from: Rect, to: Rect)?

    private let windows: WindowSystem
    /// The frame each window should have now: the layout's target, set before it is written, so a
    /// write under a motion can still be pending. Not what the window last reported.
    private var targetFrames: [String: Rect] = [:]
    /// Draws motion with window pictures. Without one, windows move at once.
    public weak var presenter: StripPresenter?
    /// Runs the delayed window writes. Without one, writes happen at once.
    public var clock: Clock?
    private var shownWorkspace = 0
    /// Windows now waiting out of sight for their workspace.
    private var parked: Set<String> = []
    /// Where each parked floating window was on screen, so it returns there with its own size.
    private var floatHomes: [String: Rect] = [:]
    /// Where each window behind a peek card sits on the strip. Its picture moves from and to
    /// there, by the card, not from where the hidden window really is, and the card shows the
    /// part of its picture that would be on screen there.
    public private(set) var peekStrip: [String: Rect] = [:]
    /// Hidden windows a neighbouring display pushed past the far edge, with their real frame and
    /// the frame on the near edge their picture moves from and to, so it slides with the strip.
    private var slideFrames: [String: (real: Rect, slide: Rect)] = [:]
    private var nextID = 0

    public init(windows: WindowSystem, viewport: Rect, settings: StripSettings = StripSettings()) {
        self.windows = windows
        self.viewport = viewport
        self.settings = settings
    }

    /// The frame a window on the active strip should have: the layout's target, which a motion
    /// may not have written yet. Nil for a window not on the active strip.
    public func frame(of id: String) -> Rect? {
        strip.column(of: id) != nil ? targetFrames[id] : nil
    }

    /// Whether a window on the active strip is narrowed to the part of its column on screen,
    /// as beside another display. Its width then says nothing about what its app accepts.
    public func isTrimmed(_ id: String) -> Bool {
        guard let target = frame(of: id), let full = stripFrames(strip, metrics, clamp: false)[id] else { return false }
        return target.width < full.width - 0.5
    }

    /// Every floating window's frame relative to the viewport's top-left: where it is now on the
    /// active workspace, and where it will return to on the others.
    public func floatFrames() -> [String: Rect] {
        var out: [String: Rect] = [:]
        for (i, s) in workspaces.strips.enumerated() {
            for id in s.floating {
                // A frame just written wins, since the window may not have reported it yet.
                let r = i == workspaces.active ? (targetFrames[id] ?? windows.frameOf(id)) : floatHomes[id]
                guard let r else { continue }
                out[id] = Rect(x: r.x - viewport.x, y: r.y - viewport.y, width: r.width, height: r.height)
            }
        }
        return out
    }

    /// Whether focus sits at the strip's end in `direction`, or the strip is empty.
    public func atStripEdge(_ direction: Direction) -> Bool {
        guard let f = strip.focusedColumn else { return true }
        switch direction {
        case .left: return f == 0
        case .right: return f == strip.columns.count - 1
        case .up, .down: return false
        }
    }

    /// Built afresh on each read from every window on every workspace, so an operation that
    /// needs it more than once reads it into a local first.
    public var metrics: StripMetrics { metrics(of: workspaces) }

    /// Metrics for a layout not applied yet, so a column it resizes asks its new width again.
    private func metrics(of workspaces: Workspaces) -> StripMetrics {
        var m = StripMetrics(viewport: viewport, gap: settings.gap)
        for strip in workspaces.strips {
            for column in strip.columns {
                let share = m.columnWidth(column.width)
                for id in column.windows {
                    guard let r = refusals[id], abs(r.asked - share) < 0.5 else { continue }
                    if r.took > r.asked { m.minimums[id] = r.took } else { m.maximums[id] = r.took }
                }
            }
        }
        return m
    }
    public var hideaway: Hideaway { Hideaway(screen: viewport, others: neighbours) }

    /// Moves to another screen area in one pass, so windows are written once.
    public func setGeometry(viewport: Rect, neighbours: [Rect]) {
        guard viewport != self.viewport || neighbours != self.neighbours else { return }
        suspendApply = true
        self.viewport = viewport
        self.neighbours = neighbours
        suspendApply = false
        apply()
    }
    private var suspendApply = false

    /// Writes every window's frame again, even where the engine believes it already is. macOS
    /// moves windows itself, as when a display changes resolution, and those moves would stay.
    public func retile() {
        Log.note("engine", "\(label) retiles every window")
        forceWrite = true
        apply()
        forceWrite = false
    }
    private var forceWrite = false

    // MARK: Window lifecycle

    /// Adds a new window right of the focused column. With `takesFocus`, it becomes the strip's
    /// focused window when it already has system focus or the strip has no focused column, so a
    /// background app opening a window does not steal the screen. `takesFocus` also lets the
    /// change raise the strip's focused window.
    ///
    /// A floating window is recorded without a column. With `takesFocus` false the window joins
    /// quietly: focus and scroll stay as they were.
    /// `workspace` puts the window on that numbered workspace, counted from 1 at the top, without
    /// switching to it.
    public func windowAdded(_ id: String, floating: Bool = false, takesFocus: Bool = true, workspace: Int? = nil) {
        Log.note("engine", "\(label) windowAdded \(Log.name(id)) floating=\(floating) takesFocus=\(takesFocus)"
            + (workspace.map { " workspace=\($0)" } ?? ""))
        guard workspaces.workspace(of: id) == nil else {
            return Log.note("anomaly", "\(label) windowAdded: \(Log.name(id)) is already in workspace \(workspaces.workspace(of: id)!)")
        }
        if let workspace, workspaces.index(ofWorkspace: workspace) != workspaces.active {
            let width = rememberedWidth(id) ?? settings.defaultWidth
            changeWorkspaces(raise: false) { $0.add(id, toWorkspace: workspace, width: width, columnID: newColumnID(), floating: floating) }
            return
        }
        if floating {
            change(raise: false) { $0.addFloating(id) }
            return
        }
        let focus = takesFocus && (windows.focusedWindow == id || strip.focusedColumn == nil)
        change(raise: takesFocus) { $0.insert(id, width: rememberedWidth(id) ?? settings.defaultWidth, columnID: newColumnID(), focus: focus) }
    }

    /// Takes a tiled window off the strip, wherever it sits, without moving focus.
    public func floatWindow(_ id: String) {
        Log.note("engine", "\(label) floatWindow \(Log.name(id))")
        guard let w = workspaces.workspace(of: id), workspaces.strips[w].column(of: id) != nil else { return }
        changeWorkspaces(raise: false) { $0.strips[w].floatOut(id) }
    }

    /// `refocus` false leaves focus where it is, as for a window that went fullscreen and keeps it.
    public func windowRemoved(_ id: String, refocus: Bool = true) {
        Log.note("engine", "\(label) windowRemoved \(Log.name(id))")
        targetFrames[id] = nil
        parked.remove(id)
        floatHomes[id] = nil
        // A drop must not bring the window back.
        if dragView?.id == id {
            dragView?.target = nil
            dragView?.leaving = false
        }
        changeWorkspaces(raise: refocus) { $0.remove(id) }
    }

    /// Gives `new` the place of `old`, which leaves, as when an app shows another tab of the same
    /// window. The column keeps its width, and focus stays where it was. When `new` already has a
    /// place of its own, as a tab the app showed before hiding the old one, it leaves that place.
    public func windowReplaced(_ old: String, by new: String) {
        Log.note("engine", "\(label) windowReplaced \(Log.name(old)) by \(Log.name(new))")
        guard workspaces.workspace(of: old) != nil else { return }
        targetFrames[old] = nil
        parked.remove(old)
        floatHomes[old] = nil
        changeWorkspaces(raise: false) {
            $0.remove(new)
            if let w = $0.workspace(of: old) { $0.strips[w].replace(old, with: new) }
        }
    }

    // MARK: Windows that hide for a while

    /// Where a window sits, so it can come back there after its app hid it, as Steam does.
    public struct Slot: Equatable, Sendable {
        public var workspace: Int
        /// The column index, or nil for a floating window.
        public var column: Int?
        public var width: Double
    }

    public func slot(of id: String) -> Slot? {
        guard let w = workspaces.workspace(of: id) else { return nil }
        let s = workspaces.strips[w]
        guard let c = s.column(of: id) else { return Slot(workspace: w, column: nil, width: settings.defaultWidth) }
        return Slot(workspace: w, column: c, width: s.columns[c].width)
    }

    /// Puts a window back at its old slot without moving focus.
    public func restore(_ id: String, to slot: Slot) {
        Log.note("engine", "\(label) restore \(Log.name(id)) to \(slot)")
        guard workspaces.workspace(of: id) == nil else { return }
        let w = min(slot.workspace, workspaces.strips.count - 1)
        let columnID = newColumnID()
        changeWorkspaces(raise: false) {
            if let c = slot.column { $0.strips[w].insert(id, width: slot.width, columnID: columnID, at: c) }
            else { $0.strips[w].addFloating(id) }
        }
    }

    // MARK: Moving between displays

    /// A window arriving from another display becomes a column right of the focused one.
    /// With `from`, its frame there, it lifts and flies in from it.
    public func adopt(_ id: String, width: Double, focus: Bool, from: Rect? = nil) {
        Log.note("engine", "\(label) adopt \(Log.name(id)) width=\(width) focus=\(focus)")
        guard workspaces.workspace(of: id) == nil else { return }
        if let from, focus { liftNext = true; arrivalFrame = from }
        change { $0.insert(id, width: width, columnID: newColumnID(), focus: focus) }
        arrivalFrame = nil
    }

    /// Takes the focused window off this strip so another display can adopt it. The window keeps
    /// system focus: focusing a window left behind would arrive after the move and pull focus back.
    /// With `toward`, the other display's frame, its picture lifts and flies off that way.
    public func takeFocused(toward: Rect? = nil) -> (id: String, width: Double, frame: Rect?)? {
        guard let f = strip.focusedColumn, let id = strip.focusedWindow else { return nil }
        let width = strip.columns[f].width
        let frame = frame(of: id)
        if let toward, let frame {
            let dx = toward.x + toward.width / 2 - (viewport.x + viewport.width / 2)
            let dy = toward.y + toward.height / 2 - (viewport.y + viewport.height / 2)
            departing = (id, frame, Rect(x: frame.x + dx, y: frame.y + dy, width: frame.width, height: frame.height))
        }
        windowRemoved(id, refocus: false)
        departing = nil
        return (id, width, frame)
    }

    /// Gives the focused window system focus, as when the user switches to this display.
    public func activate() {
        guard let id = strip.focusedWindow else { return }
        windows.focus(id)
    }

    public struct Released { public var id: String; public var width: Double; public var floating: Bool }

    /// Empties the engine and returns what it held, in strip order. The windows are not moved.
    public func releaseAll() -> [Released] {
        Log.note("engine", "\(label) releaseAll\n" + workspaces.summary)
        var out: [Released] = []
        for s in workspaces.strips {
            for c in s.columns {
                for id in c.windows { out.append(Released(id: id, width: c.width, floating: false)) }
            }
            for id in s.floating { out.append(Released(id: id, width: settings.defaultWidth, floating: true)) }
        }
        workspaces = Workspaces()
        targetFrames = [:]
        parked = []
        shownWorkspace = 0
        return out
    }

    /// Puts a rebuilt layout in place in one write, without motion. Does nothing once the engine holds windows.
    ///
    /// The window that has system focus keeps it: its workspace and column become the focused ones.
    public func restore(_ restored: Workspaces) {
        guard workspaces.strips.allSatisfy(\.isEmpty) else {
            return Log.note("anomaly", "\(label) restore skipped: the engine already holds windows\n" + workspaces.summary)
        }
        var next = restored
        if let focused = windows.focusedWindow, let w = next.workspace(of: focused) {
            next.switchTo(w)
            next.current.focus(window: focused)
        }
        let m = metrics(of: next)
        for i in next.strips.indices {
            let reach = max(0, m.columnOffsets(next.strips[i]).total - viewport.width)
            next.strips[i].scroll = max(0, min(reach, next.strips[i].scroll))
        }
        workspaces = next
        // A layout kept from an earlier engine has its column IDs; new columns must not reuse them.
        for s in next.strips { for c in s.columns { if c.id.hasPrefix("c"), let n = Int(c.id.dropFirst()) { nextID = max(nextID, n) } } }
        Log.note("engine", "\(label) restored layout\n" + next.summary)
        apply()
    }

    /// Follows focus the user changed by clicking or ⌘-Tab. A window on another workspace
    /// brings that workspace into view, as niri does.
    public func windowFocused(_ id: String) {
        guard let w = workspaces.workspace(of: id) else { return }
        if w != workspaces.active {
            changeWorkspaces(raise: false) {
                $0.switchTo(w)
                $0.current.focus(window: id)
            }
        } else if strip.column(of: id) != nil, strip.focusedWindow != id || !fullyShown(id) {
            change(raise: false) { $0.focus(window: id) }
        }
    }

    /// Whether a window's slot lies wholly inside the screen.
    private func fullyShown(_ id: String) -> Bool {
        guard let r = stripFrames(strip, metrics, clamp: false)[id] else { return true }
        return r.x >= viewport.x - 0.5 && r.maxX <= viewport.maxX + 0.5
    }

    // MARK: Swipe

    /// Scroll the fingers have dragged the strip to, while a swipe is under way.
    public private(set) var swipeScroll: Double?
    /// How far a swipe across the whole trackpad moves the strip, in screen widths.
    public var swipeScale = 1.5
    /// How far ahead the lift-off velocity carries the strip before it snaps, in seconds.
    public var swipeProjection = 0.15

    public func beginSwipe() {
        swipeScroll = strip.scroll
    }

    /// Moves the strip with the fingers. `dx` is trackpad travel; fingers moving left pull the
    /// strip left, showing what lies to the right.
    public func swipe(by dx: Double) {
        guard var scroll = swipeScroll else { return }
        scroll -= dx * swipeScale * viewport.width
        swipeScroll = scroll
        var preview = strip
        preview.scroll = rubberBand(scroll)
        _ = presenter?.preview(frames: stripFrames(preview, metrics, clamp: false), focused: strip.focusedWindow)
    }

    /// Snaps to the column nearest where the swipe was heading, then lands like any other move.
    public func endSwipe(velocity: Double) {
        guard let scroll = swipeScroll else { return }
        swipeScroll = nil
        let projected = scroll - velocity * swipeScale * viewport.width * swipeProjection
        let points = snapPoints(strip, metrics, mode: settings.scrollMode)
        let target = points.min { abs($0 - projected) < abs($1 - projected) } ?? 0

        // Motion starts from where the pictures are now, not from the old real frames.
        var shown = strip
        shown.scroll = rubberBand(scroll)
        for (id, r) in stripFrames(shown, metrics, clamp: false) { targetFrames[id] = r }

        var next = strip
        next.scroll = target
        if settings.scrollMode == .center, let f = next.focusedColumn {
            // Focus follows the column the swipe centred, or the nearest one where the strip's end stops it.
            let m = metrics
            if abs(centredScroll(next, m, column: f) - target) >= 0.5 {
                next.focusedColumn = next.columns.indices.min {
                    abs(centredScroll(next, m, column: $0) - target) < abs(centredScroll(next, m, column: $1) - target)
                }
            }
        } else if let f = next.focusedColumn {
            let m = metrics
            let (lefts, _) = m.columnOffsets(next)
            let left = lefts[f] - settings.gap, right = lefts[f] + m.width(of: next.columns[f]) + settings.gap
            if left < target - 0.5 || right > target + viewport.width + 0.5 {
                // The focused column left the screen, so focus follows the column the swipe settled on.
                next.focusedColumn = lefts.firstIndex { abs(max(0, $0 - settings.gap) - target) < 0.5 }
                    ?? lefts.indices.min { abs(lefts[$0] - target) < abs(lefts[$1] - target) }
            }
        }
        workspaces.current = next
        Log.note("engine", "\(label) endSwipe\n" + workspaces.summary)
        apply()
        presenter?.endPreview()
        if let target = strip.focusedWindow, target != windows.focusedWindow { windows.focus(target) }
    }

    /// Past either end the strip follows the fingers with resistance, then springs back.
    private func rubberBand(_ scroll: Double) -> Double {
        let maxScroll = max(0, metrics.columnOffsets(strip).total - viewport.width)
        if scroll < 0 { return scroll * 0.3 }
        if scroll > maxScroll { return maxScroll + (scroll - maxScroll) * 0.3 }
        return scroll
    }

    // MARK: Mouse drag

    /// The window under `p` on the active workspace. Floating windows come first, since they
    /// sit above the strip. Tiled windows count only where they show on this display.
    public func window(at p: Point) -> (id: String, frame: Rect, floating: Bool)? {
        for id in strip.floating.reversed() {
            if let r = windows.frameOf(id), r.contains(p) { return (id, r, true) }
        }
        guard viewport.contains(p) else { return nil }
        for (id, r) in stripFrames(strip, metrics, clamp: false) where r.contains(p) { return (id, r, false) }
        return nil
    }

    /// What a drag shows on this display: where the dragged window would land, if anywhere.
    private struct DragView {
        var id: String
        var target: DropTarget?
        var leaving: Bool
        var width: Double
        var columnID: String
        /// Where the drag has scrolled the view, which edge scrolling changes.
        var scroll: Double
        /// Other floating windows, drawn where they are so they stay in sight under the pictures.
        var floats: [String: Rect]
    }
    private var dragView: DragView?

    /// Covers this display with pictures, without the dragged window. The real windows stay
    /// where they are until the drop.
    @discardableResult
    public func beginDrag(_ id: String) -> Bool {
        if dragView == nil {
            var floats: [String: Rect] = [:]
            for f in strip.floating where f != id { floats[f] = windows.frameOf(f) }
            dragView = DragView(id: id, target: nil, leaving: false, width: settings.defaultWidth,
                                columnID: newColumnID(), scroll: strip.scroll, floats: floats)
        }
        return presenter?.preview(frames: dragFrames().frames, focused: nil) ?? false
    }

    /// Lays the strip out as if the dragged window were dropped at `target`, and moves the
    /// pictures there. This opens a gap where the window would land. With no target the strip
    /// shows as it is, or with the window gone when it is `leaving` for another display.
    /// Returns the frame the window would take, or nil without a target.
    @discardableResult
    public func previewDrop(_ id: String, at target: DropTarget?, width: Double, leaving: Bool) -> Rect? {
        if dragView == nil { beginDrag(id) }
        guard var d = dragView else { return nil }
        let changed = d.target != target || d.leaving != leaving || d.width != width
        d.target = target
        d.leaving = leaving
        d.width = width
        dragView = d
        let (frames, slot) = dragFrames()
        if changed { _ = presenter?.arrange(frames: frames) }
        return target == nil ? nil : slot
    }

    /// The frame a dragged window would take if dropped at `target` on this strip.
    public func dropSlot(_ id: String, at target: DropTarget, width: Double) -> Rect? {
        var base = strip
        if let d = dragView { base.scroll = d.scroll }
        let m = metrics
        let layout = dropLayout(base, moving: id, to: target, leaving: false, width: width,
                                columnID: dragView?.columnID ?? "", m)
        return stripFrames(layout, m, clamp: false)[id]
    }

    /// Writes the layout the drag showed, so the real windows take the frames their pictures
    /// already have. A window placed on this strip lands from `picture`, where its picture was
    /// let go, and takes focus.
    public func endDrag(from picture: Rect) {
        guard let d = dragView else { return }
        let layout = dragLayout(metrics)
        dragView = nil
        if layout.column(of: d.id) != nil { targetFrames[d.id] = picture } else if d.leaving { targetFrames[d.id] = nil }
        // The view stays where the drag scrolled it, unless that leaves the focused window off
        // screen; then the view moves to show it.
        changeWorkspaces(raise: d.target != nil, scroll: { [self] s, m, mode in
            guard let id = s.focusedWindow, let r = stripFrames(s, m, clamp: false)[id],
                  r.x < viewport.x || r.maxX > viewport.maxX else { return s }
            var shown = s
            shown.scroll = scrollToFocus(s, m, mode: mode)
            return shown
        }) { $0.current = layout }
        presenter?.endPreview()
    }

    private func dragLayout(_ m: StripMetrics) -> Strip {
        guard let d = dragView else { return strip }
        var base = strip
        base.scroll = d.scroll
        return dropLayout(base, moving: d.id, to: d.target, leaving: d.leaving, width: d.width,
                          columnID: d.columnID, m)
    }

    private func dragFrames() -> (frames: [String: Rect], slot: Rect?) {
        let m = metrics
        var frames = stripFrames(dragLayout(m), m, clamp: false)
        let slot = dragView.flatMap { frames.removeValue(forKey: $0.id) }
        for (f, r) in dragView?.floats ?? [:] { frames[f] = r }
        return (frames, slot)
    }

    /// Where a window dragged to `p` would land on this strip, or nil when `p` is off this display.
    /// During a drag the zones come from the layout the pictures show, so they line up with
    /// what is on screen; the target is then given in the strip's own indices.
    public func dropHint(at p: Point, dragging: String?, style: DropStyle = DropStyle()) -> DropHint? {
        guard dragView != nil, let id = dragging else {
            return StripModel.dropHint(at: p, in: strip, metrics, dragging: dragging, style: style)
        }
        let m = metrics
        let shown = dragLayout(m)
        guard var hint = StripModel.dropHint(at: p, in: shown, m, dragging: id, style: style) else { return nil }
        hint.target = baseTarget(hint.target, from: shown, to: strip, dragging: id)
        return hint
    }

    /// Scrolls the view of a drag by `dx` points, kept inside the strip, and shows it at once.
    /// Returns false when the view could not move, at the strip's ends.
    @discardableResult
    public func dragScroll(by dx: Double) -> Bool {
        guard var d = dragView else { return false }
        let m = metrics
        let before = dragLayout(m).scroll
        d.scroll = before + dx
        dragView = d
        let after = dragLayout(m).scroll
        d.scroll = after
        dragView = d
        guard abs(after - before) > 0.01 else { return false }
        _ = presenter?.preview(frames: dragFrames().frames, focused: nil)
        return true
    }

    /// Takes a window off this strip without moving focus, for a floating window let go over
    /// another display.
    public func handOver(_ id: String) {
        guard workspaces.workspace(of: id) != nil else { return }
        targetFrames[id] = nil
        changeWorkspaces(raise: false) { $0.remove(id) }
    }

    // MARK: Workspaces

    /// Shows the workspace above (negative) or below (positive).
    public func switchWorkspace(by delta: Int) { changeWorkspaces { $0.switchBy(delta) } }

    /// Carries the focused window to the workspace above or below and follows it.
    public func moveToWorkspace(by delta: Int) {
        let id = newColumnID()
        liftNext = strip.focusedWindow != nil
        let to = workspaces.active + delta
        arrivalPlaces = workspaces.strips.indices.contains(to) ? stripFrames(workspaces.strips[to], metrics, clamp: false) : [:]
        changeWorkspaces { $0.moveFocused(by: delta, width: settings.defaultWidth, columnID: id) }
    }

    // MARK: Commands

    public func focus(_ d: Direction) { change { $0.focus(d) } }
    public func focusColumn(_ i: Int) { change { $0.focusColumn(i) } }
    public func move(_ d: Direction) { lift { $0.move(d) } }
    public func stack(_ d: Direction) { lift { $0.stack(d) } }
    public func popOut() {
        let id = newColumnID()
        lift { $0.popOut(columnID: id) }
    }
    public func cycleWidth(backward: Bool = false) { resize { $0.cycleWidth(settings.widthPresets, backward: backward) } }
    public func toggleFullWidth() { resize { $0.toggleFullWidth() } }
    public func halfWidth() { resize { $0.setWidth(0.5) } }
    public func wider() { resize { $0.nudgeWidth(by: settings.nudge) } }
    public func narrower() { resize { $0.nudgeWidth(by: -settings.nudge) } }

    /// Centres the focused column once, without changing the scroll mode.
    public func center() {
        workspaces.current.scroll = scrollToFocus(strip, metrics, mode: .center)
        apply()
    }

    /// Switches focus between the strip and its floating windows, as niri's layer toggle does.
    /// From the strip the first float comes up; from a float the next one follows, and after the
    /// last one focus returns to the strip. Focusing a float activates its app, which is what
    /// brings it in front of the strip: macOS lets no one else order it above the active app.
    public func toggleFloatFocus() {
        let floats = strip.floating
        guard !floats.isEmpty else { return }
        if let current = windows.focusedWindow, let i = floats.firstIndex(of: current) {
            if i + 1 < floats.count { windows.focus(floats[i + 1]) }
            else if let back = strip.focusedWindow { windows.focus(back) }
        } else {
            windows.focus(floats[0])
        }
    }

    public func toggleFloat() {
        guard let view = windows.focusedWindow else { return }
        let id = newColumnID()
        change { $0.toggleFloat(view, width: settings.defaultWidth, columnID: id) }
    }

    // MARK: Applying

    /// Edits the strip, scrolls to the focused column, moves windows, and focuses the new target.
    private func change(raise: Bool = true, caller: String = #function, _ edit: (inout Strip) -> Void) {
        changeWorkspaces(raise: raise, caller: caller) { edit(&$0.current) }
    }

    /// A change that moves the focused window lifts its picture, even when its frame stays the same.
    private func lift(caller: String = #function, _ edit: (inout Strip) -> Void) {
        var probe = strip
        edit(&probe)
        liftNext = probe.columns != strip.columns
        change(caller: caller, edit)
    }

    /// Width changes keep the view the user had before the column grew.
    private func resize(caller: String = #function, _ edit: (inout Strip) -> Void) {
        let before = strip
        changeWorkspaces(scroll: { scrollAfterResize(before, $0, $1, mode: $2) }, caller: caller) { edit(&$0.current) }
    }

    /// Moves a window from the overview without switching workspaces.
    public func moveWindow(_ id: String, toWorkspace w: Int, at target: DropTarget, width incoming: Double? = nil) {
        guard workspaces.strips.indices.contains(w) else { return }
        let src = workspaces.workspace(of: id)
        let width = src.flatMap { i in workspaces.strips[i].column(of: id).map { workspaces.strips[i].columns[$0].width } } ?? incoming
        guard let width else { return }
        let columnID = newColumnID()
        changeWorkspaces(raise: false) { ws in
            let focused = ws.strips[w].focusedWindow
            if let src, src != w { ws.strips[src].remove(id) }
            ws.strips[w].place(id, at: target, width: width, columnID: columnID)
            if let focused, let c = ws.strips[w].column(of: focused) {
                ws.strips[w].focusedColumn = c
                ws.strips[w].columns[c].focused = ws.strips[w].columns[c].windows.firstIndex(of: focused) ?? 0
            }
        }
    }

    private func changeWorkspaces(
        raise: Bool = true,
        scroll: ((Strip, StripMetrics, ScrollMode) -> Strip)? = nil,
        caller: String = #function,
        _ edit: (inout Workspaces) -> Void
    ) {
        var next = workspaces
        let focusedBefore = strip.focusedColumn.map { strip.columns[$0].id }
        edit(&next)
        next.normalize()
        logChange(caller, from: workspaces, to: next)
        if let scroll {
            next.current = scroll(next.current, metrics(of: next), settings.scrollMode)
        } else {
            // Any other change forgets the remembered view once focus leaves that column.
            let focusedNow = next.current.focusedColumn.map { next.current.columns[$0].id }
            if focusedNow != focusedBefore || next.current.viewBeforeGrow?.column != focusedNow {
                next.current.viewBeforeGrow = nil
            }
            next.current.scroll = scrollToFocus(next.current, metrics(of: next), mode: settings.scrollMode)
        }
        let refocus = raise && next.current.focusedWindow != windows.focusedWindow
        workspaces = next
        apply()
        if refocus, let target = strip.focusedWindow { windows.focus(target) }
    }

    /// Refits each strip's scroll after column widths changed outside a layout change, as when
    /// a window refused its column's width, so a narrowed column leaves no empty space past the strip's end.
    public func widthsChanged() {
        let m = metrics
        for i in workspaces.strips.indices {
            workspaces.strips[i].scroll = scrollToFocus(workspaces.strips[i], m, mode: settings.scrollMode)
        }
        apply()
    }

    /// Writes frames that changed since the last write. Windows on other workspaces wait
    /// just past the screen's bottom-right corner, since macOS cannot hide single windows.
    public func apply() {
        // A fit lasts only while its column asks the width it was made for, so a window
        // that refused one share is asked afresh when its column comes back to it.
        let share = StripMetrics(viewport: viewport, gap: settings.gap)
        refusals = refusals.filter { id, r in
            workspaces.strips.contains { s in
                s.column(of: id).map { abs(share.columnWidth(s.columns[$0].width) - r.asked) < 0.5 } ?? false
            }
        }
        var frames = stripFrames(strip, metrics, trim: !settings.peekCovers, hideaway: hideaway)
        peeks = settings.peekCovers ? blockedPeeks(strip, metrics, hideaway: hideaway) : [:]
        let unclamped = stripFrames(strip, metrics, clamp: false)
        let plain = Hideaway(screen: viewport)
        var slides: [String: Rect] = [:]
        // Any window hidden to a sliver counts, including a column that barely reaches the screen.
        for (id, r) in unclamped {
            guard let real = frames[id], min(real.maxX, viewport.maxX) - max(real.x, viewport.x) <= 2.5 else { continue }
            let edge = plain.sliver(r, pastRight: r.x + r.width / 2 > viewport.x + viewport.width / 2, sliver: 2)
            if !real.isApproximately(edge) { slides[id] = edge }
        }
        let peekStripBefore = peekStrip
        let placesBefore = stripPlaces
        stripPlaces = unclamped
        peekStrip = unclamped.filter { peeks[$0.key] != nil }
        var parkedNow: Set<String> = []
        for (i, other) in workspaces.strips.enumerated() where i != workspaces.active {
            for id in other.floating where !parked.contains(id) {
                if let home = windows.frameOf(id) ?? targetFrames[id] { floatHomes[id] = home }
            }
            // A tiled window is parked at its column's size, so its picture has the right shape
            // even before its workspace is first shown, as after a restart.
            let tiled = stripFrames(other, metrics, clamp: false)
            for id in other.allWindows + other.floating {
                let size = tiled[id] ?? targetFrames[id] ?? floatHomes[id] ?? Rect(x: 0, y: 0, width: 800, height: 600)
                let origin = hideaway.parkOrigin(size: Size(width: size.width, height: size.height))
                frames[id] = Rect(x: origin.x, y: origin.y, width: size.width, height: size.height)
                parkedNow.insert(id)
            }
        }
        // Floating windows coming back return to where they were; otherwise they are left alone.
        for id in strip.floating where parked.contains(id) {
            if let home = floatHomes.removeValue(forKey: id) { frames[id] = home }
        }
        let wasParked = parked
        parked = parkedNow
        func isParked(_ id: String, before: Bool) -> Bool { (before ? wasParked : parkedNow).contains(id) }
        // Positive when the view moves down to a later workspace, so content slides up.
        let delta = Double((workspaces.active - shownWorkspace).signum())
        shownWorkspace = workspaces.active
        let height = viewport.height

        var moves: [String: (from: Rect, to: Rect, then: Rect?)] = [:]
        var direct: [String: Rect] = [:]
        for (id, target) in frames where forceWrite || targetFrames[id].map({ !$0.isApproximately(target) }) ?? true {
            guard !forceWrite, let before = targetFrames[id] else {
                // A window seen for the first time goes straight to its place.
                direct[id] = target
                continue
            }
            if isParked(id, before: false) {
                if isParked(id, before: true) || delta == 0 {
                    direct[id] = target
                } else {
                    // Slide off the way the workspace leaves, then park out of sight.
                    let away = Rect(x: before.x, y: before.y - delta * height, width: before.width, height: before.height)
                    moves[id] = (before, away, target)
                }
            } else if isParked(id, before: true) {
                // Arrive from the edge the new workspace comes from.
                let to = slides[id] ?? target
                let enter = Rect(x: to.x, y: to.y + (delta == 0 ? height : delta * height),
                                 width: to.width, height: to.height)
                moves[id] = (enter, to, slides[id] == nil ? nil : target)
            } else {
                // A window going behind a card slides to the card, then is written out of sight.
                // A window hidden past the far edge slides past the near one, then is written there.
                let slid = slideFrames[id].flatMap { $0.real.isApproximately(before) ? $0.slide : nil }
                let from = peekStripBefore[id] ?? slid ?? before
                let to = peekStrip[id] ?? slides[id] ?? target
                if from.isApproximately(to) { direct[id] = target; continue }
                moves[id] = (from, to, to.isApproximately(target) ? nil : target)
            }
        }
        // A moved window lifts even when it keeps its frame, as a full-width one does.
        var lifted: String?
        // A window from another display is new here, but flies in from where it was.
        if liftNext, let from = arrivalFrame, let id = strip.focusedWindow, let to = direct[id] {
            direct[id] = nil
            moves[id] = (from, to, nil)
        }
        if liftNext, let id = strip.focusedWindow, direct[id] == nil, let to = frames[id] {
            if moves[id] == nil { moves[id] = (to, to, nil) }
            lifted = id
            // The others travel along the strip, across the screen even between hidden places,
            // so the lifted window passes over them. On a workspace it is carried to, they come in
            // where that workspace showed them, then make room.
            for other in strip.allWindows where other != id {
                let from: Rect?
                if isParked(other, before: true) {
                    from = arrivalPlaces[other].map { Rect(x: $0.x, y: $0.y + delta * height, width: $0.width, height: $0.height) }
                } else {
                    from = placesBefore[other]
                }
                guard let from, let along = unclamped[other], !from.isApproximately(along),
                      let target = frames[other] else { continue }
                moves[other] = (from, along, along.isApproximately(target) ? nil : target)
                direct[other] = nil
            }
        }
        liftNext = false
        arrivalPlaces = [:]
        // The display it goes to writes a departing window; here only its picture leaves.
        if let d = departing {
            moves[d.id] = (d.from, d.to, nil)
            lifted = d.id
        }
        // A window staying behind a card keeps its hidden frame, but its picture follows the strip.
        for (id, to) in peekStrip where moves[id] == nil {
            if let from = peekStripBefore[id], !from.isApproximately(to) { moves[id] = (from, to, frames[id]) }
        }
        targetFrames = frames
        slideFrames = [:]
        for (id, slide) in slides { if let real = frames[id] { slideFrames[id] = (real, slide) } }
        for (id, r) in direct {
            Log.note("frame", "\(label) \(Log.name(id)) -> \(Log.rect(r)) at once\(parkedNow.contains(id) ? " (parked)" : "")")
            windows.setFrame(id, r) { [weak self, weak presenter] took in
                presenter?.wrote(id)
                self?.checkWidth(id, asked: r, took: took)
            }
        }
        for (id, m) in moves {
            Log.note("frame", "\(label) \(Log.name(id)) \(Log.rect(m.from)) -> \(Log.rect(m.to))"
                + (m.then.map { " then \(Log.rect($0))\(peekStrip[id] != nil ? " (behind a card)" : " (parked)")" } ?? ""))
        }

        var still: [String: Rect] = [:]
        for id in strip.allWindows where moves[id] == nil { still[id] = peekStrip[id] ?? slides[id] ?? frames[id] }
        let finals = moves.filter { $0.key != departing?.id }.mapValues { $0.then ?? $0.to }
        if !moves.isEmpty, let presenter,
           let token = presenter.begin(moves: moves.mapValues { (from: $0.from, to: $0.to) }, still: still,
                                       focused: strip.focusedWindow, lifted: lifted) {
            let write: @MainActor () -> Void = { [weak self, weak presenter] in
                guard let self else { return }
                // A window given another frame since, or taken off this strip, has a newer write coming
                // or belongs elsewhere, so this one would put it back.
                let current = finals.filter { self.targetFrames[$0.key] == $0.value }
                for (id, r) in current {
                    self.windows.setFrame(id, r) { [weak self] took in
                        presenter?.landed(id, token: token)
                        self?.checkWidth(id, asked: r, took: took)
                    }
                }
                presenter?.writesIssued(Set(current.keys), token: token)
            }
            if let clock, presenter.writeDelay > 0 { clock.after(presenter.writeDelay, write) } else { write() }
        } else {
            for (id, r) in finals {
                windows.setFrame(id, r) { [weak self, weak presenter] took in
                    presenter?.wrote(id)
                    self?.checkWidth(id, asked: r, took: took)
                }
            }
        }
        moved = !moves.isEmpty || !direct.isEmpty
        for o in observers { o(self) }
    }

    /// Reports a tiled window that took a wider or narrower frame than asked, with the frame a second read
    /// finds a moment later, since an app still busy with the change can report its old size.
    /// A frame off the screen proves nothing: macOS widens a window it would leave almost hidden.
    /// Nor does a trimmed one, which the app may refuse though it takes its column's width.
    private func checkWidth(_ id: String, asked: Rect, took: Rect?) {
        guard let took, abs(took.width - asked.width) > 2,
              asked.x >= viewport.x - 2, asked.maxX <= viewport.maxX + 2, !isTrimmed(id) else { return }
        let confirm: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            windows.readFrame(id) { [weak self] again in
                guard let self, let again,
                      workspaces.strips.contains(where: { $0.column(of: id) != nil }),
                      let wanted = targetFrames[id], abs(wanted.width - asked.width) < 0.5 else { return }
                refused(id, asked: asked.width, took: again.width)
            }
        }
        if let clock { clock.after(0.3, confirm) } else { confirm() }
    }

    /// Fits the column of a window that took `took` points when asked for its column's share.
    /// A width asked for some other reason, such as a fit already made, proves nothing. Nor does
    /// a window that comes back nearly as wide as the screen: it was zoomed, not refusing a width.
    private func refused(_ id: String, asked: Double, took: Double) {
        guard abs(took - asked) > 2, took < viewport.width * 0.95,
              let c = strip.column(of: id), abs(metrics.columnWidth(strip.columns[c].width) - asked) < 0.5 else { return }
        refusals[id] = (asked, took)
        Log.note("width", "\(label) \(Log.name(id)) took \(Int(took)) points when asked for \(Int(asked)); its column fits it")
        widthsChanged()
    }

    private func logChange(_ caller: String, from before: Workspaces, to after: Workspaces) {
        guard Log.isOn else { return }
        let focus = windows.knownFocus.map(Log.name) ?? "none"
        guard before != after else {
            return Log.note("engine", "\(label) \(caller): no change (system focus \(focus))")
        }
        Log.note("engine", "\(label) \(caller) (system focus \(focus))\n" + after.summary)
    }

    private func newColumnID() -> String {
        nextID += 1
        return "c\(nextID)"
    }
}
