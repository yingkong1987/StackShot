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
        do {
            isEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            isEnabled = false
            lastErrorMessage = "无法读取开机启动状态：\(error.localizedDescription)"
        }
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
            lastErrorMessage = "设置开机启动失败：\(error.localizedDescription)"
        }
    }
}
