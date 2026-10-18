import StripEngine
import Testing

@Suite struct SwipeShieldTests {
    /// Feeds events with finger counts and returns which were dropped.
    private func drops(_ events: [(SwipeShield.Event, Int)], enabled: Bool = true) -> [Bool] {
        var s = SwipeShield()
        s.enabled = enabled
        return events.map { s.shouldDrop($0.0, touching: $0.1) }
    }

    @Test func dropsScrollsAndGesturesWithSwipeFingers() {
        #expect(drops([(.gesture, 3), (.scroll(phase: 1, momentum: 0), 3), (.gesture, 2)]) == [true, true, false])
    }

    @Test func keepsTwoFingerScrolls() {
        #expect(drops([(.scroll(phase: 1, momentum: 0), 2), (.scroll(phase: 2, momentum: 0), 2)]) == [false, false])
    }

    @Test func dropsTailAndMomentumUntilNextScroll() {
        let events: [(SwipeShield.Event, Int)] = [
            (.scroll(phase: 2, momentum: 0), 3), (.scroll(phase: 2, momentum: 0), 2),
            (.scroll(phase: 4, momentum: 0), 0), (.scroll(phase: 0, momentum: 1), 0),
            (.scroll(phase: 0, momentum: 3), 0), (.scroll(phase: 1, momentum: 0), 2),
        ]
        #expect(drops(events) == [true, true, true, true, true, false])
    }

    @Test func mouseWheelEndsSwallowing() {
        #expect(drops([(.scroll(phase: 2, momentum: 0), 3), (.scroll(phase: 0, momentum: 0), 0)]) == [true, false])
    }

    @Test func disabledPassesEverything() {
        #expect(drops([(.gesture, 3), (.scroll(phase: 2, momentum: 0), 3)], enabled: false) == [false, false])
    }
}
