// Compile beside DiagnosticScore.swift, DiagnosticScanEngine.swift, the fixture, and MonitorKit.
// Uses real rules, cache refresh and persistence. External scans and AI are disabled by the fixture.
import Foundation
import MonitorKit

@main
struct DiagnosticMemorySmokeMain {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String = "Diagnostic contract failed") {
            checks += 1
            precondition(condition(), message)
        }
        let now = Date()
        let disk = DiskVolume(name: "System", path: "/", total: 500 * 1_073_741_824, free: 200 * 1_073_741_824, kind: .system)
        var cpu = CPULoad(sampledAt: now)
        cpu.totalUsage = 0.2
        var ram = RAMUsage(total: 100, used: 99, free: 1,
                           swap: .init(isAvailable: true), pressure: .init(level: 1, value: .normal), sampledAt: now)
        func score(_ snapshot: MonitorSnapshot) -> DiagnosticScoreBreakdown {
            DiagnosticScore.evaluate(snapshot: snapshot, cleanup: nil, now: now)
        }
        func snapshot() -> MonitorSnapshot { .init(cpu: cpu, ram: ram, disks: [disk], disksSampledAt: now) }
        check(score(.init()).total == nil, "Missing samples must not receive 100")
        check(score(snapshot()).total == 100, "High usage with normal pressure is not a memory problem")
        ram.pressure = .init()
        check(score(.init(cpu: cpu, ram: ram)).memoryScore == nil, "Unknown pressure must not receive a memory score")
        ram.pressure = .init(level: 2, value: .warning)
        check(score(.init(cpu: cpu, ram: ram)).memoryScore == 88)
        ram.swap = .init()
        check(score(.init(cpu: cpu, ram: ram)).total == nil, "Unknown swap must preserve incomplete evidence")
        ram.swap = .init(isAvailable: true)
        cpu.sampledAt = now.addingTimeInterval(-16)
        check(score(.init(cpu: cpu, ram: ram, updatedAt: now)).loadScore == nil, "Fresh aggregate must not revive old CPU")
        check(score(.init(cpu: cpu, ram: ram)).statusKey == "diag.status.incomplete")
        let missing = DiagnosticScanEngine.buildReport(snapshot: .init(), junkBytes: 0, apps: [], now: now)
        check(missing.findings.contains { $0.id == "monitor-incomplete" })
        check(!missing.findings.contains { $0.kind == .ok }, "Missing telemetry must not create an all-clear card")
        check(missing.summaryLine == "status.incomplete")
        cpu.sampledAt = now
        ram.pressure = .init(level: 1, value: .normal)
        let highUsage = DiagnosticScanEngine.buildReport(snapshot: snapshot(), junkBytes: 0, apps: [], now: now)
        check(!highUsage.findings.contains { $0.severity == .warn || $0.severity == .high })
        ram.pressure = .init()
        let unknown = DiagnosticScanEngine.buildReport(snapshot: .init(cpu: cpu, ram: ram), junkBytes: 0, apps: [], now: now)
        check(unknown.findings.contains { $0.id == "monitor-incomplete" })
        check(!unknown.findings.contains { $0.kind == .ok })
        ram.pressure = .init(level: 1, value: .normal)
        let partial = DiagnosticScanEngine.buildReport(snapshot: snapshot(), junkBytes: 6 * 1_073_741_824,
            trashBytes: 1_073_741_824, apps: [], cleanupIsPartial: true, now: now)
        check(partial.cleanupIsPartial)
        check(partial.findings.contains { $0.id == "cleanup-incomplete" })
        check(!partial.findings.contains { $0.severity > .info || $0.kind == .ok })
        check(partial.summaryLine == "status.incomplete")
        let partialScore = DiagnosticScore.evaluate(snapshot: snapshot(), cleanup: .init(junkBytes: partial.junkBytes,
            trashBytes: partial.trashBytes, largestAppBytes: 0, isPartial: true), now: now)
        check(partialScore.total == nil && partialScore.spaceScore == nil)
        check(partialScore.deductions.isEmpty)
        check(DiagnosticScore.evaluateLive(snapshot: snapshot(), report: partial, hasFreshScan: false).total == nil,
              "Expiration must not turn an incomplete cleanup scan into a complete score")
        check(score(.init(cpu: cpu, ram: ram)).spaceScore == nil)
        let usb = DiskVolume(name: "USB", path: "/Volumes/USB", total: 16 * 1_073_741_824,
                             free: 8 * 1_073_741_824, kind: .external)
        check(!DiagnosticScore.isSystemDiskTight([usb]), "External disk cannot substitute for system root")
        let missingSystem = MonitorSnapshot(cpu: cpu, ram: ram, disks: [usb], disksSampledAt: now)
        check(score(missingSystem).total == nil)
        check(score(missingSystem).deductions.isEmpty)
        let storageUnknown = DiagnosticScanEngine.buildReport(snapshot: missingSystem, junkBytes: 0, apps: [], now: now)
        check(storageUnknown.findings.contains { $0.id == "storage-incomplete" })
        check(!storageUnknown.findings.contains { $0.severity > .info || $0.kind == .ok })

        var cached = highUsage
        cached.aiNarrative = "Old AI says healthy"
        cached.findings.append(.init(id: "ai-old", kind: .ok, severity: .info, title: "Old normal",
                                    detail: "Old normal", action: .openMonitor, actionTitle: "Monitor"))
        let service = DiagnosticScanService(initialReport: cached)
        service.refreshCachedReport(snapshot: snapshot(), now: now)
        check(service.report.aiNarrative != nil, "Unchanged fresh evidence can keep its AI interpretation")
        service.refreshCachedReport(snapshot: snapshot(), now: now.addingTimeInterval(16))
        check(service.report.scannedAt == cached.scannedAt, "Refresh must retain disk scan date")
        check(service.report.findings.contains { $0.id == "monitor-incomplete" })
        check(service.report.findings.contains { $0.id == "storage-incomplete" })
        check(!service.report.findings.contains { $0.kind == .ok })
        check(service.report.aiNarrative == nil && !service.report.findings.contains { $0.id.hasPrefix("ai-") })
        let partialService = DiagnosticScanService(initialReport: partial)
        partialService.refreshCachedReport(snapshot: snapshot(), now: now)
        check(partialService.report.cleanupIsPartial && partialService.report.summaryLine == "status.incomplete")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-memory-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        DiagnosticScanStore.save(report: partialService.report, useAI: false, lastError: nil, rawAIReply: nil, directory: directory)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(DiagnosticScanStore.Snapshot.self,
            from: Data(contentsOf: directory.appendingPathComponent("last_diagnostic_scan.json")))
        check(saved.cleanupIsPartial == true && saved.monitorEvidenceIsComplete == true)
        check(saved.findings.contains { $0.id == "cleanup-incomplete" })
        let text = try String(contentsOf: directory.appendingPathComponent("last_diagnostic_scan.txt"), encoding: .utf8)
        check(text.contains("cleanupIsPartial: true"))
        DiagnosticScanStore.save(report: service.report, useAI: false, lastError: nil, rawAIReply: nil, directory: directory)
        let unknownSaved = try decoder.decode(DiagnosticScanStore.Snapshot.self,
            from: Data(contentsOf: directory.appendingPathComponent("last_diagnostic_scan.json")))
        check(unknownSaved.monitorEvidenceIsComplete == false)
        check(!unknownSaved.findings.contains { $0.kind == "ok" })
        print("Diagnostic memory smoke: \(checks) checks passed")
    }
}
