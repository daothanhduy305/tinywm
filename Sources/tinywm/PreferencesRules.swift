import AppKit
import SwiftUI
import StripEngine

struct PreferencesRules: View {
    let model: PreferencesModel
    private let kinds = [("float", "Float"), ("ignore", "Don't manage"), ("no-focus", "Don't take focus"), ("open-on", "Open on")]

    var body: some View {
        Form {
            PreferencesIssues(model: model)
            ForEach(kinds, id: \.0) { kind, title in
                Section(title) {
                    ForEach(StripConfig.entries(in: model.text).filter { $0.kind == kind }, id: \.line) { entry in
                        PreferencesRule(model: model, number: entry.line, kind: kind, value: entry.value)
                    }
                    PreferencesRule(model: model, number: nil, kind: kind, value: "")
                }
            }
            Text("Match an app name or bundle ID. Use * for any characters, /regex/ for a regular expression, or app: \"title\" for a window title. Press Return to save.")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}

private struct PreferencesRule: View {
    let model: PreferencesModel
    let number: Int?
    let kind: String
    let value: String
    @State private var pattern = ""
    @State private var display = ""
    @State private var workspace = 0

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                TextField("App or pattern", text: $pattern, prompt: Text("App or pattern"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save() }
                if let number {
                    Button { model.entry(number, "") } label: { Image(systemName: "minus.circle") }.help("Remove rule")
                } else {
                    Menu {
                        Button("Add pattern") { save() }.disabled(pattern.isEmpty)
                        ForEach(appNames, id: \.self) { name in Button(name) { pattern = name; save() } }
                    } label: { Image(systemName: "plus.circle") }.help("Add a rule or choose a running app")
                }
            }
            if kind == "open-on" {
                HStack {
                    Picker("Display", selection: Binding(get: { display }, set: { display = $0; if number != nil { save() } })) {
                        Text("Any display").tag("")
                        ForEach(Array(Set(NSScreen.screens.map(\.localizedName) + (display.isEmpty ? [] : [display]))).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    Stepper(workspace == 0 ? "Any workspace" : "Workspace \(workspace)", value: Binding(get: { workspace }, set: { workspace = $0; if number != nil { save() } }), in: 0...Int.max)
                }
            }
        }.onAppear { load() }.onChange(of: value) { _, _ in load() }
    }

    private var appNames: [String] {
        Array(Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName))).sorted()
    }

    private func load() {
        if kind == "open-on", let arrow = value.range(of: "->", options: .backwards) {
            pattern = value[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            let target = StripConfig.parse("open-on = \(value)").config.rules.openOn.first?.target
            display = target?.display ?? ""
            workspace = target?.workspace ?? 0
        } else {
            pattern = value
            if kind == "open-on" { workspace = 1 }
        }
    }

    private func save() {
        var line = "\(kind) = \(pattern)"
        if kind == "open-on" {
            line += " ->"
            if !display.isEmpty { line += " display \(display)" }
            if workspace > 0 { line += " workspace \(workspace)" }
            if display.isEmpty && workspace == 0 { model.error = "Choose a display or workspace."; return }
        }
        model.entry(number, line)
    }
}
