import Foundation

public enum OverviewCommand: Equatable, Sendable { case left, right, up, down, next, previous, confirm, cancel }

/// What each key does while the overview is open, built from the resolved bindings.
public struct OverviewKeys: Equatable, Sendable {
    private var plain: [Int: OverviewCommand] = [:]

    /// Plain keys: the arrows, Tab, Return and Esc. Letters type into the search bar instead, so
    /// the focus letters steer only with the meta key held.
    public init(bindings: [String: MetaKeyBindings.Chord] = StripActions.defaultBindings) {
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

    /// The command for an action fired through the meta key while the overview is open.
    /// Other actions are ignored then, so they cannot move real windows.
    public static func command(forAction name: String) -> OverviewCommand? {
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
