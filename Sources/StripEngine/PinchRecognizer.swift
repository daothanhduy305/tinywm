/// Turns pinches and spreads with exactly `fingers` moving contacts into one event per touch.
/// The 0.8 ratio catches measured pinches at 0.70–0.77; swipes stay at or above 0.85.
///
/// Only contacts that move count. A palm or an idle thumb resting on the pad stays where it
/// landed, so it neither counts as a finger nor restarts the gesture by landing or lifting.
public struct PinchRecognizer: Sendable {
    public enum Event: Equatable, Sendable { case pinchIn, spreadOut }
    public typealias Contact = (id: Int, x: Double, y: Double)

    public var fingers = 5
    public var ratio = 0.8
    /// A contact counts as a finger once it has moved this far from where it landed (pad widths)…
    public var minTravel = 0.02
    /// …and at least this share of the farthest any contact has moved. A thumb travels about
    /// twice as far as a little finger; a resting palm hardly moves at all.
    public var follow = 0.3

    /// Where each contact touching now landed, or where it was when the gesture last re-armed.
    private var landed: [Int: (x: Double, y: Double)] = [:]
    /// The farthest each contact has been from where it landed, so a finger that goes out and
    /// comes back still counts as moving.
    private var travel: [Int: Double] = [:]
    /// The moving contacts the baseline belongs to.
    private var moving: Set<Int> = []
    private var base: Double?
    private var fired = false

    public init() {}

    /// Reports only `want`, measured from the widest spread of the moving fingers for a pinch or
    /// the narrowest for a spread. The other direction never uses up the touch, so fingers that
    /// settle outward first can still pinch. After firing, a contact landing or lifting starts a
    /// new gesture from where the fingers are then.
    public mutating func feed(_ touches: [Contact], at t: Double, want: Event) -> Event? {
        let ids = Set(touches.map(\.id))
        if touches.isEmpty || (fired && ids != Set(landed.keys)) {
            fired = false
            landed = [:]
            travel = [:]
            moving = []
            base = nil
        }
        landed = landed.filter { ids.contains($0.key) }
        travel = travel.filter { ids.contains($0.key) }
        for c in touches {
            guard let start = landed[c.id] else {
                landed[c.id] = (c.x, c.y)
                travel[c.id] = 0
                continue
            }
            let d = ((c.x - start.x) * (c.x - start.x) + (c.y - start.y) * (c.y - start.y)).squareRoot()
            travel[c.id] = max(travel[c.id] ?? 0, d)
        }
        guard !fired else { return nil }

        let most = travel.values.max() ?? 0
        let fingersNow = touches.filter { travel[$0.id]! >= minTravel && travel[$0.id]! >= most * follow }
        let now = Set(fingersNow.map(\.id))
        guard now.count == fingers else { return nil }

        let spread = Self.spread(fingersNow.map { ($0.x, $0.y) })
        if now != moving || base == nil {
            moving = now
            base = Self.spread(fingersNow.map { landed[$0.id]! })
        }
        let b = want == .pinchIn ? max(base!, spread) : min(base!, spread)
        base = b
        guard b > 0 else { return nil }
        let hit = want == .pinchIn ? spread <= b * ratio : spread >= b / ratio
        guard hit else { return nil }
        fired = true
        return want
    }

    /// Mean distance from the points' centre.
    private static func spread(_ points: [(x: Double, y: Double)]) -> Double {
        let x = points.map(\.x).reduce(0, +) / Double(points.count)
        let y = points.map(\.y).reduce(0, +) / Double(points.count)
        return points.map { (($0.x - x) * ($0.x - x) + ($0.y - y) * ($0.y - y)).squareRoot() }
            .reduce(0, +) / Double(points.count)
    }
}
