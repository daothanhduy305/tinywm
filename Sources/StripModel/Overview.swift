import WindowCore

/// One window in the overview, placed in screen-local coordinates (origin at the viewport's top-left).
public struct OverviewWindow: Equatable, Sendable {
    public var id: String
    public var workspace: Int
    /// Floating windows come after the strip's columns, one column each.
    public var column: Int
    /// Position within the column's stack, top first.
    public var index: Int
    public var rect: Rect
}

public struct OverviewRow: Equatable, Sendable {
    /// The workspace shown, or -1 for the shelf of floating windows.
    public var workspace: Int
    public var isActive: Bool
    public var rect: Rect
    public var windows: [OverviewWindow]
}

/// Where the overview shows floating windows.
public enum OverviewFloating: String, Equatable, Sendable, CaseIterable {
    /// At their real place, above the strip.
    case off
    /// On a shelf down the right side of the screen, as equally wide pictures.
    case vertical
    /// On a shelf along the bottom of the screen, as equally tall pictures.
    case horizontal
}

public struct OverviewStyle: Equatable, Sendable {
    /// Space kept free around the rows.
    public var margin = 48.0
    public var rowGap = 44.0
    /// Extra space under each stacked window but the last, so its label does not cover the next.
    public var labelGap = 30.0
    /// A lone small strip is not blown up past this share of its real size.
    public var maxScale = 0.6
    /// Below this a wide strip stops shrinking and the view pans sideways instead. Rows still
    /// shrink past it to fit every workspace on screen, since the view cannot pan up or down.
    public var minScale = 0.15
    /// Extra room kept above the rows, for the search bar.
    public var top = 0.0
    public var floating = OverviewFloating.vertical
    /// The width of every picture on a vertical shelf, or the height of every one on a horizontal
    /// shelf. A shelf too long for the screen shrinks to fit.
    public var shelfSize = 160.0
    public var shelfGap = 24.0
    /// On a horizontal shelf a slot is at least this wide, so labels under narrow pictures do
    /// not overlap.
    public var shelfSlot = 100.0
    /// Room around the shelf's pictures and labels inside its plate, and from the plate to the
    /// screen's edge.
    public var shelfPad = 14.0
    public var shelfEdge = 12.0

    public init(top: Double = 0, floating: OverviewFloating = .vertical) {
        self.top = top
        self.floating = floating
    }
}

/// Every workspace with windows, plus the active one, as scaled-down strips stacked top to bottom.
public struct OverviewLayout: Equatable, Sendable {
    public var scale: Double
    public var rows: [OverviewRow]
    /// How far the rows can pan sideways; zero when they all fit.
    public var panRange: Double
    /// The space the rows use: the screen, less the room a vertical shelf takes on its right.
    public var screen: Size
    public var margin: Double
    /// Where floating windows are: on a shelf, they are the last row, with workspace -1.
    public var floating = OverviewFloating.off

    public var windows: [OverviewWindow] { rows.flatMap(\.windows) }

    public func window(_ id: String) -> OverviewWindow? { windows.first { $0.id == id } }

    /// This layout with only the `matching` windows, plus `id` so moves can start from it.
    /// Nil keeps every window.
    func keeping(_ matching: Set<String>?, and id: String? = nil) -> OverviewLayout {
        guard let matching else { return self }
        var out = self
        for r in out.rows.indices { out.rows[r].windows.removeAll { $0.id != id && !matching.contains($0.id) } }
        return out
    }

    /// The topmost window under `p`; floating windows lie above the strip.
    public func window(at p: Point) -> OverviewWindow? { windows.last { $0.rect.contains(p) } }

    /// The pan that brings `id` fully on screen, changing `current` as little as possible.
    /// `current` is the pan this layout was made with.
    public func pan(toReveal id: String, current: Double) -> Double {
        guard let r = window(id)?.rect else { return current }
        var pan = current
        if r.x < margin { pan -= margin - r.x }
        if r.maxX > screen.width - margin { pan += r.maxX - (screen.width - margin) }
        if r.width > screen.width - 2 * margin { pan = current + r.center.x - screen.width / 2 }
        return max(0, min(panRange, pan))
    }
}

public struct OverviewDrop: Equatable, Sendable {
    public var workspace: Int
    public var target: DropTarget
    public var marker: Rect
}

/// A drag preview keeps workspace indices stable until the drop is committed.
public func overviewPreview(_ base: Workspaces, moving id: String, to destination: (workspace: Int, target: DropTarget)?,
                            width: Double, columnID: String) -> Workspaces {
    var out = base
    let source = out.workspace(of: id)
    if let destination, out.strips.indices.contains(destination.workspace) {
        if let source, source != destination.workspace { out.strips[source].remove(id) }
        out.strips[destination.workspace].place(id, at: destination.target, width: width, columnID: columnID)
        if let c = out.strips[destination.workspace].column(of: id) {
            out.strips[destination.workspace].columns[c].width = width
        }
    } else if let source { out.strips[source].remove(id) }
    return out
}

/// Finds a base column slot from the layout currently shown.
public func overviewDrop(_ layout: OverviewLayout, shownWS: Workspaces, base: Workspaces, at p: Point, dragging: String) -> OverviewDrop? {
    if layout.rows.contains(where: { $0.workspace == -1 && $0.rect.contains(p) }) { return nil }
    let rows = layout.rows.filter { shownWS.strips.indices.contains($0.workspace) && base.strips.indices.contains($0.workspace) }
    guard let first = rows.first, let last = rows.last,
          p.y >= first.rect.y - layout.margin, p.y <= last.rect.maxY + layout.margin,
          let row = rows.min(by: { abs($0.rect.center.y - p.y) < abs($1.rect.center.y - p.y) }) else { return nil }
    let columns = (0..<shownWS.strips[row.workspace].columns.count).compactMap { c -> (Double, Double)? in
        let windows = row.windows.filter { $0.column == c }
        guard let left = windows.map(\.rect.x).min(), let right = windows.map(\.rect.maxX).max() else { return nil }
        return (left, right)
    }
    let k = columns.filter { ($0.0 + $0.1) / 2 < p.x }.count
    let target = baseTarget(.newColumn(k), from: shownWS.strips[row.workspace], to: base.strips[row.workspace], dragging: dragging)
    return OverviewDrop(workspace: row.workspace, target: target, marker: layout.window(dragging)?.rect ?? row.rect)
}

/// Lays out the overview for a screen of `screen` points. Window rects keep each window's
/// proportions, since the whole strip scales by one factor. `floats` gives floating windows'
/// frames relative to the viewport's top-left; a floating window without one is left out.
/// `style.floating` says where floating windows go; on a shelf, the rows keep clear of it.
/// `fullScreen` gives fullscreen windows' frames; they sit on the shelf after the floating
/// windows, and are left out without one.
public func overviewLayout(
    _ ws: Workspaces, _ m: StripMetrics, screen: Size, pan: Double = 0, style: OverviewStyle = OverviewStyle(),
    floats: [String: Rect] = [:], fullScreen: [String: Rect] = [:], rows: [Int]? = nil
) -> OverviewLayout {
    var local = m
    local.viewport = Rect(x: 0, y: 0, width: m.viewport.width, height: m.viewport.height)
    let shelved = style.floating != .off
    let shown = rows ?? ws.strips.indices.filter {
        !ws.strips[$0].columns.isEmpty || $0 == ws.active
            || !shelved && ws.strips[$0].floating.contains { floats[$0] != nil }
    }
    let widths = shown.map { max(local.columnOffsets(ws.strips[$0]).total, local.viewport.width) }
    let widest = max(1, widths.max() ?? 1)
    let n = Double(max(1, widths.count))
    let shelf = overviewShelf(ws, style, floats: floats, fullScreen: fullScreen, screen: screen)
    // The rows fit in the space the shelf leaves, as if the screen ended a row gap before it.
    var screen = screen
    if let r = shelf?.rect {
        if style.floating == .vertical { screen.width = r.x - style.rowGap + style.margin }
        else { screen.height = r.y - style.rowGap + style.margin }
    }
    let availW = max(1, screen.width - 2 * style.margin)
    let availH = max(1, screen.height - 2 * style.margin - style.top)

    let fitH = (availH - (n - 1) * style.rowGap) / (n * local.viewport.height)
    let fitW = availW / widest
    let scale = max(0.01, min(style.maxScale, fitH, max(style.minScale, fitW)))

    let contentW = widest * scale
    let rowH = local.viewport.height * scale
    let blockH = n * rowH + (n - 1) * style.rowGap
    let x0 = style.margin + max(0, (availW - contentW) / 2)
    let y0 = style.top + max(0, (screen.height - style.top - blockH) / 2)
    let panRange = max(0, contentW - availW)
    let shift = max(0, min(panRange, pan))

    var rows: [OverviewRow] = []
    for (r, i) in shown.enumerated() {
        var strip = ws.strips[i]
        strip.scroll = 0
        let frames = stripFrames(strip, local, clamp: false)
        let top = y0 + Double(r) * (rowH + style.rowGap)
        var windows: [OverviewWindow] = []
        for (c, column) in strip.columns.enumerated() {
            // A stack frees `labelGap` under each window but the last for its label: every window
            // gives up an equal share of height and shrinks in proportion, centred in its column.
            let k = Double(column.windows.count)
            let share = (k - 1) * style.labelGap / k
            for (j, id) in column.windows.enumerated() {
                guard let f = frames[id] else { continue }
                var rect = Rect(x: x0 - shift + f.x * scale, y: top + f.y * scale, width: f.width * scale, height: f.height * scale)
                if k > 1, rect.height > share {
                    let s = (rect.height - share) / rect.height
                    rect = Rect(x: rect.center.x - rect.width * s / 2, y: rect.y + Double(j) * (style.labelGap - share),
                                width: rect.width * s, height: rect.height - share)
                }
                windows.append(OverviewWindow(id: id, workspace: i, column: c, index: j, rect: rect))
            }
        }
        if !shelved {
            var column = strip.columns.count
            for id in strip.floating {
                guard let f = floats[id] else { continue }
                let rect = Rect(x: x0 - shift + f.x * scale, y: top + f.y * scale, width: f.width * scale, height: f.height * scale)
                windows.append(OverviewWindow(id: id, workspace: i, column: column, index: 0, rect: rect))
                column += 1
            }
        }
        rows.append(OverviewRow(
            workspace: i, isActive: i == ws.active,
            rect: Rect(x: x0 - shift, y: top, width: widths[r] * scale, height: rowH), windows: windows))
    }
    if let shelf { rows.append(shelf) }
    return OverviewLayout(scale: scale, rows: rows, panRange: panRange, screen: screen, margin: style.margin,
                          floating: shelf == nil ? .off : style.floating)
}

/// Every workspace's floating windows on a shelf at the right or bottom edge of the screen, which
/// does not pan. Pictures keep their proportions and are all `shelfSize` wide (vertical) or tall
/// (horizontal), each with its label under it. The row's rect is the plate behind them. Fullscreen
/// windows come last, with workspace -1. Nil when floating windows stay in place or there is none to show.
func overviewShelf(_ ws: Workspaces, _ style: OverviewStyle, floats: [String: Rect], fullScreen: [String: Rect] = [:],
                   screen: Size) -> OverviewRow? {
    guard style.floating != .off else { return nil }
    let floating = ws.strips.enumerated().flatMap { i, strip in strip.floating.compactMap { id in floats[id].map { (id, i, $0) } } }
    let shown = (floating + fullScreen.sorted { $0.key < $1.key }.map { ($0.key, -1, $0.value) })
        .filter { $0.2.width > 0 && $0.2.height > 0 }
    guard !shown.isEmpty else { return nil }
    let pad = style.shelfPad, label = style.labelGap, gaps = Double(shown.count - 1) * style.shelfGap
    var windows: [OverviewWindow] = []
    if style.floating == .vertical {
        let heights = shown.map { $0.2.height / $0.2.width * style.shelfSize }
        let total = heights.reduce(0) { $0 + $1 + label } + gaps
        let room = screen.height - style.top - 2 * (style.shelfEdge + pad)
        let s = min(1, room / total)
        let w = style.shelfSize * s
        let x = screen.width - style.shelfEdge - pad - w
        var y = style.top + (screen.height - style.top - total * s) / 2
        let start = y
        for (k, (id, workspace, _)) in shown.enumerated() {
            windows.append(OverviewWindow(id: id, workspace: workspace, column: 0, index: k,
                                          rect: Rect(x: x, y: y, width: w, height: heights[k] * s)))
            y += (heights[k] + label + style.shelfGap) * s
        }
        let plate = Rect(x: x - pad, y: start - pad, width: w + 2 * pad, height: total * s + 2 * pad)
        return OverviewRow(workspace: -1, isActive: false, rect: plate, windows: windows)
    }
    let widths = shown.map { $0.2.width / $0.2.height * style.shelfSize }
    let total = widths.reduce(0) { $0 + max($1, style.shelfSlot) } + gaps
    let s = min(1, (screen.width - 2 * (style.shelfEdge + pad)) / total)
    let h = style.shelfSize * s
    let y = screen.height - style.shelfEdge - pad - label - h
    var x = (screen.width - total * s) / 2
    let start = x
    for (k, (id, workspace, _)) in shown.enumerated() {
        let w = widths[k] * s, slot = max(widths[k], style.shelfSlot) * s
        windows.append(OverviewWindow(id: id, workspace: workspace, column: k, index: 0,
                                      rect: Rect(x: x + (slot - w) / 2, y: y, width: w, height: h)))
        x += slot + style.shelfGap * s
    }
    let plate = Rect(x: start - pad, y: y - pad, width: total * s + 2 * pad, height: h + label + 2 * pad)
    return OverviewRow(workspace: -1, isActive: false, rect: plate, windows: windows)
}

/// Where every window sits in the real layout, in the same coordinates as `overviewLayout`.
/// Other workspaces sit above and below the active one, one screen height apart.
public func overviewRealFrames(_ ws: Workspaces, _ m: StripMetrics, floats: [String: Rect] = [:]) -> [String: Rect] {
    var local = m
    local.viewport = Rect(x: 0, y: 0, width: m.viewport.width, height: m.viewport.height)
    var out: [String: Rect] = [:]
    for (i, strip) in ws.strips.enumerated() {
        let dy = Double(i - ws.active) * m.viewport.height
        for (id, r) in stripFrames(strip, local, clamp: false) {
            out[id] = Rect(x: r.x, y: r.y + dy, width: r.width, height: r.height)
        }
        for id in strip.floating {
            guard let r = floats[id] else { continue }
            out[id] = Rect(x: r.x, y: r.y + dy, width: r.width, height: r.height)
        }
    }
    return out
}

/// The window the selection moves to, or nil at an edge.
///
/// Left and right move to the nearest column that way, landing on its window nearest in height.
/// Up and down walk the column's stack, then cross to the nearest row that has windows, landing
/// on the window whose centre is horizontally nearest. With `matching`, only those windows count.
public func overviewMove(_ layout: OverviewLayout, from id: String, _ d: Direction, matching: Set<String>? = nil) -> String? {
    let layout = layout.keeping(matching, and: id)
    guard let w = layout.window(id), let row = layout.rows.firstIndex(where: { $0.windows.contains(w) }) else { return nil }
    let here = layout.rows[row].windows
    switch d {
    case .left, .right:
        let columns = here.map(\.column).filter { d == .left ? $0 < w.column : $0 > w.column }
        guard let column = d == .left ? columns.max() : columns.min() else {
            // A vertical shelf lies right of every row: right enters it, left leaves it.
            guard layout.floating == .vertical, let shelf = layout.rows.last, shelf.workspace == -1,
                  (d == .right) == (layout.rows[row].workspace != -1) else { return nil }
            let others = d == .right ? shelf.windows : layout.rows.dropLast().flatMap(\.windows)
            return nearest(others) { ($0.rect.center.x - w.rect.center.x).magnitude + ($0.rect.center.y - w.rect.center.y).magnitude }
        }
        return nearest(here.filter { $0.column == column }) { abs($0.rect.center.y - w.rect.center.y) }
    case .up, .down:
        let stack = here.filter { $0.column == w.column && (d == .up ? $0.index < w.index : $0.index > w.index) }
        if let next = d == .up ? stack.max(by: { $0.index < $1.index }) : stack.min(by: { $0.index < $1.index }) { return next.id }
        // Up and down never cross between the rows and a vertical shelf beside them.
        let beside = layout.floating == .vertical
        if beside, layout.rows[row].workspace == -1 { return nil }
        let step = d == .up ? -1 : 1
        var r = row + step
        while layout.rows.indices.contains(r) {
            let candidates = beside && layout.rows[r].workspace == -1 ? [] : layout.rows[r].windows
            if !candidates.isEmpty {
                // Entering from above prefers the top of a stack, from below the bottom.
                return nearest(d == .down ? candidates : candidates.reversed()) { abs($0.rect.center.x - w.rect.center.x) }
            }
            r += step
        }
        return nil
    }
}

/// Where the selection lands when the keys arrive from another display moving `d`, starting
/// from the selected `id`: the near end of its row for left and right, the near row for up and down.
/// With `matching`, only those windows count.
public func overviewEntry(_ layout: OverviewLayout, from id: String, _ d: Direction, matching: Set<String>? = nil) -> String? {
    // The selection only says where the keys come in; it is a candidate only if it matches.
    guard let w = layout.window(id), let r = layout.rows.firstIndex(where: { $0.windows.contains(w) }) else { return nil }
    let layout = layout.keeping(matching)
    let row = layout.rows[r]
    switch d {
    case .left, .right:
        let columns = row.windows.map(\.column)
        guard let edge = d == .right ? columns.min() : columns.max() else { return nil }
        return nearest(row.windows.filter { $0.column == edge }) { abs($0.rect.center.y - w.rect.center.y) }
    case .up, .down:
        let rows = layout.rows.filter { !$0.windows.isEmpty && !(layout.floating == .vertical && $0.workspace == -1) }
        guard let r = d == .down ? rows.first : rows.last else { return nil }
        return nearest(d == .down ? r.windows : r.windows.reversed()) { abs($0.rect.center.x - w.rect.center.x) }
    }
}

/// The window after (positive) or before (negative) `id` in reading order: rows top to bottom,
/// columns left to right, stacks top to bottom. With `matching`, only those windows count.
public func overviewStep(_ layout: OverviewLayout, from id: String, by delta: Int, matching: Set<String>? = nil) -> String? {
    let all = layout.windows.map(\.id).filter { $0 == id || matching?.contains($0) ?? true }
    guard let i = all.firstIndex(of: id), all.indices.contains(i + delta) else { return nil }
    return all[i + delta]
}

private func nearest(_ windows: [OverviewWindow], by distance: (OverviewWindow) -> Double) -> String? {
    var best: (OverviewWindow, Double)?
    for w in windows {
        let d = distance(w)
        if best == nil || d < best!.1 - 1e-9 { best = (w, d) }
    }
    return best?.0.id
}
