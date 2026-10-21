import CleanupKit
import SwiftUI

/// Cached once per navigation. Hovering never sorts the scanned filesystem again.
struct DiskMapPresentation {
    static let empty = DiskMapPresentation(entries: [], zeroCount: 0)
    let entries: [DiskMapEntry]
    let zeroCount: Int

    private init(entries: [DiskMapEntry], zeroCount: Int) {
        self.entries = entries
        self.zeroCount = zeroCount
    }

    init(parent: DiskUsageNode, children: [DiskUsageNode], snapshot: DiskUsageSnapshot) {
        let positive = children.filter { $0.allocatedBytes > 0 }
        zeroCount = children.count - positive.count
        let total = positive.reduce(0.0) { $0 + Double($1.allocatedBytes) }
        // Keep the chart readable and bounded. Small items retain their exact sum
        // in an explicit aggregate; zero/unknown values never get invented area.
        let visible = positive.prefix(48).prefix { Double($0.allocatedBytes) >= total * 0.004 }
        var result = visible.map { node -> DiskMapEntry in
            let nested = snapshot.children(of: node.path).filter { $0.allocatedBytes > 0 }
            var preview = nested.prefix(11).map { DiskTreemapItem(id: $0.path, weight: Double($0.allocatedBytes)) }
            let remainder = nested.dropFirst(11).reduce(0.0) { $0 + Double($1.allocatedBytes) }
            if remainder > 0 { preview.append(DiskTreemapItem(id: "__remainder__", weight: remainder)) }
            return DiskMapEntry(id: node.path, node: node, weight: Double(node.allocatedBytes),
                                groupedCount: 0, isMetadata: false, isPartial: !node.isComplete, preview: preview)
        }
        let remaining = positive.dropFirst(visible.count)
        if !remaining.isEmpty {
            result.append(DiskMapEntry(id: "__other__", node: nil,
                weight: remaining.reduce(0.0) { $0 + Double($1.allocatedBytes) },
                groupedCount: remaining.count, isMetadata: false, isPartial: remaining.contains { !$0.isComplete }, preview: []))
        }
        let ownBytes = max(0, Double(parent.allocatedBytes) - total)
        if ownBytes > 0 {
            result.append(DiskMapEntry(id: "__metadata__", node: nil, weight: ownBytes,
                                      groupedCount: 0, isMetadata: true, isPartial: false, preview: []))
        }
        entries = result
    }
}

struct DiskMapEntry: Identifiable {
    let id: String
    let node: DiskUsageNode?
    let weight: Double
    let groupedCount: Int
    let isMetadata: Bool
    let isPartial: Bool
    let preview: [DiskTreemapItem]

    var title: String {
        node?.name ?? L10n.t(isMetadata ? "diskmap.metadata" : "diskmap.other", groupedCount)
    }
    var symbol: String {
        if isMetadata { return "internaldrive" }
        guard let node else { return "square.grid.2x2" }
        return node.isSymbolicLink ? "link" : (node.isDirectory ? "folder.fill" : "doc.fill")
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
    // Opaque fills keep white labels legible in both appearances and when
    // Reduce Transparency is enabled. Color identifies a tile, never risk.
    private static let colors: [Color] = [
        Color(red: 0.22, green: 0.36, blue: 0.68),
        Color(red: 0.19, green: 0.40, blue: 0.58),
        Color(red: 0.32, green: 0.41, blue: 0.55),
        Color(red: 0.22, green: 0.43, blue: 0.61),
        Color(red: 0.27, green: 0.36, blue: 0.49),
        Color(red: 0.24, green: 0.39, blue: 0.64),
        Color(red: 0.34, green: 0.43, blue: 0.51)
    ]
    static func color(for id: String) -> Color {
        // Swift's randomized Hasher would change the palette on every launch.
        let hash = id.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        return colors[Int(hash % UInt64(colors.count))]
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
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { proxy in
            let tiles = DiskTreemapLayout.layout(entries.map { DiskTreemapItem(id: $0.id, weight: $0.weight) },
                                                in: CGRect(origin: .zero, size: proxy.size))
            let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            ZStack(alignment: .topLeading) {
                ForEach(tiles) { tile in
                    if let entry = byID[tile.id] {
                        tileButton(entry, frame: tile.frame)
                            .frame(width: max(0, tile.frame.width - 3), height: max(0, tile.frame.height - 3))
                            .position(x: tile.frame.midX, y: tile.frame.midY)
                    }
                }
            }
        }
        .accessibilityIdentifier("diskmap.treemap")
    }

    private func tileButton(_ entry: DiskMapEntry, frame: CGRect) -> some View {
        let large = frame.width >= 115 && frame.height >= 80
        let medium = frame.width >= 70 && frame.height >= 42
        let emphasized = hoveredID == entry.id || selectedID == entry.id
        return Button { activate(entry) } label: {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(entry.node == nil ? Color(red: 0.36, green: 0.40, blue: 0.48) : DiskMapPalette.color(for: entry.id))
                if large && frame.height > 145 && entry.preview.count > 1 {
                    nestedPreview(entry, in: CGSize(width: max(0, frame.width - 23), height: max(0, frame.height - 77)))
                        .padding(.horizontal, 10).padding(.top, 66).padding(.bottom, 10)
                        .accessibilityHidden(true)
                }
                if medium {
                    VStack(alignment: .leading, spacing: large ? 5 : 2) {
                        HStack(alignment: .top, spacing: 5) {
                            if large { Image(systemName: entry.symbol).imageScale(.small) }
                            Text(entry.title).font(large ? .callout.weight(.semibold) : .caption.weight(.medium))
                                .lineLimit(large ? 2 : 1).truncationMode(.middle)
                            if large && entry.node?.isDirectory == true {
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                            }
                        }
                        if large || frame.height > 55 {
                            Text(entry.sizeLabel).font(large ? .callout : .caption2).monospacedDigit()
                        }
                        if large && frame.height > 110 && entry.preview.count < 2 {
                            Spacer(minLength: 4)
                            Text(DiskMapFormat.percent(entry.weight, total: parentBytes))
                                .font(.title2.weight(.medium)).monospacedDigit()
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(large ? 11 : 6)
                }
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(emphasized ? Color.white : Color.white.opacity(contrast == .increased ? 0.8 : 0.12),
                                  lineWidth: emphasized ? 2.5 : 1)
            }
            .clipped()
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(DiskTileButtonStyle())
        .onHover { hover(entry.id, $0) }
        .help(entry.title + "\n" + entry.sizeLabel + " · " + DiskMapFormat.percent(entry.weight, total: parentBytes))
        .accessibilityLabel(entry.title)
        .accessibilityValue(entry.sizeLabel + ", " + DiskMapFormat.percent(entry.weight, total: parentBytes))
        .accessibilityHint(L10n.t(entry.isMetadata ? "diskmap.about" : (entry.node == nil ? "diskmap.list_mode" : (entry.node?.isDirectory == true ? "diskmap.hint.folder" : "diskmap.hint.item"))))
        .contextMenu {
            if let node = entry.node {
                if node.isDirectory { Button(L10n.t("diskmap.open_folder", node.name)) { activate(entry) } }
                Button(L10n.t("diskmap.reveal")) { reveal(node) }
            } else if !entry.isMetadata {
                Button(L10n.t("diskmap.list_mode")) { activate(entry) }
            }
        }
    }

    private func nestedPreview(_ entry: DiskMapEntry, in size: CGSize) -> some View {
        let tiles = DiskTreemapLayout.layout(entry.preview, in: CGRect(origin: .zero, size: size))
        return Canvas { context, _ in
            for (index, tile) in tiles.enumerated() {
                let rect = tile.frame.insetBy(dx: 1, dy: 1)
                guard rect.width > 0, rect.height > 0 else { continue }
                let path = Path(roundedRect: rect, cornerRadius: 3)
                context.fill(path, with: .color(.white.opacity(index.isMultiple(of: 2) ? 0.13 : 0.23)))
                context.stroke(path, with: .color(.white.opacity(0.24)), lineWidth: 0.5)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct DiskTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.82 : 1)
    }
}
