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
        XCTAssertEqual(partialScore.spaceScore, 86, "Fresh system disk + lower-bound junk/trash must still produce a real space score")
        XCTAssertEqual(partialScore.total, 86)
        XCTAssertFalse(partialScore.includesCleanupScan, "Partial cleanup must not claim full cleanup coverage")
        XCTAssertFalse(partialScore.deductions.isEmpty)
        XCTAssertEqual(DiagnosticScore.evaluateLive(snapshot: snapshot(), report: partial, hasFreshScan: false).spaceScore, 86)
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

    func testPhase1DarkLagAndProcessFamilyFindingsReplayRealIncident() {
        let now = Date()
        let tightDisk = DiskVolume(
            name: "Macintosh HD",
            path: "/",
            total: 460 * 1_073_741_824,
            free: 23 * 1_000_000_000,
            kind: .system
        )
        var cpu = CPULoad(sampledAt: now)
        cpu.totalUsage = 0.35 // Total CPU < 65%, previously blind

        let ram = RAMUsage(
            total: 16 * 1_073_741_824,
            used: 15 * 1_073_741_824,
            free: 1 * 1_073_741_824,
            compressed: 3.67 * 1_073_741_824,
            swap: .init(total: 3 * 1_073_741_824, used: 2.45 * 1_073_741_824, free: 0.55 * 1_073_741_824, isAvailable: true),
            pressure: .init(level: 1, value: .normal), // Kernel pressure still normal!
            sampledAt: now
        )

        var snapshot = MonitorSnapshot(
            cpu: cpu,
            ram: ram,
            topCPU: [
                TopProcess(pid: 682, name: "Google Chrome", usage: 59.1),
                TopProcess(pid: 417, name: "WindowServer", usage: 48.5)
            ],
            disks: [tightDisk],
            disksSampledAt: now,
            topCPUSampledAt: now
        )
        snapshot.processFamilies = [
            ProcessFamilySummary(
                id: "app:/Applications/Google Chrome.app",
                name: "Google Chrome",
                kind: .userApp,
                processCount: 24,
                footprintBytes: 2.56 * 1_073_741_824,
                cpuUsage: 81.5,
                rootPID: 682,
                appPath: "/Applications/Google Chrome.app",
                bundleID: "com.google.Chrome"
            ),
            ProcessFamilySummary(
                id: "simulator:ios",
                name: "iOS Simulator",
                kind: .iosSimulator,
                processCount: 160,
                footprintBytes: 2.30 * 1_073_741_824,
                cpuUsage: 1.5,
                bootedSimulators: [
                    BootedSimulatorDevice(udid: "EF96C0C8-FDF7-478E-947E-987810995207", name: "iPhone 16 Pro", runtime: "iOS 18.6")
                ]
            ),
            ProcessFamilySummary(
                id: "automated-browser:37231:100",
                name: "Google Chrome",
                kind: .automatedBrowser,
                processCount: 11,
                footprintBytes: 506 * 1_048_576,
                cpuUsage: 0.7,
                rootPID: 37231,
                appPath: "/Applications/Google Chrome.app",
                bundleID: "com.google.Chrome",
                automationHint: ":9333 · .maitian-data"
            ),
            ProcessFamilySummary(
                id: "sys:WindowServer",
                name: "WindowServer",
                kind: .systemService,
                processCount: 1,
                footprintBytes: 108 * 1_048_576,
                cpuUsage: 48.5,
                rootPID: 417
            )
        ]
        snapshot.processFamiliesSampledAt = now

        let report = DiagnosticScanEngine.buildReport(snapshot: snapshot, junkBytes: 0, apps: [], now: now)
        let ids = Set(report.findings.map(\.id))

        XCTAssertTrue(ids.contains("swap-disk-combo"), "Must catch high swap + tight disk even when pressure is normal")
        XCTAssertTrue(ids.contains("windowserver-high"), "Must catch elevated WindowServer CPU")
        XCTAssertTrue(ids.contains("simulator-running"), "Must catch 160-process background iOS Simulator")
        XCTAssertTrue(ids.contains("auto-browser-37231"), "Must separate background automated Chrome from primary Chrome")
        XCTAssertTrue(ids.contains("family-cpu-app:/Applications/Google Chrome.app"), "Must catch multi-process family CPU >= 75%")

        let simFinding = report.findings.first { $0.id == "simulator-running" }
        XCTAssertEqual(simFinding?.action, .shutdownSimulators)
        XCTAssertTrue(simFinding?.detail.contains("iPhone 16 Pro") ?? false)

        let ctx = DiagnosticScanEngine.contextText(for: report, snapshot: snapshot)
        XCTAssertTrue(ctx.contains("iPhone 16 Pro"))
        XCTAssertTrue(ctx.contains("压缩内存"))

        let breakdown = DiagnosticScore.evaluate(snapshot: snapshot, cleanup: nil, now: now)
        XCTAssertLessThan(breakdown.memoryScore ?? 100, 100, "Score must reflect swap+disk strain")

        // Regression: pressure worsening from .normal to .warning must never INCREASE score!
        var worseRAM = ram
        worseRAM.pressure = .init(level: 2, value: .warning)
        let worseSnapshot = MonitorSnapshot(cpu: cpu, ram: worseRAM, disks: [tightDisk], disksSampledAt: now)
        let worseBreakdown = DiagnosticScore.evaluate(snapshot: worseSnapshot, cleanup: nil, now: now)
        XCTAssertLessThanOrEqual(worseBreakdown.memoryScore ?? 100, breakdown.memoryScore ?? 0)

        // Regression: at t = +45s, workbench keeps CPU/RAM/Disk fresh while processFamilies aged out;
        // refreshReport MUST retain scan-time family findings and AI narrative instead of self-destructing!
        let later = now.addingTimeInterval(45)
        var laterCPU = cpu
        laterCPU.sampledAt = later
        var laterRAM = ram
        laterRAM.sampledAt = later
        var laterSnap = snapshot
        laterSnap.cpu = laterCPU
        laterSnap.ram = laterRAM
        laterSnap.disksSampledAt = later
        var withAI = report
        withAI.scannedAt = now
        withAI.aiNarrative = "AI summary retained"
        let refreshed45 = DiagnosticScanEngine.refreshReport(withAI, snapshot: laterSnap, apps: [], preserveAI: true, now: later)
        XCTAssertTrue(refreshed45.findings.contains { $0.id == "simulator-running" })
        XCTAssertEqual(refreshed45.aiNarrative, "AI summary retained")

        // Regression: empty Simulator.app GUI with 0 booted devices must NOT emit simulator-running
        var idleSimSnap = snapshot
        idleSimSnap.processFamilies = [
            ProcessFamilySummary(
                id: "simulator:ios",
                name: "iOS Simulator",
                kind: .iosSimulator,
                processCount: 1,
                footprintBytes: 600 * 1_048_576,
                cpuUsage: 0,
                bootedSimulators: [],
                hasActiveSimulatedOS: false
            )
        ]
        let idleSimReport = DiagnosticScanEngine.buildReport(snapshot: idleSimSnap, junkBytes: 0, apps: [], now: now)
        XCTAssertFalse(idleSimReport.findings.contains { $0.id == "simulator-running" })
    }
}
