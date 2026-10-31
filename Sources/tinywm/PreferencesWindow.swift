import AppKit
import SwiftUI
import Observation
import StripEngine
import WindowCore

@MainActor
@Observable
final class PreferencesModel {
    let file: ConfigFile
    var parsed: StripConfig.Parsed
    var text = ""
    var error: String?
    var config: StripConfig { parsed.config }

    init(file: ConfigFile) {
        self.file = file
        parsed = StripConfig.parse("")
        refresh()
        file.onChange.append { [weak self] parsed in
            self?.parsed = parsed
            self?.refresh()
        }
    }

    func refresh() {
        let contents: Result<Data, Error>?
        do { contents = .success(try Data(contentsOf: ConfigFile.url)) } catch CocoaError.fileReadNoSuchFile {
            contents = nil
        } catch { contents = .failure(error) }
        text = (try? contents?.get()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        parsed = StripConfig.read(contents, previous: parsed)
    }

    func write(_ edit: (String) -> String) {
        do { try file.write(edit); error = nil } catch { self.error = error.localizedDescription }
    }

    func setting(_ key: String, _ value: String) {
        let line = "\(key) = \(value)"
        guard valid(line) else { return }
        write { StripConfig.setting(key, value, in: $0) }
    }

    private func parsing(_ line: String) -> StripConfig.Parsed {
        StripConfig.parse("meta = \(config.meta == .rightCommand ? "right-command" : "control-option")\n" + line)
    }

    func valid(_ line: String) -> Bool {
        let issues = parsing(line).issues
        error = issues.isEmpty ? nil : issues.map(\.message).joined(separator: "\n")
        return issues.isEmpty
    }

    func entry(_ number: Int?, _ line: String) {
        guard valid(line) else { return }
        let original = text.components(separatedBy: "\n")
        let command = parsing(line).config.commands.first
        let owners = command.map { command in config.bindings.filter { $0.value == command.chord }.map(\.key) } ?? []
        let previous = number.flatMap { original.indices.contains($0 - 1) ? parsing(original[$0 - 1]).config.commands.first : nil }
        let other = command.flatMap { command in config.commands.first { $0.chord == command.chord && $0.chord != previous?.chord } }
        if let command, !owners.isEmpty || other != nil {
            let alert = NSAlert()
            let owner = owners.first.flatMap { StripActions.spec(named: $0)?.title } ?? other!.title
            alert.messageText = "\(keyLabel(command.chord, meta: config.meta)) is used by \(owner). Use it here?"
            alert.addButton(withTitle: "Use It Here"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        var stale = false
        write { fresh in
            // A file edited meanwhile needs a fresh row selection rather than a stale line number.
            if let number {
                let lines = fresh.components(separatedBy: "\n")
                guard lines.indices.contains(number - 1), original.indices.contains(number - 1),
                      lines[number - 1] == original[number - 1] else { stale = true; return fresh }
            }
            var updated: String
            if let number {
                updated = line.isEmpty ? StripConfig.removingLine(number, in: fresh) : StripConfig.replacingLine(number, with: line, in: fresh)
            } else { updated = StripConfig.appending(line, in: fresh) }
            if let command {
                let keptLine = number ?? fresh.components(separatedBy: "\n").count + (fresh.isEmpty || fresh.hasSuffix("\n") ? 0 : 1)
                updated = StripConfig.removingCommands(on: command.chord, exceptLine: keptLine, meta: config.meta, in: updated)
                for owner in owners { updated = StripConfig.binding(owner, nil, meta: config.meta, in: updated) }
            }
            return updated
        }
        if stale { error = "The config file changed. Review the updated row and try again." }
    }

}

@MainActor
final class PreferencesWindow {
    private let window: NSWindow
    private let model: PreferencesModel

    init(configFile: ConfigFile) {
        model = PreferencesModel(file: configFile)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 650),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.title = "tinywm Preferences"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: PreferencesView(model: model))
        hosting.sizingOptions = [.minSize]
        window.contentViewController = hosting
        window.minSize = NSSize(width: 720, height: 500)
        window.setContentSize(NSSize(width: 850, height: 650))
        window.center()
    }

    func show() {
        model.refresh()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

private enum PreferencesPage: String, CaseIterable, Identifiable {
    case general = "General", keys = "Key bindings", gestures = "Gestures", rules = "Rules"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .keys: "keyboard"
        case .gestures: "hand.draw"
        case .rules: "macwindow.on.rectangle"
        }
    }
    var color: Color {
        switch self {
        case .general: .gray
        case .keys: .blue
        case .gestures: .purple
        case .rules: .orange
        }
    }
}

struct PreferencesView: View {
    @Bindable var model: PreferencesModel
    @State private var page: PreferencesPage? = .general

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(PreferencesPage.allCases, selection: $page) { category in
                HStack(spacing: 8) {
                    Image(systemName: category.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(category.color, in: RoundedRectangle(cornerRadius: 5))
                        .accessibilityHidden(true)
                    Text(category.rawValue)
                }.tag(category)
            }
            .navigationSplitViewColumnWidth(215)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch page ?? .general {
                case .general: general
                case .keys: PreferencesKeys(model: model)
                case .gestures: gestures
                case .rules: PreferencesRules(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle((page ?? .general).rawValue)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text((page ?? .general).rawValue).font(.headline)
                }
            }
        }
        .frame(minWidth: 720, idealWidth: 850, minHeight: 500, idealHeight: 650)
    }

    private func toggle(_ title: String, _ key: String, _ path: KeyPath<StripConfig, Bool>, _ help: String) -> some View {
        VStack(alignment: .leading) {
            Toggle(title, isOn: Binding(get: { model.config[keyPath: path] }, set: { model.setting(key, $0 ? "on" : "off") }))
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var general: some View {
        Form {
            PreferencesIssues(model: model)
            Section {
                Picker("Meta key", selection: Binding(get: { model.config.meta == .rightCommand }, set: { model.setting("meta", $0 ? "right-command" : "control-option") })) {
                    Text("Right ⌘").tag(true); Text("⌃⌥").tag(false)
                }.help("Hold this key with a binding.")
                PreferencesGap(model: model)
                VStack(alignment: .leading) {
                    let presets = Array(Set(model.config.widthPresets)).sorted()
                    let selected = presets.first { abs($0 - model.config.defaultWidth) < 0.0005 }
                    Picker("New window width", selection: Binding(get: { selected ?? model.config.defaultWidth }, set: {
                        model.setting("default-width", StripConfig.format($0))
                    })) {
                        ForEach(presets, id: \.self) { width in
                            Text("\(Int((width * 100).rounded()))%").tag(width)
                        }
                        if selected == nil {
                            Text("\(Int((model.config.defaultWidth * 100).rounded()))% (not a step)").tag(model.config.defaultWidth)
                        }
                    }.pickerStyle(.menu)
                    Text("Share of the screen for new apps.").font(.caption).foregroundStyle(.secondary)
                }
                PreferencesWidths(model: model)
            }
            Section {
                toggle("Focus border", "focus-border", \.focusBorder, "Outline the focused window.")
                PreferencesBorderColor(model: model)
                toggle("Center active window", "center-focus", \.centerFocus, "Scrolling to a window centres it, as far as the strip's ends allow.")
                toggle("Continue to the next display", "focus-crosses-displays", \.focusCrossesDisplays, "Focus and move keys go past the strip's last column onto the display beside it.")
                toggle("Show overview with ⌘ + Tab", "overview-as-mission-control", \.overviewOnCommandTab, "Replaces the macOS app switcher.")
                VStack(alignment: .leading) {
                    Picker("Show floating windows strip in overview", selection: Binding(get: { model.config.overviewFloating.rawValue }, set: { model.setting("overview-floating", $0) })) {
                        Text("Vertical").tag("vertical"); Text("Horizontal").tag("horizontal"); Text("Off").tag("off")
                    }
                    Text("Where the overview lines up floating windows, or Off to leave them out.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section { PreferencesLogin() }
        }.formStyle(.grouped)
    }

    @State private var trackpad: [String: Int] = [:]
    private var gestures: some View {
        Form {
            PreferencesIssues(model: model)
            Section {
                toggle("Swipe between columns", "swipe", \.swipe, "Swipe sideways for columns and vertically for workspaces.")
                Picker("Swipe fingers", selection: Binding(get: { model.config.swipeFingers }, set: { model.setting("swipe-fingers", String($0)) })) {
                    Text("3").tag(3); Text("4").tag(4)
                }
                toggle("Pinch for overview", "pinch-overview", \.pinchOverview, "Pinch to open; spread to close.")
                Picker("Pinch fingers (including thumb)", selection: Binding(get: { model.config.pinchFingers }, set: { model.setting("pinch-fingers", String($0)) })) {
                    Text("4").tag(4); Text("5").tag(5)
                }
            }
            let clashes = (model.config.swipe ? SwipeClash.clashes(fingers: model.config.swipeFingers, settings: trackpad) : [])
                + (model.config.pinchOverview ? SwipeClash.pinchClashes(fingers: model.config.pinchFingers, settings: trackpad) : [])
            if !clashes.isEmpty {
                Section("macOS uses the same gestures") {
                    ForEach(clashes, id: \.self) { Text($0) }
                    Button("Open Trackpad Settings…") { SystemSetup.openTrackpadSettings() }
                }
            }
        }.formStyle(.grouped)
            .onAppear { trackpad = SystemSetup.trackpadSettings() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in trackpad = SystemSetup.trackpadSettings() }
    }
}

struct PreferencesIssues: View {
    let model: PreferencesModel

    var body: some View {
        if !model.parsed.issues.isEmpty {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The config file has \(model.parsed.issues.count) problems")
                        Text("See Config Errors in the menu-bar menu.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(8)
                .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        if let error = model.error {
            Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
    }
}

private struct PreferencesBorderColor: View {
    let model: PreferencesModel
    @State private var panel = PreferencesColorPanel()
    private let accents = [
        (name: "Cyan", hex: "16fffa"), (name: "Blue", hex: "007aff"),
        (name: "Purple", hex: "af52de"), (name: "Pink", hex: "ff2d55"),
        (name: "Red", hex: "ff3b30"), (name: "Orange", hex: "ff9500"),
        (name: "Yellow", hex: "ffcc00"), (name: "Green", hex: "28cd41"),
        (name: "Graphite", hex: "8e8e93"),
    ]

    var body: some View {
        let hex = PreferencesColorPanel.hex(model.config.focusBorderColor)
        HStack {
            Text("Focus border color")
            Spacer()
            HStack(spacing: 10) {
                ForEach(accents, id: \.name) { accent in
                    let color = StripConfig.parse("focus-border-color = \(accent.hex)").config.focusBorderColor
                    Button {
                        panel.stop(savePending: false)
                        model.setting("focus-border-color", accent.hex)
                    } label: {
                        Circle().fill(Color(.sRGB, red: color.r, green: color.g, blue: color.b))
                            .frame(width: 18, height: 18)
                            .overlay { ring(hex == accent.hex) }
                    }
                    .buttonStyle(.plain)
                    .help(accent.name)
                    .accessibilityLabel(accent.name)
                    .accessibilityAddTraits(hex == accent.hex ? .isSelected : [])
                }
                Button {
                    panel.show(color: model.config.focusBorderColor) { model.setting("focus-border-color", $0) }
                } label: {
                    Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                        .frame(width: 18, height: 18)
                        .overlay { ring(!accents.contains { $0.hex == hex }) }
                }
                .buttonStyle(.plain)
                .help("Custom")
                .accessibilityLabel("Custom color")
                .accessibilityAddTraits(accents.contains { $0.hex == hex } ? [] : .isSelected)
            }
            .padding(3)
        }
        .disabled(!model.config.focusBorder)
        .opacity(model.config.focusBorder ? 1 : 0.4)
        .onChange(of: model.config.focusBorder) { _, enabled in if !enabled { panel.stop() } }
        .onDisappear { panel.stop() }
    }

    private func ring(_ selected: Bool) -> some View {
        Circle().strokeBorder(selected ? Color.primary : .clear, lineWidth: 1.5).padding(-3)
    }
}

@MainActor
private final class PreferencesColorPanel {
    private var observers: [NSObjectProtocol] = []
    private var pending: Task<Void, Never>?
    private var pendingHex: String?
    private var changed: ((String) -> Void)?

    static func hex(_ color: RGBA) -> String {
        let hex = StripConfig.hex(color)
        return color.a < 1 ? hex : String(hex.prefix(6))
    }

    func show(color: RGBA, changed: @escaping (String) -> Void) {
        let point = NSEvent.mouseLocation
        stop()
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.isContinuous = true
        panel.color = NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: color.a)
        self.changed = changed
        observers.append(NotificationCenter.default.addObserver(forName: NSColorPanel.colorDidChangeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.colorChanged() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                if window === NSColorPanel.shared || window.contentViewController is NSHostingController<PreferencesView> {
                    self?.stop()
                }
            }
        })
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            let size = panel.frame.size
            let right = point.x + 8
            let x = right + size.width <= visible.maxX ? right : point.x - size.width - 8
            panel.setFrameTopLeftPoint(NSPoint(
                x: max(visible.minX, min(x, visible.maxX - size.width)),
                y: min(visible.maxY, max(point.y, visible.minY + size.height))))
        }
        panel.orderFront(nil)
    }

    private func colorChanged() {
        guard let color = NSColorPanel.shared.color.usingColorSpace(.sRGB) else { return }
        pendingHex = Self.hex(RGBA(r: color.redComponent, g: color.greenComponent, b: color.blueComponent, a: color.alphaComponent))
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.commit()
        }
    }

    private func commit() {
        guard let hex = pendingHex else { return }
        pendingHex = nil
        changed?(hex)
    }

    func stop(savePending: Bool = true) {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        pending?.cancel()
        pending = nil
        if savePending { commit() }
        pendingHex = nil
        changed = nil
    }
}

private struct PreferencesGap: View {
    let model: PreferencesModel
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Gap")
                Spacer()
                TextField("Gap", text: Binding(get: { draft }, set: { draft = $0.filter { $0.isASCII && $0.isNumber } }), prompt: Text("0–200"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 50)
                    .focused($editing)
                    .onSubmit { commit() }
                Text("pt").foregroundStyle(.secondary)
                Stepper("Gap", value: Binding(get: { Int(model.config.gap) }, set: { value in
                    draft = String(value)
                    model.setting("gap", draft)
                }), in: 0...200).labelsHidden()
            }
            Text("Space between windows.").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { draft = String(Int(model.config.gap)) }
        .onChange(of: model.config.gap) { _, gap in
            if !editing { draft = String(Int(gap)) }
        }
        .onChange(of: editing) { _, editing in if !editing { commit() } }
        .onDisappear { if editing { commit() } }
    }

    private func commit() {
        guard !draft.isEmpty else { draft = String(Int(model.config.gap)); return }
        let value = min(Int(draft) ?? 200, 200)
        draft = String(value)
        if Double(value) != model.config.gap { model.setting("gap", draft) }
    }
}

private struct PreferencesWidths: View {
    let model: PreferencesModel
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Width steps")
            PreferencesFlow {
                let presets = model.config.widthPresets.sorted()
                ForEach(Array(presets.enumerated()), id: \.offset) { index, width in
                    HStack(spacing: 6) {
                        Text("\(Int((width * 100).rounded()))%")
                        Button { remove(index) } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .disabled(presets.count == 1 || abs(width - model.config.defaultWidth) < 0.0005)
                        .help(abs(width - model.config.defaultWidth) < 0.0005 ? "This is the new window width. Choose another first." : "Remove width")
                        .accessibilityLabel("Remove \(Int((width * 100).rounded())) percent")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(height: 26)
                    .background(.quaternary, in: Capsule())
                }
                HStack(alignment: .center, spacing: 4) {
                    TextField("Add width", text: $draft, prompt: Text("5–100"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: draft) { _, value in
                            draft = value.filter { $0.isASCII && $0.isNumber }
                        }
                        .frame(width: 56)
                        .accessibilityLabel("Add width percent")
                        .onSubmit { add() }
                    Text("%").foregroundStyle(.secondary)
                    Button { add() } label: { Image(systemName: "plus.circle.fill") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Add width")
                }
                .frame(height: 26)
                .fixedSize()
            }
            Text("Widths the width keys step through.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func remove(_ index: Int) {
        var presets = model.config.widthPresets.sorted()
        guard presets.count > 1, presets.indices.contains(index),
              abs(presets[index] - model.config.defaultWidth) >= 0.0005 else { return }
        presets.remove(at: index)
        save(presets)
    }

    private func add() {
        guard let percent = Int(draft), (5...100).contains(percent) else {
            model.error = "Width must be a whole percent from 5 to 100."
            return
        }
        model.error = nil
        guard !model.config.widthPresets.contains(where: { Int(($0 * 100).rounded()) == percent }) else {
            draft = ""
            return
        }
        save(model.config.widthPresets + [Double(percent) / 100])
        draft = ""
    }

    private func save(_ presets: [Double]) {
        model.setting("width-presets", presets.sorted().map(StripConfig.format).joined(separator: ", "))
    }
}

private struct PreferencesFlow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = arrangement(width: bounds.width, subviews: subviews).positions
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + positions[index].x, y: bounds.minY + positions[index].y),
                          anchor: .topLeading, proposal: .unspecified)
        }
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + 6
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + 6
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), positions)
    }
}

private struct PreferencesLogin: View {
    @State private var state = LoginItem.state
    var body: some View {
        Toggle("Launch at login", isOn: Binding(get: { state.isChecked }, set: { _ in LoginItem.toggle(); state = LoginItem.state }))
            .disabled(state == .unavailable)
        if state == .unavailable { Text(LoginItem.unavailableNote).font(.caption).foregroundStyle(.secondary) }
        if state == .needsApproval { Button("Allow in Login Items…") { LoginItem.toggle(); state = LoginItem.state } }
    }
}
