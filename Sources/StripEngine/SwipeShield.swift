/// Decides which scroll and gesture events to keep from apps during a tinywm swipe.
///
/// macOS turns the touches tinywm reads into scroll events (apps scroll, browsers go back) and
/// gesture events (Safari's swipe back). While tinywm's finger count is on the pad these belong
/// to the swipe. The scroll that started then is dropped to its end, through the fingers lifting
/// and its momentum, so the tail does not reach the app either.
public struct SwipeShield: Sendable {
    public enum Event: Sendable {
        /// Raw scroll and momentum phases (CGScrollPhase, CGMomentumScrollPhase); both are 0 for a mouse wheel.
        case scroll(phase: Int, momentum: Int)
        case gesture
    }

    public var enabled = true
    public var fingers = 3
    private var swallowing = false

    public init() {}

    /// Whether to drop `event`, with `touching` fingers on the pad now.
    public mutating func shouldDrop(_ event: Event, touching: Int) -> Bool {
        guard enabled else { swallowing = false; return false }
        let ours = touching == fingers
        switch event {
        case .gesture:
            return ours
        case .scroll(let phase, let momentum):
            // A new trackpad scroll (began) or a mouse wheel (no phases) ends the swallowed one.
            if !ours && (phase == Self.began || (phase == 0 && momentum == 0)) { swallowing = false }
            if ours { swallowing = true }
            return swallowing
        }
    }

    private static let began = 1
}
