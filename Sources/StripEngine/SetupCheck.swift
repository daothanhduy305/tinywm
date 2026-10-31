/// The macOS settings and other apps that work against tinywm, as the About page lists them.
public enum SetupCheck {
    public struct Result: Equatable, Sendable {
        public var ok: Bool
        public var status: String

        public init(ok: Bool, status: String) {
            self.ok = ok
            self.status = status
        }
    }

    /// The `com.apple.WindowManager` key that is on while Stage Manager runs.
    public static let stageManagerKey = "GloballyEnabled"

    public static func stageManager(settings: [String: Int]) -> Result {
        (settings[stageManagerKey] ?? 0) != 0
            ? Result(ok: false, status: "On. It shrinks windows into a side strip.")
            : Result(ok: true, status: "Off")
    }

    /// The `com.apple.WindowManager` keys for tiling a window by dragging it to a screen edge.
    /// Holding ⌥ while dragging is left out, since it only acts when asked.
    public static let edgeTilingKeys = ["EnableTilingByEdgeDrag", "EnableTopTilingByEdgeDrag"]

    /// macOS 15 turns edge tiling on by default, so a missing key counts as on.
    public static func edgeTiling(settings: [String: Int]) -> Result {
        edgeTilingKeys.contains { (settings[$0] ?? 1) != 0 }
            ? Result(ok: false, status: "On. A window dragged to an edge snaps out of the strip.")
            : Result(ok: true, status: "Off")
    }

    /// The `com.apple.WindowManager` key for "Click wallpaper to reveal desktop": 0 means only
    /// in Stage Manager. macOS 14 sets it to Always by default, so a missing key counts as on.
    public static let clickWallpaperKey = "EnableStandardClickToShowDesktop"

    public static func clickWallpaper(settings: [String: Int]) -> Result {
        (settings[clickWallpaperKey] ?? 1) != 0
            ? Result(ok: false, status: "Always. A click on the desktop sweeps every window aside. Set it to Only in Stage Manager.")
            : Result(ok: true, status: "Only in Stage Manager")
    }

    public enum Match: Equatable, Sendable {
        case app(bundleID: String)
        /// A daemon with no app, found by its exact process name.
        case process(name: String)
    }

    public static let windowManagers: [(name: String, match: Match)] = [
        ("Rectangle", .app(bundleID: "com.knollsoft.Rectangle")),
        ("Rectangle Pro", .app(bundleID: "com.knollsoft.Hookshot")),
        ("Magnet", .app(bundleID: "com.crowdcafe.windowmagnet")),
        ("Moom", .app(bundleID: "com.manytricks.Moom")),
        ("BetterSnapTool", .app(bundleID: "com.hegenberg.BetterSnapTool")),
        ("Spectacle", .app(bundleID: "com.divisiblebyzero.Spectacle")),
        ("Amethyst", .app(bundleID: "com.amethyst.Amethyst")),
        ("AeroSpace", .app(bundleID: "bobko.aerospace")),
        ("Loop", .app(bundleID: "com.MrKai77.Loop")),
        ("yabai", .process(name: "yabai")),
    ]

    public static func otherWindowManagers(bundleIDs: Set<String>, processNames: Set<String>) -> Result {
        let running = windowManagers.filter {
            switch $0.match {
            case .app(let id): bundleIDs.contains(id)
            case .process(let name): processNames.contains(name)
            }
        }.map(\.name)
        guard !running.isEmpty else { return Result(ok: true, status: "None running") }
        return Result(ok: false, status: "\(list(running)) \(running.count == 1 ? "is" : "are") running. Quit \(running.count == 1 ? "it" : "them") so windows stay where tinywm puts them.")
    }

    private static func list(_ items: [String]) -> String {
        items.count < 2 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items.last!
    }
}
