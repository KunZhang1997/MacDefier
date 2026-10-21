import Darwin
import Foundation
import XCTest
@testable import CleanupKit

final class CliManualEntryTests: XCTestCase {
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func record(_ value: String) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("CliManualEntry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".local/bin"),
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func executable(_ relative: String, in home: URL, contents: String = "fixture only") throws -> URL {
        let path = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path
    }

    private func codex(in home: URL) throws -> CliTool {
        let tools = CliToolInventory.manualTools(home: home.path)
        return try XCTUnwrap(tools.first { $0.bins.contains("codex") })
    }

    private func assertExecutionBlocked(_ tool: CliTool, home: URL, code: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let result = CliUninstallExecutor.uninstallManualProgram(tool, home: home.path) { _ in
            XCTFail("No destructive callback is permitted", file: file, line: line)
            return ([], [], [], 0)
        }
        XCTAssertFalse(result.ok, file: file, line: line)
        XCTAssertTrue(result.errors.contains { $0.hasPrefix(code + ":") },
                      result.errors.joined(separator: ";"), file: file, line: line)
    }

    func testUnchangedStandaloneBinaryPlansOnlyExplicitFile() throws {
        let home = try fixture()
        let program = try executable(".local/bin/codex", in: home)
        let selected = try codex(in: home)
        XCTAssertEqual(selected.displayName, "Codex")
        XCTAssertEqual(selected.programPaths, [program.path])
        let plan = try CliUninstallExecutor.manualProgramPlan(selected, home: home.path)
        XCTAssertEqual(plan.map(\.path), [program.path])
        var calls: [String] = []
        let result = CliUninstallExecutor.uninstallManualProgram(selected, home: home.path) { source in
            calls.append(source.path)
            return (["fixture callback"], [], [], 0)
        }
        XCTAssertTrue(result.ok, result.errors.joined(separator: ";"))
        XCTAssertEqual(calls, [program.path])
        XCTAssertEqual(try String(contentsOf: program, encoding: .utf8), "fixture only")
    }

    func testUnchangedHardlinkedCodexNeverPlansSharedBinOrOtherCommand() throws {
        let home = try fixture()
        let program = try executable(".local/bin/codex", in: home)
        let alias = home.appendingPathComponent(".local/bin/codex-aarch64-apple-darwin")
        try FileManager.default.linkItem(at: program, to: alias)
        let unrelated = try executable(".local/bin/unrelated", in: home)
        let selected = try codex(in: home)
        XCTAssertEqual(selected.displayName, "Codex")
        XCTAssertEqual(Set(selected.programPaths), Set([program.path, alias.path]))
        let plan = try CliUninstallExecutor.manualProgramPlan(selected, home: home.path)
        XCTAssertEqual(Set(plan.map(\.path)), Set([program.path, alias.path]))
        XCTAssertFalse(plan.contains { $0.path == unrelated.path || $0.path == home.appendingPathComponent(".local/bin").path })
        var calls: [String] = []
        let result = CliUninstallExecutor.uninstallManualProgram(selected, home: home.path) { source in
            calls.append(source.path)
            return (["fixture callback"], [], [], 0)
        }
        XCTAssertTrue(result.ok, result.errors.joined(separator: ";"))
        XCTAssertEqual(Set(calls), Set([program.path, alias.path]))
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "fixture only")
    }

    func testSameDirectorySymlinkPlansEntryAndTargetNotSharedBin() throws {
        let home = try fixture()
        let target = try executable(".local/bin/codex-aarch64-apple-darwin", in: home)
        let shim = home.appendingPathComponent(".local/bin/codex")
        try FileManager.default.createSymbolicLink(at: shim, withDestinationURL: target)
        let selected = try codex(in: home)
        let plan = try CliUninstallExecutor.manualProgramPlan(selected, home: home.path)
        XCTAssertEqual(Set(plan.map(\.path)), Set([shim.path, target.path]))
        XCTAssertEqual(plan.first?.path, shim.path)
    }

    func testReplacementAfterScanIsKeptUntilFreshScan() throws {
        let home = try fixture()
        let program = try executable(".local/bin/codex", in: home)
        let selected = try codex(in: home)
        try FileManager.default.moveItem(at: program, to: home.appendingPathComponent("old-codex"))
        _ = try executable(".local/bin/codex", in: home, contents: "reinstalled")
        assertExecutionBlocked(selected, home: home, code: "cli_manual_owner_changed")
        XCTAssertEqual(try String(contentsOf: program, encoding: .utf8), "reinstalled")
        let rescanned = try codex(in: home)
        var called = false
        let result = CliUninstallExecutor.uninstallManualProgram(rescanned, home: home.path) { _ in
            called = true
            return (["fixture callback"], [], [], 0)
        }
        XCTAssertTrue(result.ok)
        XCTAssertTrue(called)
    }

    func testInPlaceUpdateAfterScanIsKeptEvenWithSameInode() throws {
        let home = try fixture()
        let program = try executable(".local/bin/codex", in: home)
        let selected = try codex(in: home)
        let before = try UninstallFileBoundary.snapshot(program.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: program.path)
        let oldModified = try XCTUnwrap(attributes[.modificationDate] as? Date)
        try Data("changed only".utf8).write(to: program)
        try FileManager.default.setAttributes([.modificationDate: oldModified.addingTimeInterval(2)], ofItemAtPath: program.path)
        XCTAssertEqual(try UninstallFileBoundary.snapshot(program.path).item, before.item)
        assertExecutionBlocked(selected, home: home, code: "cli_manual_owner_changed")
    }

    func testSameDirectorySymlinkRetargetAfterScanIsKept() throws {
        let home = try fixture()
        let target = try executable(".local/bin/codex-aarch64-apple-darwin", in: home)
        let shim = home.appendingPathComponent(".local/bin/codex")
        try FileManager.default.createSymbolicLink(at: shim, withDestinationURL: target)
        let selected = try codex(in: home)
        let other = try executable(".local/bin/unrelated", in: home)
        try FileManager.default.moveItem(at: shim, to: home.appendingPathComponent("old-shim"))
        try FileManager.default.createSymbolicLink(at: shim, withDestinationURL: other)
        assertExecutionBlocked(selected, home: home, code: "cli_manual_owner_changed")
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "fixture only")
    }

    func testParentDirectoryReplacementAfterScanIsKept() throws {
        let home = try fixture()
        _ = try executable(".local/bin/codex", in: home)
        let selected = try codex(in: home)
        try FileManager.default.moveItem(at: home.appendingPathComponent(".local/bin"),
                                         to: home.appendingPathComponent("old-bin"))
        _ = try executable(".local/bin/codex", in: home, contents: "replacement parent")
        assertExecutionBlocked(selected, home: home, code: "cli_manual_owner_changed")
    }

    func testStandalonePathWithoutScanEvidenceIsNotAuthorized() throws {
        let home = try fixture()
        let program = try executable(".local/bin/codex", in: home)
        let selected = CliTool(id: "manual:codex", displayName: "Codex", channel: .manual, packageId: "codex",
                               programPaths: [program.path], programBytes: 0, dataDirs: [], agents: [],
                               bins: ["codex"], protected: false)
        assertExecutionBlocked(selected, home: home, code: "cli_manual_ownership_unverified")
    }

    func testSharedBinRootIsNeverOwnedOrPlannedEvenForLegacyLocalRow() throws {
        let home = try fixture()
        _ = try executable(".local/bin/codex", in: home)
        let root = home.appendingPathComponent(".local/bin").path
        let selected = CliTool(id: "manual:local", displayName: "Local", channel: .manual, packageId: "local",
                               programPaths: [root], programBytes: 0, dataDirs: [], agents: [],
                               bins: ["codex"], protected: false)
        XCTAssertEqual(CliOwnershipBoundary.programRoots(selected, home: home.path), [])
        assertExecutionBlocked(selected, home: home, code: "cli_manual_shared_root")
    }

    func testHomeBinStandaloneEntryIsSupportedWithoutSelectingSharedRoot() throws {
        let home = try fixture()
        let program = try executable("bin/codex", in: home)
        let selected = try codex(in: home)
        XCTAssertEqual(selected.programPaths, [program.path])
        XCTAssertEqual(try CliUninstallExecutor.manualProgramPlan(selected, home: home.path).map(\.path), [program.path])
    }

    func testSameDirectoryBorrowedCommandIsNotClaimedAsCodexProgram() throws {
        let home = try fixture()
        let other = try executable(".local/bin/unrelated", in: home)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".local/bin/codex"), withDestinationURL: other)
        let tools = CliToolInventory.manualTools(home: home.path)
        XCTAssertFalse(tools.contains { $0.bins.contains("codex") })
        XCTAssertEqual(tools.flatMap(\.programPaths), [other.path])
    }

    func testVendorDirectoryAndShimStillPlanNormally() throws {
        let home = try fixture()
        let program = try executable(".grok/bin/grok", in: home)
        let shim = home.appendingPathComponent(".local/bin/grok")
        try FileManager.default.createSymbolicLink(at: shim, withDestinationURL: program)
        let selected = try XCTUnwrap(CliToolInventory.manualTools(home: home.path).first { $0.bins.contains("grok") })
        let plan = try CliUninstallExecutor.manualProgramPlan(selected, home: home.path)
        XCTAssertEqual(Set(plan.map(\.path)), Set([shim.path, program.deletingLastPathComponent().path]))
        XCTAssertEqual(plan.first?.path, shim.path)
    }

    func testKnownOpencodeLeafPlansOnlyBinaryAndExplicitShim() throws {
        let home = try fixture()
        let program = try executable(".local/share/opencode/bin/opencode", in: home)
        let data = try executable(".local/share/opencode/sessions/fixture-data", in: home, contents: "precious")
        let shim = home.appendingPathComponent(".local/bin/opencode")
        try FileManager.default.createSymbolicLink(at: shim, withDestinationURL: program)
        let selected = try XCTUnwrap(CliToolInventory.manualTools(home: home.path, includeData: true)
            .first { $0.bins.contains("opencode") })
        let expected = Set([program.path, shim.path])
        XCTAssertEqual(Set(selected.programPaths), expected)
        XCTAssertEqual(selected.dataDirs.map(\.path), [home.appendingPathComponent(".local/share/opencode").path])
        XCTAssertEqual(Set(try CliUninstallExecutor.manualProgramPlan(selected, home: home.path).map(\.path)), expected)
        var calls: [String] = []
        let result = CliUninstallExecutor.uninstallManualProgram(selected, home: home.path) { source in
            calls.append(source.path)
            return (["fixture callback"], [], [], 0)
        }
        XCTAssertTrue(result.ok, result.errors.joined(separator: ";"))
        XCTAssertEqual(Set(calls), expected)
        XCTAssertEqual(try String(contentsOf: data, encoding: .utf8), "precious")
    }

    func testUnknownOpencodeNeighborLayoutIsNotClaimedAsProgram() throws {
        let home = try fixture()
        let program = try executable(".local/share/opencode/bin/other", in: home)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".local/bin/opencode"),
                                                   withDestinationURL: program)
        XCTAssertEqual(CliToolInventory.manualTools(home: home.path), [])
    }

    func testIndependentBrandPrefixedCommandIsNotPartOfCodexPlan() throws {
        let home = try fixture()
        let program = try executable(".local/bin/codex", in: home)
        let other = try executable(".local/bin/codex-mcp-server", in: home, contents: "separate product")
        let selected = try codex(in: home)
        XCTAssertEqual(selected.programPaths, [program.path])
        XCTAssertEqual(try CliUninstallExecutor.manualProgramPlan(selected, home: home.path).map(\.path), [program.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testIndependentArchitectureNamedBinaryIsNotMergedWithoutSameIdentity() throws {
        let home = try fixture()
        let program = try executable(".local/bin/codex", in: home)
        _ = try executable(".local/bin/codex-aarch64-apple-darwin", in: home, contents: "different install")
        let selected = try codex(in: home)
        XCTAssertEqual(selected.programPaths, [program.path])
        XCTAssertEqual(try CliUninstallExecutor.manualProgramPlan(selected, home: home.path).map(\.path), [program.path])
    }

    func testBorrowedBrandPrefixedCommandIsNotClaimedAsCodex() throws {
        let home = try fixture()
        let other = try executable(".local/bin/codex-mcp-server", in: home)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".local/bin/codex"), withDestinationURL: other)
        let tools = CliToolInventory.manualTools(home: home.path)
        XCTAssertFalse(tools.contains { $0.bins.contains("codex") })
        XCTAssertEqual(tools.flatMap(\.programPaths), [other.path])
    }

    func testBrandPrefixedStandaloneCommandDoesNotAcquireCodexData() throws {
        let home = try fixture()
        _ = try executable(".local/bin/codex", in: home)
        _ = try executable(".local/bin/codex-mcp-server", in: home)
        _ = try executable(".codex/fixture-data", in: home, contents: "precious")
        let tools = CliToolInventory.manualTools(home: home.path, includeData: true)
        let codex = try XCTUnwrap(tools.first { $0.bins.contains("codex") })
        let other = try XCTUnwrap(tools.first { $0.bins.contains("codex-mcp-server") })
        XCTAssertEqual(codex.dataDirs.map(\.path), [home.appendingPathComponent(".codex").path])
        XCTAssertEqual(other.dataDirs, [])
    }

    func testStandaloneProgramDoesNotOwnBrandPrefixedAgentsProgram() throws {
        let home = try fixture()
        let program = try executable(".local/bin/codex", in: home)
        let other = try executable(".local/bin/codex-mcp-server", in: home)
        let selected = try codex(in: home)
        let agentURL = home.appendingPathComponent("Library/LaunchAgents/codex.plist")
        try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let agent = CliLaunchAgentInfo(label: "fixture.codex", plistPath: agentURL.path, running: false)
        func writeAgent(program: String) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: ["Label": agent.label, "Program": program],
                                                          format: .xml, options: 0)
            try data.write(to: agentURL)
        }
        try writeAgent(program: other.path)
        XCTAssertThrowsError(try CliOwnershipBoundary.validateAgent(agent, tool: selected, home: home.path))
        try writeAgent(program: program.path)
        XCTAssertNoThrow(try CliOwnershipBoundary.validateAgent(agent, tool: selected, home: home.path))
    }

    func testNewSameNamedRegularEntryIsNotInferredFromEarlierScan() throws {
        let home = try fixture()
        _ = try executable(".local/bin/codex", in: home)
        let selected = try codex(in: home)
        _ = try executable("bin/codex", in: home, contents: "different install")
        assertExecutionBlocked(selected, home: home, code: "cli_manual_ownership_unverified")
    }

    func testInjectedExecutionAllowsDataOnlyAfterManualProgramAndVerificationSucceed() async throws {
        let home = try fixture()
        _ = try executable(".local/bin/codex", in: home)
        let discovered = try codex(in: home)
        let data = try executable(".codex-fixture/data", in: home, contents: "precious")
        var selected = CliTool(id: discovered.id, displayName: discovered.displayName, channel: .manual,
                               packageId: discovered.packageId, programPaths: discovered.programPaths,
                               programBytes: 0, dataDirs: [.init(path: data.path, bytes: 8)], agents: [],
                               bins: discovered.bins, protected: false)
        selected.manualEntryEvidence = discovered.manualEntryEvidence
        let events = Events()
        let result = await CliUninstallExecutor.execute(
            tool: selected, options: .init(stopAgents: false, uninstallProgram: true, trashDataDirs: true),
            execution: .init(program: { tool in
                CliUninstallExecutor.uninstallManualProgram(tool, home: home.path) { _ in
                    events.record("program")
                    return (["fixture callback"], [], [], 0)
                }
            }, footprintGone: { _ in events.record("verify"); return true }, trash: { _, _ in
                events.record("data")
                return (["fixture callback"], [], [], 0)
            }))
        XCTAssertTrue(result.programUninstalled)
        XCTAssertTrue(result.errors.isEmpty, result.errors.joined(separator: ";"))
        XCTAssertEqual(events.values, ["program", "verify", "data"])
        XCTAssertEqual(try String(contentsOf: data, encoding: .utf8), "precious")
    }

    func testInjectedExecutionPreservesDataWhenScannedProgramWasReplaced() async throws {
        let home = try fixture()
        let program = try executable(".local/bin/codex", in: home)
        let discovered = try codex(in: home)
        let data = try executable(".codex-fixture/data", in: home, contents: "precious")
        var selected = CliTool(id: discovered.id, displayName: discovered.displayName, channel: .manual,
                               packageId: discovered.packageId, programPaths: discovered.programPaths,
                               programBytes: 0, dataDirs: [.init(path: data.path, bytes: 8)], agents: [],
                               bins: discovered.bins, protected: false)
        selected.manualEntryEvidence = discovered.manualEntryEvidence
        try FileManager.default.moveItem(at: program, to: home.appendingPathComponent("old-codex"))
        _ = try executable(".local/bin/codex", in: home, contents: "reinstalled")
        let result = await CliUninstallExecutor.execute(
            tool: selected, options: .init(stopAgents: false, uninstallProgram: true, trashDataDirs: true),
            execution: .init(program: { tool in
                CliUninstallExecutor.uninstallManualProgram(tool, home: home.path) { _ in
                    XCTFail("changed program must not reach trash callback")
                    return ([], [], [], 0)
                }
            }, footprintGone: { _ in XCTFail("failed program must not reach verification"); return false },
            trash: { _, _ in XCTFail("data must be kept"); return ([], [], [], 0) }))
        XCTAssertFalse(result.programUninstalled)
        XCTAssertTrue(result.errors.contains { $0.hasPrefix("cli_manual_owner_changed:") })
        XCTAssertTrue(result.errors.contains("cli_data_preserved_program_failed"))
        XCTAssertEqual(try String(contentsOf: data, encoding: .utf8), "precious")
    }
}
