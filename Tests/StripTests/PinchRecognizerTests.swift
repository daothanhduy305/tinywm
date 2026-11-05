import Foundation
import Testing
@testable import StripEngine

@Suite struct PinchRecognizerTests {
    /// `n` fingers on a circle of radius `spread`, so every finger moves when the spread changes.
    func hand(_ n: Int, _ spread: Double, x: Double = 0.5) -> [PinchRecognizer.Contact] {
        (0..<n).map { i in
            let a = Double(i) * 2 * .pi / Double(n)
            return (i, x + spread * cos(a), 0.5 + spread * sin(a))
        }
    }

    func four(_ spread: Double, x: Double = 0.5) -> [PinchRecognizer.Contact] { hand(4, spread, x: x) }
    func five(_ spread: Double, x: Double = 0.5) -> [PinchRecognizer.Contact] { hand(5, spread, x: x) }

    /// A palm resting at the pad's bottom-right corner.
    let palm: PinchRecognizer.Contact = (99, 0.99, 0.01)

    @Test func fourFingerPinchWorksWhenConfigured() {
        var r = PinchRecognizer()
        r.fingers = 4
        #expect(r.feed(four(0.3), at: 0, want: .pinchIn) == nil)
        #expect(r.feed(four(0.225), at: 0.15, want: .pinchIn) == .pinchIn)
        #expect(r.feed(four(0.1), at: 0.16, want: .pinchIn) == nil)
    }

    @Test func pinchInFiresOnce() {
        var r = PinchRecognizer()
        #expect(r.feed(five(0.3), at: 0, want: .pinchIn) == nil)
        #expect(r.feed(five(0.225), at: 0.15, want: .pinchIn) == .pinchIn)
        #expect(r.feed(five(0.1), at: 0.16, want: .pinchIn) == nil)
        #expect(r.feed(five(0.5), at: 0.17, want: .spreadOut) == nil)
    }

    @Test func spreadingFires() {
        var r = PinchRecognizer()
        #expect(r.feed(five(0.1), at: 0, want: .spreadOut) == nil)
        #expect(r.feed(five(0.13), at: 0.01, want: .spreadOut) == .spreadOut)
        #expect(r.feed(five(0.2), at: 0.02, want: .spreadOut) == nil)
    }

    @Test(arguments: [3, 4, 6]) func otherFingerCountsDoNothing(count: Int) {
        var r = PinchRecognizer()
        for (i, spread) in [0.3, 0.1, 0.5].enumerated() {
            #expect(r.feed(hand(count, spread), at: Double(i), want: .pinchIn) == nil)
        }
    }

    /// The case that made 4 fingers open the overview: a resting palm made the count 5.
    @Test func restingPalmDoesNotCountAsAFinger() {
        var r = PinchRecognizer()
        for (i, spread) in [0.3, 0.2, 0.1].enumerated() {
            #expect(r.feed(four(spread) + [palm], at: Double(i), want: .pinchIn) == nil)
        }
    }

    /// The case that stopped 5 fingers working: a resting palm made the count 6.
    @Test func fiveFingersPinchWithAPalmResting() {
        var r = PinchRecognizer()
        #expect(r.feed(five(0.3) + [palm], at: 0, want: .pinchIn) == nil)
        #expect(r.feed(five(0.225) + [palm], at: 0.15, want: .pinchIn) == .pinchIn)
    }

    /// A palm landing or lifting mid-pinch keeps the pinch's progress.
    @Test func palmLandingMidPinchKeepsProgress() {
        var r = PinchRecognizer()
        #expect(r.feed(five(0.3), at: 0, want: .pinchIn) == nil)
        #expect(r.feed(five(0.26) + [palm], at: 0.05, want: .pinchIn) == nil)
        #expect(r.feed(five(0.225), at: 0.1, want: .pinchIn) == .pinchIn)
    }

    /// A finger that only starts moving late still counts from where it landed.
    @Test func lateMovingFingerKeepsProgress() {
        var r = PinchRecognizer()
        var start = five(0.3)
        #expect(r.feed(start, at: 0, want: .pinchIn) == nil)
        var mid = five(0.26)
        mid[4] = start[4]
        #expect(r.feed(mid, at: 0.05, want: .pinchIn) == nil)
        start = five(0.225)
        #expect(r.feed(start, at: 0.1, want: .pinchIn) == .pinchIn)
    }

    @Test func smallJitterAndTranslationDoNothing() {
        var r = PinchRecognizer()
        #expect(r.feed(five(0.2), at: 0, want: .pinchIn) == nil)
        #expect(r.feed(five(0.176), at: 0.15, want: .pinchIn) == nil)
        #expect(r.feed(five(0.21), at: 0.16, want: .pinchIn) == nil)
        #expect(r.feed(five(0.2, x: 0.6), at: 0.17, want: .pinchIn) == nil)
    }

    @Test(arguments: [3, 4, 6]) func changingFingerCountAllowsAnotherGesture(count: Int) {
        var r = PinchRecognizer()
        _ = r.feed(five(0.3), at: 0, want: .pinchIn)
        #expect(r.feed(five(0.2), at: 0.01, want: .pinchIn) == .pinchIn)
        #expect(r.feed(hand(count, 0.1), at: 0.02, want: .spreadOut) == nil)
        #expect(r.feed(five(0.1), at: 0.03, want: .spreadOut) == nil)
        #expect(r.feed(five(0.2), at: 0.04, want: .spreadOut) == .spreadOut)
        #expect(r.feed([], at: 0.05, want: .pinchIn) == nil)
        #expect(r.feed(five(0.3), at: 0.06, want: .pinchIn) == nil)
        #expect(r.feed(five(0.2), at: 0.07, want: .pinchIn) == .pinchIn)
    }

    @Test func coincidentContactsDoNotFire() {
        var r = PinchRecognizer()
        #expect(r.feed(five(0), at: 0, want: .spreadOut) == nil)
        #expect(r.feed(five(0), at: 0.01, want: .spreadOut) == nil)
        #expect(r.feed(five(0.1), at: 0.02, want: .pinchIn) == nil)
    }

    /// Fingers settling outward first raise the baseline; the pinch counts from the widest point.
    @Test func spreadFirstThenPinchStillFires() {
        var r = PinchRecognizer()
        #expect(r.feed(five(0.3), at: 0, want: .pinchIn) == nil)
        #expect(r.feed(five(0.36), at: 0.01, want: .pinchIn) == nil)
        #expect(r.feed(five(0.28), at: 0.02, want: .pinchIn) == .pinchIn)
    }

    /// A spread while a pinch is wanted does not use up the touch.
    @Test func unwantedDirectionDoesNotBurnTheTouch() {
        var r = PinchRecognizer()
        #expect(r.feed(five(0.2), at: 0, want: .pinchIn) == nil)
        #expect(r.feed(five(0.3), at: 0.01, want: .pinchIn) == nil)
        #expect(r.feed(five(0.2), at: 0.02, want: .pinchIn) == .pinchIn)
    }
}
