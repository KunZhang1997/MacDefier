// LaunchAtLogin — macOS 13+ SMAppService（v0.1 开机启动）

import Foundation
import ServiceManagement

enum LaunchAtLoginStatus: Equatable {
    case enabled
    case disabled
    case requiresApproval
    case notFound
    case unavailable
}

enum LaunchAtLogin {
    static var status: LaunchAtLoginStatus {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled: return .enabled
            case .requiresApproval: return .requiresApproval
            case .notFound: return .notFound
            case .notRegistered: return .disabled
            @unknown default: return .disabled
            }
        }
        return .unavailable
    }

    static var isEnabled: Bool { status == .enabled }

    /// Toggle 显示用：enabled 为 true；requiresApproval 不算已完成开启
    static var toggleIsOn: Bool {
        status == .enabled
    }

    @discardableResult
    static func setEnabled(_ on: Bool) -> (ok: Bool, status: LaunchAtLoginStatus, error: String?) {
        guard #available(macOS 13.0, *) else {
            return (false, .unavailable, L10n.t("settings.launch_unavailable"))
        }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            let s = status
            if on, s == .requiresApproval {
                return (false, s, L10n.t("settings.launch_needs_approval"))
            }
            if on, s != .enabled {
                return (false, s, L10n.t("settings.launch_failed"))
            }
            return (true, s, nil)
        } catch {
            return (false, status, error.localizedDescription)
        }
    }

    static func openLoginItemsSettings() {
        if #available(macOS 13.0, *) {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
