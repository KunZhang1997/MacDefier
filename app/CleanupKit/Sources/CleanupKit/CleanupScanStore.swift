// Persist last cleanup scan for agent/user verification (no screenshots).

import Foundation

public enum CleanupScanStore {
    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        #if DEBUG
        let d = base.appendingPathComponent("MacDefier-Dev", isDirectory: true)
        #else
        let d = base.appendingPathComponent("MacDefier", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    public static var textURL: URL { dir.appendingPathComponent("last_cleanup_scan.txt") }

    public static func save(
        groups: [CleanupCategoryGroup],
        selectedBytes: UInt64,
        selectedCount: Int,
        aiNarrative: String? = nil,
        usedAI: Bool = false,
        aiError: String? = nil
    ) {
        var lines: [String] = []
        lines.append("MacDefier cleanup scan dump")
        lines.append("scannedAt: \(Date())")
        lines.append("usedAI: \(usedAI)")
        let total = groups.reduce(UInt64(0)) { $0 + $1.totalBytes }
        lines.append("groups: \(groups.count)")
        lines.append("totalBytes: \(total)")
        lines.append("partial: \(groups.contains(where: \.isPartial))")
        lines.append("defaultSelectedBytes: \(selectedBytes)")
        lines.append("defaultSelectedCount: \(selectedCount)")
        if let err = aiError, !err.isEmpty {
            lines.append("aiError: \(err)")
        }
        if let n = aiNarrative, !n.isEmpty {
            lines.append("--- aiNarrative ---")
            lines.append(n)
        }
        lines.append("--- categories ---")
        for g in groups {
            let sel = g.selectedBytes
            lines.append("[\(g.category.rawValue)] \(g.category.title) items=\(g.items.count) total=\(g.totalBytes) selected=\(sel) defaultOn=\(g.category.defaultSelected)")
            for item in g.items.prefix(12) {
                lines.append("  - \(item.isSelected ? "[x]" : "[ ]") \(item.name) \(item.bytes) risk=\(item.risk.rawValue) sizeLowerBound=\(item.sizeIsLowerBound) path=\(item.path)")
            }
            if g.items.count > 12 {
                lines.append("  … +\(g.items.count - 12) more")
            }
        }
        lines.append("--- notes ---")
        lines.append("largeAppData: inventory only, never default-selected (not junk)")
        lines.append("trash default unselected; emptying trash = permanent delete")
        lines.append("AI only narrates / suggests; never deletes")
        lines.append("Hermes CLI uninstallable with strong confirm; MacDefier hard-locked only")
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: textURL, atomically: true, encoding: .utf8)
    }
}
