import Testing
@testable import StripEngine

@Suite struct PinchRecognizerTests {
    func four(_ spread: Double, x: Double = 0.5) -> [(x: Double, y: Double)] {
        [(x - spread, 0.5), (x + spread, 0.5), (x, 0.5 - spread), (x, 0.5 + spread)]
    }

    func five(_ spread: Double, x: Double = 0.5) -> [(x: Double, y: Double)] {
        four(spread, x: x) + [(x, 0.5)]
    }

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
            let contacts = five(spread) + [(0.5, 0.5)]
            #expect(r.feed(Array(contacts.prefix(count)), at: Double(i), want: .pinchIn) == nil)
        }
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
        let contacts = five(0.1) + [(0.5, 0.5)]
        #expect(r.feed(Array(contacts.prefix(count)), at: 0.02, want: .spreadOut) == nil)
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
