import Foundation

public enum AIConversationAge: String, CaseIterable, Identifiable, Sendable {
    case dontList, days30, days90, days180, days365, all
    public var id: String { rawValue }
    public var days: Int? {
        switch self {
        case .days30: return 30
        case .days90: return 90
        case .days180: return 180
        case .days365: return 365
        case .dontList, .all: return nil
        }
    }
    public func includes(_ date: Date?, now: Date = Date()) -> Bool {
        if self == .dontList { return false }
        if self == .all { return true }
        guard let date, date > .distantPast, date <= now, let days else { return false }
        return date < now.addingTimeInterval(-Double(days) * 86_400)
    }
}

public enum AICleanupSelection {
    public static func visible(_ candidates: [AICleanupCandidate], ages: [AITool: AIConversationAge], now: Date) -> [AICleanupCandidate] {
        candidates.filter { $0.kind != .conversation || (ages[$0.tool] ?? .dontList).includes($0.lastActivity, now: now) }
    }
    public static func approved(_ ids: Set<String>, candidates: [AICleanupCandidate]) -> [AICleanupCandidate] {
        candidates.filter { ids.contains($0.id) && $0.canSelect }
    }
    public static func resources(_ candidates: [AICleanupCandidate]) -> [AIResource] {
        AIResourceTotals.unique(candidates.flatMap(\.resources))
    }
}
