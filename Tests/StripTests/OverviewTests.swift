import Testing
import WindowCore
@testable import StripModel

private let screenRect = Rect(x: 100, y: 50, width: 1000, height: 600)
private let metrics = StripMetrics(viewport: screenRect, gap: 10)
private let display = Size(width: 1000, height: 600)

private func column(_ id: String, _ windows: [String], _ width: Double = 0.5) -> Column {
    Column(id: id, windows: windows, width: width)
}

private func strip(_ columns: [Column], focus: Int? = 0) -> Strip {
    var s = Strip()
    s.columns = columns
    s.focusedColumn = focus
    return s
}

/// Rows: 0 empty top, 1 holds a,(b over c), 2 holds d, 3 empty bottom.
private func sample(active: Int = 1) -> Workspaces {
    var ws = Workspaces()
    ws.strips = [Strip(), strip([column("1", ["a"]), column("2", ["b", "c"])]), strip([column("3", ["d"])]), Strip()]
    ws.active = active
    return ws
}

@Suite struct OverviewLayoutTests {
    @Test func rowsAreWorkspacesWithWindowsPlusTheActiveOne() {
        #expect(overviewLayout(sample(), metrics, screen: display).rows.map(\.workspace) == [1, 2])
        #expect(overviewLayout(sample(active: 3), metrics, screen: display).rows.map(\.workspace) == [1, 2, 3])
    }

    @Test func windowsKeepTheirProportions() {
        let real = overviewRealFrames(sample(), metrics)
        let layout = overviewLayout(sample(), metrics, screen: display)
        for w in layout.windows {
            let r = real[w.id]!
            #expect(abs(w.rect.width / r.width - w.rect.height / r.height) < 1e-9)
            // Only stacked windows shrink below the overview's scale, to make room for labels.
            let stacked = w.id == "b" || w.id == "c"
            #expect(stacked ? w.rect.width / r.width < layout.scale : abs(w.rect.width / r.width - layout.scale) < 1e-9)
        }
    }

    @Test func stackedWindowsLeaveRoomForALabel() {
        let layout = overviewLayout(sample(), metrics, screen: display)
        let b = layout.window("b")!.rect, c = layout.window("c")!.rect, a = layout.window("a")!.rect
        #expect(c.y - b.maxY >= OverviewStyle().labelGap)
        // The stack still spans the same height as a lone window.
        #expect(abs(b.y - a.y) < 1e-9 && abs(c.maxY - a.maxY) < 1e-9)
    }

    @Test func scaleFitsAllRowsAndStaysUnderTheCap() {
        let layout = overviewLayout(sample(), metrics, screen: display)
        #expect(layout.scale <= 0.6)
        let style = OverviewStyle()
        for r in layout.rows {
            #expect(r.rect.y >= 0 && r.rect.maxY <= display.height)
            #expect(r.rect.x >= style.margin - 1e-9 && r.rect.maxX <= display.width - style.margin + 1e-9)
        }
        // A lone small strip on a big screen is capped.
        var one = Workspaces()
        one.strips = [strip([column("1", ["a"])])]
        #expect(overviewLayout(one, metrics, screen: Size(width: 4000, height: 3000)).scale == 0.6)
    }

    @Test func manyWorkspacesShrinkUntilEveryRowFits() {
        var ws = Workspaces()
        ws.strips = (0..<8).map { strip([column("c\($0)", ["w\($0)"])]) }
        let layout = overviewLayout(ws, metrics, screen: display)
        #expect(layout.rows.count == 8)
        #expect(layout.scale < OverviewStyle().minScale)
        for r in layout.rows { #expect(r.rect.y >= 0 && r.rect.maxY <= display.height) }
    }

    @Test func roomAboveTheRowsPushesThemDown() {
        let style = OverviewStyle(top: 80)
        let layout = overviewLayout(sample(), metrics, screen: display, style: style)
        #expect(layout.rows[0].rect.y >= style.margin + style.top - 1e-9)
        #expect(layout.rows.last!.rect.maxY <= display.height - style.margin + 1e-9)
    }

    @Test func rowsStackInWorkspaceOrderWithAGap() {
        let rows = overviewLayout(sample(), metrics, screen: display).rows
        #expect(rows[1].rect.y > rows[0].rect.maxY)
        #expect(abs(rows[1].rect.y - rows[0].rect.maxY - OverviewStyle().rowGap) < 1e-9)
    }

    @Test func stackedWindowsShareAColumn() {
        let layout = overviewLayout(sample(), metrics, screen: display)
        let b = layout.window("b")!, c = layout.window("c")!
        #expect(b.rect.x == c.rect.x && b.rect.y < c.rect.y)
        #expect(b.column == 1 && c.index == 1)
    }

    @Test func wideRowsStopShrinkingAndPan() {
        var ws = Workspaces()
        ws.strips = [strip((0..<20).map { column("c\($0)", ["w\($0)"], 0.5) })]
        let layout = overviewLayout(ws, metrics, screen: display)
        #expect(layout.scale == OverviewStyle().minScale)
        #expect(layout.panRange > 0)
        let panned = overviewLayout(ws, metrics, screen: display, pan: 100)
        #expect(abs(panned.window("w0")!.rect.x - (layout.window("w0")!.rect.x - 100)) < 1e-9)
        // Panning is clamped to the range.
        let far = overviewLayout(ws, metrics, screen: display, pan: 1e9)
        #expect(abs(far.rows[0].rect.maxX - (display.width - OverviewStyle().margin)) < 1e-6)
    }

    @Test func revealingPansJustEnoughAndClamps() {
        var ws = Workspaces()
        ws.strips = [strip((0..<20).map { column("c\($0)", ["w\($0)"], 0.5) })]
        let layout = overviewLayout(ws, metrics, screen: display)
        let pan = layout.pan(toReveal: "w19", current: 0)
        let shown = overviewLayout(ws, metrics, screen: display, pan: pan).window("w19")!.rect
        #expect(shown.maxX <= display.width - OverviewStyle().margin + 1e-6)
        #expect(layout.pan(toReveal: "w0", current: 0) == 0)
    }

    @Test func realFramesStackWorkspacesOneScreenApart() {
        let real = overviewRealFrames(sample(), metrics)
        #expect(real["a"]!.x == 10 && real["a"]!.y == 10)
        #expect(real["d"]!.y == real["a"]!.y + 600)
    }
}

@Suite struct OverviewNavigationTests {
    let layout = overviewLayout(sample(), metrics, screen: display)

    @Test func leftAndRightMoveBetweenColumnsAndStopAtEnds() {
        #expect(overviewMove(layout, from: "a", .right) != nil)
        #expect(overviewMove(layout, from: "a", .left) == nil)
        #expect(overviewMove(layout, from: "b", .right) == nil)
    }

    @Test func sidewaysLandsOnTheNearestHeight() {
        // a is full height, so its centre is between b and c; b is nearer to the top-biased tie.
        #expect(["b", "c"].contains(overviewMove(layout, from: "a", .right)!))
        #expect(overviewMove(layout, from: "c", .left) == "a")
    }

    @Test func verticalWalksTheStackThenCrossesRows() {
        #expect(overviewMove(layout, from: "b", .down) == "c")
        #expect(overviewMove(layout, from: "c", .up) == "b")
        #expect(overviewMove(layout, from: "c", .down) == "d")
        #expect(overviewMove(layout, from: "d", .up) == "a")
        #expect(overviewMove(layout, from: "d", .down) == nil)
        #expect(overviewMove(layout, from: "a", .up) == nil)
    }

    @Test func crossingRowsPicksTheHorizontallyNearestWindow() {
        var ws = Workspaces()
        ws.strips = [strip([column("1", ["a"]), column("2", ["b"]), column("3", ["c"])]),
                     strip([column("4", ["d"]), column("5", ["e"])])]
        let l = overviewLayout(ws, metrics, screen: display)
        #expect(overviewMove(l, from: "a", .down) == "d")
        #expect(overviewMove(l, from: "c", .down) == "e")
        #expect(overviewMove(l, from: "e", .up) == "b")
    }

    @Test func emptyRowsAreSkipped() {
        var ws = Workspaces()
        ws.strips = [strip([column("1", ["a"])]), Strip(), strip([column("2", ["b"])])]
        ws.active = 1
        let l = overviewLayout(ws, metrics, screen: display)
        #expect(l.rows.count == 3)
        #expect(overviewMove(l, from: "a", .down) == "b")
        #expect(overviewMove(l, from: "b", .up) == "a")
    }

    @Test func arrivingFromAnotherDisplayLandsOnTheNearEdge() {
        #expect(overviewEntry(layout, from: "c", .right) == "a")
        #expect(["b", "c"].contains(overviewEntry(layout, from: "a", .left)!))
        #expect(overviewEntry(layout, from: "d", .down) == "a")
        #expect(overviewEntry(layout, from: "a", .up) == "d")
    }

    @Test func stepFollowsReadingOrder() {
        #expect(overviewStep(layout, from: "a", by: 1) == "b")
        #expect(overviewStep(layout, from: "c", by: 1) == "d")
        #expect(overviewStep(layout, from: "a", by: -1) == nil)
    }

    @Test func arrowsSkipWindowsTheSearchDoesNotMatch() {
        // a | b over c on row 1, d on row 2.
        #expect(overviewMove(layout, from: "a", .down, matching: ["d"]) == "d")
        #expect(overviewMove(layout, from: "a", .right, matching: ["a", "d"]) == nil)
        #expect(overviewMove(layout, from: "a", .right, matching: ["c"]) == "c")
        #expect(overviewMove(layout, from: "b", .down, matching: ["d"]) == "d")
        #expect(overviewMove(layout, from: "d", .up, matching: ["b"]) == "b")
        // The start need not match.
        #expect(overviewMove(layout, from: "b", .left, matching: ["a"]) == "a")
    }

    @Test func enteringADisplayLandsOnlyOnAMatch() {
        #expect(overviewEntry(layout, from: "a", .right, matching: ["c"]) == "c")
        #expect(overviewEntry(layout, from: "a", .up, matching: ["a"]) == "a")
        #expect(overviewEntry(layout, from: "a", .right, matching: []) == nil)
    }

    @Test func stepSkipsWindowsTheSearchDoesNotMatch() {
        #expect(overviewStep(layout, from: "a", by: 1, matching: ["d"]) == "d")
        #expect(overviewStep(layout, from: "d", by: -1, matching: ["a", "d"]) == "a")
        #expect(overviewStep(layout, from: "d", by: 1, matching: ["a"]) == nil)
    }

    @Test func hitTestFindsTheWindowUnderThePoint() {
        let d = layout.window("d")!
        #expect(layout.window(at: d.rect.center)?.id == "d")
        #expect(layout.window(at: Point(x: 1, y: 1)) == nil)
    }
}

@Suite struct OverviewFloatingTests {
    /// The sample with floating "f" on workspace 1 and "g" alone on workspace 3.
    private func withFloats() -> (Workspaces, [String: Rect]) {
        var ws = sample()
        ws.strips[1].floating = ["f"]
        ws.strips[3].floating = ["g"]
        return (ws, ["f": Rect(x: 200, y: 100, width: 300, height: 200), "g": Rect(x: 0, y: 0, width: 400, height: 300)])
    }

    private let off = OverviewStyle(floating: .off)

    @Test func offShowsFloatingWindowsAtTheirPlaceAboveTheStrip() {
        let (ws, floats) = withFloats()
        let layout = overviewLayout(ws, metrics, screen: display, style: off, floats: floats)
        let row = layout.rows.first { $0.workspace == 1 }!
        let f = layout.window("f")!
        #expect(row.windows.last?.id == "f")
        #expect(f.column == 2)
        #expect(abs(f.rect.x - (row.rect.x + 200 * layout.scale)) < 1e-9)
        #expect(abs(f.rect.width - 300 * layout.scale) < 1e-9)
        #expect(layout.window(at: f.rect.center)?.id == "f")
    }

    @Test func offGivesAWorkspaceHoldingOnlyAFloatingWindowARow() {
        let (ws, floats) = withFloats()
        #expect(overviewLayout(ws, metrics, screen: display, style: off, floats: floats).rows.map(\.workspace) == [1, 2, 3])
        #expect(overviewLayout(ws, metrics, screen: display, style: off).rows.map(\.workspace) == [1, 2])
    }

    @Test func verticalShelfStacksEquallyWidePicturesOnTheRight() {
        let (ws, floats) = withFloats()
        let style = OverviewStyle()
        #expect(style.floating == .vertical)
        let layout = overviewLayout(ws, metrics, screen: display, floats: floats)
        // Workspace 3 holds only "g", so it gets no row of its own.
        #expect(layout.rows.map(\.workspace) == [1, 2, -1])
        let shelf = layout.rows.last!
        #expect(shelf.windows.map(\.id) == ["f", "g"])
        #expect(layout.window("g")!.workspace == 3)
        #expect(shelf.windows.allSatisfy { $0.rect.width == style.shelfSize })
        #expect(abs(layout.window("f")!.rect.height - 200.0 / 300 * style.shelfSize) < 1e-9)
        #expect(shelf.rect.maxX == display.width - style.shelfEdge)
        // The rows keep clear of it and it stays put while they pan.
        #expect(layout.rows.dropLast().allSatisfy { $0.rect.maxX <= shelf.rect.x - style.rowGap + 1e-9 })
        #expect(overviewLayout(ws, metrics, screen: display, pan: 500, floats: floats).rows.last == shelf)
        #expect(overviewMove(layout, from: "b", .right) == "f")
        #expect(overviewMove(layout, from: "f", .down) == "g")
        #expect(overviewMove(layout, from: "g", .down) == nil)
        #expect(["b", "c"].contains(overviewMove(layout, from: "f", .left)))
        #expect(overviewMove(layout, from: "d", .down) == nil)
        #expect(overviewStep(layout, from: "d", by: 1) == "f")
    }

    @Test func horizontalShelfLinesUpEquallyTallPicturesAtTheBottom() {
        let (ws, floats) = withFloats()
        let style = OverviewStyle(floating: .horizontal)
        let layout = overviewLayout(ws, metrics, screen: display, style: style, floats: floats)
        #expect(layout.rows.map(\.workspace) == [1, 2, -1])
        let shelf = layout.rows.last!
        #expect(shelf.windows.allSatisfy { $0.rect.height == style.shelfSize })
        #expect(shelf.rect.maxY == display.height - style.shelfEdge)
        #expect(layout.rows[1].rect.maxY <= shelf.rect.y - style.rowGap + 1e-9)
        #expect(overviewMove(layout, from: "d", .down) == "f")
        #expect(overviewMove(layout, from: "f", .right) == "g")
        #expect(overviewMove(layout, from: "g", .up) == "d")
    }

    @Test func fullscreenWindowsSitOnTheShelfAfterFloatingWindows() {
        let (ws, floats) = withFloats()
        let full = ["z": Rect(x: 0, y: -24, width: 800, height: 624), "y": Rect(x: 0, y: -24, width: 800, height: 624)]
        let layout = overviewLayout(ws, metrics, screen: display, floats: floats, fullScreen: full)
        let shelf = layout.rows.last!
        #expect(shelf.windows.map(\.id) == ["f", "g", "y", "z"])
        #expect(layout.window("z")!.workspace == -1)
        #expect(overviewMove(layout, from: "g", .down) == "y")
        // A fullscreen window alone still gets a shelf, but none when floating windows stay in place.
        #expect(overviewLayout(sample(), metrics, screen: display, fullScreen: full).rows.last?.workspace == -1)
        #expect(overviewLayout(ws, metrics, screen: display, style: off, floats: floats, fullScreen: full).window("z") == nil)
    }

    @Test func aShelfTooLongForTheScreenShrinksToFit() {
        var ws = sample()
        ws.strips[1].floating = (0..<8).map { "f\($0)" }
        let floats = Dictionary(uniqueKeysWithValues: ws.strips[1].floating.map { ($0, Rect(x: 0, y: 0, width: 400, height: 300)) })
        for floating in [OverviewFloating.vertical, .horizontal] {
            let shelf = overviewLayout(ws, metrics, screen: display, style: OverviewStyle(floating: floating), floats: floats).rows.last!
            #expect(shelf.rect.y >= 0 && shelf.rect.maxY <= display.height + 1e-9)
            #expect(shelf.rect.x >= 0 && shelf.rect.maxX <= display.width + 1e-9)
        }
    }

    @Test func floatingWindowsAreReachedByKeysAndHaveRealFrames() {
        let (ws, floats) = withFloats()
        let layout = overviewLayout(ws, metrics, screen: display, style: off, floats: floats)
        #expect(overviewMove(layout, from: "b", .right) == "f")
        #expect(overviewStep(layout, from: "c", by: 1) == "f")
        let real = overviewRealFrames(ws, metrics, floats: floats)
        #expect(real["f"] == floats["f"])
        #expect(real["g"]!.y == 2 * 600)
    }
}
