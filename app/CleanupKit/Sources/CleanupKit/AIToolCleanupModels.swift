import Foundation

public enum AITool: String, CaseIterable, Sendable, Codable {
    case codex, claude, cursor, copilot, antigravity, opencode, kimi, gemini, ollama, lmstudio
    public var name: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .cursor: return "Cursor"
        case .copilot: return "GitHub Copilot"
        case .antigravity: return "Antigravity"
        case .opencode: return "OpenCode"
        case .kimi: return "Kimi CLI"
        case .gemini: return "Gemini CLI"
        case .ollama: return "Ollama"
        case .lmstudio: return "LM Studio"
        }
    }
}

public enum AIDataKind: String, CaseIterable, Sendable, Codable {
    case cache, oldVersion, conversation, worktree, model, leftover, tool, database
}

/// User-facing data categories. Candidate identity and execution policy stay unchanged.
public enum AIDataSection: String, CaseIterable, Sendable {
    case appData, cliData, conversations, models, worktrees
    public static func classify(kind: AIDataKind, path: String) -> Self {
        switch kind {
        case .conversation: return .conversations
        case .model: return .models
        case .worktree: return .worktrees
        case .tool, .oldVersion, .leftover: return .cliData
        case .cache, .database:
            if path.hasSuffix("/Library/Caches/kimi") || path.contains("/Library/Caches/kimi/") { return .cliData }
            return path.contains("/Library/") ? .appData : .cliData
        }
    }
}

public enum AICandidateState: String, Sendable, Codable {
    case ready, inUse, unknown, retained, reviewOnly
}

/// The same filesystem identity is shared across entries and product surfaces.
public struct AIResource: Identifiable, Sendable {
    public let path: String
    public let bytes: UInt64
    public let modifiedAt: Date
    public let identity: String
    let boundary: UninstallFileBoundary.Snapshot
    public var id: String { identity }

    public static func capture(path: String, bytes: UInt64) throws -> AIResource {
        let boundary = try UninstallFileBoundary.snapshot(path)
        let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw AIResourceError.invalidPath }
        return AIResource(path: boundary.path, bytes: bytes, modifiedAt: values.contentModificationDate ?? .distantPast,
                          identity: "\(boundary.item.device):\(boundary.item.inode):\(boundary.item.kind)", boundary: boundary)
    }
    public func stillMatches() -> Bool { UninstallFileBoundary.stillMatches(boundary) }
}

public enum AIResourceError: Error { case invalidPath }

public struct AICleanupCandidate: Identifiable, Sendable {
    public let id: String
    public let tool: AITool
    public let kind: AIDataKind
    public let title: String
    public let resources: [AIResource]
    public var state: AICandidateState
    /// A localization suffix, never user content or an inferred diagnosis.
    public var reason: String
    /// Filesystem modification/activity evidence, not proof that a model/tool was unused.
    public var lastActivity: Date?
    public var metadata: [String: String]
    public var cliTool: CliTool?
    public let contextPath: String

    public init(id: String? = nil, tool: AITool, kind: AIDataKind, title: String,
                resources: [AIResource], state: AICandidateState, reason: String,
                lastActivity: Date? = nil, metadata: [String: String] = [:],
                cliTool: CliTool? = nil, contextPath: String? = nil) {
        let path = contextPath ?? resources.first?.path ?? ""
        self.id = id ?? "\(tool.rawValue):\(kind.rawValue):\(path)"
        self.tool = tool; self.kind = kind; self.title = title; self.resources = resources
        self.state = state; self.reason = reason; self.lastActivity = lastActivity
        self.metadata = metadata; self.cliTool = cliTool; self.contextPath = path
    }
    public var path: String { contextPath }
    public var dataSection: AIDataSection { AIDataSection.classify(kind: kind, path: contextPath) }
    public var bytes: UInt64 { AIResourceTotals.bytes(resources) }
    public var canSelect: Bool { state == .ready && !resources.isEmpty && kind != .tool && kind != .worktree && kind != .database }
}

public enum AIResourceTotals {
    /// Parent coverage plus filesystem identity dedup; path siblings never overlap.
    public static func unique(_ resources: [AIResource]) -> [AIResource] {
        let sorted = resources.sorted {
            let a = $0.path.split(separator: "/"), b = $1.path.split(separator: "/")
            return a == b ? $0.bytes > $1.bytes : a.lexicographicallyPrecedes(b)
        }
        var ids = Set<String>(), paths = Set<String>(), result: [AIResource] = []
        var parent: String?
        for resource in sorted {
            if let parent, resource.path == parent || resource.path.hasPrefix(parent + "/") { continue }
            guard paths.insert(resource.path).inserted, ids.insert(resource.identity).inserted else { continue }
            result.append(resource); parent = resource.path
        }
        return result
    }
    public static func bytes(_ resources: [AIResource]) -> UInt64 {
        unique(resources).reduce(0) { value, resource in
            let sum = value.addingReportingOverflow(resource.bytes)
            return sum.overflow ? UInt64.max : sum.partialValue
        }
    }
}

public struct AICleanupInventory: Sendable {
    public var candidates: [AICleanupCandidate]
    public var issues: [String]
    public var scannedAt: Date
    public init(candidates: [AICleanupCandidate] = [], issues: [String] = [], scannedAt: Date = Date()) {
        self.candidates = candidates; self.issues = issues; self.scannedAt = scannedAt
    }
}
