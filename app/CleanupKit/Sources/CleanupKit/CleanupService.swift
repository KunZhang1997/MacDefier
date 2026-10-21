// CleanupService — app-facing facade for scan → preview → trash.

import AppKit
import Foundation
import Combine

/// AI  enrichment 绑定到某次 scan generation；迟到结果用 token 丢弃。
public struct CleanupAIEnrichmentToken: Equatable, Sendable {
    public let id: UUID
    public let scanGeneration: Int

    public init(id: UUID = UUID(), scanGeneration: Int) {
        self.id = id
        self.scanGeneration = scanGeneration
    }
}

public enum CleanupPreparationFailure: Sendable, Equatable {
    case expiredPreview, changedTargets, noEligibleItems
}

@MainActor
public final class CleanupService: ObservableObject {
    public static let shared = CleanupService()

    @Published public private(set) var phase: CleanupPhase = .idle
    @Published public private(set) var groups: [CleanupCategoryGroup] = []
    @Published public private(set) var lastResult: CleanupResult?
    @Published public private(set) var preparationFailure: CleanupPreparationFailure?
    /// Last confirmTrash included permanent empty of Trash category items
    @Published public private(set) var lastIncludedPermanentTrash = false
    @Published public private(set) var scanHint: String = ""
    @Published public private(set) var scanJourney = ScanJourney()
    /// Short AI summary after scan (set by app layer; empty when rules-only).
    @Published public var aiNarrative: String?
    @Published public var lastAIError: String?
    @Published public private(set) var usedAI: Bool = false
    @Published public private(set) var isAIEnriching: Bool = false
    /// When the last preview list became ready (for reuse / skip re-scan).
    @Published public private(set) var lastScanCompletedAt: Date? {
        didSet { schedulePreviewExpiry() }
    }

    /// 测试钩子：注入扫描完成时间以断言 TTL / 过期阻断（生产勿用）。
    public func setLastScanCompletedAtForTesting(_ date: Date?) {
        lastScanCompletedAt = date
    }

    private let scanner = JunkScanner()
    private let executor = TrashExecutor()
    /// Bumps on each startScan; older Tasks must not overwrite newer results.
    private(set) var scanGeneration = 0
    private var scanTask: Task<Void, Never>?
    private var trashTask: Task<Void, Never>?
    /// 当前破坏性清理操作 token；仅匹配结果可写 UI。
    private var trashOperationToken: UUID?
    /// 冻结的清理路径快照（cleaning 期间 startScan/聊天不得改写）
    private(set) var frozenTrashPaths: [String] = []
    private var activeAIToken: CleanupAIEnrichmentToken?
    private var previewIndex = CleanupPreviewIndex()
    private var previewExpiryTask: Task<Void, Never>?
    private var cachedTotalBytes: UInt64 = 0
    private var cachedSelectedBytes: UInt64 = 0
    private var cachedSelectedCount: Int = 0

    /// 测试注入：可控延迟扫描。返回 groups。
    var testScanHandler: (@Sendable (_ generation: Int) async -> [CleanupCategoryGroup])?
    /// 测试注入：可控延迟清理。
    var testTrashHandler: (@Sendable (_ items: [CleanableItem]) async -> CleanupResult)?

    private var resourceObserver: AnyCancellable?

    public init() {
        resourceObserver = NotificationCenter.default.publisher(for: CleanupResourceEvents.didChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.invalidateAfterResourceChange() }
    }

    private func invalidateAfterResourceChange() {
        guard !isDestructiveBusy else { return }
        cancelScan()
        scanJourney = ScanJourney()
        scanPartialGroups = []
        lastScanCompletedAt = nil
        clearAllSelection()
        if case .preview = phase { preparationFailure = .changedTargets }
    }

    /// 仅 hasFreshPreview == true 才允许复用；缺少完成时间视为过期。
    public var hasFreshPreview: Bool {
        guard case .preview = phase, !groups.isEmpty else { return false }
        return CleanupReusePolicy.isFresh(lastScanCompletedAt, ttl: CleanupReusePolicy.cleanupTTL)
    }

    /// 过期但仍有预览列表（可查看，执行前必须重扫）。
    public var hasStalePreview: Bool {
        guard case .preview = phase, !groups.isEmpty else { return false }
        return !hasFreshPreview
    }

    /// cleaning / 正在 trash 时禁止重扫覆盖。
    public var isDestructiveBusy: Bool {
        if case .cleaning = phase { return true }
        return trashOperationToken != nil && trashTask != nil
    }

    /// User selection is available only for a fresh, idle preview.
    public var canEditSelection: Bool {
        hasFreshPreview && !phase.isBusy && !isDestructiveBusy && !isAIEnriching
    }

    /// 非重叠路径树去重后的可回收总量（父子目录只计一次）。
    public var uniqueReclaimableBytes: UInt64 {
        cachedTotalBytes
    }

    public var totalBytes: UInt64 {
        uniqueReclaimableBytes
    }

    public var selectedBytes: UInt64 {
        cachedSelectedBytes
    }

    public var selectedCount: Int {
        cachedSelectedCount
    }

    public var selectableCount: Int {
        groups.reduce(0) { total, group in
            total + group.items.filter { $0.risk != .skip }.count
        }
    }

    public var allSelectableSelected: Bool {
        let selectable = allItems.filter { $0.risk != .skip }
        guard !selectable.isEmpty else { return false }
        return selectable.allSatisfy(\.isSelected)
    }

    public var allItems: [CleanableItem] {
        groups.flatMap(\.items)
    }

    public func reset() {
        // 不中断正在执行的 trash；仅清理扫描态
        if !isDestructiveBusy {
            cancelScan()
            phase = .idle
            previewIndex = CleanupPreviewIndex()
            groups = []
            refreshByteSummaries()
            lastResult = nil
            preparationFailure = nil
            scanHint = ""
            scanJourney = ScanJourney()
            aiNarrative = nil
            lastAIError = nil
            usedAI = false
            isAIEnriching = false
            lastScanCompletedAt = nil
            activeAIToken = nil
            frozenTrashPaths = []
        }
    }

    public func cancelScan() {
        // 破坏性清理中禁止 cancel：会抬升 generation，导致进行中的 trash 完成结果被丢弃
        if isDestructiveBusy { return }
        scanGeneration += 1
        scanTask?.cancel()
        scanTask = nil
        activeAIToken = nil
        isAIEnriching = false
        if case .scanning = phase {
            scanJourney.stop()
            phase = .idle
            scanHint = ""
        }
    }

    /// Rule scan of junk paths. Optional completion on main after preview is ready.
    /// AI enrichment (if any) is done by the app layer via `beginAIEnrichment` / `finishAIEnrichment`.
    /// - Parameter force: when false and a fresh preview exists, skip re-scan (still calls completion).
    /// - Parameter preservingSelection: explicit preview refresh only; restore exact unchanged
    ///   selections after a successful scan, without starting cleanup or extending a stale date.
    /// A newer request cancels the old scan, including its child processes.
    /// **破坏性清理进行中直接拒绝**，不取消/覆盖 trash 路径快照。
    @discardableResult
    public func startScan(
        force: Bool = true,
        preservingSelection: Bool = false,
        resuming: Bool = false,
        completion: (() -> Void)? = nil
    ) -> Bool {
        if isDestructiveBusy {
            completion?()
            return false
        }
        if !force, hasFreshPreview {
            completion?()
            return true
        }
        // Only the explicit "refresh selected" flow carries the user's choices.
        // Ordinary scans and chat previews keep their zero-selection contract.
        let previousSelection: Set<CleanupPreviewIndex.SelectionIdentity> = preservingSelection
            ? Set(allItems.filter { $0.isSelected && $0.risk != .skip }.compactMap { previewIndex.identities[$0.id] })
            : []
        scanTask?.cancel()
        scanGeneration += 1
        let gen = scanGeneration
        activeAIToken = nil
        phase = .scanning(progress: 0, hint: "preparing")
        previewIndex = CleanupPreviewIndex()
        groups = []
        refreshByteSummaries()
        lastResult = nil
        preparationFailure = nil
        lastScanCompletedAt = nil
        aiNarrative = nil
        lastAIError = nil
        usedAI = false
        isAIEnriching = false
        scanHint = "preparing"
        let canResume = resuming && scanJourney.status == .stopped
        let priorGroups = canResume ? scanPartialGroups : []
        let completed = canResume ? Set(scanJourney.completedIDs.compactMap(CleanupCategory.init(rawValue:))) : []
        scanPartialGroups = priorGroups
        scanJourney.begin(JunkScanner.cleanupScanCategories.map(\.rawValue), resuming: canResume)

        scanTask = Task { [weak self] in
            guard let self else { return }
            let result: [CleanupCategoryGroup]
            if let handler = self.testScanHandler {
                result = priorGroups + (await handler(gen))
            } else {
                let fresh = await scanner.scan(skipping: completed, onGroup: { [weak self] group in
                    Task { @MainActor in
                        self?.applyScanGroup(group, generation: gen)
                    }
                }) { [weak self] progress, hint in
                    Task { @MainActor in
                        self?.applyScanProgress(progress, hint: hint, generation: gen)
                        guard let self, self.scanGeneration == gen, case .scanning = self.phase else { return }
                        let category = String(hint.split(separator: "|", maxSplits: 1).first ?? "")
                        if CleanupCategory(rawValue: category) != nil { self.scanJourney.start(category) }
                    }
                }
                result = priorGroups + fresh
            }
            let preparation = Task.detached(priority: .utility) {
                try CleanupPreviewIndex.prepare(result, preserving: previousSelection)
            }
            let prepared: CleanupPreviewIndex.Prepared
            do {
                prepared = try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: {
                    preparation.cancel()
                }
            } catch {
                completion?()
                return
            }
            guard self.scanGeneration == gen, !self.isDestructiveBusy, !Task.isCancelled else {
                completion?()
                return
            }
            self.scanTask = nil
            self.previewIndex = prepared.index
            self.groups = prepared.groups
            self.refreshByteSummaries()
            self.phase = .preview
            for category in JunkScanner.cleanupScanCategories {
                let group = prepared.groups.first { $0.category == category }
                self.scanJourney.complete(category.rawValue, count: group?.items.count ?? 0,
                                          bytes: group?.totalBytes ?? 0, partial: group?.isPartial ?? false)
            }
            self.scanJourney.finish(partial: prepared.groups.contains(where: \.isPartial))
            self.lastScanCompletedAt = Date()
            if self.testScanHandler == nil {
                CleanupScanStore.save(
                    groups: prepared.groups,
                    selectedBytes: self.selectedBytes,
                    selectedCount: self.selectedCount,
                    aiNarrative: nil,
                    usedAI: false,
                    aiError: nil
                )
            }
            completion?()
        }
        return true
    }

    private var scanPartialGroups: [CleanupCategoryGroup] = []

    public func continueScan(completion: (() -> Void)? = nil) {
        _ = startScan(force: true, resuming: true, completion: completion)
    }

    func applyScanGroup(_ group: CleanupCategoryGroup, generation: Int) {
        guard scanGeneration == generation, case .scanning = phase, !isDestructiveBusy else { return }
        scanPartialGroups.removeAll { $0.category == group.category }
        scanPartialGroups.append(group)
        groups = scanPartialGroups.filter { !$0.items.isEmpty || $0.isPartial }
        scanJourney.complete(group.category.rawValue, count: group.items.count,
                             bytes: group.totalBytes, partial: group.isPartial)
    }

    /// Read-only presentation paths captured by the scan. Never use this cache
    /// to authorize deletion; confirmTrash and the executor recheck live paths.
    public func previewPaths(for item: CleanableItem) -> [String] {
        if let paths = previewIndex.paths[item.id] { return paths }
        var seen = Set<String>()
        return ([item.path] + item.extraPaths).filter { seen.insert($0).inserted }
    }

    /// One expiry notification per preview, not a timer refreshing the whole list.
    private func schedulePreviewExpiry() {
        previewExpiryTask?.cancel()
        previewExpiryTask = nil
        guard let completedAt = lastScanCompletedAt else { return }
        let remaining = max(0, completedAt.addingTimeInterval(CleanupReusePolicy.cleanupTTL).timeIntervalSinceNow)
        previewExpiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            guard let self, self.lastScanCompletedAt == completedAt, case .preview = self.phase else { return }
            self.previewExpiryTask = nil
            self.objectWillChange.send()
        }
    }

    /// A queued progress callback must not replace a completed or cancelled scan.
    func applyScanProgress(_ progress: Double, hint: String, generation: Int) {
        guard scanGeneration == generation, case .scanning = phase, !isDestructiveBusy else { return }
        let next = CleanupPhase.scanning(progress: progress, hint: hint)
        if phase != next { phase = next }
        if scanHint != hint { scanHint = hint }
    }

    /// 开始 AI 解读；返回绑定当前 scan generation 的 token。
    /// 仅 preview 且非破坏性忙时可激活；否则返回“死 token”（finish 必丢弃）。
    @discardableResult
    public func beginAIEnrichment(hint: String = "ai_review") -> CleanupAIEnrichmentToken {
        let token = CleanupAIEnrichmentToken(scanGeneration: scanGeneration)
        guard case .preview = phase, !isDestructiveBusy else {
            return token
        }
        activeAIToken = token
        isAIEnriching = true
        usedAI = true
        scanHint = hint
        return token
    }

    /// 仅当 token 仍匹配当前 scan generation 且仍在 preview 时写入 AI 结果；否则丢弃。
    public func finishAIEnrichment(token: CleanupAIEnrichmentToken, narrative: String?, error: String?) {
        guard activeAIToken == token,
              token.scanGeneration == scanGeneration,
              case .preview = phase,
              !isDestructiveBusy
        else {
            // 迟到的旧结果：若仍是当前 enriching 的过期 token，只清 enriching 标志
            if activeAIToken == token {
                isAIEnriching = false
                activeAIToken = nil
            }
            return
        }
        aiNarrative = narrative
        lastAIError = error
        isAIEnriching = false
        activeAIToken = nil
        CleanupScanStore.save(
            groups: groups,
            selectedBytes: selectedBytes,
            selectedCount: selectedCount,
            aiNarrative: narrative,
            usedAI: true,
            aiError: error
        )
    }

    /// 兼容旧调用：无 token 时若仍在 enriching 则用 active token。
    public func finishAIEnrichment(narrative: String?, error: String?) {
        if let token = activeAIToken {
            finishAIEnrichment(token: token, narrative: narrative, error: error)
        } else {
            isAIEnriching = false
        }
    }

    /// 给 AI 的清单：类目 + 标题 + **~/相对路径** + 体积 + 风险。不发文件内容。
    /// 判断「能否勾」交给模型；此处只摊牌，不写死可删规则。
    public func contextTextForAI() -> String {
        if groups.isEmpty { return "（无扫描结果）" }
        var lines: [String] = []
        lines.append("合计可预览 \(totalBytes) 字节；当前已选 \(selectedCount) 项 / \(selectedBytes) 字节。尚未删除任何文件。")
        lines.append("红线：只根据下表判断；不要编造表外路径/体积；不要替用户勾选或声称已删除。路径为 ~ 相对路径。")
        for g in groups {
            var riskCounts: [String: Int] = [:]
            for item in g.items {
                riskCounts[item.risk.rawValue, default: 0] += 1
            }
            let riskSummary = riskCounts.keys.sorted().map { "\($0)=\(riskCounts[$0] ?? 0)" }.joined(separator: ",")
            lines.append(
                "分类「\(g.category.title)」：\(g.items.count) 项 · 共 \(g.totalBytes) 字节 · 风险分布 \(riskSummary)"
            )
            // 大文件类多给一些，便于区分同名；其它类 Top8
            let limit = g.category == .largeAppData ? 16 : 8
            for item in g.items.sorted(by: { $0.bytes > $1.bytes }).prefix(limit) {
                let title = item.displayTitle.isEmpty ? item.name : item.displayTitle
                let rel = item.homeRelativePath
                lines.append(
                    "  - \(item.isSelected ? "已选" : "未选") title=\(title) · path=\(rel) · \(item.bytes) 字节 · 风险 \(item.risk.rawValue)"
                )
            }
        }
        return lines.joined(separator: "\n")
    }

    public func setSelected(itemID: String, selected: Bool) {
        guard let location = previewIndex.locations[itemID] else { return }
        let item = groups[location.group].items[location.item]
        let next = selected && item.risk != .skip
        guard item.isSelected != next else { return }
        var updated = groups
        updated[location.group].items[location.item].isSelected = next
        applySelection(updated)
    }

    /// Explicit user bulk selection, including caution and Trash items.
    /// Selection never authorizes execution; skip items and execution guards remain unchanged.
    public func setAllSelected(_ selected: Bool, in category: CleanupCategory? = nil) {
        guard canEditSelection else { return }
        var updated = groups
        for g in updated.indices where category == nil || updated[g].category == category {
            for i in updated[g].items.indices {
                updated[g].items[i].isSelected = selected && updated[g].items[i].risk != .skip
            }
        }
        applySelection(updated)
    }

    /// 组头一键勾选：selected=true 时**追加勾选低风险**（不取消组内已手勾的谨慎项）；
    /// caution / 废纸篓等仍须用户手勾。selected=false 时组内全清。
    public func setCategorySelected(_ category: CleanupCategory, selected: Bool) {
        var updated = groups
        guard let gi = updated.firstIndex(where: { $0.category == category }) else { return }
        for i in updated[gi].items.indices {
            if selected {
                if updated[gi].items[i].isLowRiskBulkEligible {
                    updated[gi].items[i].isSelected = true
                }
            } else {
                updated[gi].items[i].isSelected = false
            }
        }
        applySelection(updated)
    }

    public func isItemSelected(id: String) -> Bool {
        guard let location = previewIndex.locations[id] else { return false }
        return groups[location.group].items[location.item].isSelected
    }

    /// 一键只勾「低风险」：浏览器/包管理缓存、DerivedData、日志等；不含孤儿/tmp 工具/开发机缓存。
    /// 不取消用户已手勾的谨慎项（如 CLI 卸后数据），避免「勾了 Claude 再点勾选低风险 → 被清掉」。
    public func selectLowRiskOnly() {
        var updated = groups
        for g in updated.indices {
            for i in updated[g].items.indices {
                let item = updated[g].items[i]
                if item.risk == .skip {
                    updated[g].items[i].isSelected = false
                    continue
                }
                if item.isLowRiskBulkEligible {
                    updated[g].items[i].isSelected = true
                }
                // else: leave manual caution selection untouched
            }
        }
        applySelection(updated)
    }

    public func clearAllSelection() {
        var updated = groups
        for g in updated.indices {
            for i in updated[g].items.indices {
                updated[g].items[i].isSelected = false
            }
        }
        applySelection(updated)
    }

    /// Chat / Mr. Defier entry: ensure a preview list, then **always** zero-select.
    /// Reusing a fresh preview must not carry page ticks into an advise-only flow (M09-1).
    /// - Returns `false` when a destructive clean is in progress (caller must not rescan / clear mid-trash).
    @discardableResult
    public func preparePreviewForChat() async -> Bool {
        if isDestructiveBusy {
            return false
        }
        let reused = hasFreshPreview && !phase.isBusy
        if !reused {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                _ = startScan(force: true) {
                    cont.resume()
                }
            }
            // 扫描过程中可能进入 cleaning：勿 clear / 勿当成功
            if isDestructiveBusy {
                return false
            }
        }
        // Unconditional — both reuse and fresh scan paths (仅非 busy).
        clearAllSelection()
        return !isDestructiveBusy
    }

    public var lowRiskCount: Int {
        allItems.filter(\.isLowRiskBulkEligible).count
    }

    public var lowRiskBytes: UInt64 {
        allItems.filter(\.isLowRiskBulkEligible).reduce(0) { $0 + $1.bytes }
    }

    /// 当前勾选项经 PathGate 再确认后的实际执行路径（预览/确认/executor 必须一致；父子去重）。
    public var selectedExecutablePaths: [String] {
        let raw = Self.gatedExecutableItems(
            from: allItems.filter { $0.isSelected && $0.risk != .skip },
            expectedTargets: previewIndex.identities.mapValues(\.paths)
        )
            .flatMap(\.allPaths)
        return PathReclaimDeduper.nonOverlappingPaths(raw)
    }

    /// 禁止 executor 重复处理父子路径：保留较短父路径项，去掉被覆盖子项。
    private nonisolated static func dedupeItemsForExecution(_ items: [CleanableItem]) -> [CleanableItem] {
        let keepPaths = Set(PathReclaimDeduper.nonOverlappingPaths(items.flatMap(\.allPaths)))
        return items.compactMap { item -> CleanableItem? in
            let paths = item.allPaths.filter { keepPaths.contains(PathGate.normalize($0)) }
            guard !paths.isEmpty else { return nil }
            if paths.count == item.allPaths.count { return item }
            var copy = CleanableItem(
                id: item.id,
                name: item.name,
                path: paths[0],
                bytes: item.bytes,
                category: item.category,
                isSelected: false,
                appName: item.appName,
                displayTitle: item.displayTitle,
                whatIsIt: item.whatIsIt,
                ifCleaned: item.ifCleaned,
                risk: item.risk,
                parentPath: item.parentPath,
                extraPaths: Array(paths.dropFirst()),
                sizeIsLowerBound: item.sizeIsLowerBound
            )
            copy.isSelected = true
            return copy
        }
    }

    /// An allowed location is not sufficient: it must still be the target that
    /// was shown in this preview. Check every path, including intermediate links
    /// and aliases that were deduplicated when the scan completed.
    private nonisolated static func matchesPreviewTargets(
        _ item: CleanableItem,
        expectedTargets: [String: Set<String>]
    ) -> Bool {
        guard let expected = expectedTargets[item.id] else { return false }
        let current = Set(([item.path] + item.extraPaths).map { PathGate.normalize($0) })
        return current == expected
    }

    /// 确认瞬间再执行 PathGate；失败路径不进入 executor。
    nonisolated static func gatedExecutableItems(
        from items: [CleanableItem],
        expectedTargets: [String: Set<String>],
        installedApps: [InstalledApp]? = nil,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [CleanableItem] {
        let apps = items.contains { $0.category == .orphans }
            ? (installedApps ?? AppInventory.fetchInstalledApps(includeSystemApps: true, computeSize: false))
            : nil
        return items.compactMap { item -> CleanableItem? in
            guard matchesPreviewTargets(item, expectedTargets: expectedTargets) else { return nil }
            let paths: [String]
            if item.category == .trash {
                paths = item.allPaths.filter { PathGate.isUnderUserTrash($0) }
            } else if item.category == .orphans {
                paths = item.allPaths.filter { PathGate.isSafeOrphanToTrash($0, installedApps: apps, home: home) }
            } else {
                paths = item.allPaths.filter { PathGate.isSafeToTrash($0, home: home) }
            }
            guard !paths.isEmpty else { return nil }
            // 路径集合未变：保留原 item（已 isSelected）
            if paths.count == item.allPaths.count, Set(paths) == Set(item.allPaths) {
                var kept = item
                kept.isSelected = true
                return kept
            }
            var copy = CleanableItem(
                id: item.id,
                name: item.name,
                path: paths[0],
                bytes: item.bytes,
                category: item.category,
                isSelected: false,
                appName: item.appName,
                displayTitle: item.displayTitle,
                whatIsIt: item.whatIsIt,
                ifCleaned: item.ifCleaned,
                risk: item.risk,
                parentPath: item.parentPath,
                extraPaths: Array(paths.dropFirst()),
                sizeIsLowerBound: item.sizeIsLowerBound
            )
            // init 强制 false；executor 依赖 isSelected
            copy.isSelected = true
            return copy
        }
    }

    /// 冻结所选路径快照 + operation token + scanGeneration 后进入 cleaning；
    /// 仅匹配 token **且** generation 的结果可更新 UI（防重扫/并发冲掉 trash）。
    /// 过期预览禁止执行，须先重扫。
    public func confirmTrash() {
        guard case .preview = phase else { return }
        guard hasFreshPreview else {
            preparationFailure = .expiredPreview
            return
        }
        guard !isDestructiveBusy else { return }
        // Capture value snapshots without filesystem work on the UI actor.
        // Live validation below is still mandatory before invoking the executor.
        let selected = allItems.filter { $0.isSelected && $0.risk != .skip }
        guard !selected.isEmpty else { return }
        preparationFailure = nil
        let expectedTargets = previewIndex.identities.mapValues(\.paths)

        let opToken = UUID()
        trashOperationToken = opToken
        // Candidate paths only until background validation replaces them with
        // the exact gated/deduplicated execution snapshot.
        frozenTrashPaths = selected.flatMap { previewPaths(for: $0) }
        // 中止进行中的扫描/AI，并抬升 generation，使迟到的 scan/AI 结果全部失效
        scanTask?.cancel()
        scanTask = nil
        activeAIToken = nil
        isAIEnriching = false
        scanGeneration += 1
        let trashGen = scanGeneration
        phase = .cleaning(progress: 0)

        trashTask = Task { @MainActor in
            let validation = Task.detached(priority: .userInitiated) {
                () -> (items: [CleanableItem], paths: [String], rejected: [String])? in
                guard selected.allSatisfy({
                    Self.matchesPreviewTargets($0, expectedTargets: expectedTargets)
                }) else { return nil }
                let gated = Self.gatedExecutableItems(from: selected, expectedTargets: expectedTargets)
                let accepted = Set(gated.flatMap(\.allPaths))
                let rejected = Array(Set(selected.flatMap(\.allPaths)).subtracting(accepted)).sorted()
                let items = Self.dedupeItemsForExecution(gated)
                return (items, items.flatMap(\.allPaths), rejected)
            }
            let validated = await withTaskCancellationHandler {
                await validation.value
            } onCancel: {
                validation.cancel()
            }
            guard self.trashOperationToken == opToken,
                  self.scanGeneration == trashGen
            else { return }
            guard let validated, !validated.items.isEmpty, !Task.isCancelled else {
                self.trashOperationToken = nil
                self.trashTask = nil
                self.frozenTrashPaths = []
                self.phase = .preview
                if validated == nil {
                    // Require a new preview and consent for a changed target.
                    self.lastScanCompletedAt = nil
                    self.clearAllSelection()
                }
                if !Task.isCancelled {
                    self.preparationFailure = validated == nil ? .changedTargets : .noEligibleItems
                    self.lastScanCompletedAt = nil
                }
                return
            }
            let items = validated.items
            self.frozenTrashPaths = validated.paths
            self.lastIncludedPermanentTrash = items.contains { $0.category == .trash }
            var result: CleanupResult
            if let handler = self.testTrashHandler {
                result = await handler(items)
            } else {
                result = await executor.trash(items: items) { [weak self] p in
                    Task { @MainActor in
                        guard let self,
                              self.trashOperationToken == opToken,
                              self.scanGeneration == trashGen
                        else { return }
                        self.phase = .cleaning(progress: p)
                    }
                }
            }
            // token + generation 双门：任一失配则丢弃（例如异常路径抬升了 gen）
            guard self.trashOperationToken == opToken,
                  self.scanGeneration == trashGen
            else { return }
            if Task.isCancelled {
                // 仅本 token 被显式取消时收尾；默认不在 cleaning 中 cancel
                self.trashOperationToken = nil
                self.trashTask = nil
                self.frozenTrashPaths = []
                return
            }
            result.failedPaths.append(contentsOf: validated.rejected)
            result.failures.append(contentsOf: validated.rejected.map {
                .init(path: $0, name: URL(fileURLWithPath: $0).lastPathComponent, kind: .changed)
            })
            result.errors.append(contentsOf: validated.rejected.map { "未处理，执行前检查未通过：\($0)" })
            let originalGroups = groups
            let preparation = Task.detached(priority: .utility) {
                var remaining = originalGroups
                for g in remaining.indices {
                    remaining[g].items = remaining[g].items.compactMap { item in
                        if result.trashedPaths.contains(item.path) { return nil }
                        let failed = item.allPaths.filter { result.failedPaths.contains($0) }
                        let succeeded = item.allPaths.filter { result.succeededPaths.contains($0) }
                        guard !failed.isEmpty, !succeeded.isEmpty else {
                            // 全失败：保留项且默认不勾选
                            if !failed.isEmpty, succeeded.isEmpty {
                                var kept = item
                                kept.isSelected = false
                                return kept
                            }
                            return item
                        }

                        // A partial multi-path result must retry only paths that remain.
                        // Bytes become unknown rather than guessing a proportional value.
                        // 失败重试项默认不勾选（PASS：默认不勾）
                        var retry = CleanableItem(
                            id: item.id,
                            name: item.name,
                            path: failed[0],
                            bytes: 0,
                            category: item.category,
                            isSelected: false,
                            appName: item.appName,
                            displayTitle: item.displayTitle,
                            whatIsIt: item.whatIsIt,
                            ifCleaned: item.ifCleaned,
                            risk: item.risk,
                            parentPath: item.parentPath,
                            extraPaths: Array(failed.dropFirst()),
                            sizeIsLowerBound: true
                        )
                        retry.isSelected = false
                        return retry
                    }
                }
                remaining.removeAll { $0.items.isEmpty && !$0.isPartial }
                return try CleanupPreviewIndex.prepare(remaining)
            }
            let prepared = try? await preparation.value
            guard self.trashOperationToken == opToken, self.scanGeneration == trashGen else { return }
            self.lastResult = result
            if let prepared {
                self.previewIndex = prepared.index
                self.groups = prepared.groups
            }
            self.refreshByteSummaries()
            self.phase = .done(freed: result.freedBytes, count: result.cleanedCount, errors: result.errors)
            self.trashOperationToken = nil
            self.trashTask = nil
            self.frozenTrashPaths = []
        }
    }

    public func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    public func reviewFailedItems() {
        guard !groups.isEmpty, !(lastResult?.failedPaths.isEmpty ?? true) else { return }
        phase = .preview
    }

    private func applySelection(_ updated: [CleanupCategoryGroup]) {
        let before = Set(groups.flatMap(\.items).filter(\.isSelected).map(\.id))
        let after = Set(updated.flatMap(\.items).filter(\.isSelected).map(\.id))
        guard before != after else { return }
        cachedSelectedCount = after.count
        cachedSelectedBytes = previewIndex.bytes(selectedIDs: after)
        groups = updated
    }

    private func refreshByteSummaries() {
        let selected = Set(groups.flatMap(\.items).filter(\.isSelected).map(\.id))
        cachedTotalBytes = previewIndex.totalBytes
        cachedSelectedBytes = previewIndex.bytes(selectedIDs: selected)
        cachedSelectedCount = selected.count
    }
}
