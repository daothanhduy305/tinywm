import WindowCore

/// How far the screen scrolls when focus moves.
public enum ScrollMode: String, Codable, Sendable {
    /// Scroll only as much as needed to show the whole focused column.
    case fit
    /// Always centre the focused column.
    case center
}

/// The least of a column next to another display worth showing; less than this hides it.
public let minPeek = 100.0

/// Screen frames for every window on the strip, in Accessibility coordinates.
///
/// Columns outside the screen are pushed just past the screen edge with a thin sliver showing.
/// Real positions further out could land on a neighbouring display, so a column that would
/// reach one is narrowed to the part on screen, or hidden at a spot `hideaway` finds clear of
/// it when less than `minPeek` points would show. Without `trim` it is always hidden, and
/// `blockedPeeks` gives the part on screen for a card to stand in.
public func stripFrames(
    _ strip: Strip, _ m: StripMetrics, sliver: Double = 2, clamp: Bool = true, trim: Bool = true,
    hideaway: Hideaway? = nil
) -> [String: Rect] {
    let (lefts, _) = m.columnOffsets(strip)
    let v = m.viewport
    let hideaway = hideaway ?? Hideaway(screen: v)
    var out: [String: Rect] = [:]
    for (i, column) in strip.columns.enumerated() {
        let w = m.width(of: column)
        let x = v.x + lefts[i] - strip.scroll

        let n = Double(column.windows.count)
        let h = max(1, (v.height - m.gap * (n + 1)) / n)
        for (j, window) in column.windows.enumerated() {
            var r = Rect(x: x, y: v.y + m.gap + Double(j) * (h + m.gap), width: w, height: h)
            if clamp {
                if r.maxX <= v.x {
                    r = hideaway.sliver(r, pastRight: false, sliver: sliver)
                } else if r.x >= v.maxX {
                    r = hideaway.sliver(r, pastRight: true, sliver: sliver)
                } else if (r.x < v.x || r.maxX > v.maxX), hideaway.touchesOthers(r) {
                    // ponytail: an app whose minimum width is above the trimmed width still widens onto
                    // the neighbour; hide instead when its learned minimum is wider, if that bites.
                    let left = max(r.x, v.x), right = min(r.maxX, v.maxX)
                    if !trim || right - left < minPeek {
                        r = hideaway.sliver(r, pastRight: r.x >= v.x, sliver: sliver)
                    } else {
                        r.x = left
                        r.width = right - left
                    }
                }
            }
            out[window] = r
        }
    }
    return out
}

/// The part on screen of each window `stripFrames` would trim beside another display.
public func blockedPeeks(_ strip: Strip, _ m: StripMetrics, hideaway: Hideaway? = nil) -> [String: Rect] {
    let full = stripFrames(strip, m, clamp: false)
    return stripFrames(strip, m, hideaway: hideaway).filter { id, r in
        full[id].map { r.width < $0.width - 0.5 } ?? false
    }
}

/// The scroll offset that shows the focused column, keeping the strip flush with the screen edges.
public func scrollToFocus(_ strip: Strip, _ m: StripMetrics, mode: ScrollMode) -> Double {
    guard let f = strip.focusedColumn, strip.columns.indices.contains(f) else { return 0 }
    let (lefts, total) = m.columnOffsets(strip)
    let viewW = m.viewport.width
    let left = lefts[f] - m.gap
    let right = lefts[f] + m.width(of: strip.columns[f]) + m.gap

    var scroll = strip.scroll
    switch mode {
    case .center:
        scroll = (left + right) / 2 - viewW / 2
    case .fit:
        if left < scroll { scroll = left }
        if right > scroll + viewW { scroll = right - viewW }
    }
    // A strip narrower than the screen sits flush left; a wider one never shows empty space past its ends.
    return max(0, min(scroll, max(0, total - viewW)))
}

/// Scrolls after the focused column changed width, keeping the view the user had before it grew.
///
/// Growing a column remembers the old scroll if the strip has to move. Shrinking it back to that
/// width or narrower returns to that scroll, so full width on and off, or cycling widths, leaves
/// the same windows on screen as before. Other moves fall back to `scrollToFocus`.
public func scrollAfterResize(_ before: Strip, _ after: Strip, _ m: StripMetrics, mode: ScrollMode) -> Strip {
    var s = after
    guard let f = after.focusedColumn, let b = before.focusedColumn,
          after.columns.indices.contains(f), before.columns.indices.contains(b),
          after.columns[f].id == before.columns[b].id else {
        s.scroll = scrollToFocus(s, m, mode: mode)
        return s
    }
    let column = after.columns[f].id
    let oldWidth = before.columns[b].width
    let newWidth = after.columns[f].width
    if let memory = s.viewBeforeGrow, memory.column != column { s.viewBeforeGrow = nil }

    if newWidth < oldWidth, let memory = s.viewBeforeGrow, newWidth <= memory.width + 1e-9 {
        s.scroll = memory.scroll
        s.viewBeforeGrow = nil
    }
    let fitted = scrollToFocus(s, m, mode: mode)
    if newWidth > oldWidth, s.viewBeforeGrow == nil, abs(fitted - before.scroll) > 0.5 {
        s.viewBeforeGrow = ViewMemory(column: column, scroll: before.scroll, width: oldWidth)
    }
    s.scroll = fitted
    return s
}

/// Scroll positions a swipe can settle on: each column flush with the screen's left edge,
/// plus the strip's end, all kept inside the strip. With `.center`, each column centred instead.
public func snapPoints(_ strip: Strip, _ m: StripMetrics, mode: ScrollMode = .fit) -> [Double] {
    if mode == .center { return Array(Set(strip.columns.indices.map { centredScroll(strip, m, column: $0) })).sorted() }
    let (lefts, total) = m.columnOffsets(strip)
    let maxScroll = max(0, total - m.viewport.width)
    var points = lefts.map { max(0, min(maxScroll, $0 - m.gap)) }
    points.append(maxScroll)
    return Array(Set(points)).sorted()
}

/// The scroll that centres `column`, as far as the strip's ends allow.
public func centredScroll(_ strip: Strip, _ m: StripMetrics, column: Int) -> Double {
    var s = strip
    s.focusedColumn = column
    return scrollToFocus(s, m, mode: .center)
}
