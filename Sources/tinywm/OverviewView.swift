import AppKit
import StripEngine

/// The overview's click-capturing panel. It becomes key without activating tinywm, so plain keys
/// reach it and none reach the app in front.
final class OverviewPanel: NSPanel {
    /// Sees each key press first; true keeps it from the search bar.
    var onKeyDown: (NSEvent) -> Bool = { _ in false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown(event) { return }
        super.sendEvent(event)
    }

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
    var onPress: (CGPoint) -> Void = { _ in }
    var onDrag: (CGPoint) -> Void = { _ in }
    var onRelease: (CGPoint) -> Void = { _ in }
    var onRightClick: (CGPoint) -> Void = { _ in }
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
        if let p = pointer(), bounds.contains(p) { onPress(p) }
    }
    override func mouseDragged(with event: NSEvent) { if let p = pointer() { onDrag(p) } }
    override func mouseUp(with event: NSEvent) { if let p = pointer() { onRelease(p) } }
    override func rightMouseDown(with event: NSEvent) {
        if let p = pointer(), bounds.contains(p) { onRightClick(p) }
    }

    private var renameAction: () -> Void = {}

    /// A context menu at `p` whose one item calls `rename`.
    func showMenu(at p: CGPoint, rename: @escaping () -> Void) {
        renameAction = rename
        let menu = NSMenu()
        let item = NSMenuItem(title: "Rename…", action: #selector(renameChosen), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        menu.popUp(positioning: nil, at: p, in: self)
    }

    @objc private func renameChosen() { renameAction() }

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

/// The overview's search bar. Typing, the caret and editing keys such as ⌥⌫ and ⌘⌫ work as in
/// any text field; the keys the overview acts on (arrows, Tab, Return, Esc) go to `onKey` instead.
class SearchField: NSTextField, NSTextFieldDelegate {
    var keys = OverviewKeys()
    var onKey: (OverviewCommand) -> Void = { _ in }
    var onChange: (String) -> Void = { _ in }
    /// The field took the keys, as when it was clicked.
    var onFocus: () -> Void = {}

    init() {
        super.init(frame: .zero)
        delegate = self
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        cell?.isScrollable = true
        font = NSFont.systemFont(ofSize: 19, weight: .medium)
        textColor = .white
        // Dark, so the caret and the selection show on the dark pill.
        appearance = NSAppearance(named: .darkAqua)
        placeholderAttributedString = NSAttributedString(string: "Type to search windows", attributes: [
            .font: NSFont.systemFont(ofSize: 19, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.6),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        onFocus()
        return true
    }

    // A click on a display whose overview does not have the keys still reaches the field.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func controlTextDidChange(_ obj: Notification) { onChange(stringValue) }

    /// tinywm has no Edit menu, which is what normally gives a field ⌘A, ⌘C, ⌘V, ⌘X and ⌘Z.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let held = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard event.type == .keyDown, held == .command || held == [.command, .shift] else { return super.performKeyEquivalent(with: event) }
        let action: Selector? = switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": #selector(NSText.selectAll(_:))
        case "c": #selector(NSText.copy(_:))
        case "v": #selector(NSText.paste(_:))
        case "x": #selector(NSText.cut(_:))
        case "z": held.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
        default: nil
        }
        guard let action, NSApp.sendAction(action, to: nil, from: self) else { return super.performKeyEquivalent(with: event) }
        return true
    }

    /// The overview's keys pressed without ⌘, ⌃ or ⌥ steer it; with them, the field edits as usual.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let e = NSApp.currentEvent, e.type == .keyDown,
              e.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let key = keys.command(keyCode: Int(e.keyCode), shift: e.modifierFlags.contains(.shift)) else { return false }
        onKey(key)
        return true
    }
}

/// Edits a window's name over its label. Return gives the text, and Esc or leaving the field gives nil.
final class RenameField: SearchField {
    var onDone: (String?) -> Void = { _ in }

    override init() {
        super.init()
        font = NSFont.systemFont(ofSize: 16, weight: .medium)
        alignment = .center
        drawsBackground = true
        backgroundColor = NSColor(white: 0.16, alpha: 1)
        placeholderAttributedString = nil
        placeholderString = "Name"
    }

    required init?(coder: NSCoder) { nil }

    override func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): onDone(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        case #selector(NSResponder.cancelOperation(_:)): onDone(nil)
        default: return false
        }
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) { onDone(nil) }
}
