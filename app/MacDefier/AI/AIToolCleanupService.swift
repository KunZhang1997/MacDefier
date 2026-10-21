import AppKit
import CleanupKit
import Combine
import Foundation

struct AIToolCleanupGroup: Identifiable {
    let id: String
    let kind: AIDataKind
    let section: AIDataSection
    let owner: AITool?
    let all: [AICleanupCandidate]
    let visible: [AICleanupCandidate]
    let eligibleBytes: UInt64
    let totalBytes: UInt64
    var selectable: [AICleanupCandidate] { visible.filter(\.canSelect) }
}

@MainActor
final class AIToolCleanupService: ObservableObject {
    static let shared = AIToolCleanupService()
    enum Phase: Equatable { case idle, scanning, preview, cleaning }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var groups: [AIToolCleanupGroup] = []
    @Published private(set) var selectedIDs = Set<String>()
    @Published private(set) var ages: [AITool: AIConversationAge] = [:]
    @Published private(set) var scanHint = "aitools.stage.tools"
    @Published private(set) var scanJourney = ScanJourney()
    @Published private(set) var issues: [String] = []
    @Published private(set) var selectedBytes: UInt64 = 0
    @Published private(set) var eligibleBytes: UInt64 = 0
    @Published private(set) var selectedCount = 0
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastResult: CleanupResult?
    @Published private(set) var requiresRescan = false
    private var candidates: [AICleanupCandidate] = []
    private var scanDate: Date?
    private var generation = 0
    private var task: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var resourceObserver: AnyCancellable?
    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private static let ttl: TimeInterval = 300

    init() {
        resourceObserver = NotificationCenter.default.publisher(for: CleanupResourceEvents.didChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.phase != .cleaning else { return }
                self.cancelScan()
                self.scanJourney = ScanJourney()
                self.requiresRescan = true
                self.scanDate = nil
                self.selectedIDs.removeAll()
                self.refreshSelection()
            }
    }

    var previewRevision: Int { generation }
    private var previewIsFresh: Bool { scanDate.map { Date().timeIntervalSince($0) <= Self.ttl } ?? false }
    var canClean: Bool { phase == .preview && !requiresRescan && previewIsFresh && selectedCount > 0 }
    var measuredCount: Int { candidates.count }
    var hasPreview: Bool { scanDate != nil || !candidates.isEmpty }

    func setAge(_ value: AIConversationAge, for tool: AITool) {
        guard phase != .cleaning else { return }
        ages[tool] = value
        rebuildGroups()
    }
    func age(for tool: AITool) -> AIConversationAge { ages[tool] ?? .dontList }

    func toggle(_ item: AICleanupCandidate) {
        guard phase == .preview, !requiresRescan, item.canSelect else { return }
        if !selectedIDs.insert(item.id).inserted { selectedIDs.remove(item.id) }
        refreshSelection()
    }
    func toggleGroup(_ group: AIToolCleanupGroup) {
        guard phase == .preview, !requiresRescan else { return }
        let ids = Set(group.selectable.map(\.id))
        guard !ids.isEmpty else { return }
        if ids.isSubset(of: selectedIDs) { selectedIDs.subtract(ids) } else { selectedIDs.formUnion(ids) }
        refreshSelection()
    }
    func clearSelection() { selectedIDs.removeAll(); refreshSelection() }
    func selectAllEligible() {
        guard phase == .preview, !requiresRescan else { return }
        selectedIDs = Set(visibleCandidates.filter(\.canSelect).map(\.id))
        refreshSelection()
    }
    var selectedCandidates: [AICleanupCandidate] { AICleanupSelection.approved(selectedIDs, candidates: visibleCandidates) }
    var selectedResources: [AIResource] { AICleanupSelection.resources(selectedCandidates) }
    private var visibleCandidates: [AICleanupCandidate] {
        AICleanupSelection.visible(candidates, ages: ages, now: scanDate ?? Date())
    }

    static let scanStages = ["appData", "cliData", "conversations", "models", "worktrees", "verify"]

    func startScan(resuming: Bool = false) {
        guard phase != .cleaning else { return }
        let resume = resuming && scanJourney.status == .stopped
        cancelScan()
        generation += 1
        let token = generation
        if !resume { candidates = []; groups = []; issues = []; scanDate = nil }
        phase = .scanning
        requiresRescan = true
        lastResult = nil
        selectedIDs.removeAll()
        refreshSelection()
        scanJourney.begin(Self.scanStages.map { "scan.stage." + $0 }, resuming: resume)
        let home = self.home
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            for stage in Self.scanStages {
                let key = "scan.stage." + stage
                if self.scanJourney.completedIDs.contains(key) { continue }
                guard self.generation == token, !Task.isCancelled else { return }
                self.scanHint = key
                if stage == "verify" || stage == "cliData" { self.scanJourney.start(key) }
                if stage == "verify" {
                    let current = self.candidates
                    let checked = await Task.detached(priority: .utility) {
                        var all = current
                        var activities: [AITool: AIToolCleanupActivity] = [:]
                        for index in all.indices where all[index].state == .ready {
                            let tool = all[index].tool
                            let state = activities[tool] ?? AIToolCleanupGuard.live.state(for: tool)
                            activities[tool] = state
                            switch state {
                            case .idle: break
                            case .inUse: all[index].state = .inUse; all[index].reason = "in_use"
                            case .unknown: all[index].state = .unknown; all[index].reason = "probe_unknown"
                            }
                        }
                        return all
                    }.value
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.candidates = checked
                    self.scanJourney.complete(key, count: checked.count)
                    continue
                }
                if stage == "cliData" {
                    await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                        SoftwareService.shared.refreshCLI(force: false) { waiter.resume() }
                    }
                    guard self.generation == token, !Task.isCancelled else { return }
                }
                let tools = SoftwareService.shared.cliTools
                let now = self.scanJourney.startedAt ?? Date()
                let result = await DiskScanCoordinator.shared.withPermit(retainingCancelledResult: false) {
                    await MainActor.run {
                        guard self.generation == token, self.phase == .scanning else { return }
                        self.scanJourney.start(key)
                    }
                    let worker = Task.detached(priority: .utility) {
                        switch stage {
                        case "appData":
                            return AIToolCleanupScanner.scan(home: home, cliInventory: tools, now: now,
                                section: .appData, isCancelled: { Task.isCancelled })
                        case "cliData":
                            var data = AIToolCleanupScanner.scan(home: home, cliInventory: tools, now: now,
                                section: .cliData, isCancelled: { Task.isCancelled })
                            data.candidates += Self.toolCandidates(tools)
                            return data
                        case "conversations":
                            return AIConversationInventory.scan(home: home, now: now,
                                includeWorktrees: false, isCancelled: { Task.isCancelled })
                        case "models":
                            return AIOllamaInventory.scan(home: home, now: now, isCancelled: { Task.isCancelled })
                        default:
                            return AIWorktreeInventory.scan(home: home, now: now, isCancelled: { Task.isCancelled })
                        }
                    }
                    return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                }
                guard self.generation == token, !Task.isCancelled, let result else { return }
                var seen = Set(self.candidates.map(\.id))
                self.candidates += result.candidates.filter { seen.insert($0.id).inserted }
                self.issues = Array(Set(self.issues + result.issues)).sorted()
                self.scanJourney.complete(key, count: result.candidates.count,
                    bytes: AIResourceTotals.bytes(result.candidates.flatMap(\.resources)),
                    partial: !result.issues.isEmpty)
                self.rebuildGroups()
            }
            guard self.generation == token, !Task.isCancelled else { return }
            self.scanDate = self.scanJourney.startedAt ?? Date()
            self.requiresRescan = false
            self.phase = .preview
            self.task = nil
            self.scanJourney.finish(partial: !self.issues.isEmpty)
            self.rebuildGroups()
            self.scheduleExpiry()
        }
    }

    func cancelScan() {
        guard phase != .cleaning else { return }
        generation += 1
        task?.cancel(); task = nil
        if phase == .scanning {
            scanJourney.stop()
            requiresRescan = true
            scanDate = nil
            phase = hasPreview ? .preview : .idle
            if hasPreview && !previewIsFresh { requiresRescan = true; clearSelection() }
            else if phase == .preview { scheduleExpiry() }
        }
    }

    func cleanSelected(_ frozen: [AICleanupCandidate], revision: Int) {
        let expectedIDs = Set(frozen.map(\.id))
        guard revision == previewRevision, expectedIDs == selectedIDs else { requiresRescan = true; clearSelection(); return }
        guard canClean, let scanDate, Date().timeIntervalSince(scanDate) <= Self.ttl else {
            requiresRescan = true; return
        }
        guard !frozen.isEmpty, frozen.count == selectedCandidates.count else { return }
        generation += 1
        let token = generation
        phase = .cleaning
        progress = 0
        let home = self.home
        task = Task { @MainActor [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                await AIToolCleanupExecutor.execute(candidates: frozen, home: home) { value in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token, self.phase == .cleaning else { return }
                        self.progress = value
                    }
                }
            }
            let result = await worker.value
            guard let self, self.generation == token else { return }
            self.lastResult = result
            let moved = Set(result.succeededPaths)
            self.candidates = self.candidates.compactMap { candidate in
                if !candidate.resources.isEmpty, candidate.resources.allSatisfy({ moved.contains($0.path) }) { return nil }
                if candidate.resources.contains(where: { moved.contains($0.path) }) {
                    var changed = candidate; changed.state = .unknown; changed.reason = "changed"; return changed
                }
                return candidate
            }
            self.selectedIDs.removeAll()
            self.requiresRescan = true
            self.scanDate = nil
            self.phase = .preview
            self.task = nil
            self.rebuildGroups()
        }
    }

    private func scheduleExpiry() {
        expiry?.cancel()
        guard let scanDate else { return }
        expiry = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, scanDate.addingTimeInterval(Self.ttl).timeIntervalSinceNow))) } catch { return }
            guard let self, self.scanDate == scanDate, self.phase == .preview else { return }
            self.requiresRescan = true
            self.clearSelection()
        }
    }

    private func rebuildGroups() {
        var next: [AIToolCleanupGroup] = []
        for section in AIDataSection.allCases {
        for kind in AIDataKind.allCases {
            let rows = candidates.filter { $0.kind == kind && $0.dataSection == section }
            guard !rows.isEmpty else { continue }
            let owners: [AITool?] = kind == .conversation ? AITool.allCases.filter { owner in rows.contains { $0.tool == owner } }.map(Optional.some) : [nil]
            for owner in owners {
                let all = rows.filter { owner == nil || $0.tool == owner }
                let visible = AICleanupSelection.visible(all, ages: ages, now: scanDate ?? Date()).sorted {
                    if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
                    return $0.id < $1.id
                }
                next.append(AIToolCleanupGroup(id: section.rawValue + ":" + kind.rawValue + (owner.map { ":" + $0.rawValue } ?? ""),
                    kind: kind, section: section, owner: owner, all: all, visible: visible,
                    eligibleBytes: AIResourceTotals.bytes(visible.filter(\.canSelect).flatMap(\.resources)),
                    totalBytes: AIResourceTotals.bytes(all.flatMap(\.resources))))
            }
        }
        }
        groups = next
        eligibleBytes = AIResourceTotals.bytes(visibleCandidates.filter(\.canSelect).flatMap(\.resources))
        selectedIDs.formIntersection(Set(visibleCandidates.filter(\.canSelect).map(\.id)))
        refreshSelection()
    }
    private func refreshSelection() {
        let approved = selectedCandidates
        selectedCount = approved.count
        selectedBytes = AIResourceTotals.bytes(approved.flatMap(\.resources))
    }

    private nonisolated static func toolCandidates(_ tools: [CliTool]) -> [AICleanupCandidate] {
        tools.compactMap { tool in
            guard let owner = owner(of: tool), !tool.programPaths.isEmpty else { return nil }
            return AICleanupCandidate(id: "cli:" + tool.id, tool: owner, kind: .tool,
                title: tool.displayName, resources: [], state: .reviewOnly, reason: "tool_installed",
                metadata: ["channel": tool.channel.rawValue, "programBytes": String(tool.programBytes), "dataBytes": String(tool.dataBytes)],
                cliTool: tool, contextPath: tool.programPaths.first)
        }
    }
    private nonisolated static func owner(of tool: CliTool) -> AITool? {
        let tokens = (tool.packageId + " " + tool.displayName + " " + tool.bins.joined(separator: " ")).lowercased()
        let mapping: [(AITool, [String])] = [(.codex, ["codex"]), (.claude, ["claude"]), (.cursor, ["cursor"]),
            (.copilot, ["copilot"]), (.antigravity, ["antigravity"]), (.opencode, ["opencode"]),
            (.kimi, ["kimi"]), (.gemini, ["gemini"]), (.ollama, ["ollama"]), (.lmstudio, ["lmstudio", "lm-studio"])]
        return mapping.first { $0.1.contains { tokens.contains($0) } }?.0
    }
}
