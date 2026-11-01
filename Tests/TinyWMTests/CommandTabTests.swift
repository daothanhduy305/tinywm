import CoreGraphics
import ApplicationServices
import Testing
import WindowCore
@testable import WindowKit
@testable import tinywm

@MainActor @Suite struct CommandTabTests {
    private func event(_ type: CGEventType, key: Int = 48, flags: CGEventFlags = [], repeatKey: Bool = false) -> MetaKey.KeyEvent {
        MetaKey.KeyEvent(type: type, keyCode: key, isRepeat: repeatKey, flags: flags.rawValue,
                         location: Point(x: 0, y: 0))
    }

    @Test func cyclesWithShiftAndRepeatAndConfirmsOnlyWhenCommandIsReleased() {
        let key = MetaKey()
        key.commandTab = true
        var presses: [Bool] = []
        var releases = 0
        key.commandTabPressed = { presses.append($0) }
        key.commandTabReleased = { releases += 1 }

        #expect(key.handle(event(.keyDown, flags: .maskCommand)))
        #expect(key.handle(event(.keyDown, flags: .maskCommand, repeatKey: true)))
        #expect(key.handle(event(.keyDown, flags: [.maskCommand, .maskShift])))
        #expect(presses == [false, false, true])
        #expect(!key.handle(event(.flagsChanged, flags: .maskCommand)))
        #expect(releases == 0)
        #expect(!key.handle(event(.flagsChanged)))
        #expect(releases == 1)
        #expect(!key.handle(event(.flagsChanged)))
        #expect(releases == 1)
    }

    @Test func leavesOtherModifiersAndDedicatedMetaBindingsAlone() {
        let key = MetaKey()
        var presses = 0
        var releases = 0
        key.commandTabPressed = { _ in presses += 1 }
        key.commandTabReleased = { releases += 1 }
        #expect(!key.handle(event(.keyDown, flags: .maskCommand)))
        key.commandTab = true
        #expect(!key.handle(event(.keyDown, flags: [.maskCommand, .maskAlternate])))
        #expect(!key.handle(event(.keyDown, flags: [.maskCommand, .maskControl])))
        let rightCommand = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
        #expect(!key.handle(event(.flagsChanged, flags: rightCommand)))
        #expect(key.handle(event(.keyDown, flags: rightCommand)))
        #expect(!key.handle(event(.flagsChanged)))
        #expect(presses == 0)
        #expect(releases == 0)
    }

    @Test func offModeTakesOnlyPlainCommandTabWithoutRepeatOrRelease() {
        let key = MetaKey()
        key.commandTab = true
        key.switchOnRelease = false
        var presses: [Bool] = []
        var releases = 0
        key.commandTabPressed = { presses.append($0) }
        key.commandTabReleased = { releases += 1 }

        #expect(key.handle(event(.keyDown, flags: .maskCommand)))
        #expect(key.handle(event(.keyDown, flags: .maskCommand, repeatKey: true)))
        #expect(!key.handle(event(.keyDown, flags: [.maskCommand, .maskShift])))
        #expect(!key.handle(event(.flagsChanged)))
        #expect(key.handle(event(.keyDown, flags: .maskCommand)))
        #expect(!key.handle(event(.flagsChanged)))
        #expect(presses == [false, false])
        #expect(releases == 0)
    }

    @Test func turningOffSwitchOnReleaseDuringAChordDoesNotConfirm() {
        let key = MetaKey()
        key.commandTab = true
        var releases = 0
        key.commandTabReleased = { releases += 1 }
        #expect(key.handle(event(.keyDown, flags: .maskCommand)))
        key.switchOnRelease = false
        #expect(!key.handle(event(.flagsChanged)))
        #expect(releases == 0)
    }

    private func track(_ windows: AXWindows, _ pid: Int32) -> String {
        windows.id(for: AXUIElementCreateApplication(pid), pid: pid, known: (frame: nil, title: nil))
    }

    @Test func focusHistoryIgnoresNilAndRepeatedReportsAndSkipsClosedWindows() {
        let windows = AXWindows()
        let a = track(windows, 2_000_001), b = track(windows, 2_000_002), c = track(windows, 2_000_003)
        windows.noteFocused(a)
        #expect(windows.previousFocus == nil)
        windows.noteFocused(b)
        #expect(windows.previousFocus == a)
        windows.noteFocused(nil)
        windows.noteFocused(b)
        #expect(windows.focusHistory == [b, a])
        windows.noteFocused(c)
        #expect(windows.previousFocus == b)
        windows.forget(b)
        #expect(windows.previousFocus == a)
        windows.noteFocused(a)
        #expect(windows.focusHistory == [a, c])
        #expect(windows.previousFocus == c)
        windows.forget(c)
        #expect(windows.previousFocus == nil)
    }

    @Test func restoredHistoryKeepsTheCurrentWindowAndSchedulesChanges() {
        for currentKnown in [false, true] {
            let windows = AXWindows()
            let current = track(windows, 2_000_001), previous = track(windows, 2_000_002)
            if currentKnown { windows.noteFocused(current) }
            var changes = 0
            windows.onFocusHistoryChanged = { changes += 1 }
            windows.restoreFocusHistory([current, previous])
            windows.noteFocused(current)
            windows.noteFocused(nil)
            windows.noteFocused(current)
            #expect(windows.previousFocus == previous)
            #expect(changes == 1)
            windows.noteFocused(previous)
            #expect(windows.previousFocus == current)
            #expect(changes == 2)
        }
    }

    @Test func focusHistoryIsBoundedAndKeepsMostRecentWindows() {
        let windows = AXWindows()
        for i in 0..<25 { windows.noteFocused("window\(i)") }
        #expect(windows.focusHistory == (5..<25).reversed().map { "window\($0)" })
    }

    @Test func controlDownCancelsOnlyAnOpenOverviewWithoutRepeating() {
        let key = MetaKey()
        var open = false
        var cancels = 0
        key.canCancelOverview = { open }
        key.cancelOverview = { cancels += 1 }
        let flags: CGEventFlags = [.maskControl, .maskNumericPad, .maskSecondaryFn]
        #expect(!key.handle(event(.keyDown, key: 125, flags: flags)))
        #expect(cancels == 0)
        open = true
        #expect(key.handle(event(.keyDown, key: 125, flags: .maskControl)))
        #expect(key.handle(event(.keyDown, key: 125, flags: flags, repeatKey: true)))
        #expect(cancels == 1)
        #expect(key.handle(event(.keyDown, key: 125, flags: flags)))
        for extra: CGEventFlags in [.maskShift, .maskAlternate, .maskCommand] {
            #expect(!key.handle(event(.keyDown, key: 125, flags: flags.union(extra))))
        }
        #expect(!key.handle(event(.keyDown, key: 125, flags: [.maskNumericPad, .maskSecondaryFn])))
        #expect(!key.handle(event(.keyUp, key: 125, flags: flags)))
        #expect(cancels == 2)
        open = false
        #expect(!key.handle(event(.keyDown, key: 125, flags: flags)))
        #expect(!key.handle(event(.keyDown, key: 125, flags: flags, repeatKey: true)))
        #expect(cancels == 2)
    }

    @Test func controlDownOpensAppOverviewOnlyWhenEnabledAndClosed() {
        let key = MetaKey()
        var open = false
        var opens = 0
        var cancels = 0
        key.canCancelOverview = { open }
        key.cancelOverview = { cancels += 1 }
        key.openAppOverview = { opens += 1; open = true }
        let flags: CGEventFlags = [.maskControl, .maskNumericPad, .maskSecondaryFn]
        #expect(!key.handle(event(.keyDown, key: 125, flags: flags)))
        key.controlDown = true
        #expect(key.handle(event(.keyDown, key: 125, flags: flags, repeatKey: true)))
        #expect(opens == 0)
        for extra: CGEventFlags in [.maskShift, .maskAlternate, .maskCommand] {
            #expect(!key.handle(event(.keyDown, key: 125, flags: flags.union(extra))))
        }
        #expect(!key.handle(event(.keyDown, key: 125)))
        #expect(!key.handle(event(.keyUp, key: 125, flags: flags)))
        #expect(key.handle(event(.keyDown, key: 125, flags: flags)))
        #expect(opens == 1)
        #expect(key.handle(event(.keyDown, key: 125, flags: flags, repeatKey: true)))
        #expect(cancels == 0)
        #expect(key.handle(event(.keyDown, key: 125, flags: flags)))
        #expect(cancels == 1)
        #expect(opens == 1)
    }

    @Test func controlUpClearsExposeStateEvenWithoutAnExitNotification() {
        let key = MetaKey()
        let expose = ExposeWatcher()
        key.exposeShowing = { expose.isShowing }
        var closes = 0
        var opens = 0
        key.closeExpose = { closes += 1; expose.closed() }
        let registry = ShortcutRegistry.shared
        registry.register(action: "overview", defaultKey: nil, handler: { opens += 1 })
        defer { registry.unregister { $0 == "overview" } }
        let up = event(.keyDown, key: 126, flags: .maskControl)
        for notification in ["AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeShowDesktop"] {
            expose.received(notification)
            #expect(expose.isShowing)
            key.controlUp = false
            #expect(!key.handle(up))
            key.controlUp = true
            #expect(key.handle(up))
            #expect(key.handle(event(.keyDown, key: 126, flags: .maskControl, repeatKey: true)))
            #expect(!expose.isShowing)
            #expect(key.handle(up))
            expose.received("AXExposeExit")
            #expect(!expose.isShowing)
        }
        #expect(closes == 3)
        #expect(opens == 3)
    }

    @Test func controlUpIsTakenOnlyWhenEnabledWithOnlyControlAndDoesNotRepeat() {
        let key = MetaKey()
        let registry = ShortcutRegistry.shared
        var actions = 0
        registry.register(action: "overview", defaultKey: nil, handler: { actions += 1 })
        defer { registry.unregister { $0 == "overview" } }
        let flags: CGEventFlags = [.maskControl, .maskNumericPad, .maskSecondaryFn]
        #expect(!key.handle(event(.keyDown, key: 126, flags: flags)))
        key.controlUp = true
        #expect(key.handle(event(.keyDown, key: 126, flags: .maskControl)))
        #expect(key.handle(event(.keyDown, key: 126, flags: flags)))
        #expect(key.handle(event(.keyDown, key: 126, flags: flags, repeatKey: true)))
        #expect(actions == 2)
        for extra: CGEventFlags in [.maskShift, .maskAlternate, .maskCommand] {
            #expect(!key.handle(event(.keyDown, key: 126, flags: flags.union(extra))))
        }
        #expect(!key.handle(event(.keyDown, key: 126, flags: [.maskNumericPad, .maskSecondaryFn])))
        #expect(!key.handle(event(.keyDown, key: 125, flags: flags)))
        #expect(actions == 2)
    }
}
