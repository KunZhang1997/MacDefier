// ResidualPreview — uninstall Sheet residual list.
// v1: delegates to ResidualMatcher (AppPathFinder-inspired, PureMac MIT subset).

import Foundation

public enum ResidualKind: String, Sendable {
    case appBundle = "应用程序"
    case cache = "缓存"
    case logs = "日志"
    case support = "支持文件"
    case preferences = "偏好设置"
    case savedState = "保存的状态"
    case containers = "容器"
    case mediaLibrary = "媒体库"
    case other = "其他"

    /// 稳妥默认：仅主程序包勾选；缓存/日志/用户数据一律手勾（「保留用户数据」开关再管 support 等）
    public var defaultSelected: Bool {
        switch self {
        case .appBundle: return true
        case .cache, .logs, .savedState, .support, .preferences, .containers, .mediaLibrary, .other:
            return false
        }
    }
}

public struct ResidualItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let path: String
    public let kind: ResidualKind
    public let bytes: UInt64
    public var isSelected: Bool
    public let note: String

    public init(
        id: String = UUID().uuidString,
        path: String,
        kind: ResidualKind,
        bytes: UInt64,
        isSelected: Bool? = nil,
        note: String
    ) {
        self.id = id
        self.path = path
        self.kind = kind
        self.bytes = bytes
        self.isSelected = isSelected ?? kind.defaultSelected
        self.note = note
    }

    public var name: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

public enum ResidualPreview {
    /// Enhanced residual match for uninstall Sheet.
    public static func findResiduals(for app: InstalledApp) -> [ResidualItem] {
        ResidualMatcher.findResiduals(for: app, sensitivity: .enhanced)
    }
}
