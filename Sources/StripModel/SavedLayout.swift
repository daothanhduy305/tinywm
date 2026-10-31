import Foundation

/// What identifies a window across a tinywm restart. Window IDs like "w3" are per run, so a saved
/// layout names windows by facts the system keeps.
public struct WindowDescriptor: Codable, Equatable, Sendable {
    /// The CGWindowID, which stays the same while the app keeps the window open.
    public var windowNumber: UInt32?
    public var bundleID: String?
    public var title: String
    public var pid: Int32
    /// The name given to the window in the overview, if any.
    public var name: String?

    public init(windowNumber: UInt32?, bundleID: String?, title: String, pid: Int32, name: String? = nil) {
        self.windowNumber = windowNumber; self.bundleID = bundleID; self.title = title; self.pid = pid; self.name = name
    }
}

public struct SavedColumn: Codable, Equatable, Sendable {
    public var windows: [WindowDescriptor]
    public var focused: Int
    public var width: Double
}

public struct SavedStrip: Codable, Equatable, Sendable {
    public var columns: [SavedColumn]
    public var focusedColumn: Int?
    public var scroll: Double
    public var floating: [WindowDescriptor]
}

/// One display's workspaces with windows replaced by descriptors.
public struct SavedWorkspaces: Codable, Equatable, Sendable {
    public var strips: [SavedStrip]
    public var active: Int

    public init(strips: [SavedStrip], active: Int) { self.strips = strips; self.active = active }

    /// Captures a display's layout. A window `describe` cannot name is left out.
    public init(_ workspaces: Workspaces, describe: (String) -> WindowDescriptor?) {
        var out: [SavedStrip] = []
        for s in workspaces.strips {
            var columns: [SavedColumn] = []
            var focusedColumn: Int?
            for (i, c) in s.columns.enumerated() {
                let named = c.windows.map { ($0, describe($0)) }
                let kept = named.compactMap(\.1)
                guard !kept.isEmpty else { continue }
                let focusedWindow = c.windows.indices.contains(c.focused) ? c.windows[c.focused] : c.windows.first
                let focused = named.filter { $0.1 != nil }.firstIndex { $0.0 == focusedWindow } ?? 0
                if s.focusedColumn == i { focusedColumn = columns.count }
                columns.append(SavedColumn(windows: kept, focused: focused, width: c.width))
            }
            out.append(SavedStrip(
                columns: columns, focusedColumn: focusedColumn ?? (columns.isEmpty ? nil : 0), scroll: s.scroll,
                floating: s.floating.compactMap(describe)))
        }
        self.init(strips: out, active: workspaces.active)
    }
}

/// The file on disk: every display's layout by display UUID.
public struct SavedLayout: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version = SavedLayout.currentVersion
    public var displays: [String: SavedWorkspaces] = [:]
    /// Each display setup's layout, by its sorted display UUIDs joined with commas. Nil in files
    /// from before setups were kept.
    public var setups: [String: [String: SavedWorkspaces]]?

    public init(displays: [String: SavedWorkspaces] = [:], setups: [String: [String: SavedWorkspaces]]? = nil) {
        self.displays = displays; self.setups = setups
    }

    /// Replaces the given displays and setups and keeps the rest, so a display that is unplugged
    /// or switched off, and a setup not in use, still has its layout when it returns.
    public func merged(with current: [String: SavedWorkspaces], setups: [String: [String: SavedWorkspaces]] = [:]) -> SavedLayout {
        var out = self
        for (id, w) in current { out.displays[id] = w }
        if !setups.isEmpty { out.setups = (out.setups ?? [:]).merging(setups) { $1 } }
        return out
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Nil for data that is not a layout or comes from a newer format.
    public static func decoded(from data: Data) -> SavedLayout? {
        guard let layout = try? JSONDecoder().decode(SavedLayout.self, from: data),
              layout.version == currentVersion else { return nil }
        return layout
    }
}
