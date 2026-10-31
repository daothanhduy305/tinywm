import Foundation

public enum OverviewCommand: Equatable, Sendable { case left, right, up, down, next, previous, confirm, cancel, rename }

/// What each key does while the overview is open, built from the resolved bindings.
public struct OverviewKeys: Equatable, Sendable {
    private var plain: [Int: OverviewCommand] = [:]
    private var meta = MetaModifier.rightCommand
    private var rename: MetaKeyBindings.Chord?
    /// Global actions on the rename chord, whose hotkey would otherwise swallow it.
    private var renameActions: Set<String> = []

    /// Plain keys: the arrows, Tab, Return and Esc. Letters type into the search bar instead, so
    /// the focus letters steer only with the meta key held.
    public init(bindings: [String: MetaKeyBindings.Chord] = StripActions.defaultBindings, meta: MetaModifier = .rightCommand,
                rename: MetaKeyBindings.Chord? = StripConfig.defaultRename) {
        self.meta = meta
        self.rename = rename
        renameActions = Set(bindings.filter { $0.value == rename }.keys)
        let arrows = [(123, OverviewCommand.left), (124, .right), (126, .up), (125, .down)]
        for (code, command) in arrows { plain[code] = command }
        for (name, chord) in bindings where !chord.shift && !chord.option && !Self.typesText(chord.keyCode) {
            if let command = Self.command(forAction: name), command != .confirm { plain[chord.keyCode] = command }
        }
        // These never move to a binding, so the overview can always be left.
        plain[48] = .next
        plain[36] = .confirm
        plain[76] = .confirm
        plain[53] = .cancel
    }

    /// The command for a key pressed without the meta key.
    public func command(keyCode: Int, shift: Bool) -> OverviewCommand? {
        if keyCode == 48 { return shift ? .previous : .next }
        if shift { return nil }
        return plain[keyCode]
    }

    /// Whether a key that reached the overview is the `overview-rename` chord, which renames the
    /// selected window. `flags` are the event's raw flags.
    public func isRename(keyCode: Int, flags: UInt64) -> Bool {
        guard let rename, keyCode == rename.keyCode, meta.isHeld(flags: flags) else { return false }
        let has = { (bit: UInt64) in flags & bit != 0 }
        let shift: UInt64 = 0x20000, control: UInt64 = 0x40000, option: UInt64 = 0x80000, command: UInt64 = 0x100000
        return switch meta {
        case .rightCommand: has(shift) == rename.shift && has(option) == rename.option && has(control) == rename.control
        case .controlOption: has(shift) == rename.shift && has(command) == rename.option
        }
    }

    /// Whether a key types into the search bar: anything but the arrows, the function keys and
    /// the keys the overview always keeps.
    static func typesText(_ keyCode: Int) -> Bool {
        !(96...126).contains(keyCode) && ![36, 48, 51, 53, 76].contains(keyCode)
    }

    /// Whether every word of `query` appears in `text`, ignoring case and accents. An empty
    /// query matches everything.
    public static func matches(_ text: String, query: String) -> Bool {
        query.split(separator: " ").allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// The command for an action fired through the meta key while the overview is open. An action
    /// on the rename chord renames. Other actions are ignored then, so they cannot move real windows.
    public func command(forAction name: String) -> OverviewCommand? {
        renameActions.contains(name) ? .rename : Self.command(forAction: name)
    }

    static func command(forAction name: String) -> OverviewCommand? {
        switch name {
        case "focus-left", "focus-left-arrow": .left
        case "focus-right", "focus-right-arrow": .right
        case "focus-up", "focus-up-arrow": .up
        case "focus-down", "focus-down-arrow": .down
        case "overview": .confirm
        default: nil
        }
    }
}
