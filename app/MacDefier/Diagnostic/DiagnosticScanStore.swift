// Persist last diagnostic / AI scan so we can inspect without screenshots.

import Foundation
import CleanupKit

enum DiagnosticScanStore {
    #if DEBUG
    private static let dirName = "MacDefier-Dev"
    #else
    private static let dirName = "MacDefier"
    #endif
    private static let jsonName = "last_diagnostic_scan.json"
    private static let textName = "last_diagnostic_scan.txt"
    private static let rawAIName = "last_ai_scan_raw.txt"

    private static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent(dirName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var jsonURL: URL { supportDir.appendingPathComponent(jsonName) }
    static var textURL: URL { supportDir.appendingPathComponent(textName) }
    static var rawAIURL: URL { supportDir.appendingPathComponent(rawAIName) }

    struct Snapshot: Codable {
        var scannedAt: Date
        var useAI: Bool
        var summaryLine: String
        var aiNarrative: String?
        var lastError: String?
        var junkBytes: UInt64
        var trashBytes: UInt64
        /// Optional so older persisted JSON remains decodable.
        var cleanupIsPartial: Bool?
        var monitorEvidenceIsComplete: Bool?
        var findings: [FindingDTO]
        var largeApps: [AppDTO]
    }

    struct FindingDTO: Codable {
        var id: String
        var kind: String
        var severity: String
        var title: String
        var detail: String
        var metric: String?
        var action: String
        var actionTitle: String
        var processPID: Int?
        var processName: String?
        var appPath: String?
        var appBundleID: String?
    }

    struct AppDTO: Codable {
        var name: String
        var bytes: UInt64
    }

    static func save(
        report: DiagnosticReport,
        useAI: Bool,
        lastError: String?,
        rawAIReply: String?,
        directory: URL? = nil
    ) {
        let findings = report.findings.map {
            FindingDTO(
                id: $0.id,
                kind: $0.kind.rawValue,
                severity: $0.severity.label,
                title: $0.title,
                detail: $0.detail,
                metric: $0.metric,
                action: $0.action.rawValue,
                actionTitle: $0.actionTitle,
                processPID: $0.processPID,
                processName: $0.processName,
                appPath: $0.appPath,
                appBundleID: $0.appBundleID
            )
        }
        let apps = report.largeApps.map { AppDTO(name: $0.name, bytes: $0.bytes) }
        let snap = Snapshot(
            scannedAt: report.scannedAt,
            useAI: useAI,
            summaryLine: report.summaryLine,
            aiNarrative: report.aiNarrative,
            lastError: lastError,
            junkBytes: report.junkBytes,
            trashBytes: report.trashBytes,
            cleanupIsPartial: report.cleanupIsPartial,
            monitorEvidenceIsComplete: report.monitorEvidenceIsComplete,
            findings: findings,
            largeApps: apps
        )

        let targetDirectory = directory ?? supportDir
        try? FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(snap) {
            try? data.write(to: targetDirectory.appendingPathComponent(jsonName), options: [.atomic])
        }

        // Plain text for easy agent read
        var lines: [String] = []
        lines.append("MacDefier diagnostic scan dump")
        lines.append("scannedAt: \(report.scannedAt)")
        lines.append("useAI: \(useAI)")
        lines.append("summary: \(report.summaryLine)")
        lines.append("junkBytes: \(report.junkBytes)")
        lines.append("trashBytes: \(report.trashBytes)")
        lines.append("cleanupIsPartial: \(report.cleanupIsPartial)")
        lines.append("monitorEvidenceIsComplete: \(report.monitorEvidenceIsComplete)")
        if let err = lastError, !err.isEmpty {
            lines.append("lastError: \(err)")
        }
        if let n = report.aiNarrative, !n.isEmpty {
            lines.append("--- aiNarrative ---")
            lines.append(n)
        }
        lines.append("--- findings (\(findings.count)) ---")
        for (i, f) in findings.enumerated() {
            lines.append("[\(i + 1)] \(f.severity) · \(f.kind) · \(f.title)")
            if let m = f.metric { lines.append("    metric: \(m)") }
            lines.append("    detail: \(f.detail)")
            lines.append("    action: \(f.actionTitle) (\(f.action))")
            if let p = f.appPath { lines.append("    appPath: \(p)") }
            if let b = f.appBundleID { lines.append("    bundle: \(b)") }
            if let pid = f.processPID { lines.append("    pid: \(pid) \(f.processName ?? "")") }
        }
        if !apps.isEmpty {
            lines.append("--- largeApps ---")
            for a in apps {
                lines.append("- \(a.name): \(a.bytes)")
            }
        }
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: targetDirectory.appendingPathComponent(textName), atomically: true, encoding: .utf8)

        if let raw = rawAIReply {
            try? raw.write(to: targetDirectory.appendingPathComponent(rawAIName), atomically: true, encoding: .utf8)
        }
    }

    static func loadText() -> String? {
        guard let data = try? Data(contentsOf: textURL),
              let s = String(data: data, encoding: .utf8), !s.isEmpty
        else { return nil }
        return s
    }
}
