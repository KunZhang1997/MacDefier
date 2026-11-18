import AppKit
import CleanupKit
import QuickLook
import SwiftUI

enum DiskScanScopeKind: String, CaseIterable, Identifiable {
    case wholeDisk
    case home
    case custom

    var id: String { rawValue }
}

@MainActor
final class DiskMapModel: ObservableObject {
    static let shared = DiskMapModel()

    @Published private(set) var snapshot: DiskUsageSnapshot?
    @Published private(set) var currentPath: String?
    @Published private(set) var isScanning = false
    @Published private(set) var isBackgroundRefresh = false
    @Published private(set) var children: [DiskUsageNode] = []
    @Published private(set) var presentation = DiskMapPresentation.empty
    @Published private(set) var scanJourney = ScanJourney()
    @Published private(set) var scannedEntries = 0
    @Published private(set) var liveScannedBytes: UInt64 = 0
    @Published private(set) var scopeKind: DiskScanScopeKind = .wholeDisk
    @Published private(set) var scanScopeURL = URL(fileURLWithPath: "/")
    @Published private(set) var customScopeURL: URL?
    @Published private(set) var volumeOverview: DiskVolumeSpaceOverview? = DiskUsageScanner.volumeOverview()
    @Published private(set) var mountedVolumes: [DiskVolumeSpaceOverview] = DiskUsageScanner.mountedLocalVolumes()
    @Published private(set) var hasFullDiskAccess: Bool = DiskUsageScanner.hasFullDiskAccess()

    private var completedSnapshots: [String: DiskUsageSnapshot] = [:]
    private var task: Task<Void, Never>?
    private var expandTask: Task<Void, Never>?
    private var generation = 0
    private var requestedRoot: String?
    private var lastLiveMapRender = ContinuousClock.now
    private var coldScanStartedAt = ContinuousClock.now

    var current: DiskUsageNode? {
        guard let currentPath else { return nil }
        return snapshot?.nodes[currentPath]
    }

    var breadcrumbs: [String] {
        guard let currentPath, let root = snapshot?.rootPath else { return [] }
        var result = [currentPath]
        var path = currentPath
        while path != root {
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            guard parent != path, parent == root || parent.hasPrefix(root == "/" ? "/" : root + "/") else { break }
            result.append(parent)
            path = parent
        }
        return result.reversed()
    }

    func refreshEnvironment() {
        mountedVolumes = DiskUsageScanner.mountedLocalVolumes()
        volumeOverview = DiskUsageScanner.volumeOverview(for: scanScopeURL)
        hasFullDiskAccess = DiskUsageScanner.hasFullDiskAccess()
        if snapshot != nil, currentPath != nil {
            updatePresentation()
        }
    }

    func open(_ path: String) {
        guard (!isScanning || isBackgroundRefresh), let node = snapshot?.nodes[path], node.isDirectory else { return }
        expandTask?.cancel()
        currentPath = path
        updatePresentation()

        if node.hasOmittedSmallChildren {
            let expectedGeneration = generation
            let targetURL = URL(fileURLWithPath: path)
            expandTask = Task {
                let expanded = await Task.detached(priority: .userInitiated) {
                    DiskUsageScanner.scanInteractive(
                        root: targetURL,
                        options: DiskInteractiveScanOptions(
                            maxDepth: 6,
                            minRetainedChildBytesAfterShallowDepth: 0,
                            shallowFullRetentionDepth: 4,
                            maxRetainedSmallChildrenPerDirectory: 512,
                            workerCount: 4
                        ),
                        isCancelled: { Task.isCancelled }
                    )
                }.value
                guard !Task.isCancelled, self.generation == expectedGeneration, let existing = self.snapshot else { return }
                let merged = existing.mergingExpandedSubtree(expanded)
                self.snapshot = merged
                if existing.root?.hasTruncatedWalk == false {
                    self.completedSnapshots[merged.rootPath] = merged
                }
                if self.currentPath == path {
                    self.updatePresentation()
                }
            }
        }
    }

    private func updatePresentation() {
        guard let snapshot, let current else { children = []; presentation = .empty; return }
        children = snapshot.children(of: current.path)
        let unaccounted = computeUnaccountedVolumeBytes(for: current)
        presentation = DiskMapPresentation(
            parent: current,
            children: children,
            snapshot: snapshot,
            unaccountedVolumeBytes: unaccounted
        )
    }

    private func computeUnaccountedVolumeBytes(for node: DiskUsageNode) -> UInt64 {
        guard (!isScanning || isBackgroundRefresh),
              !node.issues.contains(.inProgress),
              !node.issues.contains(.cancelled),
              let vol = volumeOverview,
              PathGate.standardizeOnly(node.path) == PathGate.standardizeOnly(vol.mountPath),
              vol.usedBytes > node.allocatedBytes else {
            return 0
        }
        let gap = vol.usedBytes - node.allocatedBytes
        return gap >= 64 * 1_048_576 ? gap : 0
    }

    private func reusableSnapshot(covering targetPath: String) -> DiskUsageSnapshot? {
        if let exact = completedSnapshots[targetPath] {
            return exact
        }
        let orderedSupersets = completedSnapshots.values.sorted { $0.rootPath.count < $1.rootPath.count }
        for superset in orderedSupersets {
            let supRoot = superset.rootPath
            if supRoot == "/" || targetPath.hasPrefix(supRoot + "/") {
                if let projected = superset.extractingSubtree(at: targetPath) {
                    return projected
                }
            }
        }
        return nil
    }

    private func availableSeedSubtrees(under targetRoot: String) -> [DiskUsageSnapshot] {
        completedSnapshots.values.filter { snap in
            let p = PathGate.standardizeOnly(snap.rootPath)
            guard p != targetRoot, snap.root?.hasTruncatedWalk == false else { return false }
            return targetRoot == "/" ? p.hasPrefix("/") : p.hasPrefix(targetRoot + "/")
        }
    }

    func selectBuiltInScope(_ kind: DiskScanScopeKind) {
        let targetURL: URL
        switch kind {
        case .wholeDisk:
            targetURL = URL(fileURLWithPath: "/")
        case .home:
            targetURL = FileManager.default.homeDirectoryForCurrentUser
        case .custom:
            guard let customScopeURL else { return }
            targetURL = customScopeURL
        }
        applyScopeSelection(url: targetURL, kind: kind)
    }

    func selectScope(_ url: URL) {
        let cleanPath = PathGate.standardizeOnly(url.path)
        let cleanURL = URL(fileURLWithPath: cleanPath)
        let homePath = PathGate.standardizeOnly(FileManager.default.homeDirectoryForCurrentUser.path)
        let kind: DiskScanScopeKind
        if cleanPath == "/" {
            kind = .wholeDisk
        } else if cleanPath == homePath {
            kind = .home
        } else {
            customScopeURL = cleanURL
            kind = .custom
        }
        applyScopeSelection(url: cleanURL, kind: kind)
    }

    private func applyScopeSelection(url: URL, kind: DiskScanScopeKind) {
        let hadPriorActivity = snapshot != nil || !completedSnapshots.isEmpty || scanJourney.status != .idle
        let newPath = PathGate.standardizeOnly(url.path)
        if scanScopeURL.path == newPath && scopeKind == kind && currentPath == newPath && !isScanning {
            return
        }

        task?.cancel()
        expandTask?.cancel()
        generation += 1
        task = nil
        isScanning = false
        isBackgroundRefresh = false
        scopeKind = kind
        scanScopeURL = URL(fileURLWithPath: newPath)
        requestedRoot = newPath
        mountedVolumes = DiskUsageScanner.mountedLocalVolumes()
        volumeOverview = DiskUsageScanner.volumeOverview(for: scanScopeURL)
        hasFullDiskAccess = DiskUsageScanner.hasFullDiskAccess()

        // Instant zero-flash projection when an existing completed snapshot already covers `newPath`.
        if let cached = reusableSnapshot(covering: newPath) {
            snapshot = cached
            currentPath = cached.rootPath
            scannedEntries = max(scannedEntries, cached.nodes.count)
            liveScannedBytes = cached.root?.allocatedBytes ?? 0
            scanJourney.finish(partial: false)
            updatePresentation()
            return
        }

        snapshot = nil; currentPath = nil; children = []; presentation = .empty
        scannedEntries = 0
        liveScannedBytes = 0
        scanJourney = ScanJourney()
        if hadPriorActivity {
            scan(scanScopeURL, forceFullRescan: false)
        }
    }

    func rescanCurrent() {
        let target = currentPath.map { URL(fileURLWithPath: $0) } ?? scanScopeURL
        scan(target, forceFullRescan: true)
    }

    func scan(_ url: URL, forceFullRescan: Bool = false) {
        task?.cancel()
        expandTask?.cancel()
        generation += 1
        let token = generation
        let rootPath = PathGate.standardizeOnly(url.path)
        let homePath = PathGate.standardizeOnly(FileManager.default.homeDirectoryForCurrentUser.path)
        if rootPath == "/" {
            scopeKind = .wholeDisk
        } else if rootPath == homePath {
            scopeKind = .home
        } else {
            customScopeURL = URL(fileURLWithPath: rootPath)
            scopeKind = .custom
        }
        requestedRoot = rootPath
        scanScopeURL = URL(fileURLWithPath: rootPath)
        mountedVolumes = DiskUsageScanner.mountedLocalVolumes()
        volumeOverview = DiskUsageScanner.volumeOverview(for: scanScopeURL)
        hasFullDiskAccess = DiskUsageScanner.hasFullDiskAccess()

        if !forceFullRescan, let cached = reusableSnapshot(covering: rootPath) {
            snapshot = cached
            currentPath = cached.rootPath
            isScanning = false
            isBackgroundRefresh = false
            scanJourney.finish(partial: false)
            updatePresentation()
            return
        }

        let keepSteadyCanvas = forceFullRescan && snapshot?.rootPath == rootPath && snapshot != nil
        let seeds = forceFullRescan ? [] : availableSeedSubtrees(under: rootPath)

        if !keepSteadyCanvas {
            if let firstSeed = seeds.sorted(by: { ($0.root?.allocatedBytes ?? 0) > ($1.root?.allocatedBytes ?? 0) }).first {
                liveScannedBytes = firstSeed.root?.allocatedBytes ?? 0
                scannedEntries = firstSeed.nodes.count
            } else {
                snapshot = nil; currentPath = nil; children = []; presentation = .empty
                scannedEntries = 0
                liveScannedBytes = 0
            }
        }

        isBackgroundRefresh = keepSteadyCanvas
        coldScanStartedAt = .now
        lastLiveMapRender = .now
        scanJourney.begin(["scan.stage.file_metadata", "scan.stage.space_map"])
        isScanning = true
        let scanURL = scanScopeURL

        task = Task {
            let result = await DiskScanCoordinator.shared.withPermit(retainingCancelledResult: true) {
                await MainActor.run {
                    guard self.generation == token else { return }
                    self.scanJourney.start("scan.stage.file_metadata")
                }
                let worker = Task.detached(priority: .utility) {
                    DiskUsageScanner.scanInteractive(
                        root: scanURL,
                        seedSubtrees: seeds,
                        onProgress: { progress in
                            Task { @MainActor in
                                guard self.generation == token, self.isScanning, self.scanJourney.status == .running else { return }
                                self.scannedEntries = progress.entries
                                self.liveScannedBytes = progress.snapshot.root?.allocatedBytes ?? self.liveScannedBytes

                                // When refreshing an existing map, keep the canvas completely steady until completion.
                                guard !self.isBackgroundRefresh else { return }

                                // During a cold scan, throttle Treemap geometry rebuilds to a calm ~1.8s cadence
                                // (after an initial 0.85s settle) so tiles never strobe or jump 4 times per second.
                                let sinceStart = self.coldScanStartedAt.duration(to: .now)
                                let sinceLastRender = self.lastLiveMapRender.duration(to: .now)
                                let isFirstReveal = self.snapshot == nil && sinceStart >= .milliseconds(850) && (progress.snapshot.root?.allocatedBytes ?? 0) > 0
                                let isCalmTick = self.snapshot != nil && sinceLastRender >= .milliseconds(1800)
                                if isFirstReveal || isCalmTick {
                                    self.lastLiveMapRender = .now
                                    self.snapshot = progress.snapshot
                                    self.currentPath = progress.snapshot.rootPath
                                    self.updatePresentation()
                                }
                            }
                        },
                        isCancelled: { Task.isCancelled }
                    )
                }
                return await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
            }
            guard generation == token else { return }
            mountedVolumes = DiskUsageScanner.mountedLocalVolumes()
            volumeOverview = DiskUsageScanner.volumeOverview(for: scanScopeURL)
            hasFullDiskAccess = DiskUsageScanner.hasFullDiskAccess()
            if let result {
                scannedEntries = max(scannedEntries, result.nodes.count - 1)
                liveScannedBytes = result.root?.allocatedBytes ?? liveScannedBytes
                snapshot = result
                if !isBackgroundRefresh || currentPath == nil || result.nodes[currentPath ?? ""] == nil {
                    currentPath = result.rootPath
                }
                isScanning = false
                isBackgroundRefresh = false
                if !Task.isCancelled, result.root?.hasTruncatedWalk == false {
                    storeCompletedSnapshot(result)
                }
                if !Task.isCancelled {
                    scanJourney.complete("scan.stage.file_metadata", count: scannedEntries,
                                         bytes: result.root?.allocatedBytes, partial: result.root?.hasTruncatedWalk == true)
                    scanJourney.start("scan.stage.space_map")
                }
                updatePresentation()
            } else {
                isScanning = false
                isBackgroundRefresh = false
            }
            if Task.isCancelled { scanJourney.stop() }
            else {
                let extraTile = presentation.unaccountedBytes > 0 ? 1 : 0
                scanJourney.complete("scan.stage.space_map", count: children.count + extraTile)
                scanJourney.finish(partial: result?.root?.hasTruncatedWalk == true)
            }
            task = nil
        }
    }

    private func storeCompletedSnapshot(_ completed: DiskUsageSnapshot) {
        let path = PathGate.standardizeOnly(completed.rootPath)
        completedSnapshots[path] = completed
        // Propagate refreshed subtree into any cached superset (e.g. "/" covering "~/Downloads").
        for (supKey, supSnap) in completedSnapshots where supKey != path {
            if supKey == "/" || path.hasPrefix(supKey + "/") {
                if supSnap.nodes[path] != nil {
                    completedSnapshots[supKey] = supSnap.mergingExpandedSubtree(completed)
                }
            }
        }
        if completedSnapshots.count > 8 {
            let keepKeys = Set(["/", PathGate.standardizeOnly(FileManager.default.homeDirectoryForCurrentUser.path), path])
            for key in completedSnapshots.keys where !keepKeys.contains(key) && completedSnapshots.count > 6 {
                completedSnapshots.removeValue(forKey: key)
            }
        }
    }

    func resourcesChanged(_ paths: [String]) {
        volumeOverview = DiskUsageScanner.volumeOverview(for: scanScopeURL)
        let roots = [requestedRoot, snapshot?.rootPath].compactMap { $0 }
        guard let root = requestedRoot ?? snapshot?.rootPath,
              roots.contains(where: { candidate in paths.contains(where: {
                  ResourceMutationCoordinator.overlaps(candidate, PathGate.standardizeOnly($0))
              }) }) else { return }
        scan(URL(fileURLWithPath: root), forceFullRescan: true)
    }

    func stop() {
        scanJourney.stop()
        expandTask?.cancel()
        task?.cancel()
        isScanning = false
        isBackgroundRefresh = false
    }
}

struct DiskMapView: View {
    @ObservedObject private var model = DiskMapModel.shared
    @StateObject private var scanAnimation = MDScanAnimationClock()
    @State private var displayLimit = 100
    @State private var mode: DisplayMode = .map
    @State private var selectedPath: String?
    @State private var hoveredID: String?
    @State private var showsInfo = false
    @State private var quickLookURL: URL?

    private enum DisplayMode: String, CaseIterable { case map, list }

    private var showsScanActivity: Bool {
        model.isScanning || model.scanJourney.status == .stopped
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MDPageBar {
                VStack(alignment: .leading, spacing: 7) {
                    wholeDiskHeaderRow
                    fullWidthVolumeBar
                    if !model.hasFullDiskAccess {
                        fullDiskAccessBanner
                    }
                }
            }

            if let node = model.current {
                VStack(alignment: .leading, spacing: 0) {
                    if showsScanActivity {
                        scanActivity(compact: true)
                            .padding(.horizontal, MDTheme.pagePadding)
                            .padding(.top, 8)
                            .padding(.bottom, MDTheme.resultCardGap)
                    }
                    compactToolbar(node)
                    ZStack(alignment: .bottom) {
                        if mode == .map {
                            mapCanvas(node)
                        } else {
                            fileList(node)
                        }
                        if selectedPath != nil || hoveredID != nil {
                            floatingHUD(node)
                                .padding(.horizontal, MDTheme.pagePadding)
                                .padding(.bottom, 16)
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                emptyState
            }
        }
        .background(MDTheme.content)
        .onAppear { model.refreshEnvironment() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshEnvironment()
        }
        .onChange(of: model.currentPath) { _, _ in
            displayLimit = 100
            selectedPath = nil
            hoveredID = nil
        }
        .onChange(of: mode) { _, _ in hoveredID = nil }
        .onReceive(NotificationCenter.default.publisher(for: CleanupResourceEvents.didChange)) { note in
            model.resourcesChanged(note.userInfo?["paths"] as? [String] ?? [])
        }
        .onReceive(NotificationCenter.default.publisher(for: .macDefierRefreshCurrentRoute)) { _ in
            guard !model.isScanning else { return }
            model.rescanCurrent()
        }
        .onKeyPress(.space) {
            guard let id = selectedPath ?? hoveredID,
                  let target = model.presentation.entriesByID[id]?.effectiveNode ?? model.snapshot?.nodes[id],
                  FileManager.default.fileExists(atPath: target.path) else {
                return .ignored
            }
            quickLookURL = URL(fileURLWithPath: target.path)
            return .handled
        }
        .quickLookPreview($quickLookURL)
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            scanActivity(compact: model.isScanning || model.scanJourney.status == .stopped)
            Spacer(minLength: 0)
        }
        .padding(MDTheme.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func scanActivity(compact: Bool) -> some View {
        let isStopped = model.scanJourney.status == .stopped
        let isStopping = model.isScanning && isStopped
        let isWaiting = model.isScanning && model.scanJourney.status == .running && model.scanJourney.activeID == nil
        let runningDetail: String = {
            if model.isBackgroundRefresh {
                return L10n.t("diskmap.refreshing_inline", model.scannedEntries)
            }
            if model.liveScannedBytes > 0 {
                return L10n.t("diskmap.scanning_inline", model.scannedEntries, DiskMapFormat.size(Double(model.liveScannedBytes)))
            }
            return L10n.t("scan.files_read", model.scannedEntries)
        }()
        return MDScanActivityCard(
            kind: .disk,
            journey: model.scanJourney,
            clock: scanAnimation,
            title: isStopping ? L10n.t("scan.stopping") : model.isScanning && !isStopped
                ? ScanProgressL10n.localize(isWaiting ? "scan.waiting" : model.scanJourney.activeID ?? "scan.stage.file_metadata")
                : L10n.t(model.scanJourney.status == .idle ? "scan.card.start" : "scan.card.rescan"),
            detail: isStopping ? nil : model.isScanning && !isStopped ? runningDetail
                : (isStopped ? (model.current != nil ? L10n.t("scan.card.saved") : nil) : L10n.t("scan.card.disk_detail")),
            compact: compact,
            activeOverride: model.isScanning && !isStopped,
            action: model.isScanning ? nil : { model.scan(model.scanScopeURL) },
            stop: model.isScanning && !isStopped ? { model.stop() } : nil,
            identifier: compact ? "diskmap.scanActivity" : "diskmap.scanPrimary"
        )
    }

    private var rootVolumeName: String {
        model.mountedVolumes.first(where: \.isRootFileSystem)?.volumeName
            ?? DiskUsageScanner.volumeOverview(for: URL(fileURLWithPath: "/"))?.volumeName
            ?? "Macintosh HD"
    }

    private var wholeDiskHeaderRow: some View {
        HStack(spacing: 10) {
            if let vol = model.volumeOverview {
                HStack(spacing: 6) {
                    if model.mountedVolumes.count > 1 {
                        Menu {
                            ForEach(model.mountedVolumes, id: \.mountPath) { item in
                                Button {
                                    model.selectScope(URL(fileURLWithPath: item.mountPath))
                                } label: {
                                    Text("\(item.volumeName) (\(DiskMapFormat.size(Double(item.usedBytes))) / \(DiskMapFormat.size(Double(item.totalBytes))))")
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "internaldrive.fill")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(MDTheme.accent)
                                Text(L10n.t(
                                    "diskmap.volume.headline",
                                    vol.volumeName,
                                    DiskMapFormat.size(Double(vol.usedBytes)),
                                    DiskMapFormat.size(Double(vol.totalBytes))
                                ))
                                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(MDTheme.label)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(MDTheme.secondary)
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help(L10n.t("diskmap.switch_volume"))
                    } else {
                        Image(systemName: "internaldrive.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(MDTheme.accent)
                        Text(L10n.t(
                            "diskmap.volume.headline",
                            vol.volumeName,
                            DiskMapFormat.size(Double(vol.usedBytes)),
                            DiskMapFormat.size(Double(vol.totalBytes))
                        ))
                        .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(MDTheme.label)
                        .lineLimit(1)
                    }

                    Text(vol.purgeableBytes >= 64 * 1_048_576
                         ? L10n.t(
                            "diskmap.volume.avail_with_purgeable",
                            DiskMapFormat.size(Double(vol.availableBytes)),
                            DiskMapFormat.size(Double(vol.purgeableBytes))
                         )
                         : L10n.t("diskmap.volume.avail_only", DiskMapFormat.size(Double(vol.availableBytes))))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(MDTheme.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            scopeSwitcher
        }
    }

    private var fullWidthVolumeBar: some View {
        Group {
            if let vol = model.volumeOverview, vol.totalBytes > 0 {
                GeometryReader { geo in
                    let width = max(0, geo.size.width)
                    let total = Double(vol.totalBytes)
                    let usedRatio = min(1, max(0, Double(vol.usedBytes) / total))
                    let usedWidth = width * usedRatio
                    let purgeWidth = width * min(max(0, 1 - usedRatio), max(0, Double(vol.purgeableBytes) / total))
                    ZStack(alignment: .leading) {
                        Capsule().fill(MDTheme.surfaceInset)
                        HStack(spacing: 0) {
                            Rectangle().fill(MDTheme.chart1).frame(width: usedWidth)
                            if purgeWidth > 1 {
                                Rectangle().fill(MDTheme.chart6.opacity(0.45)).frame(width: purgeWidth)
                            }
                        }
                        .clipShape(Capsule())
                    }
                    .overlay {
                        Capsule().strokeBorder(MDTheme.subtleBorder, lineWidth: 0.5)
                    }
                }
                .frame(height: 6)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            }
        }
    }

    private var scopeSwitcher: some View {
        HStack(spacing: 2) {
            scopePill(
                title: L10n.t("diskmap.scope.whole_disk", rootVolumeName),
                isSelected: model.scopeKind == .wholeDisk,
                identifier: "diskmap.scope.wholeDisk"
            ) {
                model.selectBuiltInScope(.wholeDisk)
            }
            scopePill(
                title: L10n.t("diskmap.scope.home"),
                isSelected: model.scopeKind == .home,
                identifier: "diskmap.scope.home"
            ) {
                model.selectBuiltInScope(.home)
            }
            scopePill(
                title: customScopeTitle,
                isSelected: model.scopeKind == .custom,
                identifier: "diskmap.scope.custom"
            ) {
                chooseFolder()
            }
            .help(model.customScopeURL?.path ?? L10n.t("diskmap.scope.custom"))
            .keyboardShortcut("o", modifiers: .command)
        }
        .padding(2.5)
        .background(MDTheme.surfaceInset, in: Capsule())
        .overlay { Capsule().strokeBorder(MDTheme.subtleBorder, lineWidth: 0.5) }
    }

    private var customScopeTitle: String {
        if model.scopeKind == .custom, let custom = model.customScopeURL {
            let leaf = custom.lastPathComponent.isEmpty ? custom.path : custom.lastPathComponent
            return L10n.t("diskmap.scope.custom_active", leaf)
        }
        return L10n.t("diskmap.scope.custom")
    }

    private func scopePill(title: String, isSelected: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? MDTheme.label : MDTheme.secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(minHeight: 23)
                .background {
                    if isSelected {
                        Capsule().fill(MDTheme.surface)
                            .overlay { Capsule().strokeBorder(MDTheme.subtleBorder, lineWidth: 0.5) }
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var fullDiskAccessBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(MDTheme.warning)
            Text(L10n.t("diskmap.fda.banner"))
                .font(.system(size: 11.5))
                .foregroundStyle(MDTheme.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(L10n.t("diskmap.fda.action")) { openFullDiskAccessSettings() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("diskmap.openFDA")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(MDTheme.surfaceInset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private func compactToolbar(_ node: DiskUsageNode) -> some View {
        let reconciled = model.presentation.unaccountedBytes > 0
        let sizeText: String = {
            if reconciled {
                return L10n.t(
                    "diskmap.summary.reconciled",
                    DiskMapFormat.size(Double(node.allocatedBytes), partial: false),
                    DiskMapFormat.size(Double(model.presentation.denominatorBytes), partial: false)
                )
            }
            return DiskMapFormat.size(Double(node.allocatedBytes), partial: node.hasTruncatedWalk)
        }()

        return HStack(spacing: 10) {
            if model.breadcrumbs.count > 1 {
                Button {
                    if model.breadcrumbs.count > 1 { model.open(model.breadcrumbs[model.breadcrumbs.count - 2]) }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11.5, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(MDTheme.surfaceInset, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(model.isScanning && !model.isBackgroundRefresh)
                .help(L10n.t("diskmap.up"))
                .accessibilityLabel(L10n.t("diskmap.up"))
                .keyboardShortcut(.upArrow, modifiers: .command)

                ScrollViewReader { scroll in
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            ForEach(model.breadcrumbs, id: \.self) { path in
                                Button { model.open(path) } label: {
                                    Text(path == "/" ? rootVolumeName : URL(fileURLWithPath: path).lastPathComponent)
                                        .font(.system(size: 12, weight: path == model.currentPath ? .semibold : .regular))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(maxWidth: 160)
                                        .foregroundStyle(path == model.currentPath ? MDTheme.label : MDTheme.secondary)
                                }
                                .buttonStyle(.plain)
                                .disabled((model.isScanning && !model.isBackgroundRefresh) || path == model.currentPath)
                                .help(path)
                                .id(path)
                                if path != model.currentPath {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(MDTheme.tertiary)
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: model.currentPath) { _, path in
                        if let path { scroll.scrollTo(path, anchor: .trailing) }
                    }
                }

                Text("· \(sizeText)")
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(MDTheme.label)
                    .lineLimit(1)
            } else {
                Text(sizeText)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(MDTheme.label)
                    .lineLimit(1)
                Text(L10n.t("diskmap.summary", model.children.count))
                    .font(.system(size: 11.5))
                    .foregroundStyle(MDTheme.secondary)
                    .lineLimit(1)
                if model.presentation.zeroCount > 0 {
                    Button(L10n.t("diskmap.zero_items", model.presentation.zeroCount)) { mode = .list }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .foregroundStyle(MDTheme.tertiary)
                }
            }

            Spacer(minLength: 6)

            Picker(L10n.t("diskmap.view"), selection: $mode) {
                Image(systemName: "square.grid.2x2.fill").tag(DisplayMode.map)
                    .accessibilityLabel(L10n.t("diskmap.map_mode"))
                Image(systemName: "list.bullet").tag(DisplayMode.list)
                    .accessibilityLabel(L10n.t("diskmap.list_mode"))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 68)
            .accessibilityIdentifier("diskmap.mode")

            if model.scanJourney.status != .stopped {
                Button { model.rescanCurrent() } label: {
                    Label(L10n.t("common.rescan"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isScanning)
                .help(L10n.t("diskmap.rescan"))
                .accessibilityLabel(L10n.t("diskmap.rescan"))
                .accessibilityIdentifier("diskmap.rescan")
            }

            Button { showsInfo.toggle() } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .frame(minWidth: 24, minHeight: 24)
            .help(L10n.t("diskmap.about"))
            .accessibilityLabel(L10n.t("diskmap.about"))
            .popover(isPresented: $showsInfo) {
                infoPopoverContent(node)
            }
        }
        .padding(.horizontal, MDTheme.pagePadding)
        .padding(.vertical, 8)
    }

    private func infoPopoverContent(_ node: DiskUsageNode) -> some View {
        let informativeIssues = node.issues.subtracting([.inProgress]).sorted { $0.rawValue < $1.rawValue }
        return VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("diskmap.about")).font(.headline)
            Text(node.path).font(.caption.monospaced()).textSelection(.enabled)
            if let vol = model.volumeOverview {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    infoMetricRow(L10n.t("diskmap.info.volume_total"), DiskMapFormat.size(Double(vol.totalBytes)))
                    infoMetricRow(L10n.t("diskmap.info.volume_used"), DiskMapFormat.size(Double(vol.usedBytes)))
                    infoMetricRow(L10n.t("diskmap.info.scanned_files"), DiskMapFormat.size(Double(node.allocatedBytes)))
                    if model.presentation.unaccountedBytes > 0 {
                        infoMetricRow(L10n.t("diskmap.unaccounted_space"), DiskMapFormat.size(Double(model.presentation.unaccountedBytes)))
                    }
                    if vol.purgeableBytes > 0 {
                        infoMetricRow(L10n.t("diskmap.info.purgeable"), DiskMapFormat.size(Double(vol.purgeableBytes)))
                    }
                    infoMetricRow(L10n.t("diskmap.info.available"), DiskMapFormat.size(Double(vol.availableBytes)))
                }
                .font(.caption)
            }
            if !informativeIssues.isEmpty {
                Divider()
                Text(informativeIssues.map { L10n.t("diskmap.issue." + $0.rawValue) }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(L10n.t("diskmap.accounting")).font(.caption).foregroundStyle(.secondary)
            if model.presentation.unaccountedBytes > 0 {
                Text(L10n.t("diskmap.unaccounted_detail")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 360)
    }

    private func infoMetricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).fontWeight(.medium).monospacedDigit()
        }
    }

    private func mapCanvas(_ node: DiskUsageNode) -> some View {
        let totalBasis = max(node.allocatedBytes, model.presentation.denominatorBytes)
        return Group {
            if model.presentation.entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.dashed").font(.largeTitle).foregroundStyle(.secondary)
                    Text(L10n.t("diskmap.no_area")).font(.headline)
                    Text(L10n.t(model.children.isEmpty ?
                        (node.isComplete ? "diskmap.no_children" : "diskmap.no_readable_children") : "diskmap.zero_explanation"))
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if !model.children.isEmpty { Button(L10n.t("diskmap.list_mode")) { mode = .list } }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DiskTreemapView(
                    entries: model.presentation.entries,
                    parentBytes: totalBasis,
                    selectedID: selectedPath,
                    hoveredID: hoveredID,
                    activate: activate,
                    hover: hover,
                    reveal: reveal,
                    quickLook: { quickLookURL = URL(fileURLWithPath: $0.path) },
                    openDirectNode: { model.open($0.path) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, MDTheme.pagePadding)
        .padding(.bottom, 12)
    }

    private func floatingHUD(_ current: DiskUsageNode) -> some View {
        let hovered = hoveredID.flatMap { model.presentation.entriesByID[$0] }
        let selectedEntry = selectedPath.flatMap { model.presentation.entriesByID[$0] }
        let activeEntry = hovered ?? selectedEntry
        let node = activeEntry?.effectiveNode ?? selectedPath.flatMap { model.snapshot?.nodes[$0] } ?? current
        let totalBasis = max(current.allocatedBytes, model.presentation.denominatorBytes)
        let swatch = activeEntry.map { DiskMapPalette.leafFill(for: $0) } ?? DiskMapPalette.color(for: node.path)
        let titleText = activeEntry?.title ?? node.name
        let sizeText = activeEntry?.sizeLabel ?? DiskMapFormat.size(Double(node.allocatedBytes), partial: node.hasTruncatedWalk)
        let percentText: String? = {
            guard let activeEntry, !activeEntry.isPartial else { return nil }
            return DiskMapFormat.percent(activeEntry.weight, total: totalBasis)
        }()
        let locationText: String = {
            if activeEntry?.isSystemUnaccounted == true {
                return L10n.t("diskmap.unaccounted_strip_hint")
            }
            if activeEntry != nil && activeEntry?.effectiveNode == nil {
                return activeEntry?.parentContext ?? node.path
            }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if node.path.hasPrefix(home + "/") {
                return "~" + node.path.dropFirst(home.count)
            }
            return node.path
        }()
        let interactive = selectedPath != nil && hovered == nil

        return HStack(spacing: 9) {
            Circle()
                .fill(swatch)
                .frame(width: 9, height: 9)
            Image(systemName: activeEntry?.symbol ?? (node.isDirectory ? "folder.fill" : "doc.fill"))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Text(titleText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(percentText.map { "\(sizeText) (\($0))" } ?? sizeText)
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
            Text("·")
                .foregroundStyle(.white.opacity(0.45))
            Text(locationText)
                .font(.system(size: 11).monospaced())
                .foregroundStyle(.white.opacity(0.76))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 360, alignment: .leading)

            if interactive {
                Button { reveal(node) } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help(L10n.t("diskmap.reveal"))

                Button { selectedPath = nil } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7.5)
        .background(
            Capsule()
                .fill(Color(red: 0.12, green: 0.14, blue: 0.17).opacity(0.92))
                .shadow(color: .black.opacity(0.24), radius: 10, x: 0, y: 4)
        )
        .overlay {
            Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75)
        }
        .allowsHitTesting(interactive)
    }

    private func fileList(_ parent: DiskUsageNode) -> some View {
        List {
            ForEach(Array(model.children.prefix(displayLimit))) { node in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3).fill(DiskMapPalette.color(for: node.path))
                        .frame(width: 7, height: 24).accessibilityHidden(true)
                    Button {
                        if node.isDirectory { model.open(node.path) } else { selectedPath = node.path }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: node.isSymbolicLink ? "link" : (node.isDirectory ? "folder" : "doc"))
                                .foregroundStyle(.secondary)
                            Text(node.name).lineLimit(1).truncationMode(.middle)
                            if node.isDirectory { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help(node.path)
                    .accessibilityLabel(node.name)
                    Text(DiskMapFormat.size(Double(node.allocatedBytes), partial: node.hasTruncatedWalk))
                        .monospacedDigit().font(.callout)
                    Button { reveal(node) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless).accessibilityLabel(L10n.t("diskmap.reveal_item", node.name))
                }
                .padding(.vertical, 3)
                .listRowBackground(selectedPath == node.path ? MDTheme.surfaceSelected : Color.clear)
                .contextMenu {
                    if node.isDirectory {
                        Button(L10n.t("diskmap.open_folder", node.name)) { model.open(node.path) }
                    } else if FileManager.default.fileExists(atPath: node.path) {
                        Button(L10n.t("context.quick_look")) {
                            quickLookURL = URL(fileURLWithPath: node.path)
                        }
                    }
                    Button(L10n.t("diskmap.reveal")) { reveal(node) }
                    Divider()
                    Button(L10n.t("common.copy_path")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(node.path, forType: .string)
                    }
                }
            }
            if model.presentation.unaccountedBytes > 0 {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.28, green: 0.31, blue: 0.36))
                        .frame(width: 7, height: 24).accessibilityHidden(true)
                    Button { showsInfo = true } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "lock.doc").foregroundStyle(.secondary)
                            Text(L10n.t("diskmap.unaccounted_space")).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Text(DiskMapFormat.size(Double(model.presentation.unaccountedBytes)))
                        .monospacedDigit().font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
            }
            if model.children.isEmpty {
                Text(L10n.t(parent.isComplete ? "diskmap.no_children" : "diskmap.no_readable_children"))
                    .foregroundStyle(.secondary)
            }
            if model.children.count > displayLimit { Button(L10n.t("diskmap.more")) { displayLimit += 100 } }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("diskmap.list")
    }

    private func activate(_ entry: DiskMapEntry) {
        hoveredID = nil
        if let target = entry.effectiveNode {
            if target.isDirectory { model.open(target.path) } else { selectedPath = target.path }
        } else if entry.isMetadata || entry.isSystemUnaccounted {
            if entry.depth > 0, entry.containerPath != model.currentPath {
                model.open(entry.containerPath)
            } else {
                showsInfo = true
            }
        } else if entry.depth > 0, entry.containerPath != model.currentPath {
            model.open(entry.containerPath)
        } else {
            mode = .list
        }
    }

    private func hover(_ id: String, _ inside: Bool) {
        if inside { hoveredID = id } else if hoveredID == id { hoveredID = nil }
    }

    private func reveal(_ node: DiskUsageNode) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.t("diskmap.choose")
        panel.directoryURL = model.scanScopeURL
        panel.begin { response in
            if response == .OK, let url = panel.url { model.selectScope(url) }
        }
    }
}
