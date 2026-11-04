import AppKit
import ApplicationServices
import Foundation
import StripEngine
import StripModel
import WindowCore
import WindowKit

/// Saves the layout to disk and brings it back when tinywm starts.
///
/// While a restore is pending, windows found at startup are held instead of placed. Once the first
/// scan has settled they are matched against the saved layout in one pass, so the order does not
/// depend on which window the system listed first.
@MainActor
final class LayoutPersistence {
    private let windows: AXWindows
    private let displays: StripDisplays
    private let url: URL
    /// True while windows found at startup are still being read. The restore waits for them,
    /// since an app can take a while to answer.
    var reading: () -> Bool = { false }
    /// The longest the restore waits for those reads.
    var readLimit = 10.0

    /// Names given to windows in the overview, by window id. Ids are not reused within a run.
    var names: [String: String] = [:]

    private var held: [StripDisplays.Pending] = []
    private var holding = false
    /// True while windows found at startup are held for the restore.
    var isRestoring: Bool { holding }
    /// Saving waits for the restore, or the empty startup layout would overwrite the saved one.
    private var ready = false
    private var pendingSave: DispatchWorkItem?
    /// Merging, encoding and writing run here, in order, so the main thread never waits on the disk.
    private let io = DispatchQueue(label: "tinywm.layout", qos: .utility)

    /// Time to let the initial window scan and the windows it triggers arrive before matching.
    var settle = 0.6
    var debounce = 1.0

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/tinywm/layout.json")
    }

    init(windows: AXWindows, displays: StripDisplays, url: URL = LayoutPersistence.defaultURL) {
        self.windows = windows
        self.displays = displays
        self.url = url
        windows.onFocusHistoryChanged = { [weak self] in self?.changed() }
    }

    // MARK: Restore

    /// Call before the first window scan. Windows are held until `settle` has passed.
    func beginRestore() {
        guard load() != nil else { ready = true; return }
        holding = true
        // Counted from the first check, so the settle time does not count against the read limit.
        var start: Double?
        var waitedForUnlock = false
        func check() {
            // While the screen is locked, apps list no windows, so matching now would place every
            // window as new once it is unlocked.
            if Self.screenLocked {
                if !waitedForUnlock { Log.note("restore", "screen is locked; waiting for the unlock") }
                waitedForUnlock = true
                start = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated(check) }
                return
            }
            if waitedForUnlock {
                // The windows come back with the tracker's next sweep, which runs every 3 s.
                waitedForUnlock = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { MainActor.assumeIsolated(check) }
                return
            }
            if start == nil { start = ProcessInfo.processInfo.systemUptime }
            guard let start else { return }
            let waited = ProcessInfo.processInfo.systemUptime - start
            if reading(), waited < readLimit {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated(check) }
                return
            }
            if waited >= readLimit { Log.note("restore", "windows still being read after \(readLimit) s; restoring anyway") }
            finishRestore()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { MainActor.assumeIsolated(check) }
    }

    private static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Takes a window that is about to be placed. Returns true when it is held for the restore.
    func hold(_ id: String, frame: Rect?, recognition: Recognition) -> Bool {
        guard holding, let d = descriptor(of: id) else { return false }
        held.append(.init(live: LiveWindow(id: id, descriptor: d), frame: frame,
                          floating: recognition.placement != .tiled, takesFocus: recognition.allowsFocus))
        return true
    }

    /// The restore keeps the focused window's workspace, so the focus is read first. No focus
    /// change is reported for a window that was already focused when tinywm started.
    private func finishRestore() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return matchHeld() }
        // A managed window read here is recorded as the known focus.
        windows.readFocused(of: front.processIdentifier) { [weak self] _ in self?.matchHeld() }
    }

    private func matchHeld() {
        holding = false
        // A window that closed while held is no longer known.
        let pending = held.filter { windows.element(of: $0.live.id) != nil }
        Log.note("restore", "matching \(pending.count) windows against the saved layout")
        held = []
        if let saved = load() {
            // The layout made for this display setup, else each display's last layout.
            let key = displays.setupKey
            var current = saved
            // An empty setup, left by a start that found no windows, does not count.
            current.displays = saved.setups?[key].flatMap { $0.isEmpty ? nil : $0 } ?? saved.displays
            let restored = displays.restore(current, pending: pending)
            names = restored.names
            // Other setups get their windows now, while every window found at startup is known.
            let live = pending.map(\.live), floating = Set(pending.filter(\.floating).map(\.live.id))
            for (k, s) in saved.setups ?? [:] where k != key {
                let plan = SavedLayout(displays: s).plan(displays: Array(s.keys), windows: live, floating: floating)
                // A setup none of these windows match keeps what the file has.
                guard !plan.workspaces.isEmpty else { continue }
                displays.seed(k, plan.workspaces)
                names.merge(plan.names) { kept, _ in kept }
            }
            windows.restoreFocusHistory(saved.plan(displays: saved.displays.keys.sorted(), windows: live).focusHistory)
        } else {
            for p in pending { displays.windowAdded(p.live.id, frame: p.frame, floating: p.floating, takesFocus: p.takesFocus) }
        }
        ready = true
        scheduleSave()
    }

    private func load() -> SavedLayout? {
        let data: Data
        do { data = try Data(contentsOf: url) } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            Log.note("restore", "could not read \(url.path): \(error)")
            return nil
        }
        guard let saved = SavedLayout.decoded(from: data) else {
            Log.note("restore", "\(url.path) does not decode; starting without the saved layout")
            return nil
        }
        return saved
    }

    // MARK: Save

    /// Set once a logout, restart or shutdown begins. Apps then quit one by one and their windows
    /// leave the layout, so saving stops and the file keeps the layout from before.
    private var poweringOff = false
    private var powerOffWatch: NSObjectProtocol?

    /// Saves once while every window is still placed, then stops saving until the power-off ends.
    func watchPowerOff() {
        powerOffWatch = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.poweringOff else { return }
                Log.note("restore", "logout or shutdown begins; saving the layout and holding it")
                self.saveNow(wait: true)
                self.poweringOff = true
                // ponytail: a cancelled logout gives no notification, so saving resumes after a while.
                DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
                    MainActor.assumeIsolated { self?.poweringOff = false }
                }
            }
        }
    }

    func changed() {
        guard ready else { return }
        scheduleSave()
    }

    private func scheduleSave() {
        guard ready else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// Saves now. Merges into the file so displays that are not attached keep their layout.
    /// `wait` blocks until the file is written, for a save just before tinywm quits.
    func saveNow(wait: Bool = false) {
        pendingSave?.cancel()
        guard ready, !poweringOff else { return }
        let describe = { [self] (id: String) in descriptor(of: id) }
        let current = displays.engines.mapValues { SavedWorkspaces($0.workspaces, describe: describe) }
        var setups = displays.setups.mapValues { $0.mapValues { SavedWorkspaces($0, describe: describe) } }
        setups[displays.setupKey] = current
        let url = url, snapshot = current, kept = setups
        let focusHistory = windows.focusHistory.compactMap(describe)
        let write: @Sendable () -> Void = { Self.write(snapshot, setups: kept, focusHistory: focusHistory, to: url) }
        if wait { io.sync(execute: write) } else { io.async(execute: write) }
    }

    private nonisolated static func write(_ current: [String: SavedWorkspaces], setups: [String: [String: SavedWorkspaces]],
                                         focusHistory: [WindowDescriptor], to url: URL) {
        var saved: SavedLayout?
        do {
            saved = SavedLayout.decoded(from: try Data(contentsOf: url))
            if saved == nil { Log.note("restore", "\(url.path) does not decode; saving over it loses its other displays") }
        } catch CocoaError.fileReadNoSuchFile {
        } catch {
            Log.note("restore", "could not read \(url.path) before saving, so its other displays are lost: \(error)")
        }
        do {
            var merged = (saved ?? SavedLayout()).merged(with: current, setups: setups)
            merged.focusHistory = focusHistory
            let data = try merged.encoded()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.note("restore", "could not save the layout to \(url.path): \(error)")
        }
    }

    /// Built from what is already known, since asking each app would hold up the main thread.
    private func descriptor(of id: String) -> WindowDescriptor? {
        guard windows.element(of: id) != nil, let pid = windows.pid(of: id) else { return nil }
        return WindowDescriptor(windowNumber: windows.number(of: id), bundleID: windows.bundleID(of: id),
                                title: windows.cachedTitle(of: id) ?? "", pid: pid, name: names[id])
    }
}
