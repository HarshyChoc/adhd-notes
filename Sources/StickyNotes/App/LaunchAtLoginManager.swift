import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var errorMessage: String?

    var isSupported: Bool {
        guard #available(macOS 13.0, *) else {
            return false
        }
        return true
    }

    init() {
        self.isEnabled = Self.currentEnabledState()
    }

    func refresh() {
        isEnabled = Self.currentEnabledState()
    }

    func setEnabled(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else {
            errorMessage = "Launch at login requires macOS 13 or newer."
            isEnabled = false
            return
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
            refresh()
        } catch {
            errorMessage = error.localizedDescription
            refresh()
        }
    }

    private static func currentEnabledState() -> Bool {
        guard #available(macOS 13.0, *) else {
            return false
        }

        switch SMAppService.mainApp.status {
        case .enabled:
            return true
        default:
            return false
        }
    }
}
