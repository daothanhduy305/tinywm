/// Permission rules for the About page, kept free of AppKit so they can be tested.
public enum Onboarding {
    /// macOS applies a new Screen Recording grant only to processes started afterwards.
    public static func needsRestart(screenRecordingAtLaunch: Bool, screenRecordingNow: Bool, inBundle: Bool) -> Bool {
        inBundle && screenRecordingNow && !screenRecordingAtLaunch
    }
}

/// The Open at Login switch, independent of ServiceManagement.
public enum LoginItemState: Equatable, Sendable {
    /// Not running from an app bundle, so there is nothing to register.
    case unavailable
    case off
    case on
    /// Registered, but the user still has to allow it in Login Items settings.
    case needsApproval

    public enum Action: Equatable, Sendable { case register, unregister, openSettings, none }

    public var isChecked: Bool { self == .on || self == .needsApproval }

    public var action: Action {
        switch self {
        case .unavailable: .none
        case .off: .register
        case .on: .unregister
        case .needsApproval: .openSettings
        }
    }
}
