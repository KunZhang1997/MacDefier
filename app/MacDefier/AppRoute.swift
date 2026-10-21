import SwiftUI

enum MonitorTab: String, CaseIterable, Identifiable, Hashable {
    case dashboard, cpu, gpu, ram, disk, sensors, network, history

    var id: String { rawValue }

    var title: String {
        L10n.t("monitor.tab.\(rawValue)")
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .cpu: return "cpu"
        case .gpu: return "display"
        case .ram: return "memorychip"
        case .disk: return "internaldrive"
        case .sensors: return "thermometer.medium"
        case .network: return "network"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

enum AppRoute: String, CaseIterable, Identifiable, Hashable {
    case diagnostic
    case cleanup
    case aiTools
    case software
    case diskMap
    case ai
    case monitor
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .diagnostic: return L10n.t("route.diagnostic")
        case .cleanup: return L10n.t("route.cleanup")
        case .aiTools: return L10n.t("route.aiTools")
        case .diskMap: return L10n.t("diskmap.title")
        case .software: return L10n.t("route.software")
        case .ai: return L10n.t("route.ai")
        case .monitor: return L10n.t("route.monitor")
        case .settings: return L10n.t("route.settings")
        }
    }

    var systemImage: String {
        switch self {
        case .diagnostic: return "stethoscope"
        case .cleanup: return "trash.fill"
        case .aiTools: return "sparkles.rectangle.stack"
        case .diskMap: return "chart.bar.xaxis"
        case .software: return "square.grid.2x2.fill"
        case .ai: return "sparkles"
        case .monitor: return "gauge.with.dots.needle.67percent"
        case .settings: return "gearshape.fill"
        }
    }

    /// 侧栏图标色（系统设置彩标感）
    var sidebarIconTint: Color {
        switch self {
        case .diagnostic: return Color.adaptive(light: 0x007AFF, dark: 0x0A84FF)
        case .cleanup: return Color.adaptive(light: 0xFF9F0A, dark: 0xFF9F0A)
        case .aiTools: return Color.adaptive(light: 0x5E5CE6, dark: 0xBF5AF2)
        case .software: return Color.adaptive(light: 0xBF5AF2, dark: 0xBF5AF2)
        case .diskMap: return Color.adaptive(light: 0x007AFF, dark: 0x0A84FF)
        case .ai: return Color.adaptive(light: 0x5E5CE6, dark: 0x5E5CE6)
        case .monitor: return Color.adaptive(light: 0x30D158, dark: 0x30D158)
        case .settings: return Color.adaptive(light: 0x8E8E93, dark: 0x98989D)
        }
    }

    var sidebarIconFill: Color {
        switch self {
        case .diagnostic: return Color.adaptive(light: 0x007AFF, dark: 0x0A84FF, lightAlpha: 0.14, darkAlpha: 0.26)
        case .cleanup: return Color.adaptive(light: 0xFF9F0A, dark: 0xFF9F0A, lightAlpha: 0.16, darkAlpha: 0.26)
        case .aiTools: return Color.adaptive(light: 0x5E5CE6, dark: 0xBF5AF2, lightAlpha: 0.14, darkAlpha: 0.26)
        case .software: return Color.adaptive(light: 0xBF5AF2, dark: 0xBF5AF2, lightAlpha: 0.14, darkAlpha: 0.26)
        case .diskMap: return Color.adaptive(light: 0x007AFF, dark: 0x0A84FF, lightAlpha: 0.14, darkAlpha: 0.26)
        case .ai: return Color.adaptive(light: 0x5E5CE6, dark: 0x5E5CE6, lightAlpha: 0.14, darkAlpha: 0.26)
        case .monitor: return Color.adaptive(light: 0x30D158, dark: 0x30D158, lightAlpha: 0.14, darkAlpha: 0.26)
        case .settings: return Color.adaptive(light: 0x8E8E93, dark: 0x98989D, lightAlpha: 0.16, darkAlpha: 0.26)
        }
    }
}
