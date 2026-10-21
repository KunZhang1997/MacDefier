// JunkScanner — path-level cache/junk discovery.
// Strategy adapted from PureMac ScanEngine (MIT). Prefer PureMac path tables &
// default selection; product-only delta: trashItem at execute time + path list UI.
// Do not invent extra blocklists / DeviceSupport beyond PureMac.

import Foundation

/// Which page owns the scan — scopes must not be mixed.
public enum JunkScanProfile: Sendable {
    /// 清理页：完整清单（含大文件、孤儿、开发者类）
    case cleanupFull
    /// 诊断页：只粗算可再生垃圾 + 废纸篓，不做大文件/完整孤儿/深开发者扫
    case diagnosticLite
}

public actor JunkScanner {
    private let fm = FileManager.default
    private var home: String { fm.homeDirectoryForCurrentUser.path }
    private var detailProgress: ((String) -> Void)?
    private var lastDetailAt = Date.distantPast
    private var stepIsPartial = false
    private var lastSizeIsPartial = false
    private var stepStarted = ContinuousClock.now

    public init() {}

    public func scan(
        skipping completed: Set<CleanupCategory> = [],
        onGroup: @escaping @Sendable (CleanupCategoryGroup) -> Void = { _ in },
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async -> [CleanupCategoryGroup] {
        await scan(profile: .cleanupFull, skipping: completed, onGroup: onGroup, onProgress: onProgress)
    }

    public func scan(
        profile: JunkScanProfile,
        skipping completed: Set<CleanupCategory> = [],
        onGroup: @escaping @Sendable (CleanupCategoryGroup) -> Void = { _ in },
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async -> [CleanupCategoryGroup] {
        onProgress(0, "scan.waiting")
        return await DiskScanCoordinator.shared.withPermit { [self] in
            await scanUnlocked(profile: profile, skipping: completed, onGroup: onGroup, onProgress: onProgress)
        } ?? []
    }

    private func scanUnlocked(
        profile: JunkScanProfile,
        skipping completed: Set<CleanupCategory>,
        onGroup: @escaping @Sendable (CleanupCategoryGroup) -> Void,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async -> [CleanupCategoryGroup] {
        var groups: [CleanupCategoryGroup] = []
        let steps = steps(for: profile)
        defer { detailProgress = nil }

        for (index, step) in steps.enumerated() {
            if Task.isCancelled { return [] }
            if completed.contains(step.0) { continue }
            let progress = Double(index) / Double(max(steps.count, 1))
            lastDetailAt = .distantPast
            detailProgress = { detail in
                onProgress(progress, step.0.rawValue + "|" + detail)
            }
            onProgress(progress, step.0.rawValue)
            stepIsPartial = false
            stepStarted = .now
            let items = await step.1()
            guard !Task.isCancelled else { return [] }
            let group = CleanupCategoryGroup(category: step.0, items: items, isPartial: stepIsPartial)
            onGroup(group)
            if !items.isEmpty || stepIsPartial {
                groups.append(group)
            }
            await Task.yield()
        }
        onProgress(1, "done")
        return groups.sorted { $0.totalBytes > $1.totalBytes }
    }

    public nonisolated static let cleanupScanCategories: [CleanupCategory] = [
        .userCache, .userLogs, .browsers, .xcode, .brew, .node, .aiApps, .docker,
        .wallpaper, .installerPackages, .largeAppData, .orphans, .temp, .trash, .systemLogs
    ]

    private func steps(
        for profile: JunkScanProfile
    ) -> [(CleanupCategory, () async -> [CleanableItem])] {
        switch profile {
        case .cleanupFull:
            // 清理页专属：可再生 + 孤儿 + 大文件(按体积) + 废纸篓…
            return [
                (.userCache, { self.scanUserCaches() }),
                (.userLogs, { self.scanUserLogs() }),
                (.browsers, { self.scanBrowsers() }),
                (.xcode, { self.scanXcode() }),
                (.brew, { self.scanBrew() }),
                (.node, { self.scanNode() }),
                (.aiApps, { self.scanAIApps() }),
                (.docker, { self.scanDocker() }),
                (.wallpaper, { self.scanWallpaper() }),
                (.installerPackages, {
                    let report = InstallerPackageScanner.scanReport()
                    self.stepIsPartial = report.isPartial
                    return report.items
                }),
                (.largeAppData, {
                    let report = await LargeFileScanner.scanReport()
                    self.stepIsPartial = report.isPartial
                    return report.items
                }),
                (.orphans, { self.scanOrphans() }),
                (.temp, { self.scanTemp() }),
                (.trash, { self.scanTrash() }),
                (.systemLogs, { self.scanSystemLogs() }),
            ]
        case .diagnosticLite:
            // 诊断页：只给「可清粗算 + 废纸篓」——禁止大文件助手、禁止完整 CLI 孤儿链
            return [
                (.userCache, { self.scanUserCaches() }),
                (.userLogs, { self.scanUserLogs() }),
                (.temp, { self.scanTemp() }),
                (.trash, { self.scanTrash() }),
            ]
        }
    }

    // MARK: - Scanners (path sets ≈ PureMac ScanEngine)

    /// PureMac `scanUserCache`: enumerate ~/Library/Caches/*; exclude roots claimed by other categories.
    private func scanUserCaches() -> [CleanableItem] {
        let root = "\(home)/Library/Caches"
        // PureMac excludedRootPaths — avoid double-count with brew / AI categories
        let excluded = Set([
            normalize("\(home)/Library/Caches/Homebrew"),
            normalize("\(home)/Library/Caches/com.electron.ollama"),
            normalize("\(home)/Library/Caches/ollama"),
            normalize("\(home)/Library/Caches/com.apple.dt.Xcode") // claimed by Xcode scan
        ].map { $0 } + BrowserCleanupCatalog.userCacheExcludedRoots(home: home).map { normalize($0) })

        var items = listImmediateChildren(of: root, category: .userCache) { [self] _, path in
                    !excluded.contains(self.normalize(path)) && !self.isUnderAnyExcluded(path, excluded)
                }

        // PureMac also folds common dev caches into userCache scan
        // npm: only `_cacache` (not whole `~/.npm`) to avoid double-count with node scan's `~/.npm`
        let extra = [
            "\(home)/.cache/pip",
            "\(home)/.cache/yarn",
            "\(home)/.cache/pnpm",
            "\(home)/Library/Caches/pip"
        ]
        for path in extra {
            if let item = makeItem(
                name: URL(fileURLWithPath: path).lastPathComponent,
                path: path,
                category: .userCache,
                selected: false
            ) {
                items.append(item)
            }
        }
        return dedupe(items)
    }

    private func scanUserLogs() -> [CleanableItem] {
        listImmediateChildren(of: "\(home)/Library/Logs", category: .userLogs)
    }

    private func scanSystemLogs() -> [CleanableItem] {
        // PureMac systemJunk includes /Library/Logs + /private/var/log.
        var items: [CleanableItem] = []
        for p in ["/Library/Logs", "/private/var/log"] {
            items.append(contentsOf: listImmediateChildren(of: p, category: .systemLogs))
        }
        return dedupe(items)
    }

    /// PureMac `scanXcodeJunk` path table (no DeviceSupport — that was our extra).
    private func scanXcode() -> [CleanableItem] {
        let targets = [
            ("DerivedData", "\(home)/Library/Developer/Xcode/DerivedData"),
            ("Archives", "\(home)/Library/Developer/Xcode/Archives"),
            ("CoreSimulator Caches", "\(home)/Library/Developer/CoreSimulator/Caches"),
            ("com.apple.dt.Xcode", "\(home)/Library/Caches/com.apple.dt.Xcode")
        ]
        return targets.compactMap { name, path in
            makeItem(name: name, path: path, category: .xcode, selected: false)
        }
    }

    /// PureMac known Homebrew roots + `brew --cache` (only if inside known roots).
    private func scanBrew() -> [CleanableItem] {
        let knownRoots = [
            "\(home)/Library/Caches/Homebrew",
            "/opt/homebrew/Library/Caches",
            "/usr/local/Homebrew/Library/Caches",
            "/Library/Caches/Homebrew"
        ]
        var paths = knownRoots

        for brewBin in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            guard fm.isExecutableFile(atPath: brewBin) else { continue }
            if let detected = runBrewCachePath(brewBin: brewBin) {
                let normalized = normalize(detected)
                let isKnown = knownRoots.contains { root in
                    let n = normalize(root)
                    return normalized == n || normalized.hasPrefix(n + "/")
                }
                if isKnown, !paths.map(normalize).contains(normalized) {
                    paths.append(detected)
                }
            }
            break
        }

        return paths.compactMap { path in
            makeItem(
                name: URL(fileURLWithPath: path).lastPathComponent,
                path: path,
                category: .brew,
                selected: false
            )
        }
    }

    /// PureMac `scanNodeCache` default paths (CLI probe omitted — keep thin).
    private func scanNode() -> [CleanableItem] {
        let paths = [
            ("npm cache", "\(home)/.npm"),
            ("yarn classic cache", "\(home)/Library/Caches/Yarn"),
            ("pnpm store", "\(home)/Library/pnpm/store")
        ]
        return paths.compactMap { name, path in
            makeItem(name: name, path: path, category: .node, selected: false)
        }
    }

    /// C08: Safari / Chrome / Edge itemized browser data.
    /// Cookie 不进列表；每条路径必须能通过执行 PathGate（密码库 skip 项除外且不进可选项）。
    private func scanBrowsers() -> [CleanableItem] {
        let specs = BrowserCleanupCatalog.specs(home: home, fm: fm)
        let browserGuard = BrowserCleanupGuard.live
        var browserBlockReasons: [BrowserBrand: String] = [:]
        for brand in BrowserBrand.allCases {
            if let reason = browserGuard.ownerBlockingReason(for: brand) {
                browserBlockReasons[brand] = reason
            }
        }
        var items: [CleanableItem] = []
        for spec in specs {
            // 产品：Cookie 不进入清理列表
            if spec.kind == .cookies { continue }
            // 密码库：PathGate 硬拒，也不作为可选项列出
            if spec.kind == .passwords { continue }

            let existing = spec.paths.filter { path in
                guard fm.fileExists(atPath: path), isPathAllowed(path) else { return false }
                // 扫描产出的每条路径必须能通过同一执行 PathGate
                return PathGate.isSafeToTrash(path)
            }
            guard !existing.isEmpty else { continue }
            // Keep occupied/unknown rows visible, but never selectable. Execution
            // probes again because a browser can start after this preview.
            // Process snapshots are reused only inside this preview. Expensive
            // open-file traversal belongs to the execution boundary, not sizing.
            let blockedReason = browserBlockReasons[spec.brand]
            var total: UInt64 = 0
            var partial = false
            for p in existing {
                total += directorySize(at: p)
                partial = partial || lastSizeIsPartial
            }
            if total < 512 { continue }
            let primary = existing[0]
            let extra = Array(existing.dropFirst())
            let title = "\(spec.brand.displayName) · \(spec.kind.title)"
            items.append(
                CleanableItem(
                    name: title,
                    path: primary,
                    bytes: total,
                    category: .browsers,
                    isSelected: false,
                    appName: spec.brand.displayName,
                    displayTitle: title,
                    whatIsIt: spec.kind.what,
                    ifCleaned: blockedReason ?? spec.kind.effect,
                    risk: blockedReason == nil ? spec.kind.risk : .skip,
                    extraPaths: extra,
                    sizeIsLowerBound: partial
                )
            )
        }
        return items
    }

    private func isUnderAnyExcluded(_ path: String, _ roots: Set<String>) -> Bool {
        let n = normalize(path)
        for r in roots {
            if n == r || n.hasPrefix(r + "/") { return true }
        }
        return false
    }

    /// PureMac `scanAIApps` target table.
    private func scanAIApps() -> [CleanableItem] {
        struct Target {
            let name: String
            let path: String
            let minBytes: UInt64
        }
        let targets: [Target] = [
            .init(name: "Ollama Logs", path: "\(home)/.ollama/logs", minBytes: 1024),
            .init(name: "Ollama Cache", path: "\(home)/Library/Caches/ollama", minBytes: 1024),
            .init(name: "Ollama Electron Cache", path: "\(home)/Library/Caches/com.electron.ollama", minBytes: 1024),
            .init(name: "Ollama WebKit Data", path: "\(home)/Library/WebKit/com.electron.ollama", minBytes: 1024),
            .init(name: "Ollama Saved State", path: "\(home)/Library/Saved Application State/com.electron.ollama.savedState", minBytes: 1024),
            .init(name: "Ollama CLI Prompt History (Optional)", path: "\(home)/.ollama/history", minBytes: 0),
            .init(name: "LM Studio Server Logs", path: "\(home)/.lmstudio/server-logs", minBytes: 1024),
            .init(name: "LM Studio Conversations (Optional)", path: "\(home)/.lmstudio/conversations", minBytes: 0)
        ]
        return targets.compactMap { t in
            makeItem(name: t.name, path: t.path, category: .aiApps, selected: false, minimumBytes: t.minBytes)
        }
    }

    /// PureMac `scanDockerCache` file roots only（不做 docker binary 伪条目，避免误 trash CLI）.
    private func scanDocker() -> [CleanableItem] {
        let paths = [
            "\(home)/Library/Containers/com.docker.docker/Data/cache",
            "\(home)/Library/Containers/com.docker.docker/Data/log",
            "\(home)/Library/Containers/com.docker.docker/Data/tmp",
            "\(home)/Library/Group Containers/group.com.docker/Caches",
            "\(home)/.docker/cli-plugins/.cache",
            "\(home)/.docker/buildx/cache"
        ]
        return paths.compactMap { path in
            makeItem(
                name: URL(fileURLWithPath: path).lastPathComponent,
                path: path,
                category: .docker,
                selected: false
            )
        }
    }

    private func scanWallpaper() -> [CleanableItem] {
        WallpaperCleanupPolicy.scan(home: home)
    }

    private func scanOrphans() -> [CleanableItem] {
        // CLI ownership is only needed here, not before the first cache result.
        reportItem("scan.cli_inventory", force: true)
        let cliInventory = CliToolInventory.fetchAll(computeSize: false, isCancelled: { Task.isCancelled })
        guard !Task.isCancelled else { return [] }
        reportItem("scan.app_inventory", force: true)
        // Lightweight installed list without size (orphan ownership only needs identity)
        let apps = AppInventory.fetchInstalledApps(
            includeSystemApps: true, computeSize: false, isCancelled: { Task.isCancelled }
        )
        guard !Task.isCancelled else { return [] }
        return OrphanScanner.scan(installed: apps, cliInventory: cliInventory) { name in
            self.reportItem(name)
        }
    }

    private func scanTemp() -> [CleanableItem] {
        // PureMac systemJunk includes /tmp + /private/var/tmp
        var items: [CleanableItem] = []
        for p in ["/tmp", "/private/var/tmp", NSTemporaryDirectory()] {
            items.append(contentsOf: listImmediateChildren(of: p, category: .temp, maxItems: 80))
        }
        return dedupe(items)
    }

    private func scanTrash() -> [CleanableItem] {
        // PureMac trashBins: list children, default selected true
        listImmediateChildren(of: "\(home)/.Trash", category: .trash, maxItems: 100)
    }

    // MARK: - Helpers

    private func listImmediateChildren(
        of root: String,
        category: CleanupCategory,
        maxItems: Int = 500,
        filter: ((String, String) -> Bool)? = nil
    ) -> [CleanableItem] {
        guard fm.fileExists(atPath: root) else { return [] }
        guard let names = try? fm.contentsOfDirectory(atPath: root) else { stepIsPartial = true; return [] }

        var items: [CleanableItem] = []
        for name in names {
            if Task.isCancelled || stepStarted.duration(to: .now) >= .seconds(8) { stepIsPartial = true; break }
            if name.hasPrefix(".") { continue }
            let path = (root as NSString).appendingPathComponent(name)
            // Installer artifacts have one dedicated category. Trash remains special:
            // items already there must stay under permanent-empty semantics.
            if category != .trash, InstallerPackageScanner.isInstallerPackagePath(path) { continue }
            if let filter, !filter(name, path) { continue }
            if !isPathAllowed(path) { continue }
            if let item = makeItem(name: name, path: path, category: category, selected: category.defaultSelected) {
                items.append(item)
            }
            if items.count >= maxItems { stepIsPartial = true; break }
        }
        return items.sorted { $0.bytes > $1.bytes }
    }

    private func makeItem(
        name: String,
        path: String,
        category: CleanupCategory,
        selected: Bool,
        minimumBytes: UInt64 = 4096
    ) -> CleanableItem? {
        reportItem(name)
        guard fm.fileExists(atPath: path) else { return nil }
        guard isPathAllowed(path) else { return nil }
        // 废纸篓清空走 removeItem，不要求 isSafeToTrash；其余项必须执行闸可通过
        if category != .trash, !PathGate.isSafeToTrash(path) { return nil }
        if category == .trash, !PathGate.isUnderUserTrash(path) { return nil }
        let size = directorySize(at: path)
        if size < minimumBytes && category != .trash { return nil }
        let appName = friendlyAppName(from: name)
        let aiReason = category == .trash ? nil : AIToolCleanupGuard.live.blockingReason(for: path, home: home)
        let eligibility = CleanupEligibility.previewBlock(for: path, home: home)
        return CleanableItem(
            name: name,
            path: path,
            bytes: size,
            category: category,
            isSelected: false, // 永远不自动勾；用户手动或「勾选低风险」
            appName: appName,
            ifCleaned: eligibility.map { "cleanup_blocked:" + $0.rawValue } ?? aiReason.map { "ai_cleanup:" + $0 },
            risk: eligibility == nil && aiReason == nil ? nil : .skip,
            sizeIsLowerBound: lastSizeIsPartial
        )
    }

    private func runBrewCachePath(brewBin: String) -> String? {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("HOMEBREW_") {
            env.removeValue(forKey: key)
        }
        guard let run = try? ProcessRunner.runSync(
            [brewBin, "--cache"],
            environment: env,
            timeout: 5,
            isCancelled: { Task.isCancelled }
        ), run.succeeded else { return nil }
        let output = run.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    private func friendlyAppName(from folder: String) -> String? {
        if folder.hasPrefix("com.") || folder.hasPrefix("org.") || folder.hasPrefix("net.") {
            return folder.split(separator: ".").last.map(String.init)
        }
        return folder
    }

    private func reportItem(_ detail: String, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastDetailAt) >= 0.15 else { return }
        lastDetailAt = now
        detailProgress?(detail)
    }

    private func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func dedupe(_ items: [CleanableItem]) -> [CleanableItem] {
        var seen = Set<String>()
        var out: [CleanableItem] = []
        for item in items {
            if Task.isCancelled { break }
            let key = normalize(item.path)
            if seen.insert(key).inserted {
                out.append(item)
            }
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// Scan-time allowlist — PathGate (PureMac junk + Docker/AI/Browser carve-outs).
    private func isPathAllowed(_ path: String) -> Bool {
        PathGate.isPathAllowedForScan(path)
    }

    private func directorySize(at path: String) -> UInt64 {
        let result = DiskUsageScanner.scan(root: URL(fileURLWithPath: path),
            budget: DiskScanBudget(maxEntries: 50_000, maxSeconds: 2),
            isCancelled: { Task.isCancelled })
        lastSizeIsPartial = result.root?.isComplete != true
        stepIsPartial = stepIsPartial || lastSizeIsPartial
        return result.root?.allocatedBytes ?? 0
    }
}
