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
        #expect(r.feed(four(0.3), at: 0) == nil)
        #expect(r.feed(four(0.225), at: 0.15) == .pinchIn)
        #expect(r.feed(four(0.1), at: 0.16) == nil)
    }

    @Test func pinchInFiresOnce() {
        var r = PinchRecognizer()
        #expect(r.feed(five(0.3), at: 0) == nil)
        #expect(r.feed(five(0.225), at: 0.15) == .pinchIn)
        #expect(r.feed(five(0.1), at: 0.16) == nil)
        #expect(r.feed(five(0.5), at: 0.17) == nil)
    }

    @Test func spreadingFires() {
        var r = PinchRecognizer()
        #expect(r.feed(five(0.1), at: 0) == nil)
        #expect(r.feed(five(0.13), at: 0.01) == .spreadOut)
        #expect(r.feed(five(0.2), at: 0.02) == nil)
    }

    @Test(arguments: [3, 4, 6]) func otherFingerCountsDoNothing(count: Int) {
        var r = PinchRecognizer()
        for (i, spread) in [0.3, 0.1, 0.5].enumerated() {
            let contacts = five(spread) + [(0.5, 0.5)]
            #expect(r.feed(Array(contacts.prefix(count)), at: Double(i)) == nil)
        }
    }

    @Test func smallJitterAndTranslationDoNothing() {
        var r = PinchRecognizer()
        #expect(r.feed(five(0.2), at: 0) == nil)
        #expect(r.feed(five(0.176), at: 0.15) == nil)
        #expect(r.feed(five(0.21), at: 0.16) == nil)
        #expect(r.feed(five(0.2, x: 0.6), at: 0.17) == nil)
    }

    @Test(arguments: [3, 4, 6]) func changingFingerCountAllowsAnotherGesture(count: Int) {
        var r = PinchRecognizer()
        _ = r.feed(five(0.3), at: 0)
        #expect(r.feed(five(0.2), at: 0.01) == .pinchIn)
        let contacts = five(0.1) + [(0.5, 0.5)]
        #expect(r.feed(Array(contacts.prefix(count)), at: 0.02) == nil)
        #expect(r.feed(five(0.1), at: 0.03) == nil)
        #expect(r.feed(five(0.2), at: 0.04) == .spreadOut)
        #expect(r.feed([], at: 0.05) == nil)
        #expect(r.feed(five(0.3), at: 0.06) == nil)
        #expect(r.feed(five(0.2), at: 0.07) == .pinchIn)
    }

    @Test func coincidentContactsDoNotFire() {
        var r = PinchRecognizer()
        #expect(r.feed(five(0), at: 0) == nil)
        #expect(r.feed(five(0), at: 0.01) == nil)
        #expect(r.feed(five(0.1), at: 0.02) == nil)
    }
}
