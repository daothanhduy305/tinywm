import Foundation
import WindowCore

extension StripConfig {
    public static func setting(_ name: String, _ value: String, in text: String) -> String {
        updating(name, with: "\(name) = \(value)", in: text)
    }

    public static func binding(_ action: String, _ chord: MetaKeyBindings.Chord?, meta: MetaModifier, in text: String) -> String {
        updating("bind \(action)", with: chord.map { "bind \(action) = \(describe($0, meta: meta))" } ?? "unbind \(action)", in: text)
    }

    private static func updating(_ key: String, with replacement: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let active = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("#") && Self.key(of: lines[$0][...]) == key }
        let commented = lines.indices.first {
            let line = lines[$0].trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("#") && Self.key(of: line.dropFirst().drop(while: \.isWhitespace)) == key
        }
        guard let index = active.last ?? commented else { return appending(replacement, in: text) }
        let raw = lines[index]
        // Keep the spacing before a trailing comment, as well as the comment itself.
        let comment: String
        let content = active.isEmpty ? String(raw.drop(while: { $0.isWhitespace || $0 == "#" })) : raw
        if let hash = content.firstIndex(of: "#") {
            let prefix = content[..<hash]
            comment = String(prefix.reversed().prefix(while: \.isWhitespace).reversed()) + content[hash...]
        } else { comment = "" }
        lines[index] = replacement + comment
        for duplicate in active.dropLast().reversed() { lines.remove(at: duplicate) }
        return lines.joined(separator: "\n")
    }

    public static func resetting(_ key: String, in text: String) -> String {
        text.components(separatedBy: "\n").filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") || Self.key(of: $0[...]) != key
        }.joined(separator: "\n")
    }

    /// Repeating entries use one-based file line numbers, including lines the parser rejects.
    public static func entries(in text: String) -> [(line: Int, kind: String, value: String)] {
        text.components(separatedBy: "\n").enumerated().compactMap { index, raw in
            let content = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let parts = content.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let head = parts[0].trimmingCharacters(in: .whitespaces)
            let kind = head.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? ""
            guard ["float", "ignore", "no-focus", "open-on", "run", "send"].contains(kind) else { return nil }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return (index + 1, kind, kind == "run" || kind == "send" ? String(head.dropFirst(kind.count)).trimmingCharacters(in: .whitespaces) + " = " + value : value)
        }
    }

    public static func replacingLine(_ number: Int, with line: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(number - 1) else { return text }
        let old = lines[number - 1]
        if let hash = old.firstIndex(of: "#") {
            lines[number - 1] = line + String(old[..<hash].reversed().prefix(while: \.isWhitespace).reversed()) + old[hash...]
        } else { lines[number - 1] = line }
        return lines.joined(separator: "\n")
    }

    public static func removingLine(_ number: Int, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(number - 1) else { return text }
        lines.remove(at: number - 1)
        return lines.joined(separator: "\n")
    }

    public static func appending(_ line: String, in text: String) -> String {
        text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + line + "\n"
    }

    public static func removingCommands(on chord: MetaKeyBindings.Chord, exceptLine: Int?, meta: MetaModifier, in text: String) -> String {
        var updated = text
        let prefix = "meta = \(meta == .rightCommand ? "right-command" : "control-option")\n"
        for entry in entries(in: text).reversed() where entry.line != exceptLine && (entry.kind == "run" || entry.kind == "send") {
            if parse(prefix + "\(entry.kind) \(entry.value)").config.commands.first?.chord == chord {
                updated = removingLine(entry.line, in: updated)
            }
        }
        return updated
    }

    public static func issues(forLine line: String) -> [ConfigIssue] { parse(line).issues }

    public static func hex(_ color: RGBA) -> String {
        [color.r, color.g, color.b, color.a].map { String(format: "%02x", Int((min(1, max(0, $0)) * 255).rounded())) }.joined()
    }
}
