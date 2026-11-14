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
        case .monitor: return "gauge.with.dots.needle.67percent"
        case .settings: return "gearshape.fill"
        }
    }
}
