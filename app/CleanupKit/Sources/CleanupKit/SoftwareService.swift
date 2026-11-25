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
    @Published public private(set) var userServices: [UserLaunchAgentItem] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var isSizingApps = false
    @Published public private(set) var isCLILoading = false
    @Published public private(set) var isServicesLoading = false
    @Published public private(set) var loadError: String?
    @Published public private(set) var cliLoadError: String?
    @Published public private(set) var servicesLoadError: String?
    @Published public private(set) var servicesProbeFailed = false
    @Published public private(set) var appScanJourney = ScanJourney()
    @Published public private(set) var cliScanJourney = ScanJourney()
    @Published public private(set) var servicesScanJourney = ScanJourney()
    /// Generation that currently owns `isLoading=true` for app inventory refresh.
    /// Used so stale MainActor callbacks after cancellation can clear the spinner
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
    /// 原位标记「已清理」的应用路径与 CLI 工具 ID（避免卸载后整页重扫丢失上下文）
    @Published public private(set) var cleanedAppPaths: Set<String> = []
    @Published public private(set) var cleanedCLIToolIDs: Set<String> = []
    @Published public private(set) var trashedServicePaths: Set<String> = []
    @Published public private(set) var actingServicePaths: Set<String> = []

    private var resourceObserver: AnyCancellable?

    public init() {
        resourceObserver = NotificationCenter.default.publisher(for: CleanupResourceEvents.didChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Do NOT cancel ongoing size calculations or force a full inventory reload
                // when an uninstall or cleanup completes; keep rows in place.
                self.aiNarrative = nil
            }
    }

    public func isAppCleaned(_ app: InstalledApp) -> Bool {
        cleanedAppPaths.contains(PathGate.normalize(app.path)) || cleanedAppPaths.contains(app.path)
    }

    public func isCLIToolCleaned(_ tool: CliTool) -> Bool {
        cleanedCLIToolIDs.contains(tool.id)
    }

    public func isServiceTrashed(_ item: UserLaunchAgentItem) -> Bool {
        trashedServicePaths.contains(item.plistPath) || trashedServicePaths.contains(PathGate.normalize(item.plistPath))
    }

    public func isServiceActing(_ item: UserLaunchAgentItem) -> Bool {
        actingServicePaths.contains(item.plistPath)
    }

    public func markAppCleaned(_ app: InstalledApp, result: CleanupResult) {
        guard result.cleanedCount > 0 || !result.succeededPaths.isEmpty else { return }
        cleanedAppPaths.insert(app.path)
        cleanedAppPaths.insert(PathGate.normalize(app.path))
        aiPreviewActions.removeAll {
            PathGate.normalize($0.path) == PathGate.normalize(app.path)
                || $0.bundleID == app.bundleIdentifier
        }
    }

    public func markCLIToolCleaned(_ tool: CliTool, result: CliUninstallResult) {
        guard result.programUninstalled || !result.trashedPaths.isEmpty || result.agentsStopped > 0 else { return }
        cleanedCLIToolIDs.insert(tool.id)
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
            return list.sorted {
                if $0.totalBytes != $1.totalBytes { return $0.totalBytes > $1.totalBytes }
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
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

    public func filteredServices(query rawQuery: String) -> [UserLaunchAgentItem] {
        let q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = userServices
        if !q.isEmpty {
            list = list.filter {
                $0.displayName.localizedCaseInsensitiveContains(q)
                    || $0.label.localizedCaseInsensitiveContains(q)
                    || $0.plistPath.localizedCaseInsensitiveContains(q)
                    || ($0.programPath?.localizedCaseInsensitiveContains(q) ?? false)
                    || ($0.targetPath?.localizedCaseInsensitiveContains(q) ?? false)
            }
        }
        return UserLaunchAgentService.defaultSort(list)
    }

    public var filteredServices: [UserLaunchAgentItem] {
        filteredServices(query: query)
    }

    /// 按体积分档分组（组内仍尊重当前 sort）。空档不返回。
    public var tierGroups: [SoftwareTierGroup] {
        let list = filtered
        var buckets: [SoftwareSizeTier: [InstalledApp]] = [:]
        for app in list where app.sizeState == .measured || app.sizeState == .partial {
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

    public var unmeasuredApps: [InstalledApp] {
        filtered.filter { $0.sizeState == .pending || $0.sizeState == .unavailable }
    }

    /// Attempted items include explicit partial/unavailable results, never just nonzero sizes.
    public var completedSizeCount: Int { apps.filter { $0.sizeState != .pending }.count }

    /// When last inventory finished.
    @Published public private(set) var lastInventoryAt: Date?
    @Published public private(set) var lastCLIInventoryAt: Date?
    @Published public private(set) var lastServicesInventoryAt: Date?

    /// Waiters while inventory is loading (so chat never gets empty busy).
    private var pendingRefreshCompletions: [() -> Void] = []
    private var inventoryGeneration = 0
    private var cliInventoryGeneration = 0
    private var servicesInventoryGeneration = 0
    private var pendingCLIRefreshCompletions: [() -> Void] = []
    private var pendingServicesRefreshCompletions: [() -> Void] = []
    private var inventoryTask: Task<Void, Never>?
    private var cliInventoryTask: Task<Void, Never>?
    private var servicesInventoryTask: Task<Void, Never>?
    private var sizeTask: Task<Void, Never>?
    private var sizeGeneration = 0

    // In-memory test seams keep queue tests away from the user's installed apps and history.
    var testInventoryHandler: (@Sendable () async -> [InstalledApp])?
    var testSizeHandler: (@Sendable (InstalledApp) async -> InstalledApp?)?

    /// 15 分钟内有列表可复用。
    public var hasFreshInventory: Bool {
        !apps.isEmpty
            && CleanupReusePolicy.isFresh(lastInventoryAt, ttl: CleanupReusePolicy.softwareTTL)
    }

    public var hasFreshCLIInventory: Bool {
        !cliTools.isEmpty
            && CleanupReusePolicy.isFresh(lastCLIInventoryAt, ttl: CleanupReusePolicy.softwareTTL)
    }

    public var hasFreshServicesInventory: Bool {
        CleanupReusePolicy.isFresh(lastServicesInventoryAt, ttl: 30)
    }

    /// Force: false and list still fresh → skip enum, keep AI copy.
    /// App 列表与 CLI 列表任务分离：本方法只扫 .app，不触发 CLI / 清理。
    public func refresh(force: Bool = true, completion: (() -> Void)? = nil) {
        if !force, hasFreshInventory {
            resumeSizeCalculation()
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
        cancelSizeCalculation()
        let gen = inventoryGeneration
        inventoryLoadingGen = gen
        isLoading = true
        appScanJourney.begin(["scan.stage.apps", "scan.stage.app_sizes", "scan.stage.verify"])
        appScanJourney.start("scan.stage.apps")
        loadError = nil
        aiNarrative = nil
        lastAIError = nil
        usedAI = false
        isAIEnriching = false
        aiPreviewActions = []
        cleanedAppPaths.removeAll()
        lastInventoryAt = nil

        let inventoryHandler = testInventoryHandler
        inventoryTask = Task.detached(priority: .userInitiated) {
            // Return the app list quickly; expensive related-data sizes are filled by
            // a bounded, cancellable pass rather than blocking first paint.
            let list: [InstalledApp]
            if let inventoryHandler {
                list = await inventoryHandler()
            } else {
                list = AppInventory.fetchInstalledApps(
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
            }
            await MainActor.run {
                guard self.inventoryGeneration == gen else {
                    // Stale after cancellation: clear spinner only if we still own it
                    // (a newer refresh would have inventoryLoadingGen == current gen).
                    if self.inventoryLoadingGen == gen {
                        self.isLoading = false
                    }
                    completion?()
                    return
                }
                self.apps = list
                self.appScanJourney.complete("scan.stage.apps", count: list.count)
                self.isLoading = false
                self.lastInventoryAt = Date()
                self.resumeSizeCalculation()
                self.flushRefreshWaiters(extra: completion)
            }
        }
    }

    /// Metadata appears first. One utility-priority worker then measures every pending app.
    public func resumeSizeCalculation() {
        guard !isLoading, !isSizingApps else { return }
        let pending = apps.filter { $0.sizeState == .pending }
        guard !pending.isEmpty else {
            finishSizeCalculation()
            return
        }
        sizeGeneration += 1
        let gen = sizeGeneration
        let previousTask = sizeTask
        let sizeHandler = testSizeHandler
        isSizingApps = true
        appScanJourney.begin(["scan.stage.apps", "scan.stage.app_sizes", "scan.stage.verify"])
        appScanJourney.complete("scan.stage.apps", count: apps.count)
        appScanJourney.start("scan.stage.app_sizes")
        sizeTask = Task.detached(priority: .utility) {
            // A cancelled filesystem call may still be returning. Do not overlap its successor.
            await previousTask?.value
            for app in pending {
                guard !Task.isCancelled else { return }
                let skipCleaned = await MainActor.run { self.isAppCleaned(app) }
                if skipCleaned { continue }
                let result = await DiskScanCoordinator.shared.withPermit {
                    if let sizeHandler { return await sizeHandler(app) }
                    return AppInventory.loadApp(
                        at: URL(fileURLWithPath: app.path), computeSize: true,
                        isCancelled: { Task.isCancelled }
                    )
                }
                guard !Task.isCancelled else { return }
                let sized = result ?? nil
                // Do not attach measurements from an app replaced while we were traversing it.
                let valid = sized.map {
                    $0.path == app.path && $0.bundleIdentifier == app.bundleIdentifier
                        && $0.version == app.version && $0.sizeState != .pending
                } ?? false
                let updated = valid ? sized! : InstalledApp(
                    name: app.name, bundleIdentifier: app.bundleIdentifier, path: app.path,
                    version: app.version, bytes: 0, isSystemLocation: app.isSystemLocation,
                    canTrashAppBundle: app.canTrashAppBundle, sizeState: .unavailable
                )
                await MainActor.run {
                    guard self.sizeGeneration == gen,
                          let index = self.apps.firstIndex(where: { $0.path == app.path })
                    else { return }
                    self.apps[index] = updated
                }
                // Bound UI re-sorts and give other disk scans a chance to acquire the permit.
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { return }
            }
            await MainActor.run {
                guard self.sizeGeneration == gen else { return }
                self.finishSizeCalculation()
            }
        }
    }

    private func finishSizeCalculation() {
        isSizingApps = false
        let incomplete = apps.contains { $0.sizeState != .measured }
        appScanJourney.complete("scan.stage.app_sizes", count: completedSizeCount, partial: incomplete)
        appScanJourney.start("scan.stage.verify")
        appScanJourney.complete("scan.stage.verify", count: apps.count)
        appScanJourney.finish(partial: incomplete)
        if testInventoryHandler == nil {
            SoftwareScanStore.save(apps: apps, sort: sort, aiNarrative: aiNarrative,
                                   usedAI: usedAI, aiError: lastAIError, previewActions: aiPreviewActions)
        }
    }

    private func cancelSizeCalculation() {
        sizeGeneration += 1
        sizeTask?.cancel()
        isSizingApps = false
    }

    public func cancelServicesScanIfRunning() {
        guard isServicesLoading else { return }
        servicesScanJourney.stop()
        servicesInventoryGeneration += 1
        servicesInventoryTask?.cancel()
        servicesInventoryTask = nil
        isServicesLoading = false
        flushServicesRefreshWaiters(extra: nil)
    }

    public func cancelInventoryWork() {
        cancelSizeCalculation()
        appScanJourney.stop()
        cliScanJourney.stop()
        servicesScanJourney.stop()
        inventoryGeneration += 1
        inventoryTask?.cancel()
        inventoryTask = nil
        cliInventoryGeneration += 1
        cliInventoryTask?.cancel()
        cliInventoryTask = nil
        servicesInventoryGeneration += 1
        servicesInventoryTask?.cancel()
        servicesInventoryTask = nil
        isLoading = false
        isCLILoading = false
        isServicesLoading = false
        flushRefreshWaiters(extra: nil)
        flushCLIRefreshWaiters(extra: nil)
        flushServicesRefreshWaiters(extra: nil)
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
            cleanedCLIToolIDs.removeAll()
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

    private func flushServicesRefreshWaiters(extra: (() -> Void)?) {
        let pending = pendingServicesRefreshCompletions
        pendingServicesRefreshCompletions = []
        extra?()
        for c in pending { c() }
    }

    /// User `~/Library/LaunchAgents/*.plist` background services inventory.
    public func refreshServices(force: Bool = true, completion: (() -> Void)? = nil) {
        if !force, hasFreshServicesInventory {
            completion?()
            return
        }
        if isServicesLoading || !actingServicePaths.isEmpty {
            if let completion { pendingServicesRefreshCompletions.append(completion) }
            return
        }
        servicesInventoryGeneration += 1
        servicesInventoryTask?.cancel()
        let gen = servicesInventoryGeneration
        isServicesLoading = true
        servicesScanJourney.begin(["scan.stage.launch_agents", "scan.stage.verify"])
        servicesScanJourney.start("scan.stage.launch_agents")
        servicesLoadError = nil
        if force {
            trashedServicePaths.removeAll()
            lastServicesInventoryAt = nil
        }

        servicesInventoryTask = Task.detached(priority: .userInitiated) {
            let scanResult = UserLaunchAgentService.scan(isCancelled: { Task.isCancelled })
            await MainActor.run {
                guard self.servicesInventoryGeneration == gen else {
                    completion?()
                    return
                }
                self.userServices = scanResult.items
                self.servicesProbeFailed = scanResult.probeFailed
                self.servicesScanJourney.complete(
                    "scan.stage.launch_agents",
                    count: scanResult.items.count,
                    partial: scanResult.probeFailed
                )
                self.servicesScanJourney.start("scan.stage.verify")
                self.servicesScanJourney.complete(
                    "scan.stage.verify",
                    count: scanResult.items.count,
                    partial: scanResult.probeFailed
                )
                self.servicesScanJourney.finish(partial: scanResult.probeFailed)
                self.isServicesLoading = false
                self.lastServicesInventoryAt = Date()
                self.flushServicesRefreshWaiters(extra: completion)
            }
        }
    }

    public func pauseService(_ item: UserLaunchAgentItem) async -> UserLaunchAgentActionResult {
        guard !actingServicePaths.contains(item.plistPath) else {
            return UserLaunchAgentActionResult(ok: false, errorCode: "busy")
        }
        actingServicePaths.insert(item.plistPath)
        defer { actingServicePaths.remove(item.plistPath) }
        let res = await Task.detached(priority: .userInitiated) {
            await UserLaunchAgentService.pause(item)
        }.value
        await reloadServicesInPlace()
        return res
    }

    public func resumeService(_ item: UserLaunchAgentItem) async -> UserLaunchAgentActionResult {
        guard !actingServicePaths.contains(item.plistPath) else {
            return UserLaunchAgentActionResult(ok: false, errorCode: "busy")
        }
        actingServicePaths.insert(item.plistPath)
        defer { actingServicePaths.remove(item.plistPath) }
        let res = await Task.detached(priority: .userInitiated) {
            await UserLaunchAgentService.resume(item)
        }.value
        await reloadServicesInPlace()
        return res
    }

    public func trashService(_ item: UserLaunchAgentItem) async -> UserLaunchAgentActionResult {
        guard !actingServicePaths.contains(item.plistPath) else {
            return UserLaunchAgentActionResult(ok: false, errorCode: "busy")
        }
        actingServicePaths.insert(item.plistPath)
        defer { actingServicePaths.remove(item.plistPath) }
        let res = await Task.detached(priority: .userInitiated) {
            await UserLaunchAgentService.moveToTrash(item)
        }.value
        if res.ok {
            trashedServicePaths.insert(item.plistPath)
            trashedServicePaths.insert(PathGate.normalize(item.plistPath))
        }
        await reloadServicesInPlace(preservingTrashed: item)
        return res
    }

    private func reloadServicesInPlace(preservingTrashed trashed: UserLaunchAgentItem? = nil) async {
        servicesInventoryGeneration += 1
        servicesInventoryTask?.cancel()
        servicesInventoryTask = nil
        let gen = servicesInventoryGeneration
        let scanResult = await Task.detached(priority: .userInitiated) {
            UserLaunchAgentService.scan(isCancelled: { Task.isCancelled })
        }.value
        guard servicesInventoryGeneration == gen else { return }
        var next = scanResult.items
        if let trashed, isServiceTrashed(trashed), !next.contains(where: { $0.plistPath == trashed.plistPath }) {
            var placeholder = trashed
            placeholder.runState = .paused
            placeholder.pid = nil
            placeholder.processStartMicros = nil
            next.append(placeholder)
        }
        // Keep previously trashed rows visible in session for confirmation feedback
        for prev in userServices where isServiceTrashed(prev) && !next.contains(where: { $0.plistPath == prev.plistPath }) {
            var placeholder = prev
            placeholder.runState = .paused
            placeholder.pid = nil
            placeholder.processStartMicros = nil
            next.append(placeholder)
        }
        userServices = UserLaunchAgentService.defaultSort(next)
        servicesProbeFailed = scanResult.probeFailed
        servicesScanJourney.begin(["scan.stage.launch_agents", "scan.stage.verify"])
        servicesScanJourney.complete("scan.stage.launch_agents", count: scanResult.items.count, partial: scanResult.probeFailed)
        servicesScanJourney.complete("scan.stage.verify", count: scanResult.items.count, partial: scanResult.probeFailed)
        servicesScanJourney.finish(partial: scanResult.probeFailed)
        isServicesLoading = false
        lastServicesInventoryAt = Date()
        flushServicesRefreshWaiters(extra: nil)
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
        for a in apps where a.sizeState == .measured || a.sizeState == .partial {
            let t = SoftwareSizeTier.tier(for: a.totalBytes)
            tierCounts[t, default: 0] += 1
        }
        let tierLine = SoftwareSizeTier.allCases.map { t in
            "\(t.title)=\(tierCounts[t, default: 0])"
        }.joined(separator: " · ")
        let sizesKnown = apps.contains { $0.sizeState == .measured || $0.sizeState == .partial }
        lines.append("体积计算进度：\(completedSizeCount)/\(apps.count)；部分测量仅为下限，未测量或无法读取不等于 0 B。")
        if sizesKnown {
            lines.append("体积分档：\(tierLine)（≥10GB 重大 / 1–10GB 较大 / 100MB–1GB 一般 / <100MB 轻量）")
            // 隐私：不发完整安装路径；有实测体积才发字节（禁止未知编码为 0）
            lines.append("Top 体积（name | bundle | totalBytes | relatedBytes | system）：")
            for a in topBySize.prefix(20) where a.sizeState == .measured || a.sizeState == .partial {
                let tier = SoftwareSizeTier.tier(for: a.totalBytes).title
                lines.append(
                    "- [\(tier)] \(a.name) | \(a.bundleIdentifier) | \(a.sizeState == .partial ? ">=" : "")\(a.totalBytes) | \(a.relatedBytes) | \(a.isSystemLocation)"
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
        let selectedItems = items.filter { $0.isSelected && $0.canSelect }
        let targetIdentity = await Task.detached(priority: .userInitiated) {
            UninstallTargetIdentity(app: app, residualPaths: selectedItems.map(\.path))
        }.value
        let mapped: [CleanableItem] = selectedItems.map { r in
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
