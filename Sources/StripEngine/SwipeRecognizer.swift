/// Turns raw trackpad contact frames into strip swipes.
///
/// Coordinates are normalised to the trackpad (0…1, y up). A swipe needs exactly `fingers`
/// touching. It starts after the fingers' average position travels `startDistance`, and locks to
/// the axis that leads by `axisRatio`. The defaults, 0.03 and 1.2, keep a resting hand from
/// starting a swipe and keep diagonal drags from picking an axis.
///
/// Every finger must also move the same way: each one's travel along the average's direction must
/// be at least `together` of the average's travel. In a pinch the fingers move toward each other,
/// so the average can drift without starting a swipe.
public struct SwipeRecognizer: Sendable {
    public enum Axis: Sendable { case horizontal, vertical }

    public enum Event: Equatable, Sendable {
        case began(Axis)
        /// Travel since the last event, in trackpad units.
        case moved(dx: Double, dy: Double)
        /// Fingers lifted. Velocity in trackpad units per second along the locked axis.
        case ended(velocity: Double)
        case cancelled
    }

    public var fingers = 3
    public var startDistance = 0.03
    public var axisRatio = 1.2
    public var together = 0.5

    private var origin: (x: Double, y: Double)?
    private var originSpread = 0.0
    /// Where each finger was when the origin was set.
    private var starts: [Int: (x: Double, y: Double)] = [:]
    private var last: (x: Double, y: Double, t: Double)?
    private var axis: Axis?
    /// Recent samples along the axis, to estimate the lift-off velocity.
    private var samples: [(t: Double, v: Double)] = []

    public init() {}

    /// Feeds one contact frame: the fingers touching now, at time `t` (seconds).
    public mutating func feed(_ touches: [(id: Int, x: Double, y: Double)], at t: Double) -> [Event] {
        guard touches.count == fingers else { return finish(at: t) }
        // A finger swapped for another in the same frame starts a new touch.
        if origin != nil, Set(touches.map(\.id)) != Set(starts.keys) { return finish(at: t) }
        let x = touches.map(\.x).reduce(0, +) / Double(touches.count)
        let y = touches.map(\.y).reduce(0, +) / Double(touches.count)
        let spread = touches.map { (($0.x - x) * ($0.x - x) + ($0.y - y) * ($0.y - y)).squareRoot() }
            .reduce(0, +) / Double(touches.count)
        guard let o = origin, let l = last else {
            origin = (x, y)
            originSpread = spread
            starts = Dictionary(touches.map { ($0.id, ($0.x, $0.y)) }, uniquingKeysWith: { a, _ in a })
            last = (x, y, t)
            return []
        }
        var events: [Event] = []
        if axis == nil {
            let dx = x - o.x, dy = y - o.y
            let distance = (dx * dx + dy * dy).squareRoot()
            guard distance >= startDistance, abs(spread - originSpread) <= distance else { return [] }
            let movedTogether = touches.allSatisfy { c in
                let s = starts[c.id]!
                return ((c.x - s.x) * dx + (c.y - s.y) * dy) / distance >= together * distance
            }
            guard movedTogether else { return [] }
            if abs(dx) >= axisRatio * abs(dy) { axis = .horizontal }
            else if abs(dy) >= axisRatio * abs(dx) { axis = .vertical }
            else { return [] }
            events.append(.began(axis!))
            // The travel that crossed the threshold counts, so the strip does not lag the fingers.
            events.append(.moved(dx: dx, dy: dy))
        } else {
            events.append(.moved(dx: x - l.x, dy: y - l.y))
        }
        let along = axis == .horizontal ? x : y
        samples.append((t, along))
        samples.removeAll { t - $0.t > 0.08 }
        last = (x, y, t)
        return events
    }

    /// Fingers changed count or lifted: ends a swipe in progress.
    private mutating func finish(at t: Double) -> [Event] {
        defer { origin = nil; last = nil; axis = nil; samples = []; starts = [:] }
        guard axis != nil else { return [] }
        guard let first = samples.first, let lastSample = samples.last, lastSample.t > first.t else {
            return [.ended(velocity: 0)]
        }
        return [.ended(velocity: (lastSample.v - first.v) / (lastSample.t - first.t))]
    }
}
