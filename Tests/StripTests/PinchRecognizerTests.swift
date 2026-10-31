import Testing
@testable import StripEngine

@Suite struct PinchRecognizerTests {
    func four(_ spread: Double, x: Double = 0.5) -> [(x: Double, y: Double)] {
        [(x - spread, 0.5), (x + spread, 0.5), (x, 0.5 - spread), (x, 0.5 + spread)]
    }

    func five(_ spread: Double) -> [(x: Double, y: Double)] {
        four(spread) + [(0.5, 0.5)]
    }

    @Test func fiveFingerPinchDoesNotFireAgainWhenAFingerLifts() {
        var r = PinchRecognizer()
        #expect(r.feed(five(0.3), at: 0) == nil)
        #expect(r.feed(five(0.225), at: 0.15) == .pinchIn)
        #expect(r.feed(four(0.2), at: 0.16) == nil)
        #expect(r.feed(four(0.1), at: 0.17) == nil)
        #expect(r.feed(four(0.4), at: 0.18) == nil)
    }

    @Test func addingAFingerRestartsTheOrigin() {
        var r = PinchRecognizer()
        #expect(r.feed(four(0.3), at: 0) == nil)
        #expect(r.feed(five(0.2), at: 0.01) == nil)
        #expect(r.feed(five(0.18), at: 0.02) == nil)
        #expect(r.feed(five(0.15), at: 0.15) == .pinchIn)
    }

    @Test func liftingAFingerBeforeFiringRestartsTheOrigin() {
        var r = PinchRecognizer()
        #expect(r.feed(five(0.1), at: 0) == nil)
        #expect(r.feed(four(0.3), at: 0.01) == nil)
        #expect(r.feed(four(0.27), at: 0.02) == nil)
        #expect(r.feed(four(0.225), at: 0.15) == .pinchIn)
    }

    @Test func pinchInFiresOnce() {
        var r = PinchRecognizer()
        #expect(r.feed(four(0.3), at: 0) == nil)
        #expect(r.feed(four(0.225), at: 0.15) == .pinchIn)
        #expect(r.feed(four(0.1), at: 0.16) == nil)
        #expect(r.feed(four(0.5), at: 0.17) == nil)
    }

    @Test func spreadingFires() {
        var r = PinchRecognizer()
        #expect(r.feed(four(0.1), at: 0) == nil)
        #expect(r.feed(four(0.13), at: 0.01) == .spreadOut)
        #expect(r.feed(four(0.2), at: 0.02) == nil)
    }

    @Test(arguments: [3, 6]) func countsOutsideTheRangeDoNothing(count: Int) {
        var r = PinchRecognizer()
        for (i, spread) in [0.3, 0.1, 0.5].enumerated() {
            let contacts = four(spread) + [(0.5, 0.5), (0.5, 0.5)]
            #expect(r.feed(Array(contacts.prefix(count)), at: Double(i)) == nil)
        }
    }

    @Test func smallJitterAndTranslationDoNothing() {
        var r = PinchRecognizer()
        #expect(r.feed(four(0.2), at: 0) == nil)
        #expect(r.feed(four(0.176), at: 0.15) == nil)
        #expect(r.feed(four(0.21), at: 0.16) == nil)
        #expect(r.feed(four(0.2, x: 0.6), at: 0.17) == nil)
    }

    @Test(arguments: [3, 6]) func leavingTheRangeAllowsAnotherGesture(count: Int) {
        var r = PinchRecognizer()
        _ = r.feed(four(0.3), at: 0)
        #expect(r.feed(four(0.2), at: 0.01) == .pinchIn)
        let contacts = four(0.1) + [(0.5, 0.5), (0.5, 0.5)]
        #expect(r.feed(Array(contacts.prefix(count)), at: 0.02) == nil)
        #expect(r.feed(four(0.1), at: 0.03) == nil)
        #expect(r.feed(four(0.2), at: 0.04) == .spreadOut)
        #expect(r.feed([], at: 0.05) == nil)
        #expect(r.feed(four(0.3), at: 0.06) == nil)
        #expect(r.feed(four(0.2), at: 0.07) == .pinchIn)
    }

    @Test func coincidentContactsDoNotFire() {
        var r = PinchRecognizer()
        #expect(r.feed(four(0), at: 0) == nil)
        #expect(r.feed(four(0), at: 0.01) == nil)
        #expect(r.feed(four(0.1), at: 0.02) == nil)
    }
}
