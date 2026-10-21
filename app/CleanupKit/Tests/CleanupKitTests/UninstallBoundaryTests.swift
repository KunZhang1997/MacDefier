import Darwin
import Foundation
import XCTest
@testable import CleanupKit

final class UninstallBoundaryTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("UninstallBoundary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func folder(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }

    private func write(_ text: String, to path: URL) throws {
        try Data(text.utf8).write(to: path)
    }

    private func tool(paths: [String], data: [CliDataDir] = [], bins: [String] = []) -> CliTool {
        CliTool(id: "fixture", displayName: "Fixture", channel: .manual, packageId: "fixture",
                programPaths: paths, programBytes: 10, dataDirs: data, agents: [], bins: bins, protected: false)
    }

    func testReplacementAfterSnapshotIsKept() throws {
        let root = try fixture()
        let trash = try folder("trash", in: root)
        let source = root.appendingPathComponent("app")
        try write("original", to: source)
        let snapshot = try UninstallFileBoundary.snapshot(source.path)
        try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("original"))
        try write("replacement", to: source)
        XCTAssertThrowsError(try UninstallFileBoundary.move(snapshot, toTrashDirectory: trash.path))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "replacement")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path), [])
    }

    func testReplacedSourceParentIsKept() throws {
        let root = try fixture()
        let parent = try folder("parent", in: root)
        let trash = try folder("trash", in: root)
        let source = parent.appendingPathComponent("app")
        try write("original", to: source)
        let snapshot = try UninstallFileBoundary.snapshot(source.path)
        try FileManager.default.moveItem(at: parent, to: root.appendingPathComponent("old-parent"))
        _ = try folder("parent", in: root)
        try write("replacement", to: source)
        XCTAssertThrowsError(try UninstallFileBoundary.move(snapshot, toTrashDirectory: trash.path))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "replacement")
    }

    func testSymlinkedTrashCannotRedirectMove() throws {
        let root = try fixture()
        let target = try folder("other", in: root)
        let link = root.appendingPathComponent("trash-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let source = root.appendingPathComponent("app")
        try write("keep", to: source)
        let snapshot = try UninstallFileBoundary.snapshot(source.path)
        XCTAssertThrowsError(try UninstallFileBoundary.move(snapshot, toTrashDirectory: link.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }

    func testRedirectedSourceAncestorIsRejected() throws {
        let root = try fixture()
        let parent = try folder("parent", in: root)
        let other = try folder("other", in: root)
        let trash = try folder("trash", in: root)
        let source = parent.appendingPathComponent("app")
        try write("original", to: source)
        try write("unrelated", to: other.appendingPathComponent("app"))
        let snapshot = try UninstallFileBoundary.snapshot(source.path)
        try FileManager.default.moveItem(at: parent, to: root.appendingPathComponent("old-parent"))
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: other)
        XCTAssertThrowsError(try UninstallFileBoundary.move(snapshot, toTrashDirectory: trash.path))
        XCTAssertEqual(try String(contentsOf: other.appendingPathComponent("app"), encoding: .utf8), "unrelated")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("old-parent/app"), encoding: .utf8), "original")
    }

    func testTrashAncestorSymlinkIsRejected() throws {
        let root = try fixture()
        let other = try folder("other/trash", in: root)
        let link = root.appendingPathComponent("redirect")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other.deletingLastPathComponent())
        let source = root.appendingPathComponent("app")
        try write("keep", to: source)
        XCTAssertThrowsError(try UninstallFileBoundary.move(UninstallFileBoundary.snapshot(source.path),
                                                           toTrashDirectory: link.appendingPathComponent("trash").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: other.path), [])
    }

    func testWritableByOthersTrashIsRejected() throws {
        let root = try fixture()
        let trash = try folder("trash", in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: trash.path)
        let source = root.appendingPathComponent("app")
        try write("keep", to: source)
        XCTAssertThrowsError(try UninstallFileBoundary.move(UninstallFileBoundary.snapshot(source.path), toTrashDirectory: trash.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testCollisionNeverOverwritesExistingTrashItem() throws {
        let root = try fixture()
        let trash = try folder("trash", in: root)
        let source = root.appendingPathComponent("same-name")
        try write("new", to: source)
        try write("old", to: trash.appendingPathComponent("same-name"))
        let destination = try UninstallFileBoundary.move(UninstallFileBoundary.snapshot(source.path), toTrashDirectory: trash.path)
        XCTAssertNotEqual(destination, trash.appendingPathComponent("same-name").path)
        XCTAssertEqual(try String(contentsOf: trash.appendingPathComponent("same-name"), encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOfFile: destination, encoding: .utf8), "new")
        XCTAssertTrue(UninstallFileBoundary.isMissing(source.path))
    }

    func testMoveTrashesSymlinkOnly() throws {
        let root = try fixture()
        let trash = try folder("trash", in: root)
        let target = root.appendingPathComponent("target")
        let link = root.appendingPathComponent("shim")
        try write("keep", to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let destination = try UninstallFileBoundary.move(UninstallFileBoundary.snapshot(link.path), toTrashDirectory: trash.path)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination), target.path)
        XCTAssertTrue(UninstallFileBoundary.isMissing(link.path))
    }

    func testProgramFailurePreservesDataWithoutCallingTrash() async throws {
        let root = try fixture()
        let data = root.appendingPathComponent("data")
        try write("precious", to: data)
        let result = await CliUninstallExecutor.execute(
            tool: tool(paths: [root.appendingPathComponent("program").path], data: [.init(path: data.path, bytes: 8)]),
            options: .init(stopAgents: false, uninstallProgram: true, trashDataDirs: true),
            execution: .init(program: { _ in ([], ["failed fixture"], false) }, footprintGone: { _ in true },
                             trash: { _, _ in XCTFail("data must not be touched"); return ([], [], [], 0) }))
        XCTAssertFalse(result.programUninstalled)
        XCTAssertTrue(result.errors.contains("cli_data_preserved_program_failed"))
        XCTAssertEqual(try String(contentsOf: data, encoding: .utf8), "precious")
    }

    func testCommandSuccessWithRemainingProgramPreservesData() async throws {
        let root = try fixture()
        let data = root.appendingPathComponent("data")
        try write("precious", to: data)
        let result = await CliUninstallExecutor.execute(
            tool: tool(paths: [root.appendingPathComponent("program").path], data: [.init(path: data.path, bytes: 8)]),
            options: .init(stopAgents: false, uninstallProgram: true, trashDataDirs: true),
            execution: .init(program: { _ in ([], [], true) }, footprintGone: { _ in false },
                             trash: { _, _ in XCTFail("data must not be touched"); return ([], [], [], 0) }))
        XCTAssertTrue(result.errors.contains("program_still_present"))
        XCTAssertEqual(try String(contentsOf: data, encoding: .utf8), "precious")
    }

    func testExplicitDataOnlyDoesNotRequireProgramRemoval() async throws {
        let root = try fixture()
        let data = root.appendingPathComponent("data")
        let trash = try folder("trash", in: root)
        try write("data", to: data)
        let result = await CliUninstallExecutor.execute(
            tool: tool(paths: [root.appendingPathComponent("program").path], data: [.init(path: data.path, bytes: 4)]),
            options: .init(stopAgents: false, uninstallProgram: false, trashDataDirs: true, selectedDataPaths: [data.path]),
            execution: .init(program: { _ in XCTFail("program not selected"); return ([], [], false) }, footprintGone: { _ in false },
                             trash: { path, bytes in
                                 do {
                                     _ = try UninstallFileBoundary.move(UninstallFileBoundary.snapshot(path), toTrashDirectory: trash.path)
                                     return ([], [], [path], bytes)
                                 } catch { return ([], [error.localizedDescription], [], 0) }
                             }))
        XCTAssertTrue(result.errors.isEmpty, result.errors.joined(separator: ";"))
        XCTAssertEqual(result.trashedPaths, [data.path])
        XCTAssertEqual(result.movedToTrashBytes, 4)
        XCTAssertEqual(result.freedBytes, 0)
    }

    func testManualShimOwnershipIsRechecked() throws {
        let root = try fixture()
        let home = try folder("home", in: root)
        let vendor = try folder(".fixture/bin", in: home)
        let shims = try folder(".local/bin", in: home)
        let program = vendor.appendingPathComponent("fixture")
        let unrelated = root.appendingPathComponent("unrelated")
        try write("program", to: program)
        try write("keep", to: unrelated)
        let shim = shims.appendingPathComponent("fixture")
        try FileManager.default.createSymbolicLink(at: shim, withDestinationURL: program)
        let selected = tool(paths: [vendor.path, shim.path], bins: ["fixture"])
        XCTAssertEqual(try CliUninstallExecutor.manualProgramPlan(selected, home: home.path).count, 2)
        try FileManager.default.removeItem(at: shim)
        try FileManager.default.createSymbolicLink(at: shim, withDestinationURL: unrelated)
        XCTAssertThrowsError(try CliUninstallExecutor.manualProgramPlan(selected, home: home.path))
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "keep")
    }

    func testManualPlanDoesNotInferSiblingDownloads() throws {
        let root = try fixture()
        let home = try folder("home", in: root)
        let program = try folder(".fixture/bin", in: home)
        let downloads = try folder(".fixture/downloads", in: home)
        let plan = try CliUninstallExecutor.manualProgramPlan(tool(paths: [program.path]), home: home.path)
        XCTAssertEqual(plan.map(\.path), [program.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloads.path))
    }

    func testRegularFileWithShimNameDoesNotProveOwnership() throws {
        let root = try fixture()
        let home = try folder("home", in: root)
        let vendor = try folder(".fixture/bin", in: home)
        let shims = try folder(".local/bin", in: home)
        let shim = shims.appendingPathComponent("fixture")
        try write("another program", to: shim)
        XCTAssertThrowsError(try CliUninstallExecutor.manualProgramPlan(tool(paths: [vendor.path], bins: ["fixture"]), home: home.path))
        XCTAssertEqual(try String(contentsOf: shim, encoding: .utf8), "another program")
    }

    func testFailedMainAppMoveKeepsResiduals() async throws {
        let root = try fixture()
        let main = root.appendingPathComponent("Missing-\(UUID().uuidString).app")
        let data = root.appendingPathComponent("data")
        try write("keep", to: data)
        var app = CleanableItem(name: "App", path: main.path, bytes: 1, category: .userCache, isSelected: false)
        var residual = CleanableItem(name: "Data", path: data.path, bytes: 4, category: .userCache, isSelected: false)
        app.isSelected = true
        residual.isSelected = true
        let result = await UninstallExecutor().trash(items: [residual, app], appBundlePath: main.path)
        XCTAssertEqual(result.cleanedCount, 0)
        XCTAssertTrue(result.errors.contains { $0.hasPrefix("uninstall_data_preserved:") })
        XCTAssertEqual(try String(contentsOf: data, encoding: .utf8), "keep")
    }

    func testLaunchAgentRequiresFreshExactLabelAndProgramOwner() throws {
        let root = try fixture()
        let home = try folder("home", in: root)
        let agents = try folder("Library/LaunchAgents", in: home)
        let program = root.appendingPathComponent("program")
        try write("program", to: program)
        let path = agents.appendingPathComponent("agent.plist")
        let selected = tool(paths: [program.path])
        let agent = CliLaunchAgentInfo(label: "fixture.agent", plistPath: path.path, running: false)
        func plist(_ label: String, _ executable: String) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: ["Label": label, "ProgramArguments": [executable]], format: .xml, options: 0)
            try data.write(to: path)
        }
        try plist(agent.label, program.path)
        XCTAssertNoThrow(try CliOwnershipBoundary.validateAgent(agent, tool: selected, home: home.path))
        try plist("different.agent", program.path)
        XCTAssertThrowsError(try CliOwnershipBoundary.validateAgent(agent, tool: selected, home: home.path))
        try plist(agent.label, "/usr/bin/true")
        XCTAssertThrowsError(try CliOwnershipBoundary.validateAgent(agent, tool: selected, home: home.path))
    }

    func testDanglingLinkDoesNotCountAsAbsentProgram() throws {
        let root = try fixture()
        let link = root.appendingPathComponent("shim")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: root.appendingPathComponent("missing").path)
        XCTAssertFalse(UninstallFileBoundary.isMissing(link.path))
    }
}
