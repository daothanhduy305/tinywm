import AppKit
import ServiceManagement
import WindowCore
import StripEngine

/// Open at Login through the app's own login item. It only exists for an installed .app.
@MainActor
enum LoginItem {
    static var inBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static let unavailableNote = "Available in the installed app"

    static var state: LoginItemState {
        guard inBundle else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .notRegistered, .notFound: return .off
        @unknown default: return .off
        }
    }

    /// Flips the setting. A fresh registration that macOS holds for approval opens Login Items.
    static func toggle() {
        switch state.action {
        case .register:
            do { try SMAppService.mainApp.register() } catch { Log.note("login", "could not add tinywm to Login Items: \(error)") }
            if state == .needsApproval { SMAppService.openSystemSettingsLoginItems() }
        case .unregister:
            do { try SMAppService.mainApp.unregister() } catch { Log.note("login", "could not remove tinywm from Login Items: \(error)") }
        case .openSettings: SMAppService.openSystemSettingsLoginItems()
        case .none: break
        }
    }
}
