import AppKit
import StripEngine

/// The overview's click-capturing panel. It becomes key without activating tinywm, so plain keys
/// reach it and none reach the app in front.
final class OverviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Reads the keys, pointer and scrolling the overview reacts to. Points are top-left based.
final class OverviewView: NSView {
    typealias Key = OverviewCommand

    var keys = OverviewKeys()
    var onKey: (Key) -> Void = { _ in }
    var onHover: (CGPoint) -> Void = { _ in }
    var onExit: () -> Void = {}
    var onClick: (CGPoint) -> Void = { _ in }
    var onScroll: (CGFloat) -> Void = { _ in }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    // A click on a display whose overview does not have the keys still picks a window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func keyDown(with event: NSEvent) {
        let held = event.modifierFlags.intersection([.command, .control, .option])
        guard held.isEmpty, let key = keys.command(keyCode: Int(event.keyCode), shift: event.modifierFlags.contains(.shift)) else { return }
        onKey(key)
    }

    // The key panel hears every move, even with the pointer on another display, and an event's
    // location can be relative to another panel. So the pointer is read from the screen.
    override func mouseMoved(with event: NSEvent) {
        guard let p = pointer() else { return }
        if bounds.contains(p) { onHover(p) } else { onExit() }
    }
    override func mouseExited(with event: NSEvent) { onExit() }
    override func mouseDown(with event: NSEvent) {
        if let p = pointer(), bounds.contains(p) { onClick(p) }
    }

    private func pointer() -> CGPoint? {
        window.map { convert($0.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil) }
    }

    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        // A plain vertical wheel pans only with shift held, so it does not fight the rows' vertical layout.
        let delta = abs(dx) >= abs(dy) ? dx : (event.modifierFlags.contains(.shift) ? dy : 0)
        if delta != 0 { onScroll(delta) }
    }
}
