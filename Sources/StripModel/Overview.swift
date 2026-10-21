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
    public var workspace: Int
    public var isActive: Bool
    public var rect: Rect
    public var windows: [OverviewWindow]
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

    public init() {}
}

/// Every workspace with windows, plus the active one, as scaled-down strips stacked top to bottom.
public struct OverviewLayout: Equatable, Sendable {
    public var scale: Double
    public var rows: [OverviewRow]
    /// How far the rows can pan sideways; zero when they all fit.
    public var panRange: Double
    public var screen: Size
    public var margin: Double

    public var windows: [OverviewWindow] { rows.flatMap(\.windows) }

    public func window(_ id: String) -> OverviewWindow? { windows.first { $0.id == id } }

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

/// Lays out the overview for a screen of `screen` points. Window rects keep each window's
/// proportions, since the whole strip scales by one factor. `floats` gives floating windows'
/// frames relative to the viewport's top-left; a floating window without one is left out.
public func overviewLayout(
    _ ws: Workspaces, _ m: StripMetrics, screen: Size, pan: Double = 0, style: OverviewStyle = OverviewStyle(),
    floats: [String: Rect] = [:]
) -> OverviewLayout {
    var local = m
    local.viewport = Rect(x: 0, y: 0, width: m.viewport.width, height: m.viewport.height)
    let shown = ws.strips.indices.filter {
        !ws.strips[$0].columns.isEmpty || ws.strips[$0].floating.contains { floats[$0] != nil } || $0 == ws.active
    }
    let widths = shown.map { max(local.columnOffsets(ws.strips[$0]).total, local.viewport.width) }
    let widest = max(1, widths.max() ?? 1)
    let n = Double(max(1, shown.count))
    let availW = max(1, screen.width - 2 * style.margin)
    let availH = max(1, screen.height - 2 * style.margin)

    let fitH = (availH - (n - 1) * style.rowGap) / (n * local.viewport.height)
    let fitW = availW / widest
    let scale = max(0.01, min(style.maxScale, fitH, max(style.minScale, fitW)))

    let contentW = widest * scale
    let rowH = local.viewport.height * scale
    let blockH = n * rowH + (n - 1) * style.rowGap
    let x0 = style.margin + max(0, (availW - contentW) / 2)
    let y0 = max(0, (screen.height - blockH) / 2)
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
        var column = strip.columns.count
        for id in strip.floating {
            guard let f = floats[id] else { continue }
            let rect = Rect(x: x0 - shift + f.x * scale, y: top + f.y * scale, width: f.width * scale, height: f.height * scale)
            windows.append(OverviewWindow(id: id, workspace: i, column: column, index: 0, rect: rect))
            column += 1
        }
        rows.append(OverviewRow(
            workspace: i, isActive: i == ws.active,
            rect: Rect(x: x0 - shift, y: top, width: widths[r] * scale, height: rowH), windows: windows))
    }
    return OverviewLayout(scale: scale, rows: rows, panRange: panRange, screen: screen, margin: style.margin)
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
/// Left and right move to the neighbouring column, landing on its window nearest in height.
/// Up and down walk the column's stack, then cross to the nearest row that has windows, landing
/// on the window whose centre is horizontally nearest.
public func overviewMove(_ layout: OverviewLayout, from id: String, _ d: Direction) -> String? {
    guard let w = layout.window(id), let row = layout.rows.firstIndex(where: { $0.workspace == w.workspace }) else { return nil }
    let here = layout.rows[row].windows
    switch d {
    case .left, .right:
        let column = w.column + (d == .left ? -1 : 1)
        return nearest(here.filter { $0.column == column }) { abs($0.rect.center.y - w.rect.center.y) }
    case .up, .down:
        let step = d == .up ? -1 : 1
        if let next = here.first(where: { $0.column == w.column && $0.index == w.index + step }) { return next.id }
        var r = row + step
        while layout.rows.indices.contains(r) {
            let candidates = layout.rows[r].windows
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
public func overviewEntry(_ layout: OverviewLayout, from id: String, _ d: Direction) -> String? {
    guard let w = layout.window(id), let row = layout.rows.first(where: { $0.workspace == w.workspace }) else { return nil }
    switch d {
    case .left, .right:
        let columns = row.windows.map(\.column)
        guard let edge = d == .right ? columns.min() : columns.max() else { return nil }
        return nearest(row.windows.filter { $0.column == edge }) { abs($0.rect.center.y - w.rect.center.y) }
    case .up, .down:
        let rows = layout.rows.filter { !$0.windows.isEmpty }
        guard let r = d == .down ? rows.first : rows.last else { return nil }
        return nearest(d == .down ? r.windows : r.windows.reversed()) { abs($0.rect.center.x - w.rect.center.x) }
    }
}

/// The window after (positive) or before (negative) `id` in reading order: rows top to bottom,
/// columns left to right, stacks top to bottom.
public func overviewStep(_ layout: OverviewLayout, from id: String, by delta: Int) -> String? {
    let all = layout.windows
    guard let i = all.firstIndex(where: { $0.id == id }), all.indices.contains(i + delta) else { return nil }
    return all[i + delta].id
}

private func nearest(_ windows: [OverviewWindow], by distance: (OverviewWindow) -> Double) -> String? {
    var best: (OverviewWindow, Double)?
    for w in windows {
        let d = distance(w)
        if best == nil || d < best!.1 - 1e-9 { best = (w, d) }
    }
    return best?.0.id
}
