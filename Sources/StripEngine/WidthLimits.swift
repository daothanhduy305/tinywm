/// The narrowest and widest widths each app lets its windows take, learned from the widths it refuses.
///
/// Keyed by bundle ID, so a new window of an app that refused before gets a fitting column at once.
public struct WidthLimits: Codable, Equatable, Sendable {
    public private(set) var minimums: [String: Double]
    public private(set) var maximums: [String: Double]

    /// Differences smaller than this are rounding, not a refusal.
    static let tolerance = 2.0
    /// A window that comes back this close to the screen's width was not refusing a width,
    /// as when it is zoomed to fill the screen, so it teaches nothing.
    static let nearlyScreen = 0.95

    public init(_ minimums: [String: Double] = [:], maximums: [String: Double] = [:]) {
        self.minimums = minimums
        self.maximums = maximums
    }

    public func minimum(for app: String) -> Double? { minimums[app] }
    public func maximum(for app: String) -> Double? { maximums[app] }

    /// Records that a window of `app` took `took` points when asked for `asked`: wider teaches
    /// a minimum, narrower a maximum, each only when its flag is on. Returns whether a learned width changed.
    public mutating func refused(app: String, asked: Double, took: Double, screenWidth: Double,
                                 minimums learnMinimums: Bool = true, maximums learnMaximums: Bool = true) -> Bool {
        if learnMinimums, took > asked + Self.tolerance, took < screenWidth * Self.nearlyScreen,
           took > (minimums[app] ?? 0) + Self.tolerance {
            minimums[app] = took
            return true
        }
        if learnMaximums, took < asked - Self.tolerance, took < (maximums[app] ?? .infinity) - Self.tolerance {
            maximums[app] = took
            return true
        }
        return false
    }

    /// Records a window of `app` seen `width` points wide. Narrower than the learned minimum
    /// proves the app allows it, so the minimum comes down; wider than the learned maximum
    /// raises it, each only when its flag is on. Returns whether a learned width changed.
    public mutating func seen(app: String, width: Double, minimums learnMinimums: Bool = true, maximums learnMaximums: Bool = true) -> Bool {
        if learnMinimums, let learned = minimums[app], width < learned - Self.tolerance {
            minimums[app] = width
            return true
        }
        if learnMaximums, let learned = maximums[app], width > learned + Self.tolerance {
            maximums[app] = width
            return true
        }
        return false
    }
}
