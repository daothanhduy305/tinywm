import ApplicationServices
import CoreGraphics
import Foundation
import WindowCore

/// Maps Accessibility windows to CGWindowIDs, which ScreenCaptureKit needs.
///
/// Primary: the SPI `_AXUIElementGetWindow`, resolved with dlsym so nothing private is linked.
/// It is exact and has been stable for over a decade; many window managers rely on it.
/// Fallback when the symbol is missing or fails: match the CGWindow list by owner pid,
/// frame and title.
public enum WindowNumbers {
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let getWindow: GetWindow? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(sym, to: GetWindow.self)
    }()

    public static func windowID(of element: AXUIElement, pid: pid_t) -> CGWindowID? {
        if let id = exactWindowID(of: element) { return id }
        return match(pid: pid, frame: AX.frame(element),
                     title: AX.attribute(element, kAXTitleAttribute, as: String.self))
    }

    /// The window number from the SPI alone, without the fallback match, which two windows of one
    /// app at the same frame would confuse.
    public static func exactWindowID(of element: AXUIElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var id: CGWindowID = 0
        return getWindow(element, &id) == .success && id != 0 ? id : nil
    }

    private typealias CreateWithToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

    private static let createWithToken: CreateWithToken? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementCreateWithRemoteToken") else { return nil }
        return unsafeBitCast(sym, to: CreateWithToken.self)
    }()

    /// The app's fullscreen windows on Spaces not shown, which its window list leaves out. They are
    /// found by trying the app's element numbers through the SPI `_AXUIElementCreateWithRemoteToken`,
    /// as AltTab does, and keeping the elements whose window number matches. `known` are window
    /// numbers already in hand. Waits for the app, so call it off the main thread.
    public static func fullScreenElsewhere(pid: pid_t, known: Set<CGWindowID>) -> [AXUIElement] {
        let displays = AX.displayBounds()
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var wanted = Set(list.compactMap { info -> CGWindowID? in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid, (info[kCGWindowLayer as String] as? Int) == 0,
                  info[kCGWindowIsOnscreen as String] as? Bool != true,
                  let id = info[kCGWindowNumber as String] as? CGWindowID, !known.contains(id),
                  let b = info[kCGWindowBounds as String] as? [String: Double] else { return nil }
            let r = Rect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            return displays.contains { r.isApproximately($0, tolerance: 1) } ? id : nil
        })
        guard !wanted.isEmpty, let createWithToken else { return [] }
        // The token is the process ID, four zero bytes, "coco", then the element number.
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
        var found: [AXUIElement] = []
        // ponytail: blind scan of the first 1000 element numbers, capped at half a second per app.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        for n in UInt64(0)..<1000 where !wanted.isEmpty && ProcessInfo.processInfo.systemUptime < deadline {
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: n) { Data($0) })
            guard let element = createWithToken(token as CFData)?.takeRetainedValue(),
                  let id = exactWindowID(of: element), wanted.remove(id) != nil else { continue }
            found.append(element)
        }
        return found
    }

    /// Which of these windows still exist, and whether each is shown. An app's hidden tab, a
    /// minimized window or one of a hidden app still exists but is not shown. Asks only the window
    /// server, never the app, so it is quick and never waits.
    public static func states(_ numbers: [CGWindowID]) -> [CGWindowID: Bool] {
        guard !numbers.isEmpty else { return [:] }
        var values = numbers.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        let array = CFArrayCreate(nil, &values, values.count, nil)
        let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] ?? []
        var states: [CGWindowID: Bool] = [:]
        for info in list {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            states[id] = info[kCGWindowIsOnscreen as String] as? Bool ?? false
        }
        return states
    }

    private static func match(pid: pid_t, frame: Rect?, title: String?) -> CGWindowID? {
        guard let frame,
              let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        var best: (id: CGWindowID, score: Int)?
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let b = info[kCGWindowBounds as String] as? [String: Double] else { continue }
            let r = Rect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard r.isApproximately(frame, tolerance: 2) else { continue }
            let score = (title != nil && (info[kCGWindowName as String] as? String) == title) ? 2 : 1
            if score > (best?.score ?? 0) { best = (id, score) }
        }
        return best?.id
    }
}
