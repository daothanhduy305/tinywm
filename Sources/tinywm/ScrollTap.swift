import AppKit
import StripEngine
import WindowKit

/// Keeps the scroll and gesture events macOS makes from a tinywm swipe away from apps.
/// `SwipeShield` decides; this is the event tap around it.
@MainActor
final class ScrollTap {
    var shield = SwipeShield()
    private var tap: CFMachPort?

    func start() {
        guard tap == nil else { return }
        // 29 is NSEventTypeGesture, which has no CGEventType case.
        let mask = (1 << CGEventType.scrollWheel.rawValue) | (1 << 29)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: scrollTapCallback, userInfo: me
        ) else { return }
        tap = port
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// Returns true when the event must not reach apps; nil means macOS turned the tap off.
    fileprivate func handle(_ e: SwipeShield.Event?) -> Bool {
        guard let e else {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        return shield.shouldDrop(e, touching: Multitouch.touching.withLock { $0 })
    }
}

private func scrollTapCallback(
    _: CGEventTapProxy, type: CGEventType, event: CGEvent, info: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let info else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<ScrollTap>.fromOpaque(info).takeUnretainedValue()
    let e: SwipeShield.Event?
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        e = nil
    case .scrollWheel:
        e = .scroll(phase: Int(event.getIntegerValueField(.scrollWheelEventScrollPhase)),
                    momentum: Int(event.getIntegerValueField(.scrollWheelEventMomentumPhase)))
    default:
        e = .gesture
    }
    let drop = MainActor.assumeIsolated { tap.handle(e) }
    return drop ? nil : Unmanaged.passUnretained(event)
}
