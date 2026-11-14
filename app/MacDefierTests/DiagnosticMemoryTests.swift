import CleanupKit
import Foundation
import MonitorKit
import XCTest
@testable import MacDefier

final class DiagnosticMemoryTests: XCTestCase {
    @MainActor
    func testScoreEvaluationRefreshAndPersistenceContracts() throws {
        let now = Date()
        let disk = DiskVolume(name: "System", path: "/", total: 500 * 1_073_741_824, free: 200 * 1_073_741_824, kind: .system)
        var cpu = CPULoad(sampledAt: now)
        cpu.totalUsage = 0.2
        var ram = RAMUsage(
            total: 100,
            used: 99,
            free: 1,
            swap: .init(isAvailable: true),
            pressure: .init(level: 1, value: .normal),
            sampledAt: now
        )

        func score(_ snapshot: MonitorSnapshot) -> DiagnosticScoreBreakdown {
            DiagnosticScore.evaluate(snapshot: snapshot, cleanup: nil, now: now)
        }
        func snapshot() -> MonitorSnapshot {
            .init(cpu: cpu, ram: ram, disks: [disk], disksSampledAt: now)
        }

        XCTAssertNil(score(.init()).total, "Missing samples must not receive 100")
        XCTAssertEqual(score(snapshot()).total, 100, "High usage with normal pressure is not a memory problem")

        ram.pressure = .init()
        XCTAssertNil(score(.init(cpu: cpu, ram: ram)).memoryScore, "Unknown pressure must not receive a memory score")

        ram.pressure = .init(level: 2, value: .warning)
        XCTAssertEqual(score(.init(cpu: cpu, ram: ram)).memoryScore, 88)

        ram.swap = .init()
        XCTAssertNil(score(.init(cpu: cpu, ram: ram)).total, "Unknown swap must preserve incomplete evidence")

        ram.swap = .init(isAvailable: true)
        cpu.sampledAt = now.addingTimeInterval(-16)
        XCTAssertNil(score(.init(cpu: cpu, ram: ram, updatedAt: now)).loadScore, "Fresh aggregate must not revive old CPU")
        XCTAssertEqual(score(.init(cpu: cpu, ram: ram)).statusKey, "diag.status.incomplete")

        let missing = DiagnosticScanEngine.buildReport(snapshot: .init(), junkBytes: 0, apps: [], now: now)
        XCTAssertTrue(missing.findings.contains { $0.id == "monitor-incomplete" })
        XCTAssertFalse(missing.findings.contains { $0.kind == .ok }, "Missing telemetry must not create an all-clear card")
        XCTAssertEqual(missing.summaryLine, L10n.t("status.incomplete"))

        cpu.sampledAt = now
        ram.pressure = .init(level: 1, value: .normal)
        let highUsage = DiagnosticScanEngine.buildReport(snapshot: snapshot(), junkBytes: 0, apps: [], now: now)
        XCTAssertFalse(highUsage.findings.contains { $0.severity == .warn || $0.severity == .high })

        ram.pressure = .init()
        let unknown = DiagnosticScanEngine.buildReport(snapshot: .init(cpu: cpu, ram: ram), junkBytes: 0, apps: [], now: now)
        XCTAssertTrue(unknown.findings.contains { $0.id == "monitor-incomplete" })
        XCTAssertFalse(unknown.findings.contains { $0.kind == .ok })

        ram.pressure = .init(level: 1, value: .normal)
        let partial = DiagnosticScanEngine.buildReport(
            snapshot: snapshot(),
            junkBytes: 6 * 1_073_741_824,
            trashBytes: 1_073_741_824,
            apps: [],
            cleanupIsPartial: true,
            now: now
        )
        XCTAssertTrue(partial.cleanupIsPartial)
        XCTAssertTrue(partial.findings.contains { $0.id == "cleanup-incomplete" })
        XCTAssertFalse(partial.findings.contains { $0.severity > .info || $0.kind == .ok })
        XCTAssertEqual(partial.summaryLine, L10n.t("status.incomplete"))

        let partialScore = DiagnosticScore.evaluate(
            snapshot: snapshot(),
            cleanup: .init(junkBytes: partial.junkBytes, trashBytes: partial.trashBytes, largestAppBytes: 0, isPartial: true),
            now: now
        )
        XCTAssertNil(partialScore.total)
        XCTAssertNil(partialScore.spaceScore)
        XCTAssertTrue(partialScore.deductions.isEmpty)
        XCTAssertNil(DiagnosticScore.evaluateLive(snapshot: snapshot(), report: partial, hasFreshScan: false).total)
        XCTAssertNil(score(.init(cpu: cpu, ram: ram)).spaceScore)

        let usb = DiskVolume(name: "USB", path: "/Volumes/USB", total: 16 * 1_073_741_824, free: 8 * 1_073_741_824, kind: .external)
        XCTAssertFalse(DiagnosticScore.isSystemDiskTight([usb]), "External disk cannot substitute for system root")

        let missingSystem = MonitorSnapshot(cpu: cpu, ram: ram, disks: [usb], disksSampledAt: now)
        XCTAssertNil(score(missingSystem).total)
        XCTAssertTrue(score(missingSystem).deductions.isEmpty)
        let storageUnknown = DiagnosticScanEngine.buildReport(snapshot: missingSystem, junkBytes: 0, apps: [], now: now)
        XCTAssertTrue(storageUnknown.findings.contains { $0.id == "storage-incomplete" })
        XCTAssertFalse(storageUnknown.findings.contains { $0.severity > .info || $0.kind == .ok })

        var cached = highUsage
        cached.aiNarrative = "Old AI says healthy"
        cached.findings.append(.init(
            id: "ai-old",
            kind: .ok,
            severity: .info,
            title: "Old normal",
            detail: "Old normal",
            action: .openMonitor,
            actionTitle: "Monitor"
        ))
        let service = DiagnosticScanService(initialReport: cached)
        service.refreshCachedReport(snapshot: snapshot(), now: now)
        XCTAssertNotNil(service.report.aiNarrative, "Unchanged fresh evidence can keep its AI interpretation")

        service.refreshCachedReport(snapshot: snapshot(), now: now.addingTimeInterval(16))
        XCTAssertEqual(service.report.scannedAt, cached.scannedAt, "Refresh must retain disk scan date")
        XCTAssertTrue(service.report.findings.contains { $0.id == "monitor-incomplete" })
        XCTAssertTrue(service.report.findings.contains { $0.id == "storage-incomplete" })
        XCTAssertFalse(service.report.findings.contains { $0.kind == .ok })
        XCTAssertNil(service.report.aiNarrative)
        XCTAssertFalse(service.report.findings.contains { $0.id.hasPrefix("ai-") })

        let partialService = DiagnosticScanService(initialReport: partial)
        partialService.refreshCachedReport(snapshot: snapshot(), now: now)
        XCTAssertTrue(partialService.report.cleanupIsPartial)
        XCTAssertEqual(partialService.report.summaryLine, L10n.t("status.incomplete"))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-memory-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        DiagnosticScanStore.save(report: partialService.report, useAI: false, lastError: nil, rawAIReply: nil, directory: directory)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(
            DiagnosticScanStore.Snapshot.self,
            from: Data(contentsOf: directory.appendingPathComponent("last_diagnostic_scan.json"))
        )
        XCTAssertEqual(saved.cleanupIsPartial, true)
        XCTAssertEqual(saved.monitorEvidenceIsComplete, true)
        XCTAssertTrue(saved.findings.contains { $0.id == "cleanup-incomplete" })
        let text = try String(contentsOf: directory.appendingPathComponent("last_diagnostic_scan.txt"), encoding: .utf8)
        XCTAssertTrue(text.contains("cleanupIsPartial: true"))

        DiagnosticScanStore.save(report: service.report, useAI: false, lastError: nil, rawAIReply: nil, directory: directory)
        let unknownSaved = try decoder.decode(
            DiagnosticScanStore.Snapshot.self,
            from: Data(contentsOf: directory.appendingPathComponent("last_diagnostic_scan.json"))
        )
        XCTAssertEqual(unknownSaved.monitorEvidenceIsComplete, false)
        XCTAssertFalse(unknownSaved.findings.contains { $0.kind == "ok" })
    }

    func testUnifiedHealthThresholdsConsistency() {
        let lowDisk = DiskVolume(name: "Macintosh HD", path: "/", total: 500_000_000_000, free: 18_000_000_000, kind: .system)
        XCTAssertTrue(HealthThresholds.isSystemDiskTight([lowDisk]))
        XCTAssertTrue(DiagnosticScore.isSystemDiskTight([lowDisk]))

        let plentyDisk = DiskVolume(name: "Macintosh HD", path: "/", total: 500_000_000_000, free: 100_000_000_000, kind: .system)
        XCTAssertFalse(HealthThresholds.isSystemDiskTight([plentyDisk]))

        let normalRAM = RAMUsage(total: 100, used: 95, free: 5, pressure: .init(level: 1, value: .normal))
        XCTAssertFalse(HealthThresholds.isMemoryPressureElevated(normalRAM))

        let warnRAM = RAMUsage(total: 100, used: 80, free: 20, pressure: .init(level: 2, value: .warning))
        XCTAssertTrue(HealthThresholds.isMemoryPressureElevated(warnRAM))
    }
}
