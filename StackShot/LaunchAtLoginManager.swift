import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    @Published var isEnabled = false
    @Published var lastErrorMessage: String?

    init() {
        refresh()
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            isEnabled = enabled
            lastErrorMessage = nil
        } catch {
            isEnabled = (SMAppService.mainApp.status == .enabled)
            let format = L10n.tr("launch_at_login.error_format")
            lastErrorMessage = String(format: format, error.localizedDescription)
        }
    }
}
