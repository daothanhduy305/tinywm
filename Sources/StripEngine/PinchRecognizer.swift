/// Turns pinches and spreads with exactly `fingers` contacts into one event per touch.
/// The 0.8 ratio catches measured pinches at 0.70–0.77; swipes stay at or above 0.85.
public struct PinchRecognizer: Sendable {
    public enum Event: Equatable, Sendable { case pinchIn, spreadOut }

    public var fingers = 5
    public var ratio = 0.8

    private var origin: Double?
    private var fired = false

    public init() {}

    /// Reports only `want`, measured from the widest spread of this touch for a pinch or the
    /// narrowest for a spread. The other direction never uses up the touch, so fingers that
    /// settle outward first can still pinch.
    public mutating func feed(_ touches: [(x: Double, y: Double)], at t: Double, want: Event) -> Event? {
        guard touches.count == fingers else {
            origin = nil
            fired = false
            return nil
        }
        guard !fired else { return nil }
        let x = touches.map(\.x).reduce(0, +) / Double(touches.count)
        let y = touches.map(\.y).reduce(0, +) / Double(touches.count)
        let spread = touches.map { (($0.x - x) * ($0.x - x) + ($0.y - y) * ($0.y - y)).squareRoot() }
            .reduce(0, +) / Double(touches.count)
        guard let start = origin else {
            origin = spread
            return nil
        }
        let base = want == .pinchIn ? max(start, spread) : min(start, spread)
        origin = base
        guard base > 0 else { return nil }
        let hit = want == .pinchIn ? spread <= base * ratio : spread >= base / ratio
        guard hit else { return nil }
        fired = true
        return want
    }
}
