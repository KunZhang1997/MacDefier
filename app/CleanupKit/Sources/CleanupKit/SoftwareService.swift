// SoftwareService — loads apps + uninstall via trash.

import AppKit
import Combine
import Foundation

public enum SoftwareSort: String, CaseIterable, Sendable, Identifiable {
    case sizeDesc
    case nameAsc

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sizeDesc: return "体积"
        case .nameAsc: return "名称"
        }
    }
}

/// Software page segment: GUI apps vs CLI tools (§7.3.1).
public enum SoftwareListKind: String, CaseIterable, Sendable, Identifiable, Hashable {
    case apps
    case cli

    public var id: String { rawValue }
}

/// 按「用户体感」分档（规则，非 AI）。大体积 ≠ 故障，仅便于扫一眼。
public enum SoftwareSizeTier: String, CaseIterable, Sendable, Identifiable, Comparable {
    case major   // 重大占用
    case large   // 较大
    case medium  // 一般
    case light   // 轻量

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .major: return "重大占用"
        case .large: return "较大"
        case .medium: return "一般"
        case .light: return "轻量"
        }
    }

    public var subtitle: String {
        switch self {
        case .major: return "≥ 10 GB · 多为游戏/大包开发工具"
        case .large: return "1～10 GB"
        case .medium: return "100 MB～1 GB"
        case .light: return "< 100 MB"
        }
    }

    private static let gb10: UInt64 = 10 * 1_073_741_824
    private static let gb1: UInt64 = 1_073_741_824
    private static let mb100: UInt64 = 100 * 1_048_576

    public static func tier(for totalBytes: UInt64) -> SoftwareSizeTier {
        if totalBytes >= gb10 { return .major }
        if totalBytes >= gb1 { return .large }
        if totalBytes >= mb100 { return .medium }
        return .light
    }

    public static func < (lhs: SoftwareSizeTier, rhs: SoftwareSizeTier) -> Bool {
        lhs.sortIndex < rhs.sortIndex
    }

    private var sortIndex: Int {
        switch self {
        case .major: return 0
        case .large: return 1
        case .medium: return 2
        case .light: return 3
        }
    }
}

public struct SoftwareTierGroup: Identifiable, Sendable {
    public var id: String { tier.rawValue }
    public let tier: SoftwareSizeTier
    public let apps: [InstalledApp]
    public var totalBytes: UInt64 { apps.reduce(0) { $0 &+ $1.totalBytes } }
    public var formattedTotal: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
    }
}

@MainActor
public final class SoftwareService: ObservableObject {
    public static let shared = SoftwareService()

    @Published public private(set) var apps: [InstalledApp] = []
    @Published public private(set) var cliTools: [CliTool] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var isCLILoading = false
    @Published public private(set) var loadError: String?
    @Published public private(set) var cliLoadError: String?
    @Published public private(set) var appScanJourney = ScanJourney()
    @Published public private(set) var cliScanJourney = ScanJourney()
    /// Generation that currently owns `isLoading=true` for app inventory refresh.
    /// Used so stale MainActor callbacks (after loadSize/cancel bump) can clear the spinner
    /// without clobbering a newer refresh that already re-took ownership.
    private var inventoryLoadingGen: Int = 0
    @Published public var query: String = ""
    @Published public var sort: SoftwareSort = .sizeDesc
    /// Apps list vs CLI tools (UI segment).
    @Published public var listKind: SoftwareListKind = .apps

    /// AI 盘点文案（仅建议，不卸载）
    @Published public var aiNarrative: String?
    @Published public var lastAIError: String?
    @Published public private(set) var usedAI = false
    @Published public private(set) var isAIEnriching = false
    /// AI 建议预览卸载的真实 path（须在 apps 列表内）
    @Published public var aiPreviewActions: [SoftwareAIPreviewAction] = []

    private var resourceObserver: AnyCancellable?

    public init() {
        resourceObserver = NotificationCenter.default.publisher(for: CleanupResourceEvents.didChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.cancelInventoryWork()
                self.lastInventoryAt = nil
                self.lastCLIInventoryAt = nil
                self.aiNarrative = nil
            }
    }

    public var filtered: [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = apps
        if !q.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(q)
                    || $0.bundleIdentifier.localizedCaseInsensitiveContains(q)
                    || $0.path.localizedCaseInsensitiveContains(q)
            }
        }
        switch sort {
        case .sizeDesc:
            return list.sorted { $0.totalBytes > $1.totalBytes }
        case .nameAsc:
            return list.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    public var filteredCLITools: [CliTool] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = cliTools
        if !q.isEmpty {
            list = list.filter {
                $0.displayName.localizedCaseInsensitiveContains(q)
                    || $0.packageId.localizedCaseInsensitiveContains(q)
                    || $0.bins.contains(where: { $0.localizedCaseInsensitiveContains(q) })
                    || $0.detail.localizedCaseInsensitiveContains(q)
                    || $0.channel.rawValue.localizedCaseInsensitiveContains(q)
            }
        }
        switch sort {
        case .sizeDesc:
            return list.sorted { $0.totalBytes > $1.totalBytes }
        case .nameAsc:
            return list.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
    }

    /// 按体积分档分组（组内仍尊重当前 sort）。空档不返回。
    public var tierGroups: [SoftwareTierGroup] {
        let list = filtered
        var buckets: [SoftwareSizeTier: [InstalledApp]] = [:]
        for app in list {
            let t = SoftwareSizeTier.tier(for: app.totalBytes)
            buckets[t, default: []].append(app)
        }
        return SoftwareSizeTier.allCases.compactMap { tier in
            guard let apps = buckets[tier], !apps.isEmpty else { return nil }
            return SoftwareTierGroup(tier: tier, apps: apps)
        }
    }

    public var topBySize: [InstalledApp] {
        apps.sorted { $0.totalBytes > $1.totalBytes }
    }

    /// When last inventory finished.
    @Published public private(set) var lastInventoryAt: Date?
    @Published public private(set) var lastCLIInventoryAt: Date?

    /// Waiters while inventory is loading (so chat never gets empty busy).
    private var pendingRefreshCompletions: [() -> Void] = []
    private var inventoryGeneration = 0
    private var cliInventoryGeneration = 0
    private var pendingCLIRefreshCompletions: [() -> Void] = []
    private var inventoryTask: Task<Void, Never>?
    private var cliInventoryTask: Task<Void, Never>?

    /// 15 分钟内有列表可复用。
    public var hasFreshInventory: Bool {
        !apps.isEmpty
            && CleanupReusePolicy.isFresh(lastInventoryAt, ttl: CleanupReusePolicy.softwareTTL)
    }

    public var hasFreshCLIInventory: Bool {
        !cliTools.isEmpty
            && CleanupReusePolicy.isFresh(lastCLIInventoryAt, ttl: CleanupReusePolicy.softwareTTL)
    }

    /// Force: false and list still fresh → skip enum, keep AI copy.
    /// App 列表与 CLI 列表任务分离：本方法只扫 .app，不触发 CLI / 清理。
    public func refresh(force: Bool = true, completion: (() -> Void)? = nil) {
        if !force, hasFreshInventory {
            completion?()
            return
        }
        // Already loading: queue waiter (no busy reject). Do not start a second walk.
        if isLoading || isAIEnriching {
            if let completion { pendingRefreshCompletions.append(completion) }
            return
        }
        inventoryGeneration += 1
        inventoryTask?.cancel()
        let gen = inventoryGeneration
        inventoryLoadingGen = gen
        isLoading = true
        appScanJourney.begin(["scan.stage.apps", "scan.stage.verify"])
        appScanJourney.start("scan.stage.apps")
        loadError = nil
        aiNarrative = nil
        lastAIError = nil
        usedAI = false
        isAIEnriching = false
        aiPreviewActions = []
        lastInventoryAt = nil

        inventoryTask = Task.detached(priority: .userInitiated) {
            // Return the app list quickly; expensive related-data sizes are filled by
            // a bounded, cancellable pass rather than blocking first paint.
            let list = AppInventory.fetchInstalledApps(
                includeSystemApps: true,
                computeSize: false,
                onBatch: { list in
                    Task { @MainActor in
                        guard self.inventoryGeneration == gen, self.isLoading else { return }
                        self.apps = list
                    }
                },
                isCancelled: { Task.isCancelled }
            )
            await MainActor.run {
                guard self.inventoryGeneration == gen else {
                    // Stale after loadSize/cancel bumped gen: clear spinner only if we still own it
                    // (a newer refresh would have inventoryLoadingGen == current gen).
                    if self.inventoryLoadingGen == gen {
                        self.isLoading = false
                    }
                    completion?()
                    return
                }
                self.apps = list
                self.appScanJourney.complete("scan.stage.apps", count: list.count)
                self.appScanJourney.start("scan.stage.verify")
                self.appScanJourney.complete("scan.stage.verify", count: list.count)
                self.appScanJourney.finish()
                self.isLoading = false
                self.lastInventoryAt = Date()
                SoftwareScanStore.save(
                    apps: list,
                    sort: self.sort,
                    aiNarrative: nil,
                    usedAI: false,
                    aiError: nil,
                    previewActions: []
                )
                self.flushRefreshWaiters(extra: completion)
            }
        }
    }

    /// Size one visible/selected app on demand. There is deliberately no silent all-app walk.
    public func loadSize(for app: InstalledApp) {
        inventoryTask?.cancel()
        inventoryGeneration += 1
        // Cancelling an in-flight refresh must not leave isLoading stuck true forever.
        // Stale refresh MainActor callback will also clear when inventoryLoadingGen matches,
        // but clear immediately so a subsequent refresh(force:) can start without waiting.
        if isLoading, inventoryLoadingGen != inventoryGeneration {
            appScanJourney.stop()
            isLoading = false
            flushRefreshWaiters(extra: nil)
        }
        let gen = inventoryGeneration
        inventoryTask = Task.detached(priority: .userInitiated) {
            let sized = AppInventory.loadApp(
                at: URL(fileURLWithPath: app.path),
                computeSize: true,
                isCancelled: { Task.isCancelled }
            )
            guard let sized, !Task.isCancelled else { return }
            await MainActor.run {
                guard self.inventoryGeneration == gen,
                      let index = self.apps.firstIndex(where: { $0.path == app.path })
                else { return }
                self.apps[index] = sized
            }
        }
    }

    public func cancelInventoryWork() {
        appScanJourney.stop()
        cliScanJourney.stop()
        inventoryGeneration += 1
        inventoryTask?.cancel()
        inventoryTask = nil
        cliInventoryGeneration += 1
        cliInventoryTask?.cancel()
        cliInventoryTask = nil
        isLoading = false
        isCLILoading = false
        flushRefreshWaiters(extra: nil)
        flushCLIRefreshWaiters(extra: nil)
    }

    /// CLI tools inventory (npm / brew / uv + data dirs). C0 list only.
    public func refreshCLI(force: Bool = true, completion: (() -> Void)? = nil) {
        if !force, hasFreshCLIInventory {
            completion?()
            return
        }
        if isCLILoading {
            if let completion { pendingCLIRefreshCompletions.append(completion) }
            return
        }
        cliInventoryGeneration += 1
        cliInventoryTask?.cancel()
        let gen = cliInventoryGeneration
        isCLILoading = true
        cliScanJourney.begin(["scan.stage.npm", "scan.stage.brew", "scan.stage.uv", "scan.stage.manual", "scan.stage.verify"])
        cliLoadError = nil
        // Force: clear ghosts immediately so deleted tools (e.g. vercel) don't linger in UI
        if force {
            cliTools = []
            lastCLIInventoryAt = nil
        }

        cliInventoryTask = Task.detached(priority: .userInitiated) {
            let list = CliToolInventory.fetchAll(
                computeSize: true,
                onStage: { stage in
                    Task { @MainActor in
                        guard self.cliInventoryGeneration == gen, self.isCLILoading else { return }
                        self.cliScanJourney.advance(stage)
                    }
                },
                onBatch: { list in
                    Task { @MainActor in
                        guard self.cliInventoryGeneration == gen, self.isCLILoading else { return }
                        self.cliTools = list
                    }
                },
                isCancelled: { Task.isCancelled }
            )
            await MainActor.run {
                guard self.cliInventoryGeneration == gen else {
                    completion?()
                    return
                }
                self.cliTools = list
                for stage in self.cliScanJourney.stages {
                    self.cliScanJourney.complete(stage.id, count: stage.id == "scan.stage.verify" ? list.count : nil)
                }
                self.cliScanJourney.finish()
                self.isCLILoading = false
                self.lastCLIInventoryAt = Date()
                self.flushCLIRefreshWaiters(extra: completion)
            }
        }
    }

    private func flushCLIRefreshWaiters(extra: (() -> Void)?) {
        let pending = pendingCLIRefreshCompletions
        pendingCLIRefreshCompletions = []
        extra?()
        for c in pending { c() }
    }

    private func flushRefreshWaiters(extra: (() -> Void)?) {
        let pending = pendingRefreshCompletions
        pendingRefreshCompletions = []
        extra?()
        for c in pending { c() }
    }

    public func beginAIEnrichment(hintIgnored: String = "") {
        isAIEnriching = true
        usedAI = true
    }

    public func finishAIEnrichment(
        narrative: String?,
        error: String?,
        previewActions: [SoftwareAIPreviewAction]
    ) {
        aiNarrative = narrative
        lastAIError = error
        aiPreviewActions = previewActions
        isAIEnriching = false
        SoftwareScanStore.save(
            apps: apps,
            sort: sort,
            aiNarrative: narrative,
            usedAI: true,
            aiError: error,
            previewActions: previewActions
        )
    }

    public func contextTextForAI(diskTight: Bool, freeDiskLabel: String) -> String {
        var lines: [String] = []
        lines.append("已装应用数：\(apps.count)（含系统位置标记）")
        lines.append("磁盘是否偏紧：\(diskTight ? "是" : "否")；可用约 \(freeDiskLabel)")
        lines.append("规则：大体积≠故障；磁盘不紧时不要催卸游戏/常用软件。不要编造路径；卸载须用户到软件页预览确认。")
        var tierCounts: [SoftwareSizeTier: Int] = [:]
        for a in apps {
            let t = SoftwareSizeTier.tier(for: a.totalBytes)
            tierCounts[t, default: 0] += 1
        }
        let tierLine = SoftwareSizeTier.allCases.map { t in
            "\(t.title)=\(tierCounts[t, default: 0])"
        }.joined(separator: " · ")
        let sizesKnown = apps.contains { $0.totalBytes > 0 || $0.bytes > 0 }
        if sizesKnown {
            lines.append("体积分档：\(tierLine)（≥10GB 重大 / 1–10GB 较大 / 100MB–1GB 一般 / <100MB 轻量）")
            // 隐私：不发完整安装路径；有实测体积才发字节（禁止未知编码为 0）
            lines.append("Top 体积（name | bundle | totalBytes | relatedBytes | system）：")
            for a in topBySize.prefix(20) where a.totalBytes > 0 || a.bytes > 0 {
                let tier = SoftwareSizeTier.tier(for: a.totalBytes).title
                lines.append(
                    "- [\(tier)] \(a.name) | \(a.bundleIdentifier) | \(a.totalBytes) | \(a.relatedBytes) | \(a.isSystemLocation)"
                )
            }
        } else {
            lines.append("体积：尚未测量（勿假设 0 B / 勿编造 GB）")
            lines.append("应用列表（name | bundle | system only）：")
            for a in apps.prefix(20) {
                lines.append("- \(a.name) | \(a.bundleIdentifier) | \(a.isSystemLocation)")
            }
        }
        return lines.joined(separator: "\n")
    }

    public func residuals(for app: InstalledApp) -> [ResidualItem] {
        ResidualPreview.findResiduals(for: app)
    }

    public func uninstall(
        app: InstalledApp,
        items: [ResidualItem],
        forceQuitIfNeeded: Bool = false
    ) async -> CleanupResult {
        // Freeze target identity and the exact preflight paths before the first .app
        // move; PathGate must not re-open an app bundle after it no longer exists.
        let targetIdentity = UninstallTargetIdentity(
            app: app,
            residualPaths: items.filter(\.isSelected).map(\.path)
        )
        let mapped: [CleanableItem] = items.filter(\.isSelected).map { r in
            var item = CleanableItem(
                name: r.name,
                path: r.path,
                bytes: r.bytes,
                category: .temp,
                isSelected: true,
                appName: app.name,
                displayTitle: r.name,
                whatIsIt: r.note,
                ifCleaned: "移入废纸篓，可还原",
                risk: .rebuild
            )
            // init 按产品规则强制 isSelected=false（防扫描自动勾选）；
            // 这里恢复用户在卸载预览里的勾选态，否则执行器过滤后为空
            item.isSelected = true
            return item
        }
        return await UninstallExecutor.shared.trash(
            items: mapped,
            appBundlePath: app.path,
            targetIdentity: targetIdentity,
            forceQuitIfNeeded: forceQuitIfNeeded
        )
    }
}

/// AI 建议的「预览卸载」入口（须匹配真实已装 path）
public struct SoftwareAIPreviewAction: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let title: String
    public let path: String
    public let bundleID: String?
    public let reason: String

    public init(title: String, path: String, bundleID: String? = nil, reason: String = "") {
        self.title = title
        self.path = path
        self.bundleID = bundleID
        self.reason = reason
    }
}
