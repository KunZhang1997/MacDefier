import CleanupKit
import SwiftUI

/// Cached once per navigation. Hovering and window resizing never re-sort the scanned filesystem.
struct DiskMapPresentation {
    static let empty = DiskMapPresentation(
        entries: [],
        entriesByID: [:],
        zeroCount: 0,
        denominatorBytes: 0,
        unaccountedBytes: 0
    )

    private static let maxVisualNestingDepth = 3

    private static let atomicPackageExtensions: Set<String> = [
        "app", "framework", "bundle", "plugin", "kext", "systemextension", "appex",
        "dsym", "xcodeproj", "xcworkspace", "playground", "photoslibrary", "tvlibrary",
        "musiclibrary", "key", "pages", "numbers", "rtfd", "savedstate", "qlgenerator",
        "mdimporter", "prefpane", "saver", "wdgt", "xpc"
    ]

    private static let atomicDirectoryNames: Set<String> = [
        ".git", "node_modules"
    ]

    let entries: [DiskMapEntry]
    let entriesByID: [String: DiskMapEntry]
    let zeroCount: Int
    let denominatorBytes: UInt64
    let unaccountedBytes: UInt64

    private init(
        entries: [DiskMapEntry],
        entriesByID: [String: DiskMapEntry],
        zeroCount: Int,
        denominatorBytes: UInt64,
        unaccountedBytes: UInt64
    ) {
        self.entries = entries
        self.entriesByID = entriesByID
        self.zeroCount = zeroCount
        self.denominatorBytes = denominatorBytes
        self.unaccountedBytes = unaccountedBytes
    }

    init(parent: DiskUsageNode, children: [DiskUsageNode], snapshot: DiskUsageSnapshot, unaccountedVolumeBytes: UInt64 = 0) {
        let positive = children.filter { $0.allocatedBytes > 0 }
        zeroCount = children.count - positive.count

        var lookup: [String: DiskMapEntry] = [:]
        var nextHueCounter = 0
        var built = Self.buildContainerEntries(
            containerID: parent.path,
            containerPath: parent.path,
            outerAllocatedBytes: parent.allocatedBytes,
            hasOmittedSmall: parent.hasOmittedSmallChildren,
            positiveCandidates: positive,
            snapshot: snapshot,
            unaccountedVolumeBytes: unaccountedVolumeBytes,
            depth: 0,
            inheritedHue: nil,
            assignDistinctChildHues: true,
            hueCounter: &nextHueCounter,
            parentContext: nil,
            lookup: &lookup
        )

        if unaccountedVolumeBytes > 0 {
            let sysEntry = DiskMapEntry(
                id: "__system_unaccounted__",
                node: nil,
                collapsedTargetNode: nil,
                containerPath: parent.path,
                displayTitle: nil,
                parentContext: nil,
                weight: Double(unaccountedVolumeBytes),
                groupedCount: 0,
                isMetadata: false,
                isSystemUnaccounted: true,
                usesSmallFilesTitle: false,
                isPartial: false,
                hueIndex: DiskMapPalette.neutralHueIndex,
                usesNeutralWrapperFrame: false,
                depth: 0,
                preview: [],
                childrenEntries: []
            )
            built.append(sysEntry)
            lookup[sysEntry.id] = sysEntry
        }

        entries = built
        entriesByID = lookup
        unaccountedBytes = unaccountedVolumeBytes
        denominatorBytes = parent.allocatedBytes &+ unaccountedVolumeBytes
    }

    static func isAtomicOverviewDirectory(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        if atomicDirectoryNames.contains(name) { return true }
        let ext = url.pathExtension.lowercased()
        return !ext.isEmpty && atomicPackageExtensions.contains(ext)
    }

    private struct CollapsedChain {
        let targetNode: DiskUsageNode?
        let displayTitle: String?
        let effectivePath: String
        let effectiveHasOmittedSmall: Bool
        let positiveChildren: [DiskUsageNode]
    }

    /// Collapses single-dominant-child wrapper chains (such as `/Users` -> `/Users/<you>`
    /// or `/private` -> `/private/var`) up to 2 hops while preserving minor sibling bytes.
    private static func resolveContainerChain(for outerNode: DiskUsageNode, snapshot: DiskUsageSnapshot) -> CollapsedChain {
        let initialChildren = snapshot.children(of: outerNode.path).filter { $0.allocatedBytes > 0 }
        guard !initialChildren.isEmpty, !isAtomicOverviewDirectory(outerNode.path) else {
            return CollapsedChain(
                targetNode: nil,
                displayTitle: nil,
                effectivePath: outerNode.path,
                effectiveHasOmittedSmall: outerNode.hasOmittedSmallChildren,
                positiveChildren: initialChildren
            )
        }

        var current = outerNode
        var currentChildren = initialChildren
        var chainNames = [outerNode.name]
        var carriedMinorSiblings: [DiskUsageNode] = []
        var collapsedTarget: DiskUsageNode?

        for _ in 0..<2 {
            guard let dominant = currentChildren.first,
                  dominant.isDirectory,
                  !dominant.isSymbolicLink,
                  !isAtomicOverviewDirectory(dominant.path),
                  current.allocatedBytes > 0,
                  Double(dominant.allocatedBytes) >= Double(current.allocatedBytes) * 0.95 else {
                break
            }
            let nextChildren = snapshot.children(of: dominant.path).filter { $0.allocatedBytes > 0 }
            guard !nextChildren.isEmpty else { break }

            carriedMinorSiblings.append(contentsOf: currentChildren.dropFirst())
            chainNames.append(dominant.name)
            current = dominant
            currentChildren = nextChildren
            collapsedTarget = dominant
        }

        guard let collapsedTarget else {
            return CollapsedChain(
                targetNode: nil,
                displayTitle: nil,
                effectivePath: outerNode.path,
                effectiveHasOmittedSmall: outerNode.hasOmittedSmallChildren,
                positiveChildren: initialChildren
            )
        }

        var merged = currentChildren + carriedMinorSiblings
        merged.sort {
            if $0.allocatedBytes != $1.allocatedBytes { return $0.allocatedBytes > $1.allocatedBytes }
            return $0.path < $1.path
        }
        return CollapsedChain(
            targetNode: collapsedTarget,
            displayTitle: chainNames.joined(separator: " / "),
            effectivePath: collapsedTarget.path,
            effectiveHasOmittedSmall: outerNode.hasOmittedSmallChildren || collapsedTarget.hasOmittedSmallChildren,
            positiveChildren: merged
        )
    }

    private static func buildContainerEntries(
        containerID: String,
        containerPath: String,
        outerAllocatedBytes: UInt64,
        hasOmittedSmall: Bool,
        positiveCandidates: [DiskUsageNode],
        snapshot: DiskUsageSnapshot,
        unaccountedVolumeBytes: UInt64,
        depth: Int,
        inheritedHue: Int?,
        assignDistinctChildHues: Bool,
        hueCounter: inout Int,
        parentContext: String?,
        lookup: inout [String: DiskMapEntry]
    ) -> [DiskMapEntry] {
        let total: Double = positiveCandidates.reduce(into: 0.0) { $0 += Double($1.allocatedBytes) }
        let basis = max(total, Double(outerAllocatedBytes)) + Double(unaccountedVolumeBytes)

        let maxVisible: Int
        let minFraction: Double
        switch depth {
        case 0:
            maxVisible = 56
            minFraction = 0.0022
        case 1:
            maxVisible = 32
            minFraction = 0.0045
        case 2:
            maxVisible = 20
            minFraction = 0.009
        default:
            maxVisible = 14
            minFraction = 0.016
        }

        let visible = positiveCandidates.prefix(maxVisible).prefix { Double($0.allocatedBytes) >= basis * minFraction }
        var result: [DiskMapEntry] = []
        result.reserveCapacity(visible.count + 2)

        for node in visible {
            let canNest = depth < maxVisualNestingDepth && node.isDirectory && !node.isSymbolicLink && !isAtomicOverviewDirectory(node.path)
            let isDominantRootWrapper = depth == 0 && basis > 0 && (Double(node.allocatedBytes) / basis >= 0.36)

            let hue: Int
            if let inheritedHue, !assignDistinctChildHues {
                hue = inheritedHue
            } else {
                hue = hueCounter % DiskMapPalette.chromaticHueCount
                hueCounter += 1
            }

            var collapsedTarget: DiskUsageNode?
            var customTitle: String?
            var nestedEntries: [DiskMapEntry] = []
            var preview: [DiskTreemapItem] = []

            if canNest {
                let chain = resolveContainerChain(for: node, snapshot: snapshot)
                collapsedTarget = chain.targetNode
                customTitle = chain.displayTitle
                let labelForChildren: String = {
                    let ownTitle = customTitle ?? node.name
                    if let parentContext { return "\(parentContext) › \(ownTitle)" }
                    return ownTitle
                }()
                if !chain.positiveChildren.isEmpty {
                    // Major root wrappers (like `Users / <you>` taking >36% of the disk) give each of their
                    // top territories (`Library`, `Desktop`, `Downloads`, `.cache`, `.ollama`) its own distinct hue
                    // so the screen never turns into a monotone single-color wall.
                    let diversifyChildren = isDominantRootWrapper || collapsedTarget != nil && depth == 0
                    nestedEntries = buildContainerEntries(
                        containerID: node.path,
                        containerPath: chain.effectivePath,
                        outerAllocatedBytes: node.allocatedBytes,
                        hasOmittedSmall: chain.effectiveHasOmittedSmall,
                        positiveCandidates: chain.positiveChildren,
                        snapshot: snapshot,
                        unaccountedVolumeBytes: 0,
                        depth: depth + 1,
                        inheritedHue: hue,
                        assignDistinctChildHues: diversifyChildren,
                        hueCounter: &hueCounter,
                        parentContext: labelForChildren,
                        lookup: &lookup
                    )
                }
            }

            if nestedEntries.isEmpty, node.isDirectory {
                let leafNested = snapshot.children(of: node.path).filter { $0.allocatedBytes > 0 }
                preview = leafNested.prefix(11).map { DiskTreemapItem(id: $0.path, weight: Double($0.allocatedBytes)) }
                let remainder: Double = leafNested.dropFirst(11).reduce(into: 0.0) { $0 += Double($1.allocatedBytes) }
                if remainder > 0 { preview.append(DiskTreemapItem(id: "__remainder__", weight: remainder)) }
            }

            let neutralFrame = depth == 0 && !nestedEntries.isEmpty && (isDominantRootWrapper || collapsedTarget != nil)
            let entry = DiskMapEntry(
                id: node.path,
                node: node,
                collapsedTargetNode: collapsedTarget,
                containerPath: containerPath,
                displayTitle: customTitle,
                parentContext: parentContext,
                weight: Double(node.allocatedBytes),
                groupedCount: 0,
                isMetadata: false,
                isSystemUnaccounted: false,
                usesSmallFilesTitle: false,
                isPartial: node.hasTruncatedWalk,
                hueIndex: hue,
                usesNeutralWrapperFrame: neutralFrame,
                depth: depth,
                preview: preview,
                childrenEntries: nestedEntries
            )
            result.append(entry)
            lookup[entry.id] = entry
        }

        let remaining = positiveCandidates.dropFirst(visible.count)
        let ownBytes = max(0, Double(outerAllocatedBytes) - total)
        let aggregateHue = assignDistinctChildHues ? DiskMapPalette.neutralHueIndex : (inheritedHue ?? DiskMapPalette.neutralHueIndex)
        let foldTinyMetadataIntoOther = depth > 0 && !remaining.isEmpty && ownBytes > 0 && ownBytes < basis * 0.005

        if !remaining.isEmpty {
            let remainingSum: Double = remaining.reduce(into: 0.0) { $0 += Double($1.allocatedBytes) }
            let otherID = depth == 0 ? "__other__" : "\(containerID)/#other"
            let otherEntry = DiskMapEntry(
                id: otherID,
                node: nil,
                collapsedTargetNode: nil,
                containerPath: containerPath,
                displayTitle: nil,
                parentContext: parentContext,
                weight: remainingSum + (foldTinyMetadataIntoOther ? ownBytes : 0),
                groupedCount: remaining.count,
                isMetadata: false,
                isSystemUnaccounted: false,
                usesSmallFilesTitle: false,
                isPartial: remaining.contains { $0.hasTruncatedWalk },
                hueIndex: aggregateHue,
                usesNeutralWrapperFrame: false,
                depth: depth,
                preview: [],
                childrenEntries: []
            )
            result.append(otherEntry)
            lookup[otherEntry.id] = otherEntry
        }

        if ownBytes > 0 && !foldTinyMetadataIntoOther && (depth == 0 || ownBytes >= basis * 0.004 || result.isEmpty) {
            let metaID = depth == 0 ? "__metadata__" : "\(containerID)/#metadata"
            let metaEntry = DiskMapEntry(
                id: metaID,
                node: nil,
                collapsedTargetNode: nil,
                containerPath: containerPath,
                displayTitle: nil,
                parentContext: parentContext,
                weight: ownBytes,
                groupedCount: 0,
                isMetadata: true,
                isSystemUnaccounted: false,
                usesSmallFilesTitle: hasOmittedSmall,
                isPartial: false,
                hueIndex: aggregateHue,
                usesNeutralWrapperFrame: false,
                depth: depth,
                preview: [],
                childrenEntries: []
            )
            result.append(metaEntry)
            lookup[metaEntry.id] = metaEntry
        }

        return result
    }
}

struct DiskMapEntry: Identifiable {
    let id: String
    let node: DiskUsageNode?
    let collapsedTargetNode: DiskUsageNode?
    let containerPath: String
    let displayTitle: String?
    let parentContext: String?
    let weight: Double
    let groupedCount: Int
    let isMetadata: Bool
    let isSystemUnaccounted: Bool
    let usesSmallFilesTitle: Bool
    let isPartial: Bool
    let hueIndex: Int
    let usesNeutralWrapperFrame: Bool
    let depth: Int
    let preview: [DiskTreemapItem]
    let childrenEntries: [DiskMapEntry]

    var effectiveNode: DiskUsageNode? { collapsedTargetNode ?? node }

    var title: String {
        if let displayTitle { return displayTitle }
        if let node { return node.name }
        if isSystemUnaccounted { return L10n.t("diskmap.unaccounted_space") }
        if isMetadata {
            return L10n.t(usesSmallFilesTitle ? "diskmap.small_files_aggregate" : "diskmap.metadata")
        }
        return L10n.t("diskmap.other", groupedCount)
    }

    var symbol: String {
        if isSystemUnaccounted { return "lock.doc" }
        if isMetadata { return usesSmallFilesTitle ? "doc.on.doc" : "internaldrive" }
        guard let target = effectiveNode else { return "square.grid.2x2" }
        if target.isSymbolicLink { return "link" }
        if target.isDirectory {
            if URL(fileURLWithPath: target.path).pathExtension.lowercased() == "app" {
                return "app.fill"
            }
            return "folder.fill"
        }
        return "doc.fill"
    }

    var sizeLabel: String { DiskMapFormat.size(weight, partial: isPartial) }
}

enum DiskMapFormat {
    static func size(_ bytes: Double, partial: Bool = false) -> String {
        let value = !bytes.isFinite || bytes >= Double(Int64.max) ? Int64.max : Int64(max(0, bytes))
        let size = ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
        return partial ? L10n.t("diskmap.read_size", size) : size
    }

    static func percent(_ bytes: Double, total: UInt64) -> String {
        guard total > 0 else { return "—" }
        let ratio = min(1, max(0, bytes / Double(total)))
        return ratio.formatted(.percent.precision(.fractionLength(ratio < 0.01 ? 1 : 0)))
    }
}

enum DiskMapPalette {
    static let chromaticHueCount = 9
    static let neutralHueIndex = 9

    private struct HueFamily {
        let outerContainer: (Double, Double, Double)
        let innerContainer: (Double, Double, Double)
        let leafBase: (Double, Double, Double)
    }

    // Balanced multi-hue editorial palette (Teal, Sage, Ochre-Sand, Dusty Plum,
    // Twilight Indigo, Cypress, Clay, Fjord, Pewter). Avoids monotone blue walls
    // and avoids red/yellow alarmist scareware while keeping >= 4.7:1 white text contrast.
    private static let families: [HueFamily] = [
        // 0: Nordic Teal
        HueFamily(outerContainer: (0.14, 0.28, 0.31), innerContainer: (0.17, 0.34, 0.37), leafBase: (0.20, 0.43, 0.47)),
        // 1: Botanical Sage
        HueFamily(outerContainer: (0.19, 0.29, 0.24), innerContainer: (0.23, 0.35, 0.29), leafBase: (0.28, 0.43, 0.36)),
        // 2: Warm Sand-Bronze
        HueFamily(outerContainer: (0.31, 0.25, 0.18), innerContainer: (0.37, 0.30, 0.22), leafBase: (0.47, 0.38, 0.28)),
        // 3: Dusty Mineral Plum
        HueFamily(outerContainer: (0.27, 0.20, 0.29), innerContainer: (0.33, 0.25, 0.35), leafBase: (0.41, 0.31, 0.44)),
        // 4: Twilight Indigo-Slate
        HueFamily(outerContainer: (0.20, 0.23, 0.34), innerContainer: (0.24, 0.28, 0.41), leafBase: (0.30, 0.35, 0.50)),
        // 5: Cypress Olive
        HueFamily(outerContainer: (0.22, 0.28, 0.19), innerContainer: (0.27, 0.34, 0.24), leafBase: (0.34, 0.42, 0.30)),
        // 6: Warm Terracotta-Taupe
        HueFamily(outerContainer: (0.31, 0.22, 0.20), innerContainer: (0.37, 0.27, 0.25), leafBase: (0.46, 0.34, 0.31)),
        // 7: Fjord Steel
        HueFamily(outerContainer: (0.16, 0.25, 0.32), innerContainer: (0.20, 0.31, 0.39), leafBase: (0.25, 0.39, 0.48)),
        // 8: Architectural Pewter
        HueFamily(outerContainer: (0.21, 0.25, 0.29), innerContainer: (0.25, 0.30, 0.35), leafBase: (0.31, 0.37, 0.43)),
        // 9: Neutral Graphite (aggregates & unaccounted system space)
        HueFamily(outerContainer: (0.19, 0.21, 0.24), innerContainer: (0.23, 0.25, 0.29), leafBase: (0.29, 0.32, 0.37))
    ]

    private static let neutralWrapperRGB = (0.17, 0.19, 0.22)

    private static func stableHash(_ id: String) -> UInt64 {
        id.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
    }

    static func color(for id: String) -> Color {
        let hash = stableHash(id)
        let rgb = families[Int(hash % UInt64(chromaticHueCount))].leafBase
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    static func containerFill(for entry: DiskMapEntry) -> Color {
        if entry.usesNeutralWrapperFrame {
            return Color(red: neutralWrapperRGB.0, green: neutralWrapperRGB.1, blue: neutralWrapperRGB.2)
        }
        let family = families[min(max(0, entry.hueIndex), families.count - 1)]
        let rgb = entry.depth == 0 ? family.outerContainer : family.innerContainer
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    static func leafFill(for entry: DiskMapEntry) -> Color {
        if entry.isSystemUnaccounted {
            return Color(red: 0.28, green: 0.31, blue: 0.36)
        }
        if entry.node == nil {
            let family = families[min(max(0, entry.hueIndex), families.count - 1)]
            let base = family.leafBase
            return Color(red: base.0 * 0.86, green: base.1 * 0.86, blue: base.2 * 0.88)
        }
        let family = families[min(max(0, entry.hueIndex), families.count - 1)]
        let hash = stableHash(entry.id)
        let step = Double(Int(hash % 5) - 2) * 0.026
        let r = min(0.72, max(0.11, family.leafBase.0 + step))
        let g = min(0.72, max(0.12, family.leafBase.1 + step))
        let b = min(0.76, max(0.14, family.leafBase.2 + step))
        return Color(red: r, green: g, blue: b)
    }
}

struct DiskTreemapView: View {
    let entries: [DiskMapEntry]
    let parentBytes: UInt64
    let selectedID: String?
    let hoveredID: String?
    let activate: (DiskMapEntry) -> Void
    let hover: (String, Bool) -> Void
    let reveal: (DiskUsageNode) -> Void
    var quickLook: ((DiskUsageNode) -> Void)? = nil
    var openDirectNode: ((DiskUsageNode) -> Void)? = nil
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { proxy in
            renderEntries(entries, in: CGRect(origin: .zero, size: proxy.size))
        }
        .accessibilityIdentifier("diskmap.treemap")
    }

    private func renderEntries(_ items: [DiskMapEntry], in rect: CGRect) -> some View {
        let tiles = DiskTreemapLayout.layout(
            items.map { DiskTreemapItem(id: $0.id, weight: $0.weight) },
            in: rect
        )
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return ZStack(alignment: .topLeading) {
            ForEach(tiles) { tile in
                if let entry = byID[tile.id] {
                    entryRegion(entry, frame: tile.frame)
                }
            }
        }
    }

    @ViewBuilder
    private func entryRegion(_ entry: DiskMapEntry, frame: CGRect) -> some View {
        let gap: CGFloat = entry.depth == 0 ? 3.0 : (entry.depth == 1 ? 2.4 : 2.0)
        let usableWidth = max(0, frame.width - gap)
        let usableHeight = max(0, frame.height - gap)
        let canSubdivide: Bool = {
            guard !entry.childrenEntries.isEmpty else { return false }
            switch entry.depth {
            case 0: return usableWidth >= 116 && usableHeight >= 80
            case 1: return usableWidth >= 138 && usableHeight >= 90
            case 2: return usableWidth >= 164 && usableHeight >= 102
            default: return false
            }
        }()

        if canSubdivide {
            groupContainer(entry, usableWidth: usableWidth, usableHeight: usableHeight)
                .frame(width: usableWidth, height: usableHeight)
                .position(x: frame.midX, y: frame.midY)
        } else {
            leafTileButton(entry, usableWidth: usableWidth, usableHeight: usableHeight)
                .frame(width: usableWidth, height: usableHeight)
                .position(x: frame.midX, y: frame.midY)
        }
    }

    private func groupContainer(_ entry: DiskMapEntry, usableWidth: CGFloat, usableHeight: CGFloat) -> some View {
        let headerHeight: CGFloat = entry.depth == 0 ? 23 : (entry.depth == 1 ? 19.5 : 18)
        let pad: CGFloat = entry.depth == 0 ? 3.5 : (entry.depth == 1 ? 2.5 : 2.0)
        let radius: CGFloat = entry.depth == 0 ? 8 : (entry.depth == 1 ? 6 : 5)
        let emphasized = hoveredID == entry.id || selectedID == entry.id
        let childCanvasSize = CGSize(
            width: max(0, usableWidth - pad * 2),
            height: max(0, usableHeight - headerHeight - pad)
        )

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(DiskMapPalette.containerFill(for: entry))

            Button { activate(entry) } label: {
                HStack(spacing: 4.5) {
                    Image(systemName: entry.symbol)
                        .font(.system(size: entry.depth == 0 ? 10 : 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.84))
                    Text(entry.title)
                        .font(.system(size: entry.depth == 0 ? 11.5 : 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if usableWidth >= 136 {
                        Text(headerMetricLabel(for: entry, width: usableWidth))
                            .font(.system(size: entry.depth == 0 ? 10.5 : 9.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.86))
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.68))
                }
                .padding(.horizontal, entry.depth == 0 ? 7.5 : 5.5)
                .frame(width: usableWidth, height: headerHeight, alignment: .leading)
                .background(emphasized ? Color.white.opacity(0.12) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(DiskTileButtonStyle())
            .onHover { hover(entry.id, $0) }
            .help(tooltipText(for: entry))
            .accessibilityLabel(entry.title)
            .accessibilityValue(entry.sizeLabel)
            .contextMenu { entryContextMenu(entry) }

            if childCanvasSize.width > 4, childCanvasSize.height > 4 {
                AnyView(renderEntries(entry.childrenEntries, in: CGRect(origin: .zero, size: childCanvasSize)))
                    .frame(width: childCanvasSize.width, height: childCanvasSize.height)
                    .offset(x: pad, y: headerHeight)
            }

            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    emphasized ? Color.white : Color.white.opacity(contrast == .increased ? 0.8 : (entry.depth == 0 ? 0.20 : 0.14)),
                    lineWidth: emphasized ? 2.0 : 0.9
                )
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private func headerMetricLabel(for entry: DiskMapEntry, width: CGFloat) -> String {
        if entry.depth == 0, !entry.isPartial, width >= 220 {
            return "\(entry.sizeLabel) · \(DiskMapFormat.percent(entry.weight, total: parentBytes))"
        }
        return entry.sizeLabel
    }

    private func leafTileButton(_ entry: DiskMapEntry, usableWidth: CGFloat, usableHeight: CGFloat) -> some View {
        let large = usableWidth >= 102 && usableHeight >= 70
        let medium = usableWidth >= 52 && usableHeight >= 34
        let compact = usableWidth >= 32 && usableHeight >= 18
        let radius: CGFloat = entry.depth == 0 ? 7 : 4.5
        let emphasized = hoveredID == entry.id || selectedID == entry.id
        let tileColor = DiskMapPalette.leafFill(for: entry)

        return Button { activate(entry) } label: {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(tileColor)

                if large && usableHeight > 136 && entry.preview.count > 1 {
                    nestedPreview(entry, in: CGSize(width: max(0, usableWidth - 18), height: max(0, usableHeight - 68)))
                        .padding(.horizontal, 8).padding(.top, 58).padding(.bottom, 8)
                        .accessibilityHidden(true)
                }

                if medium {
                    VStack(alignment: .leading, spacing: large ? 3.5 : 1.5) {
                        HStack(alignment: .top, spacing: 4) {
                            if large {
                                Image(systemName: entry.symbol)
                                    .font(.system(size: 10.5, weight: .semibold))
                            }
                            Text(entry.title)
                                .font(.system(size: large ? 12 : 10.5, weight: large ? .semibold : .medium))
                                .lineLimit(large ? 2 : 1)
                                .truncationMode(.middle)
                            if large && entry.effectiveNode?.isDirectory == true {
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.bold))
                            }
                        }
                        Text(entry.sizeLabel)
                            .font(.system(size: large ? 11 : 9.5).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.90))
                            .lineLimit(1)
                        if large && usableHeight > 104 && entry.preview.count < 2 && !entry.isPartial && entry.depth == 0 {
                            Spacer(minLength: 2)
                            Text(DiskMapFormat.percent(entry.weight, total: parentBytes))
                                .font(.title3.weight(.semibold).monospacedDigit())
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(large ? 8.5 : 4.5)
                } else if compact {
                    Text(entry.title)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 3.5)
                        .padding(.vertical, 2)
                }

                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        emphasized ? Color.white : Color.white.opacity(contrast == .increased ? 0.8 : 0.13),
                        lineWidth: emphasized ? 2.0 : 0.75
                    )
            }
            .clipped()
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(DiskTileButtonStyle())
        .onHover { hover(entry.id, $0) }
        .help(tooltipText(for: entry))
        .accessibilityLabel(entry.title)
        .accessibilityValue(entry.sizeLabel + (entry.isPartial ? "" : ", " + DiskMapFormat.percent(entry.weight, total: parentBytes)))
        .accessibilityHint(L10n.t((entry.isMetadata || entry.isSystemUnaccounted) ? "diskmap.about" : (entry.effectiveNode == nil ? "diskmap.list_mode" : (entry.effectiveNode?.isDirectory == true ? "diskmap.hint.folder" : "diskmap.hint.item"))))
        .contextMenu { entryContextMenu(entry) }
    }

    private func tooltipText(for entry: DiskMapEntry) -> String {
        if entry.isPartial {
            if let path = entry.effectiveNode?.path {
                return "\(entry.title)\n\(path)"
            }
            return entry.title
        }
        var lines = [entry.title]
        if let path = entry.effectiveNode?.path, path != entry.title {
            lines.append(path)
        }
        lines.append("\(entry.sizeLabel) · \(DiskMapFormat.percent(entry.weight, total: parentBytes))")
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func entryContextMenu(_ entry: DiskMapEntry) -> some View {
        if let target = entry.effectiveNode {
            if target.isDirectory {
                Button(L10n.t("diskmap.open_folder", target.name)) { activate(entry) }
                if let outer = entry.node, entry.collapsedTargetNode != nil, outer.path != target.path, let openDirectNode {
                    Button(L10n.t("diskmap.open_parent_folder", outer.name)) { openDirectNode(outer) }
                }
            }
            if let quickLook, !target.isDirectory, FileManager.default.fileExists(atPath: target.path) {
                Button(L10n.t("context.quick_look")) { quickLook(target) }
            }
            Button(L10n.t("diskmap.reveal")) { reveal(target) }
            Divider()
            Button(L10n.t("common.copy_path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(target.path, forType: .string)
            }
        } else if entry.isMetadata || entry.isSystemUnaccounted {
            Button(L10n.t("diskmap.about")) { activate(entry) }
        } else {
            Button(L10n.t("diskmap.list_mode")) { activate(entry) }
        }
    }

    private func nestedPreview(_ entry: DiskMapEntry, in size: CGSize) -> some View {
        let tiles = DiskTreemapLayout.layout(entry.preview, in: CGRect(origin: .zero, size: size))
        return Canvas { context, _ in
            for (index, tile) in tiles.enumerated() {
                let rect = tile.frame.insetBy(dx: 1, dy: 1)
                guard rect.width > 0, rect.height > 0 else { continue }
                let path = Path(roundedRect: rect, cornerRadius: 3)
                context.fill(path, with: .color(.white.opacity(index.isMultiple(of: 2) ? 0.12 : 0.20)))
                context.stroke(path, with: .color(.white.opacity(0.22)), lineWidth: 0.5)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct DiskTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.84 : 1)
    }
}
