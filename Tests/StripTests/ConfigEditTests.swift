import Testing
import StripEngine
import WindowCore

@Suite struct ConfigEditTests {
    @Test func replacementKeepsCommentsAndOtherLines() {
        let text = "# header\ngap = 4\nfloat = Notes\ngap = 8   # space\n# end\n"
        let edited = StripConfig.setting("gap", "12", in: text)
        #expect(edited == "# header\nfloat = Notes\ngap = 12   # space\n# end\n")
        #expect(StripConfig.parse(edited).config.gap == 12)
    }

    @Test func uncommentAndAppend() {
        #expect(StripConfig.setting("gap", "10", in: "# heading\n  # gap = 8 # points\n") == "# heading\ngap = 10 # points\n")
        #expect(StripConfig.setting("gap", "10", in: "# heading") == "# heading\ngap = 10\n")
        #expect(StripConfig.setting("gap", "10", in: "") == "gap = 10\n")
    }

    @Test func unbindAndReset() {
        let text = "# keys\nbind focus-left = x # mine\nunbind focus-left\n"
        let edited = StripConfig.binding("focus-left", nil, meta: .rightCommand, in: text)
        #expect(edited == "# keys\nunbind focus-left\n")
        #expect(StripConfig.parse(edited).config.bindings["focus-left"] == nil)
        #expect(StripConfig.binding("focus-left", nil, meta: .rightCommand, in: "unbind focus-left # mine\n") == "unbind focus-left # mine\n")
        #expect(StripConfig.setting("gap", "12", in: "GAP = 3\n") == "gap = 12\n")
        let reset = StripConfig.resetting("bind focus-left", in: edited)
        #expect(reset == "# keys\n")
        #expect(StripConfig.parse(reset).config.bindings["focus-left"] == StripConfig().bindings["focus-left"])
        #expect(StripConfig.resetting("gap", in: "# gap = 8\ngap = 12\ngap = 4\n") == "# gap = 8\n")
    }

    @Test func repeatingEntriesUseFileLines() {
        let text = "# rules\nfloat = Notes # note\n\nfloat = Safari\nrun shift+return = open -a Notes\nsend x = cmd+space\n"
        let entries = StripConfig.entries(in: text)
        #expect(entries.map(\.line) == [2, 4, 5, 6])
        #expect(entries.map(\.kind) == ["float", "float", "run", "send"])
        #expect(entries.map(\.value) == ["Notes", "Safari", "shift+return = open -a Notes", "x = cmd+space"])
        let edited = StripConfig.replacingLine(2, with: "float = Terminal", in: text)
        #expect(edited.contains("float = Terminal # note\n"))
        #expect(StripConfig.removingLine(4, in: edited) == "# rules\nfloat = Terminal # note\n\nrun shift+return = open -a Notes\nsend x = cmd+space\n")
        #expect(StripConfig.replacingLine(0, with: "bad", in: text) == text)
        #expect(StripConfig.removingLine(99, in: text) == text)
    }

    @Test func editedTemplateRoundTrips() {
        var text = StripConfig.setting("meta", "control-option", in: StripConfig.template)
        text = StripConfig.setting("gap", "22", in: text)
        let chord = MetaKeyBindings.Chord(keyCode: KeyNames.codes["x"]!, shift: true, option: true)
        text = StripConfig.binding("focus-left", chord, meta: .controlOption, in: text)
        text = StripConfig.appending("float = Notes", in: text)
        let parsed = StripConfig.parse(text)
        #expect(parsed.issues.isEmpty)
        #expect(parsed.config.meta == .controlOption)
        #expect(parsed.config.gap == 22)
        #expect(parsed.config.bindings["focus-left"] == chord)
        #expect(parsed.config.rules.float == [AppPattern(app: "Notes")])
    }

    @Test func takingACommandKeyRemovesShadowedEntries() {
        let text = "# shortcuts\nrun command+x = first\nfloat = Notes\nsend command+x = cmd+space\nrun command+x = last # keep\nrun y = other\n"
        let chord = MetaKeyBindings.Chord(keyCode: KeyNames.codes["x"]!, shift: false, option: true)
        let kept = StripConfig.removingCommands(on: chord, exceptLine: 5, meta: .controlOption, in: text)
        #expect(kept == "# shortcuts\nfloat = Notes\nrun command+x = last # keep\nrun y = other\n")
        let removed = StripConfig.removingCommands(on: chord, exceptLine: nil, meta: .controlOption, in: text)
        #expect(removed == "# shortcuts\nfloat = Notes\nrun y = other\n")
        #expect(StripConfig.entries(in: "FLOAT = Notes\n").first?.kind == "float")
    }

    @Test func colorsAndValidation() {
        let color = RGBA(r: 0.2, g: 0.4, b: 0.6, a: 0.8)
        #expect(StripConfig.hex(color) == "336699cc")
        #expect(StripConfig.parse("focus-border-color = \(StripConfig.hex(color))").config.focusBorderColor == color)
        #expect(StripConfig.issues(forLine: "float = /[/").first?.message == "bad regular expression /[/")
        #expect(!StripConfig.issues(forLine: "bind focus-left = banana").isEmpty)
    }
}
