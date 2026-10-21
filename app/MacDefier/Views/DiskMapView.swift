import AppKit
import CleanupKit
import SwiftUI

@MainActor
final class DiskMapModel: ObservableObject {
    @Published private(set) var snapshot: DiskUsageSnapshot?
    @Published private(set) var currentPath: String?
    @Published private(set) var isScanning = false
    @Published private(set) var children: [DiskUsageNode] = []
    @Published private(set) var presentation = DiskMapPresentation.empty
    @Published private(set) var scanJourney = ScanJourney()
    @Published private(set) var scannedEntries = 0
    @Published private(set) var scanScopeURL = FileManager.default.homeDirectoryForCurrentUser
    private var task: Task<Void, Never>?
    private var generation = 0
    private var requestedRoot: String?

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

    func open(_ path: String) {
        guard !isScanning, snapshot?.nodes[path]?.isDirectory == true else { return }
        currentPath = path
        updatePresentation()
    }

    private func updatePresentation() {
        guard let snapshot, let current else { children = []; presentation = .empty; return }
        children = snapshot.children(of: current.path)
        presentation = DiskMapPresentation(parent: current, children: children, snapshot: snapshot)
    }

    func selectScope(_ url: URL) {
        guard !isScanning else { return }
        task?.cancel()
        generation += 1
        task = nil
        requestedRoot = nil
        scanScopeURL = URL(fileURLWithPath: PathGate.standardizeOnly(url.path))
        snapshot = nil; currentPath = nil; children = []; presentation = .empty
        scannedEntries = 0
        scanJourney = ScanJourney()
    }

    func scan(_ url: URL) {
        task?.cancel()
        generation += 1
        let token = generation
        let rootPath = PathGate.standardizeOnly(url.path)
        requestedRoot = rootPath
        scanScopeURL = URL(fileURLWithPath: rootPath)
        snapshot = nil; currentPath = nil; children = []; presentation = .empty
        scannedEntries = 0
        scanJourney.begin(["scan.stage.file_metadata", "scan.stage.space_map"])
        isScanning = true
        task = Task {
            let result = await DiskScanCoordinator.shared.withPermit(retainingCancelledResult: true) {
                await MainActor.run {
                    guard self.generation == token else { return }
                    self.scanJourney.start("scan.stage.file_metadata")
                }
                let worker = Task.detached(priority: .utility) {
                    DiskUsageScanner.scan(root: url, onProgress: { progress in
                        Task { @MainActor in
                            guard self.generation == token, self.isScanning, self.scanJourney.status == .running else { return }
                            self.scannedEntries = progress.entries
                            self.snapshot = progress.snapshot
                            self.currentPath = progress.snapshot.rootPath
                            self.updatePresentation()
                        }
                    }, isCancelled: { Task.isCancelled })
                }
                return await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
            }
            guard generation == token else { return }
            if let result {
                scannedEntries = max(scannedEntries, result.nodes.count - 1)
                snapshot = result
                currentPath = result.rootPath
                if !Task.isCancelled {
                    scanJourney.complete("scan.stage.file_metadata", count: scannedEntries,
                                         bytes: result.root?.allocatedBytes, partial: result.root?.isComplete != true)
                    scanJourney.start("scan.stage.space_map")
                }
                updatePresentation()
            }
            if Task.isCancelled { scanJourney.stop() }
            else {
                scanJourney.complete("scan.stage.space_map", count: children.count)
                scanJourney.finish(partial: result?.root?.isComplete != true)
            }
            isScanning = false
            task = nil
        }
    }

    func resourcesChanged(_ paths: [String]) {
        let roots = [requestedRoot, snapshot?.rootPath].compactMap { $0 }
        guard let root = requestedRoot ?? snapshot?.rootPath,
              roots.contains(where: { candidate in paths.contains(where: {
                  ResourceMutationCoordinator.overlaps(candidate, PathGate.standardizeOnly($0))
              }) }) else { return }
        scan(URL(fileURLWithPath: root))
    }

    func stop() { scanJourney.stop(); task?.cancel() }
}

struct DiskMapView: View {
    @StateObject private var model = DiskMapModel()
    @StateObject private var scanAnimation = MDScanAnimationClock()
    @State private var displayLimit = 100
    @State private var mode: DisplayMode = .map
    @State private var selectedPath: String?
    @State private var hoveredID: String?
    @State private var showsInfo = false

    private enum DisplayMode: String, CaseIterable { case map, list }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MDPageBar {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.caption)
                        .foregroundStyle(MDTheme.secondary)
                    Text(model.scanScopeURL.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(MDTheme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.scanScopeURL.path)
                    Spacer(minLength: 8)
                    Button(L10n.t("diskmap.choose")) { chooseFolder() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.isScanning)
                        .accessibilityIdentifier("diskmap.choose")
                }
            }
            MDScanWorkbench(journey: model.scanJourney,
                stages: ["scan.stage.file_metadata", "scan.stage.space_map"]) {
            VStack(alignment: .leading, spacing: 0) {
            if let node = model.current {
                if model.breadcrumbs.count > 1 { breadcrumb }
                if model.isScanning || model.scanJourney.status == .stopped {
                    scanActivity(compact: true)
                        .padding(.horizontal, MDTheme.pagePadding)
                        .padding(.bottom, 10)
                }
                summary(node)
                if !node.isComplete && !model.isScanning { partialNotice(node) }
                if mode == .map {
                    map(node).disabled(model.isScanning)
                } else {
                    fileList(node).disabled(model.isScanning)
                }
                if selectedPath != nil || hoveredID != nil {
                    detailStrip(node).disabled(model.isScanning)
                }
            } else {
                emptyState
            }
            }
            }
        }
        .background(MDTheme.content)
        .onChange(of: model.currentPath) { _, _ in
            displayLimit = 100
            selectedPath = nil
            hoveredID = nil
        }
        .onChange(of: mode) { _, _ in hoveredID = nil }
        .onReceive(NotificationCenter.default.publisher(for: CleanupResourceEvents.didChange)) { note in
            model.resourcesChanged(note.userInfo?["paths"] as? [String] ?? [])
        }
        .onDisappear { model.stop() }
    }

    private var breadcrumb: some View {
        HStack(spacing: 8) {
            Button {
                if model.breadcrumbs.count > 1 { model.open(model.breadcrumbs[model.breadcrumbs.count - 2]) }
            } label: { Image(systemName: "arrow.up") }
            .buttonStyle(.borderless)
            .disabled(model.isScanning || model.breadcrumbs.count < 2)
            .help(L10n.t("diskmap.up"))
            .accessibilityLabel(L10n.t("diskmap.up"))
            .keyboardShortcut(.upArrow, modifiers: .command)
            ScrollViewReader { scroll in
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(model.breadcrumbs, id: \.self) { path in
                            Button { model.open(path) } label: {
                                Text(path == "/" ? "/" : URL(fileURLWithPath: path).lastPathComponent)
                                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 150)
                                    .foregroundStyle(path == model.currentPath ? .primary : .secondary)
                            }
                            .buttonStyle(.plain).disabled(model.isScanning || path == model.currentPath)
                            .help(path).id(path)
                            if path != model.currentPath {
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .font(.caption)
                }
                .scrollIndicators(.hidden)
                .onChange(of: model.currentPath) { _, path in if let path { scroll.scrollTo(path, anchor: .trailing) } }
            }
        }
        .padding(.horizontal, MDTheme.pagePadding).padding(.bottom, 12)
    }

    private func summary(_ node: DiskUsageNode) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(DiskMapFormat.size(Double(node.allocatedBytes), partial: !node.isComplete))
                    .font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                Text(L10n.t("diskmap.summary", model.children.count))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 2)
            Picker(L10n.t("diskmap.view"), selection: $mode) {
                Image(systemName: "square.grid.2x2.fill").tag(DisplayMode.map)
                    .accessibilityLabel(L10n.t("diskmap.map_mode"))
                Image(systemName: "list.bullet").tag(DisplayMode.list)
                    .accessibilityLabel(L10n.t("diskmap.list_mode"))
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 76)
            .accessibilityIdentifier("diskmap.mode")
            if model.scanJourney.status != .stopped || node.path != model.scanScopeURL.path {
                Button { model.scan(URL(fileURLWithPath: node.path)) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(model.isScanning)
                    .help(L10n.t("diskmap.rescan")).accessibilityLabel(L10n.t("diskmap.rescan"))
                    .accessibilityIdentifier("diskmap.rescan")
            }
            Button { showsInfo.toggle() } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless).help(L10n.t("diskmap.about"))
                .accessibilityLabel(L10n.t("diskmap.about"))
                .popover(isPresented: $showsInfo) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.t("diskmap.about")).font(.headline)
                        Text(node.path).textSelection(.enabled)
                        Text(L10n.t("diskmap.accounting")).foregroundStyle(.secondary)
                    }
                    .font(.callout).padding(20).frame(width: 340)
                }
        }
        .padding(.horizontal, MDTheme.pagePadding).padding(.bottom, 12)
    }

    private func partialNotice(_ node: DiskUsageNode) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle")
            VStack(alignment: .leading, spacing: 2) {
                Text(node.issues.sorted { $0.rawValue < $1.rawValue }
                    .map { L10n.t("diskmap.issue." + $0.rawValue) }.joined(separator: " · "))
                    .fontWeight(.medium)
            }
        }
        .font(.caption)
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(MDTheme.surfaceInset, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, MDTheme.pagePadding).padding(.bottom, 8)
    }

    private func map(_ node: DiskUsageNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.presentation.entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.dashed").font(.largeTitle).foregroundStyle(.secondary)
                    Text(L10n.t("diskmap.no_area")).font(.headline)
                    Text(L10n.t(model.children.isEmpty ?
                        (node.isComplete ? "diskmap.no_children" : "diskmap.no_readable_children") : "diskmap.zero_explanation"))
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if !model.children.isEmpty { Button(L10n.t("diskmap.list_mode")) { mode = .list } }
                }
                .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DiskTreemapView(entries: model.presentation.entries, parentBytes: node.allocatedBytes,
                                selectedID: selectedPath, hoveredID: hoveredID,
                                activate: activate, hover: hover, reveal: reveal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
            }
            HStack(spacing: 8) {
                if model.presentation.zeroCount > 0 {
                    Button(L10n.t("diskmap.zero_items", model.presentation.zeroCount)) { mode = .list }
                        .buttonStyle(.borderless)
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, MDTheme.pagePadding).padding(.bottom, 10)
    }

    private func detailStrip(_ current: DiskUsageNode) -> some View {
        let hovered = model.presentation.entries.first { $0.id == hoveredID }
        let node = hovered?.node ?? selectedPath.flatMap { model.snapshot?.nodes[$0] } ?? current
        let isAggregate = hovered != nil && hovered?.node == nil
        return HStack(spacing: 10) {
            Image(systemName: hovered?.symbol ?? (node.isDirectory ? "folder.fill" : "doc.fill"))
                .font(.title3).foregroundStyle(DiskMapPalette.color(for: node.path))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(hovered?.title ?? node.name).font(.callout.weight(.medium))
                    .lineLimit(1).truncationMode(.middle).help(isAggregate ? (hovered?.title ?? "") : node.path)
                if !isAggregate && (node.isHardLinkDuplicate || node.hardLinkBytesCountedElsewhere > 0) {
                    Text(L10n.t("diskmap.shared_link")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(hovered == nil ? L10n.t("diskmap.logical", DiskMapFormat.size(Double(node.logicalBytes), partial: !node.isComplete)) :
                            L10n.t("diskmap.of_folder", DiskMapFormat.percent(hovered!.weight, total: current.allocatedBytes)))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Text(hovered?.sizeLabel ?? DiskMapFormat.size(Double(node.allocatedBytes), partial: !node.isComplete))
                .font(.callout.weight(.semibold)).monospacedDigit().lineLimit(1)
            if hovered == nil || hovered?.node != nil {
                Button { reveal(node) } label: { Image(systemName: "magnifyingglass") }
                    .help(L10n.t("diskmap.reveal")).accessibilityLabel(L10n.t("diskmap.reveal_item", node.name))
            }
        }
        .padding(.horizontal, MDTheme.pagePadding).padding(.vertical, 12)
        .background(MDTheme.surface)
        .overlay(alignment: .top) { Divider() }
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
                    Text(DiskMapFormat.size(Double(node.allocatedBytes), partial: !node.isComplete))
                        .monospacedDigit().font(.callout)
                    Button { reveal(node) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless).accessibilityLabel(L10n.t("diskmap.reveal_item", node.name))
                }
                .padding(.vertical, 3)
                .listRowBackground(selectedPath == node.path ? MDTheme.surfaceSelected : Color.clear)
            }
            if model.children.isEmpty {
                Text(L10n.t(parent.isComplete ? "diskmap.no_children" : "diskmap.no_readable_children"))
                    .foregroundStyle(.secondary)
            }
            if model.children.count > displayLimit { Button(L10n.t("diskmap.more")) { displayLimit += 100 } }
        }
        .listStyle(.inset).accessibilityIdentifier("diskmap.list")
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            scanActivity(compact: false)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(MDTheme.pagePadding)
    }

    private func scanActivity(compact: Bool) -> some View {
        let isStopped = model.scanJourney.status == .stopped
        let isStopping = model.isScanning && isStopped
        let isWaiting = model.isScanning && model.scanJourney.status == .running && model.scanJourney.activeID == nil
        return MDScanActivityCard(
            kind: .disk,
            journey: model.scanJourney,
            clock: scanAnimation,
            title: isStopping ? L10n.t("scan.stopping") : model.isScanning && !isStopped
                ? ScanProgressL10n.localize(isWaiting ? "scan.waiting" : model.scanJourney.activeID ?? "scan.stage.file_metadata")
                : L10n.t(isStopped ? "scan.card.rescan" : "scan.card.start"),
            detail: isStopping ? nil : model.isScanning && !isStopped ? L10n.t("scan.files_read", model.scannedEntries) :
                (isStopped ? (model.current != nil ? L10n.t("scan.card.saved") : nil) : L10n.t("scan.card.disk_detail")),
            compact: compact,
            action: model.isScanning ? nil : { model.scan(model.scanScopeURL) },
            stop: model.isScanning && !isStopped ? { model.stop() } : nil,
            identifier: compact ? "diskmap.scanActivity" : "diskmap.scanPrimary"
        )
    }

    private func activate(_ entry: DiskMapEntry) {
        hoveredID = nil
        if let node = entry.node {
            if node.isDirectory { model.open(node.path) } else { selectedPath = node.path }
        } else if entry.isMetadata { showsInfo = true } else { mode = .list }
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
