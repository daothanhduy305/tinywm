/// Turns four- or five-finger pinches and spreads into one event per touch.
/// The 0.8 ratio catches measured pinches at 0.70–0.77; swipes stay at or above 0.85.
public struct PinchRecognizer: Sendable {
    public enum Event: Equatable, Sendable { case pinchIn, spreadOut }

    public var fingers = 4...5
    public var ratio = 0.8

    private var origin: Double?
    private var count = 0
    private var fired = false

    public init() {}

    public mutating func feed(_ touches: [(x: Double, y: Double)], at t: Double) -> Event? {
        guard fingers.contains(touches.count) else {
            origin = nil
            count = 0
            fired = false
            return nil
        }
        if count != touches.count {
            origin = nil
            count = touches.count
        }
        guard !fired else { return nil }
        let x = touches.map(\.x).reduce(0, +) / Double(touches.count)
        let y = touches.map(\.y).reduce(0, +) / Double(touches.count)
        let spread = touches.map { (($0.x - x) * ($0.x - x) + ($0.y - y) * ($0.y - y)).squareRoot() }
            .reduce(0, +) / Double(touches.count)
        guard let origin else {
            origin = spread
            return nil
        }
        guard origin > 0 else { return nil }
        let event: Event
        if spread <= origin * ratio { event = .pinchIn }
        else if spread >= origin / ratio { event = .spreadOut }
        else { return nil }
        fired = true
        return event
    }
}
