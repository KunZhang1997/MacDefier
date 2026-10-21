import Foundation

/// Presentation evidence, updated only by real scanner events; never a timer.
public struct ScanJourney: Equatable, Sendable {
    public enum Status: String, Sendable { case idle, running, stopped, complete, partial }
    public struct Stage: Identifiable, Equatable, Sendable {
        public let id: String
        public var completed = false
        public var partial = false
        public var count: Int?
        public var bytes: UInt64?
    }
    public private(set) var stages: [Stage] = []
    public private(set) var activeID: String?
    public private(set) var status = Status.idle
    public private(set) var startedAt: Date?
    public init(stages: [String] = []) { self.stages = stages.map { Stage(id: $0) } }
    public mutating func begin(_ ids: [String], resuming: Bool = false, now: Date = Date()) {
        if !resuming || stages.map(\.id) != ids {
            stages = ids.map { Stage(id: $0) }; startedAt = now
        }
        status = .running; activeID = nil
    }
    public mutating func start(_ id: String) {
        guard status == .running, stages.contains(where: { $0.id == id }) else { return }
        activeID = id
    }
    /// For sequential scanners whose next-stage notification proves the previous returned.
    public mutating func advance(_ id: String) {
        if let previous = activeID, previous != id { complete(previous) }
        start(id)
    }
    public mutating func complete(_ id: String, count: Int? = nil, bytes: UInt64? = nil, partial: Bool = false) {
        guard status == .running, let index = stages.firstIndex(where: { $0.id == id }) else { return }
        stages[index].completed = true; stages[index].partial = partial
        stages[index].count = count; stages[index].bytes = bytes
        if activeID == id { activeID = nil }
    }
    public mutating func stop() { if status == .running { status = .stopped; activeID = nil } }
    public mutating func finish(partial: Bool = false) {
        guard status == .running else { return }
        activeID = nil
        status = partial || stages.contains(where: { !$0.completed || $0.partial }) ? .partial : .complete
    }
    public var completedIDs: Set<String> { Set(stages.filter(\.completed).map(\.id)) }
}
