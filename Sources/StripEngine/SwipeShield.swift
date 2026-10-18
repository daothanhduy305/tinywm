/// Decides which scroll and gesture events to keep from apps during a tinywm swipe.
///
/// macOS turns the touches tinywm reads into scroll events (apps scroll, browsers go back) and
/// gesture events (Safari's swipe back). While tinywm's finger count is on the pad these belong
/// to the swipe. Scrolls stay dropped until one begins in a later touch: as fingers lift unevenly,
/// macOS restarts the scroll with the fingers left and adds momentum, which must not reach the
/// app either.
public struct SwipeShield: Sendable {
    public enum Event: Sendable {
        /// Raw scroll and momentum phases (CGScrollPhase, CGMomentumScrollPhase); both are 0 for a mouse wheel.
        case scroll(phase: Int, momentum: Int)
        case gesture
    }

    public var enabled = true
    public var fingers = 3
    /// The touch whose scrolls are being dropped.
    private var swallowing: Int?

    public init() {}

    /// Whether to drop `event`, with `touching` fingers on the pad now during touch number `touch`.
    public mutating func shouldDrop(_ event: Event, touching: Int, touch: Int) -> Bool {
        guard enabled else { swallowing = nil; return false }
        let ours = touching == fingers
        switch event {
        case .gesture:
            return ours
        case .scroll(let phase, let momentum):
            if ours {
                swallowing = touch
            } else if (phase == Self.began && touch != swallowing) || (phase == 0 && momentum == 0) {
                // A scroll in a later touch, or a mouse wheel (no phases), ends the swallowed one.
                swallowing = nil
            }
            return swallowing != nil
        }
    }

    private static let began = 1
}
