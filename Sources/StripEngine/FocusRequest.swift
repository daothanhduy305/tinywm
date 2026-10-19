/// Tells an app overriding a focus tinywm asked for from a focus change the user made.
///
/// tinywm raises a window and activates its app. An app with windows on several displays, such
/// as a browser, may then make its last key window key again, which can sit on another display.
/// Following that would pull focus back to where the user just left.
public struct FocusRequest: Sendable {
    /// The window tinywm last focused, its app, and when, as seconds of uptime.
    public private(set) var asked: (window: String, app: Int32, at: Double)?

    public init() {}

    public mutating func asked(_ window: String, app: Int32, at: Double) { asked = (window, app, at) }

    public mutating func clear() { asked = nil }

    /// The window to focus again when `window` of `app` taking focus is the app overriding the
    /// request, else nil. Another app taking focus ends the request.
    public mutating func overridden(by window: String, app: Int32, now: Double, secondsSinceInput: Double) -> String? {
        guard let a = asked else { return nil }
        guard a.app == app else {
            asked = nil
            return nil
        }
        let age = now - a.at
        guard window != a.window, age < FocusIntent.ownWindow, secondsSinceInput >= age else { return nil }
        return a.window
    }
}
