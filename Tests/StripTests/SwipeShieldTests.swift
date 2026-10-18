import StripEngine
import Testing

@Suite struct SwipeShieldTests {
    /// Feeds events with finger counts and returns which were dropped. Each time the pad empties,
    /// the next touch gets a new number, as `Multitouch` counts them.
    private func drops(_ events: [(SwipeShield.Event, Int)], fingers: Int = 3, enabled: Bool = true) -> [Bool] {
        var s = SwipeShield()
        s.fingers = fingers
        s.enabled = enabled
        var touch = 1, empty = false
        return events.map { e, fingers in
            if fingers > 0 && empty { touch += 1 }
            empty = fingers == 0
            return s.shouldDrop(e, touching: fingers, touch: touch)
        }
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

    /// Recorded on a trackpad: lifting fingers unevenly, macOS ends the scroll and begins a new one
    /// with the two fingers left, then coasts with momentum.
    @Test func dropsScrollRestartedAsFingersLift() {
        let events: [(SwipeShield.Event, Int)] = [
            (.scroll(phase: 1, momentum: 0), 4), (.scroll(phase: 2, momentum: 0), 3),
            (.scroll(phase: 4, momentum: 0), 2), (.scroll(phase: 1, momentum: 0), 2),
            (.scroll(phase: 0, momentum: 1), 2), (.scroll(phase: 4, momentum: 0), 0),
            (.scroll(phase: 0, momentum: 2), 0), (.scroll(phase: 0, momentum: 3), 0),
            (.scroll(phase: 1, momentum: 0), 2),
        ]
        #expect(drops(events, fingers: 4) == [true, true, true, true, true, true, true, true, false])
    }

    @Test func mouseWheelEndsSwallowing() {
        #expect(drops([(.scroll(phase: 2, momentum: 0), 3), (.scroll(phase: 0, momentum: 0), 0)]) == [true, false])
    }

    @Test func disabledPassesEverything() {
        #expect(drops([(.gesture, 3), (.scroll(phase: 2, momentum: 0), 3)], enabled: false) == [false, false])
    }
}
