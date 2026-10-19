import Testing
@testable import StripEngine

@Suite struct FocusRequestTests {
    /// Dia reports the asked window, then makes its other window key: focus goes back.
    @Test func theAppPickingAnotherOfItsWindowsIsOverridden() {
        var r = FocusRequest()
        r.asked("w6", app: 10, at: 100)
        #expect(r.overridden(by: "w6", app: 10, now: 100.01, secondsSinceInput: 1) == nil)
        #expect(r.overridden(by: "w7", app: 10, now: 100.04, secondsSinceInput: 1) == "w6")
    }

    @Test func anotherAppEndsTheRequest() {
        var r = FocusRequest()
        r.asked("w6", app: 10, at: 100)
        #expect(r.overridden(by: "w2", app: 20, now: 100.1, secondsSinceInput: 1) == nil)
        #expect(r.asked == nil)
        #expect(r.overridden(by: "w7", app: 10, now: 100.2, secondsSinceInput: 1) == nil)
    }

    @Test func aLateChangeIsFollowed() {
        var r = FocusRequest()
        r.asked("w6", app: 10, at: 100)
        #expect(r.overridden(by: "w7", app: 10, now: 100 + FocusIntent.ownWindow, secondsSinceInput: 5) == nil)
    }

    /// A click or key press after the request is the user's own choice.
    @Test func inputSinceTheRequestIsFollowed() {
        var r = FocusRequest()
        r.asked("w6", app: 10, at: 100)
        #expect(r.overridden(by: "w7", app: 10, now: 100.3, secondsSinceInput: 0.1) == nil)
    }

    @Test func aClearedRequestOverridesNothing() {
        var r = FocusRequest()
        r.asked("w6", app: 10, at: 100)
        r.clear()
        #expect(r.overridden(by: "w7", app: 10, now: 100.04, secondsSinceInput: 1) == nil)
    }
}
