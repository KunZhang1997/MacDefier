// AIConversationStore — persist chat across app restarts (Application Support JSON).

import Foundation

enum AIConversationStore {
    private static let fileName = "ai_conversation_v1.json"

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        #if DEBUG
        let dir = base.appendingPathComponent("MacDefier-Dev", isDirectory: true)
        #else
        let dir = base.appendingPathComponent("MacDefier", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    struct Snapshot: Codable {
        var messages: [StoredMessage]
        var rollingSummary: String
        var intensity: String
        var includeMonitorContext: Bool
        var updatedAt: Date
    }

    struct StoredMessage: Codable {
        var id: String
        var role: String
        var content: String
        var thinking: String?
        var date: Date
        var isSummary: Bool
        var actionsJSON: String?
    }

    static func load() -> Snapshot? {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return nil }
        return snap
    }

    /// 只保留最近 N 条：此前会话无上限增长、每条消息全量编码写盘
    static let maxStoredMessages = 200
    /// 编码 + 落盘串行后台队列：调用方（主线程）只递值快照，写盘不卡 UI
    private static let writeQueue = DispatchQueue(label: "com.macdefier.AIConversationStore", qos: .utility)

    static func save(
        messages: [AIMessage],
        rollingSummary: String,
        intensity: AIIntensity,
        includeMonitorContext: Bool
    ) {
        // 值类型裁剪拷贝在当前线程完成，编码与写盘移后台
        let trimmed = Array(messages.suffix(maxStoredMessages))
        let summaryCopy = rollingSummary
        let intensityRaw = intensity.rawValue
        writeQueue.async {
            let enc = JSONEncoder()
            let stored = trimmed.map { m -> StoredMessage in
                var actionsJSON: String?
                if !m.actions.isEmpty, let data = try? enc.encode(m.actions) {
                    actionsJSON = String(data: data, encoding: .utf8)
                }
                return StoredMessage(
                    id: m.id.uuidString,
                    role: m.role.rawValue,
                    content: m.content,
                    thinking: m.thinking,
                    date: m.date,
                    isSummary: m.isSummary,
                    actionsJSON: actionsJSON
                )
            }
            let snap = Snapshot(
                messages: stored,
                rollingSummary: summaryCopy,
                intensity: intensityRaw,
                includeMonitorContext: includeMonitorContext,
                updatedAt: Date()
            )
            guard let data = try? JSONEncoder().encode(snap) else { return }
            try? data.write(to: fileURL, options: [.atomic])
        }
    }

    static func clear() {
        // 走同一串行队列，保证「先写后清」或「先清后写」的时序不打乱
        writeQueue.async {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    static func toMessages(_ snap: Snapshot) -> [AIMessage] {
        let dec = JSONDecoder()
        return snap.messages.compactMap { s in
            guard let role = AIMessage.Role(rawValue: s.role) else { return nil }
            let id = UUID(uuidString: s.id) ?? UUID()
            var actions: [DefierAction] = []
            if let js = s.actionsJSON, let data = js.data(using: .utf8),
               let decoded = try? dec.decode([DefierAction].self, from: data) {
                actions = decoded
            }
            return AIMessage(
                id: id,
                role: role,
                content: s.content,
                thinking: s.thinking,
                date: s.date,
                isSummary: s.isSummary,
                actions: actions
            )
        }
    }
}
