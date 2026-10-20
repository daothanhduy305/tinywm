import Testing
import WindowCore
@testable import StripEngine
@testable import StripModel

@Suite struct ColumnMinimumTests {
    let m = StripMetrics(viewport: Rect(x: 0, y: 0, width: 1200, height: 600), gap: 0, minimums: ["s": 600, "huge": 5000])

    @Test func aColumnWidensToItsWindowsMinimum() {
        #expect(m.width(of: Column(id: "c", windows: ["a"], width: 0.333)) == m.columnWidth(0.333))
        #expect(m.width(of: Column(id: "c", windows: ["a", "s"], width: 0.333)) == 600)
        #expect(m.width(of: Column(id: "c", windows: ["s"], width: 0.667)) == m.columnWidth(0.667))
    }

    @Test func aColumnNarrowsToItsWindowsMaximumButAMinimumWins() {
        let m = StripMetrics(viewport: m.viewport, gap: 0, minimums: ["s": 600], maximums: ["t": 500, "s": 400])
        #expect(m.width(of: Column(id: "c", windows: ["t"], width: 0.667)) == 500)
        #expect(m.width(of: Column(id: "c", windows: ["t"], width: 0.333)) == m.columnWidth(0.333))
        #expect(m.width(of: Column(id: "c", windows: ["s"], width: 0.667)) == 600)
    }

    @Test func aMinimumNeverWidensAColumnPastTheScreen() {
        #expect(m.width(of: Column(id: "c", windows: ["huge"], width: 0.333)) == 1200)
    }
}

/// Windows whose apps refuse widths below a minimum or above a maximum, as real apps do.
@MainActor
final class StubbornWindows: WindowSystem {
    var frames: [String: Rect] = [:]
    var focusedWindow: String?
    var minimums: [String: Double] = [:]
    var maximums: [String: Double] = [:]
    /// Report the frame from before the next write, as an app still busy with the change does.
    var staleOnce: Set<String> = []
    /// Points added to a frame that starts left of the screen, as macOS does to a window it would leave almost hidden.
    var growOffLeft = 0.0
    private(set) var asked: [String: [Double]] = [:]

    func setFrame(_ id: String, _ rect: Rect, completion: @escaping @MainActor (Rect?) -> Void) {
        asked[id, default: []].append(rect.width)
        let before = frames[id]
        let grow = rect.x < 0 ? growOffLeft : 0
        let took = Rect(x: rect.x - grow, y: rect.y, width: max(min(rect.width, maximums[id] ?? .infinity), minimums[id] ?? 0) + grow, height: rect.height)
        frames[id] = took
        if staleOnce.remove(id) != nil, let before { completion(before) } else { completion(took) }
    }
    func focus(_ id: String) { focusedWindow = id }
    func frameOf(_ id: String) -> Rect? { frames[id] }
}

@MainActor
@Suite struct ColumnFitTests {
    let display = TiledDisplay(id: "A", frame: Rect(x: 0, y: 0, width: 1200, height: 600),
                               visible: Rect(x: 0, y: 0, width: 1200, height: 600))
    let apps = ["s": "slack", "s2": "slack"]

    func make() -> (StripDisplays, StubbornWindows) {
        let w = StubbornWindows()
        w.minimums = ["s": 600, "s2": 600]
        let d = StripDisplays(windows: w, configure: { _, _ in }, discard: { _ in })
        d.settings.gap = 0
        d.appOf = { [apps] id in apps[id] ?? "app.\(id)" }
        d.update([display])
        return (d, w)
    }

    func add(_ d: StripDisplays, _ w: StubbornWindows, _ ids: [String]) {
        for id in ids {
            w.frames[id] = Rect(x: 100, y: 100, width: 300, height: 300)
            w.focusedWindow = id
            d.windowAdded(id, frame: w.frames[id])
        }
    }

    @Test func aRefusedWidthWidensTheColumnSoItsNeighbourMovesAside() {
        let (d, w) = make()
        add(d, w, ["a", "s", "b"])
        let s = w.frames["s"]!, b = w.frames["b"]!
        #expect(s.width == 600)
        #expect(b.x >= s.maxX)
    }

    @Test func aRefusedWiderWidthNarrowsTheColumnSoItsNeighbourMovesIn() {
        let (d, w) = make()
        w.maximums = ["t": 300]
        add(d, w, ["t", "b"])
        let t = w.frames["t"]!, b = w.frames["b"]!
        #expect(t.width == 300)
        #expect(b.x == t.maxX)
    }

    @Test func aNarrowedLastColumnLeavesNoEmptySpaceAtTheScreensEdge() {
        // A clock, as in the app, so the refusal is confirmed after the layout's writes finish.
        let clock = TestClock()
        let w = StubbornWindows()
        w.maximums = ["t": 300]
        let d = StripDisplays(windows: w, configure: { e, _ in e.clock = clock }, discard: { _ in })
        d.settings.gap = 0
        d.appOf = { "app.\($0)" }
        d.update([display])
        add(d, w, ["a", "b", "c", "t"])
        clock.advance(by: 0.3)
        #expect(w.frames["t"]!.width == 300)
        #expect(abs(w.frames["t"]!.maxX - 1200) < 0.01)
        #expect(abs(w.frames["c"]!.maxX - w.frames["t"]!.x) < 0.01)
    }

    @Test func aNewShareOrScreenAsksTheWindowAgain() {
        let (d, w) = make()
        add(d, w, ["s"])
        let e = d.engine(holding: "s")!
        #expect(w.frames["s"]!.width == 600)
        // The app now allows narrow widths: each new share is asked for, and taken.
        w.minimums = [:]
        e.cycleWidth()
        e.cycleWidth()
        #expect(abs(w.frames["s"]!.width - 800) < 1)
        e.cycleWidth()
        #expect(abs(w.frames["s"]!.width - 400) < 1)
        w.minimums = ["s": 600]
        e.viewport = Rect(x: 0, y: 0, width: 900, height: 600)
        #expect(w.frames["s"]!.width == 600)
        w.minimums = [:]
        e.viewport = Rect(x: 0, y: 0, width: 1500, height: 600)
        #expect(abs(w.frames["s"]!.width - 500) < 1)
    }

    @Test func anAppStillBusyWithTheChangeChangesNothing() {
        let (d, w) = make()
        // The first report after the write still shows the old 900-point width, which looks
        // like a refusal of the 400 asked; the read a moment later shows the write took.
        w.frames["a"] = Rect(x: 100, y: 100, width: 900, height: 300)
        w.staleOnce = ["a"]
        w.focusedWindow = "a"
        d.windowAdded("a", frame: w.frames["a"])
        #expect(w.staleOnce.isEmpty)
        #expect(w.frames["a"]!.width < 900)
        #expect(d.engine(holding: "a")!.metrics.minimums.isEmpty)
    }

    @Test func anAppsNextWindowOpensAtItsLastClosedWidth() {
        let (d, w) = make()
        var saved: [String: Double]?
        d.onWidthsChanged = { saved = $0 }
        add(d, w, ["s"])
        let e = d.engine(holding: "s")!
        e.cycleWidth()
        let width = e.strip.columns[e.strip.column(of: "s")!].width
        #expect(width != d.settings.defaultWidth)
        d.windowRemoved("s")
        #expect(saved?["slack"] == width)
        add(d, w, ["s2", "a"])
        #expect(e.strip.columns[e.strip.column(of: "s2")!].width == width)
        #expect(e.strip.columns[e.strip.column(of: "a")!].width == d.settings.defaultWidth)
    }

    @Test func aFrameOffTheScreenFitsNothing() {
        let (d, w) = make()
        w.growOffLeft = 21
        add(d, w, ["a", "b", "c", "e", "f"])
        #expect(w.frames["a"]!.x < 0)
        #expect(d.engine(holding: "a")!.metrics.minimums.isEmpty)
    }

    @Test func aWindowTrimmedBesideAnotherDisplayFitsNothing() {
        let w = StubbornWindows()
        w.minimums = ["s": 600]
        let d = StripDisplays(windows: w, configure: { _, _ in }, discard: { _ in })
        d.settings.gap = 0
        d.settings.defaultWidth = 0.7
        d.appOf = { [apps] id in apps[id] ?? "app.\(id)" }
        d.update([display, TiledDisplay(id: "B", frame: Rect(x: 1200, y: 0, width: 1200, height: 600),
                                        visible: Rect(x: 1200, y: 0, width: 1200, height: 600))])
        add(d, w, ["a", "s"])
        let e = d.engine(holding: "s")!
        e.focus(.left)
        // s is trimmed to the 360 points left of display B; it refuses that, wanting 600.
        #expect(e.isTrimmed("s"))
        #expect(w.asked["s"]?.last == 360)
        #expect(e.metrics.minimums.isEmpty)
    }

    @Test func withPeekCoversABlockedWindowHidesAndTheEngineReportsItsCard() {
        let w = StubbornWindows()
        let d = StripDisplays(windows: w, configure: { _, _ in }, discard: { _ in })
        d.settings.gap = 0
        d.settings.defaultWidth = 0.7
        d.settings.peekCovers = true
        d.update([display, TiledDisplay(id: "B", frame: Rect(x: 1200, y: 0, width: 1200, height: 600),
                                        visible: Rect(x: 1200, y: 0, width: 1200, height: 600))])
        add(d, w, ["a", "b"])
        let e = d.engine(holding: "b")!
        let presenter = FakePresenter()
        e.presenter = presenter
        e.focus(.left)
        #expect(e.peeks == ["b": Rect(x: 840, y: 0, width: 360, height: 600)])
        #expect(w.frames["b"].map { $0.width == 840 && ($0.maxX <= 2 || $0.x >= 1198) } == true)
        #expect(!e.isTrimmed("b"))
        // The picture slides to the card's spot on the strip, not to where the window hides.
        let card = Rect(x: 840, y: 0, width: 840, height: 600)
        #expect(presenter.begun.last?.moves["b"]?.to == card)
        #expect(e.peekStrip == ["b": card])
        e.focus(.right)
        #expect(e.peeks.isEmpty)
        #expect(e.peekStrip.isEmpty)
        #expect(presenter.begun.last?.moves["b"]?.from == card)
        #expect(w.frames["b"] == Rect(x: 360, y: 0, width: 840, height: 600))
    }
}
