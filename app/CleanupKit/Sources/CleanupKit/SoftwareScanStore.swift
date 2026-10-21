// Persist last software inventory / AI 盘点 for verification.

import Foundation

public enum SoftwareScanStore {
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

    public static var textURL: URL { dir.appendingPathComponent("last_software_scan.txt") }

    public static func save(
        apps: [InstalledApp],
        sort: SoftwareSort,
        aiNarrative: String?,
        usedAI: Bool,
        aiError: String?,
        previewActions: [SoftwareAIPreviewAction]
    ) {
        var lines: [String] = []
        lines.append("MacDefier software scan dump")
        lines.append("scannedAt: \(Date())")
        lines.append("usedAI: \(usedAI)")
        lines.append("sort: \(sort.rawValue)")
        lines.append("appCount: \(apps.count)")
        if let err = aiError, !err.isEmpty {
            lines.append("aiError: \(err)")
        }
        if let n = aiNarrative, !n.isEmpty {
            lines.append("--- aiNarrative ---")
            lines.append(n)
        }
        if !previewActions.isEmpty {
            lines.append("--- aiPreviewActions ---")
            for a in previewActions {
                lines.append("- \(a.title) path=\(a.path) bundle=\(a.bundleID ?? "-") reason=\(a.reason)")
            }
        }
        lines.append("--- topBySize ---")
        for a in apps.sorted(by: { $0.totalBytes > $1.totalBytes }).prefix(25) {
            lines.append(
                "- \(a.name) total=\(a.totalBytes) app=\(a.bytes) related=\(a.relatedBytes) system=\(a.isSystemLocation) path=\(a.path)"
            )
        }
        lines.append("--- notes ---")
        lines.append("AI inventory only; never auto-uninstall; large app != fault")
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: textURL, atomically: true, encoding: .utf8)
    }
}
