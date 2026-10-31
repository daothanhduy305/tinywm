import Foundation
import StripModel

public struct ConfigIssue: Equatable, Sendable, CustomStringConvertible {
    /// The file's line, or 0 for an issue with the whole file.
    public let line: Int
    public let message: String
    public var description: String { line > 0 ? "line \(line): \(message)" : message }
}

/// The settings and key bindings in force: the shipped defaults with the config file's lines on top.
public struct StripConfig: Equatable, Sendable {
    public var meta = MetaModifier.rightCommand
    public var gap = 8.0
    public var defaultWidth = StripSettings().defaultWidth
    public var widthPresets = [0.333, 0.5, 0.667]
    public var focusBorder = true
    /// Trackpad swipes on or off, and how many fingers they use.
    public var swipe = true
    public var swipeFingers = 3
    public var pinchOverview = true
    public var pinchFingers = 5
    /// Focus or move past the strip's first or last column continues onto the display on that side.
    public var focusCrossesDisplays = false
    /// Whether the layout is saved and brought back when tinywm starts.
    public var restoreLayout = true
    /// Whether a column that would reach another display hides behind a card instead of narrowing.
    public var peekCover = false
    /// Whether scrolling to a column centres it, as far as the strip's ends allow.
    public var centerFocus = false
    /// Whether ⌘Tab opens the overview instead of the macOS app switcher.
    public var overviewOnCommandTab = false
    /// Where the overview shows floating windows.
    public var overviewFloating = OverviewFloating.vertical
    /// Bound actions only; an unbound action has no entry.
    public var bindings = StripActions.defaultBindings
    /// The overview's rename key, from `bind overview-rename`. It works only in the overview, so it
    /// shares its chord with a global action freely. Nil when unbound.
    public var overviewRename: MetaKeyBindings.Chord? = Self.defaultRename
    public static let defaultRename: MetaKeyBindings.Chord? = .init(keyCode: KeyNames.codes["r"]!, shift: false, option: false)
    /// Chords that run a shell command or press other keys, from `run` and `send` lines.
    public var commands: [CustomCommand] = []
    public var rules = WindowRules()

    public init() {}

    public struct Parsed: Equatable, Sendable {
        public var config: StripConfig
        public var issues: [ConfigIssue]
    }

    /// Carries the config's layout values into `settings`, leaving the rest as it was.
    public func applied(to settings: StripSettings) -> StripSettings {
        var s = settings
        s.gap = gap
        s.defaultWidth = defaultWidth
        s.widthPresets = widthPresets
        s.peekCovers = peekCover
        s.scrollMode = centerFocus ? .center : .fit
        return s
    }

    // MARK: Parsing

    private struct Failure: Error { let message: String }

    private enum Statement {
        case setting(String, String)
        case bind(String, String)
        case unbind(String)
        case run(String, String)
        case send(String, String)
    }

    /// Turns what reading the file gave into the config in force. A missing file (nil) means
    /// the defaults. A file that is there but cannot be read, or is not UTF-8, keeps `previous`:
    /// an editor can be caught halfway through saving, and the defaults would drop every binding.
    public static func read(_ contents: Result<Data, Error>?, previous: Parsed) -> Parsed {
        func kept(_ why: String) -> Parsed {
            Parsed(config: previous.config,
                   issues: [ConfigIssue(line: 0, message: "The config file \(why); the last good settings stay in force")])
        }
        switch contents {
        case nil: return parse("")
        case .failure(let error): return kept("could not be read (\(error.localizedDescription))")
        case .success(let data):
            guard let text = String(data: data, encoding: .utf8) else { return kept("is not UTF-8 text") }
            return parse(text)
        }
    }

    /// Reads a whole file. A bad line is skipped and reported; everything else applies.
    public static func parse(_ text: String) -> Parsed {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var config = StripConfig()
        var issues: [ConfigIssue] = []

        // Modifier names depend on the meta key, so it is settled before any binding is read.
        for raw in lines {
            if case .setting("meta", let value)? = try? statement(raw), let m = try? metaModifier(value) { config.meta = m }
        }

        // Stamps order the lines; defaults come before every line.
        var stamp: [String: Int] = [:]
        for (index, raw) in lines.enumerated() {
            let number = index + 1
            do {
                guard let s = try statement(raw) else { continue }
                switch s {
                case .setting(let name, let value):
                    if let kind = RuleKind(rawValue: name) {
                        issues += config.rules.add(kind, value).map { ConfigIssue(line: number, message: $0) }
                        continue
                    }
                    if name == "open-on" {
                        issues += config.rules.addOpenOn(value).map { ConfigIssue(line: number, message: $0) }
                        continue
                    }
                    try apply(setting: name, value, to: &config)
                case .bind("overview-rename", let key):
                    config.overviewRename = try chord(key, meta: config.meta)
                case .unbind("overview-rename"):
                    config.overviewRename = nil
                case .bind(let action, let key):
                    try requireAction(action)
                    config.bindings[action] = try chord(key, meta: config.meta)
                    stamp[action] = number
                case .unbind(let action):
                    try requireAction(action)
                    config.bindings[action] = nil
                    stamp[action] = nil
                case .run(let key, let shell):
                    let c = try chord(key, meta: config.meta)
                    add(CustomCommand(chord: c, kind: .shell(shell), text: shell, meta: config.meta), to: &config, stamp: &stamp, line: number)
                case .send(let key, let keys):
                    let c = try chord(key, meta: config.meta)
                    let stroke = try keyStroke(keys)
                    add(CustomCommand(chord: c, kind: .keys(stroke), text: keys, meta: config.meta), to: &config, stamp: &stamp, line: number)
                }
            } catch let f as Failure {
                issues.append(ConfigIssue(line: number, message: f.message))
            } catch {}
        }

        issues += resolveClashes(&config, stamp: stamp)
        return Parsed(config: config, issues: issues.sorted { $0.line < $1.line })
    }

    /// A later command on the same chord replaces the earlier one.
    private static func add(_ command: CustomCommand, to config: inout StripConfig, stamp: inout [String: Int], line: Int) {
        config.commands.removeAll { $0.chord == command.chord }
        config.commands.append(command)
        stamp[command.name] = line
    }

    /// Two actions on one chord: the later line keeps it, and the other action goes unbound.
    private static func resolveClashes(_ config: inout StripConfig, stamp: [String: Int]) -> [ConfigIssue] {
        var holders: [MetaKeyBindings.Chord: [String]] = [:]
        for name in StripActions.all.map(\.name) {
            if let c = config.bindings[name] { holders[c, default: []].append(name) }
        }
        for c in config.commands { holders[c.chord, default: []].append(c.name) }
        var issues: [ConfigIssue] = []
        for (chord, names) in holders where names.count > 1 {
            let ordered = names.sorted { (stamp[$0] ?? 0) < (stamp[$1] ?? 0) }
            let winner = ordered.last!
            for loser in ordered.dropLast() {
                config.bindings[loser] = nil
                config.commands.removeAll { $0.name == loser }
                // Taking a key from a shipped default is what rebinding means; only two lines of
                // the file fighting over one key is a mistake worth reporting.
                guard stamp[loser] != nil else { continue }
                issues.append(ConfigIssue(
                    line: stamp[winner] ?? stamp[loser] ?? 1,
                    message: "\(describe(chord, meta: config.meta)) is taken by \(winner); \(loser) is now unbound"))
            }
        }
        return issues
    }

    private static func statement(_ raw: String) throws -> Statement? {
        var s = Substring(raw)
        if let hash = s.firstIndex(of: "#") { s = s[..<hash] }
        let line = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return nil }
        let first = line.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? ""
        let rest = line.dropFirst(first.count).trimmingCharacters(in: .whitespaces)
        switch first {
        case "unbind":
            guard !rest.isEmpty, !rest.contains(where: \.isWhitespace) else { throw Failure(message: "expected 'unbind action'") }
            return .unbind(rest.lowercased())
        case "run", "send":
            let (key, value) = try assignment(rest, expecting: "\(first) key = \(first == "run" ? "command" : "keys")")
            return first == "run" ? .run(key.lowercased(), value) : .send(key.lowercased(), value.lowercased())
        case "bind":
            let (name, value) = try assignment(rest, expecting: "bind action = key")
            return .bind(name.lowercased(), value.lowercased())
        default:
            let (name, value) = try assignment(line, expecting: "name = value")
            return .setting(name.lowercased(), value)
        }
    }

    private static func assignment(_ s: String, expecting form: String) throws -> (String, String) {
        guard let eq = s.firstIndex(of: "=") else { throw Failure(message: "expected '\(form)'") }
        let name = s[..<eq].trimmingCharacters(in: .whitespaces)
        let value = s[s.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !value.isEmpty, !name.contains(where: \.isWhitespace) else {
            throw Failure(message: "expected '\(form)'")
        }
        return (name, value)
    }

    private static func requireAction(_ name: String) throws {
        guard StripActions.spec(named: name) != nil else { throw Failure(message: "unknown action '\(name)'") }
    }

    private static func metaModifier(_ value: String) throws -> MetaModifier {
        switch value.lowercased() {
        case "right-command": return .rightCommand
        case "control-option": return .controlOption
        default: throw Failure(message: "meta must be right-command or control-option, not '\(value)'")
        }
    }

    private static func apply(setting name: String, _ value: String, to config: inout StripConfig) throws {
        switch name {
        case "meta":
            config.meta = try metaModifier(value)
        case "gap":
            config.gap = try number(value, in: 0...200, for: name)
        case "default-width":
            config.defaultWidth = try number(value, in: 0.05...1, for: name)
        case "width-presets":
            let parts = value.split(separator: ",", omittingEmptySubsequences: false)
            config.widthPresets = try parts.map { try number($0.trimmingCharacters(in: .whitespaces), in: 0.05...1, for: name) }
        case "focus-border":
            config.focusBorder = try onOff(value, for: name)
        case "swipe":
            config.swipe = try onOff(value, for: name)
        case "pinch-overview":
            config.pinchOverview = try onOff(value, for: name)
        case "pinch-fingers":
            guard let n = Int(value), n == 4 || n == 5 else {
                throw Failure(message: "pinch-fingers must be 4 or 5, not '\(value)'")
            }
            config.pinchFingers = n
        case "focus-crosses-displays":
            config.focusCrossesDisplays = try onOff(value, for: name)
        case "swipe-fingers":
            guard let n = Int(value), n == 3 || n == 4 else {
                throw Failure(message: "swipe-fingers must be 3 or 4, not '\(value)'")
            }
            config.swipeFingers = n
        case "restore-layout":
            config.restoreLayout = try onOff(value, for: name)
        case "learn-minimum-widths", "learn-maximum-widths":
            // No longer used: a column fits a window that refuses its width. Still accepted so old configs load.
            _ = try onOff(value, for: name)
        case "peek-cover":
            config.peekCover = try onOff(value, for: name)
        case "center-focus":
            config.centerFocus = try onOff(value, for: name)
        case "overview-as-mission-control":
            config.overviewOnCommandTab = try onOff(value, for: name)
        case "overview-floating":
            guard let f = OverviewFloating(rawValue: value.lowercased()) else {
                throw Failure(message: "overview-floating must be vertical, horizontal or off, not '\(value)'")
            }
            config.overviewFloating = f
        default:
            throw Failure(message: "unknown setting '\(name)'")
        }
    }

    private static func number(_ s: String, in range: ClosedRange<Double>, for name: String) throws -> Double {
        guard let v = Double(s), range.contains(v) else {
            throw Failure(message: "\(name) must be a number from \(range.lowerBound) to \(range.upperBound), not '\(s)'")
        }
        return v
    }

    /// `shift+option+key`. The fourth modifier is option with right ⌘ as meta and command with ⌃⌥.
    /// Control is a further one with right ⌘; ⌃⌥ already holds it.
    private static func chord(_ text: String, meta: MetaModifier) throws -> MetaKeyBindings.Chord {
        let parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let keyName = parts.last, !keyName.isEmpty else { throw Failure(message: "missing key in '\(text)'") }
        guard let code = KeyNames.codes[keyName] else { throw Failure(message: "unknown key '\(keyName)'") }
        var shift = false, alt = false, control = false
        for m in parts.dropLast() {
            switch (m, meta) {
            case ("shift", _):
                guard !shift else { throw Failure(message: "shift is given twice") }
                shift = true
            case ("control", .rightCommand), ("ctrl", .rightCommand):
                guard !control else { throw Failure(message: "control is given twice") }
                control = true
            case ("control", .controlOption), ("ctrl", .controlOption):
                throw Failure(message: "control is already part of control-option")
            case ("option", .rightCommand), ("command", .controlOption):
                guard !alt else { throw Failure(message: "\(m) is given twice") }
                alt = true
            case ("option", .controlOption):
                throw Failure(message: "option is already part of control-option; use command for the extra modifier")
            case ("command", .rightCommand):
                throw Failure(message: "command is not available with meta = right-command; use option")
            default:
                throw Failure(message: "unknown modifier '\(m)'")
            }
        }
        return .init(keyCode: code, shift: shift, option: alt, control: control)
    }

    /// `cmd+space`: any of command, shift, option and control, then one key.
    private static func keyStroke(_ text: String) throws -> KeyStroke {
        let parts = text.split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, !keyName.isEmpty else { throw Failure(message: "missing key in '\(text)'") }
        guard let code = KeyNames.codes[keyName] else { throw Failure(message: "unknown key '\(keyName)'") }
        var s = KeyStroke(keyCode: code)
        for m in parts.dropLast() {
            switch m {
            case "cmd", "command": s.command = true
            case "shift": s.shift = true
            case "alt", "opt", "option": s.option = true
            case "ctrl", "control": s.control = true
            default: throw Failure(message: "unknown modifier '\(m)'")
            }
        }
        return s
    }

    /// How a chord is written in the file, for the given meta key.
    public static func describe(_ chord: MetaKeyBindings.Chord, meta: MetaModifier) -> String {
        var parts: [String] = []
        if chord.control { parts.append("control") }
        if chord.shift { parts.append("shift") }
        if chord.option { parts.append(meta == .rightCommand ? "option" : "command") }
        parts.append(KeyNames.name(of: chord.keyCode) ?? "key\(chord.keyCode)")
        return parts.joined(separator: "+")
    }

    // MARK: Template

    private static func onOff(_ value: String, for name: String) throws -> Bool {
        switch value.lowercased() {
        case "on", "true", "yes": return true
        case "off", "false", "no": return false
        default: throw Failure(message: "\(name) must be on or off, not '\(value)'")
        }
    }

    /// The settings and bindings written as file lines, without comment marks.
    public static var defaultLines: [String] {
        var lines = settingLines
        for spec in StripActions.all {
            lines.append("bind \(spec.name) = \(describe(spec.chord, meta: .rightCommand))")
        }
        lines.append("bind overview-rename = \(describe(defaultRename!, meta: .rightCommand)) # renames the selected window, in the overview only")
        return lines
    }

    /// A setting whose choices are not just on or off says them in a comment after its value.
    private static var settingLines: [String] {
        let d = StripConfig()
        return [
            "meta = right-command # or control-option",
            "gap = \(format(d.gap)) # points between windows, 0 to 200",
            "default-width = \(format(d.defaultWidth)) # share of the screen, 0.05 to 1",
            "width-presets = \(d.widthPresets.map(format).joined(separator: ", ")) # shares of the screen the width keys step through",
            "focus-border = on",
            "swipe = on",
            "swipe-fingers = \(d.swipeFingers) # 3 or 4",
            "pinch-overview = on # pinch opens the overview; spread closes it",
            "pinch-fingers = \(d.pinchFingers) # 4 or 5, thumb included",
            "focus-crosses-displays = off",
            "restore-layout = on",
            "peek-cover = off",
            "center-focus = off",
            "overview-as-mission-control = off",
            "overview-floating = \(d.overviewFloating.rawValue) # vertical, horizontal or off: where the overview shelves floating windows",
        ]
    }

    /// The file with every default line it never mentions added at the end, commented, so settings
    /// and bindings from a newer tinywm show up in an older file. Nil when nothing is missing.
    public static func addingMissingDefaults(to text: String) -> String? {
        let present = Set(text.split(whereSeparator: \.isNewline).map { key(of: $0.drop { $0 == "#" || $0.isWhitespace }) })
        let missing = defaultLines.filter { !present.contains(key(of: $0[...])) }
        guard !missing.isEmpty else { return nil }
        var out = text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
        out += "\n# Added by tinywm: defaults this file did not list yet.\n"
        for l in missing { out += "# \(l)\n" }
        return out
    }

    /// `gap` for `gap = 8`, and `bind focus-left` for `bind focus-left = h` or `unbind focus-left`.
    private static func key(of line: Substring) -> String {
        let words = (line.split(separator: "=", maxSplits: 1).first ?? "").split(whereSeparator: \.isWhitespace)
        return (words.first == "unbind" ? ["bind"] + words.dropFirst() : words).joined(separator: " ")
    }

    /// A commented file listing every default. Remove the `#` from a line to change it.
    public static var template: String {
        let settings = settingLines, binds = defaultLines.dropFirst(settings.count)
        var out = """
        # tinywm config. Lines starting with # are ignored; the file reloads when you save it.
        # Only the lines you uncomment or add change anything; the rest keeps the default shown here.
        #
        # The meta key is implied in every binding. Extra modifiers: shift, option and control
        # (with meta = control-option, command instead of option, and no control). Keys: letters, digits, left right up
        # down pageup pagedown esc tab return space, and = - [ ] , . / ; ' \\ ` or the names
        # equal minus leftbracket rightbracket comma period slash semicolon quote backslash grave.
        # "unbind <action>" removes a default binding. Two actions on one key: the later line wins.
        #
        # Your own shortcuts. "run" starts a shell command; "send" presses other keys, with any of
        # cmd, shift, option and ctrl. They take the key from a default binding the same way.
        # run  shift+return = open -na Ghostty
        # send space = cmd+space

        """
        out += "\n"
        for l in settings { out += "# \(l)\n" }
        out += "\n"
        for l in binds { out += "# \(l)\n" }
        out += """

        # Rules. Match an app by bundle ID or app name (case-insensitive, exact), optionally with a
        # window title substring after a colon in quotes. Several patterns per line, comma-separated.
        # A * in an app stands for anything, as in com.jetbrains.*. Between slashes, an app or a
        # title is a regular expression found anywhere in it, as in /^micro/.
        # Each kind may appear on any number of lines; all of them count.
        #   float    windows open floating, off the strip (meta+T tiles one)
        #   ignore   the app is not managed at all
        #   no-focus new windows join without taking focus, and the app cannot pull focus on its own
        #   open-on  new windows open on a display, a workspace, or both; the first matching line wins
        # float    = com.apple.calculator, System Settings
        # float    = Brave Browser: "Picture in Picture"
        # ignore   = com.apple.finder
        # no-focus = Slack, com.spotify.client
        # open-on  = /^microcube/ -> workspace 2
        # open-on  = Slack, com.tinyspeck.* -> display Built-in workspace 1

        """
        return out
    }

    private static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }
}
