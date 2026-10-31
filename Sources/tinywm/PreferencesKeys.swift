import AppKit
import SwiftUI
import StripEngine

struct PreferencesKeys: View {
    let model: PreferencesModel
    @State private var search = ""
    private let sections = ["Focus", "Move", "Workspaces", "Columns & width", "Stacks", "Floating", "Displays", "Overview & windows"]

    private func section(_ name: String) -> String {
        if name.hasPrefix("focus-column") || ["width", "center", "wider", "narrower"].contains(where: { name.hasPrefix($0) }) { return "Columns & width" }
        if name.hasPrefix("focus") { return "Focus" }
        if name.hasPrefix("move") { return "Move" }
        if name.hasPrefix("workspace") { return "Workspaces" }
        if name.hasPrefix("stack") || name == "pop-out" { return "Stacks" }
        if name.hasPrefix("float") { return "Floating" }
        if name.hasPrefix("display") { return "Displays" }
        return "Overview & windows"
    }

    var body: some View {
        Form {
            PreferencesIssues(model: model)
            Section {
                TextField("Search bindings", text: $search, prompt: Text("Search bindings"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
            ForEach(sections, id: \.self) { group in
                let specs = StripActions.all.filter { section($0.name) == group }
                let titles = specs.map(\.title).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                Section(group) {
                    ForEach(titles.filter { title in search.isEmpty || title.localizedCaseInsensitiveContains(search) || specs.contains { $0.name.localizedCaseInsensitiveContains(search) && $0.title == title } }, id: \.self) { title in
                        HStack {
                            Text(title); Spacer()
                            ForEach(specs.filter { $0.title == title }, id: \.name) { spec in
                                slot(spec.name, defaultChord: spec.chord)
                            }
                        }
                    }
                    if group == "Overview & windows", search.isEmpty || "Rename in overview".localizedCaseInsensitiveContains(search) {
                        HStack { Text("Rename in overview"); Spacer(); slot("overview-rename", defaultChord: StripConfig.defaultRename) }
                    }
                }
            }
            Section("Your own shortcuts") {
                ForEach(StripConfig.entries(in: model.text).filter { $0.kind == "run" || $0.kind == "send" }, id: \.line) { entry in
                    PreferencesCommand(model: model, number: entry.line, kind: entry.kind, value: entry.value)
                }
                PreferencesCommand(model: model, number: nil, kind: "run", value: "")
            }
        }.formStyle(.grouped)
    }

    private func slot(_ action: String, defaultChord: MetaKeyBindings.Chord?) -> some View {
        let chord = action == "overview-rename" ? model.config.overviewRename : model.config.bindings[action]
        return HStack(spacing: 4) {
            Text(model.config.meta == .rightCommand ? "R⌘" : "⌃⌥").foregroundStyle(.secondary)
            PreferencesRecorder(chord: chord, meta: model.config.meta) { value in
                bind(action, value)
            }.help(action)
            if chord != defaultChord {
                Button { model.write { StripConfig.resetting("bind \(action)", in: $0) } } label: { Image(systemName: "arrow.counterclockwise") }
                    .help("Reset to default")
            }
        }
    }

    private func bind(_ action: String, _ chord: MetaKeyBindings.Chord?) {
        let meta = model.config.meta
        let owners = action == "overview-rename" || chord == nil ? [] : model.config.bindings.filter { $0.key != action && $0.value == chord }.map(\.key)
        let commands = action == "overview-rename" || chord == nil ? [] : model.config.commands.filter { $0.chord == chord }
        if !owners.isEmpty || !commands.isEmpty {
            let alert = NSAlert()
            let title = owners.first.flatMap { StripActions.spec(named: $0)?.title } ?? commands.first!.title
            alert.messageText = "\(keyLabel(chord, meta: meta)) is used by \(title). Use it here?"
            alert.addButton(withTitle: "Use It Here"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        model.write { text in
            var updated = text
            for owner in owners { updated = StripConfig.binding(owner, nil, meta: meta, in: updated) }
            if action != "overview-rename", let chord {
                updated = StripConfig.removingCommands(on: chord, exceptLine: nil, meta: meta, in: updated)
            }
            return StripConfig.binding(action, chord, meta: meta, in: updated)
        }
    }
}

func keyLabel(_ chord: MetaKeyBindings.Chord?, meta: MetaModifier) -> String {
    guard let chord else { return "Unbound" }
    let symbols = ["left": "←", "right": "→", "up": "↑", "down": "↓", "esc": "Esc", "return": "↩", "space": "Space", "tab": "⇥", "equal": "=", "minus": "−", "leftbracket": "[", "rightbracket": "]", "comma": ",", "period": ".", "slash": "/", "semicolon": ";", "quote": "'", "backslash": "\\", "grave": "`"]
    let name = KeyNames.name(of: chord.keyCode) ?? "?"
    return (chord.control ? "⌃" : "") + (chord.shift ? "⇧" : "") + (chord.option ? (meta == .rightCommand ? "⌥" : "⌘") : "") + (symbols[name] ?? name.uppercased())
}

struct PreferencesRecorder: View {
    let chord: MetaKeyBindings.Chord?
    let meta: MetaModifier
    let recorded: (MetaKeyBindings.Chord?) -> Void
    @State private var monitor: Any?

    var body: some View {
        Button(monitor == nil ? keyLabel(chord, meta: meta) : "Type keys (meta is added)…") {
            NotificationCenter.default.post(name: Self.startedRecording, object: nil)
            stop()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                MainActor.assumeIsolated {
                    if event.keyCode == 53 { stop(); return }
                    if event.keyCode == 51 || event.keyCode == 117 { stop(); recorded(nil); return }
                    guard KeyNames.name(of: Int(event.keyCode)) != nil else { return }
                    let flags = event.modifierFlags
                    let chord = MetaKeyBindings.Chord(keyCode: Int(event.keyCode), shift: flags.contains(.shift),
                        option: flags.contains(meta == .rightCommand ? .option : .command),
                        control: meta == .rightCommand && flags.contains(.control))
                    stop(); recorded(chord)
                }
                return nil
            }
        }
        .help("Type the keys (meta is added for you). Esc cancels. Delete unbinds.")
        .onReceive(NotificationCenter.default.publisher(for: Self.startedRecording)) { _ in stop() }
        .onDisappear { stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
    }

    private static let startedRecording = Notification.Name("tinywm.preferences.recordKey")

    private func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}

private struct PreferencesCommand: View {
    let model: PreferencesModel
    let number: Int?
    let kind: String
    let value: String
    @State private var chosenKind = "run"
    @State private var key = ""
    @State private var target = ""

    var body: some View {
        HStack {
            Text(model.config.meta == .rightCommand ? "R⌘" : "⌃⌥").foregroundStyle(.secondary)
            PreferencesRecorder(chord: draftChord, meta: model.config.meta) { chord in
                if let chord {
                    key = StripConfig.describe(chord, meta: model.config.meta)
                    if number != nil { save() }
                } else if let number { model.entry(number, "") }
                else { key = "" }
            }
            Picker("Action", selection: Binding(get: { chosenKind }, set: { chosenKind = $0; if number != nil { save() } })) { Text("Run command").tag("run"); Text("Press keys").tag("send") }.labelsHidden().frame(width: 140)
            TextField("Shortcut target", text: $target, prompt: Text(chosenKind == "run" ? "Shell command" : "cmd+space"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            if let number { Button { model.entry(number, "") } label: { Image(systemName: "minus.circle") }.help("Remove shortcut") }
            else { Button("Add") { save() }.disabled(key.isEmpty || target.isEmpty) }
        }.onAppear { load() }.onChange(of: value) { _, _ in load() }
    }

    private func load() {
        chosenKind = kind
        let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        key = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        target = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
    }

    private var draftChord: MetaKeyBindings.Chord? {
        let meta = model.config.meta == .rightCommand ? "right-command" : "control-option"
        return StripConfig.parse("meta = \(meta)\nrun \(key) = true").config.commands.first?.chord
    }

    private func save() { model.entry(number, "\(chosenKind) \(key) = \(target)") }
}
