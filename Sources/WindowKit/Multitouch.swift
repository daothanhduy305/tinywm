import Foundation
import os

/// Raw trackpad contacts from Apple's private MultitouchSupport framework, through
/// MTDeviceCreateList, MTRegisterContactFrameCallback, MTDeviceStart, MTDeviceStop.
///
/// The framework is opened at runtime, so nothing private is linked. Public gesture events
/// only reach the app under the pointer; these contacts arrive whichever app is in front.
@MainActor
public final class Multitouch {
    /// Positions (0…1, y up) of fingers touching now, and the frame time in seconds.
    public var onFrame: ([(x: Double, y: Double)], Double) -> Void = { _, _ in }
    /// Fingers touching now, and a count of touches that goes up each time the first finger lands.
    /// Set on the framework's thread so event taps read it without lag.
    public nonisolated static let touching = OSAllocatedUnfairLock(initialState: (fingers: 0, touch: 0))

    nonisolated fileprivate static func setTouching(_ n: Int) {
        touching.withLock { if $0.fingers == 0 && n > 0 { $0.touch += 1 }; $0.fingers = n }
    }

    /// Frames waiting for the main thread. While it is busy, a frame replaces the one before it
    /// when the finger count is the same, so a swipe catches up instead of replaying old frames.
    /// Positions are absolute, so no travel is lost; a change in finger count still arrives in order.
    private nonisolated static let pending = OSAllocatedUnfairLock(initialState: [([(x: Double, y: Double)], Double)]())

    /// Queues a frame. Returns true when the main thread must be asked to take the queue.
    nonisolated fileprivate static func enqueue(_ touches: [(x: Double, y: Double)], _ t: Double) -> Bool {
        pending.withLock {
            let wasEmpty = $0.isEmpty
            if let last = $0.last, last.0.count == touches.count { $0[$0.count - 1] = (touches, t) }
            else { $0.append((touches, t)) }
            return wasEmpty
        }
    }

    private var devices: [UnsafeMutableRawPointer] = []
    private var stop: StopFn?
    nonisolated(unsafe) fileprivate static var current: Multitouch?

    private typealias Callback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
    ) -> Int32
    private typealias CreateListFn = @convention(c) () -> Unmanaged<CFArray>?
    private typealias RegisterFn = @convention(c) (UnsafeMutableRawPointer, Callback) -> Void
    private typealias StartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    private typealias StopFn = @convention(c) (UnsafeMutableRawPointer) -> Void

    public init() {}

    /// Starts listening. Returns false when the framework or a trackpad is missing.
    @discardableResult
    public func start() -> Bool {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let lib = dlopen(path, RTLD_NOW),
              let createSym = dlsym(lib, "MTDeviceCreateList"),
              let registerSym = dlsym(lib, "MTRegisterContactFrameCallback"),
              let startSym = dlsym(lib, "MTDeviceStart"),
              let stopSym = dlsym(lib, "MTDeviceStop") else { return false }
        let create = unsafeBitCast(createSym, to: CreateListFn.self)
        let register = unsafeBitCast(registerSym, to: RegisterFn.self)
        let startDevice = unsafeBitCast(startSym, to: StartFn.self)
        stop = unsafeBitCast(stopSym, to: StopFn.self)

        guard let list = create()?.takeRetainedValue() else { return false }
        Self.current = self
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            register(device, contactCallback)
            startDevice(device, 0)
            devices.append(device)
        }
        return !devices.isEmpty
    }

    fileprivate func drain() {
        let frames = Self.pending.withLock { f in defer { f = [] }; return f }
        for (touches, t) in frames { onFrame(touches, t) }
    }
}

/// One finger in MultitouchSupport's 96-byte contact record.
private enum Touch {
    static let stride = 96
    static let stateOffset = 20
    static let xOffset = 32
    static let yOffset = 36
    /// "Make touch" and "touching": a finger resting on the pad.
    static let touchingStates: Set<Int32> = [3, 4]
}

/// Records the fingers touching and hands the frame to the main thread, unless a hop is already waiting.
private func post(_ touches: [(x: Double, y: Double)], _ t: Double) {
    Multitouch.setTouching(touches.count)
    guard Multitouch.enqueue(touches, t) else { return }
    DispatchQueue.main.async { MainActor.assumeIsolated { Multitouch.current?.drain() } }
}

/// Runs on MultitouchSupport's own thread, so it copies the touches and hops to the main thread.
private let contactCallback: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
) -> Int32 = { _, data, count, timestamp, _ in
    guard let data, count > 0 else { post([], timestamp); return 0 }
    var touches: [(x: Double, y: Double)] = []
    for i in 0..<Int(count) {
        let base = data + i * Touch.stride
        let state = base.load(fromByteOffset: Touch.stateOffset, as: Int32.self)
        guard Touch.touchingStates.contains(state) else { continue }
        let x = Double(base.load(fromByteOffset: Touch.xOffset, as: Float.self))
        let y = Double(base.load(fromByteOffset: Touch.yOffset, as: Float.self))
        touches.append((x, y))
    }
    post(touches, timestamp)
    return 0
}
