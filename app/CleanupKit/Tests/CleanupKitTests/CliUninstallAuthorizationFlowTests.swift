import Foundation
import XCTest
@testable import CleanupKit

final class CliUninstallAuthorizationFlowTests: XCTestCase {
    private actor Calls {
        private(set) var paths: [String] = []
        func append(_ path: String) { paths.append(path) }
    }

    private func tool(programs: [String] = [], data: [String] = []) -> CliTool {
        CliTool(id: "fixture", displayName: "Fixture", channel: .manual, packageId: "fixture",
                programPaths: programs, programBytes: 0,
                dataDirs: data.map { .init(path: $0, bytes: 1) }, agents: [], bins: [], protected: false)
    }

    private func assertDataStops(after code: String) async {
        let paths = ["/fixture-only/first", "/fixture-only/second"]
        let calls = Calls()
        let result = await CliUninstallExecutor.execute(
            tool: tool(data: paths),
            options: .init(stopAgents: false, uninstallProgram: false, trashDataDirs: true),
            execution: .init(program: { _ in XCTFail("Program was not selected"); return ([], [], false) },
                             footprintGone: { _ in false }, trash: { path, _ in
                await calls.append(path)
                return ([], [code + ":" + path], [], 0)
            }))
        let recorded = await calls.paths
        XCTAssertEqual(recorded, [paths[0]])
        XCTAssertEqual(result.errors, [code + ":" + paths[0]])
        XCTAssertTrue(result.trashedPaths.isEmpty)
    }

    func testDataAuthorizationCancellationDoesNotPromptForFollowingItems() async {
        await assertDataStops(after: "uninstall_authorization_cancelled")
    }

    func testUnknownSystemTrashResultStopsFollowingData() async {
        await assertDataStops(after: "uninstall_system_result_unknown")
    }

    func testSuccessfulDataCallbacksStillProcessEverySelectedItem() async {
        let paths = ["/fixture-only/first", "/fixture-only/second"]
        let calls = Calls()
        let result = await CliUninstallExecutor.execute(
            tool: tool(data: paths),
            options: .init(stopAgents: false, uninstallProgram: false, trashDataDirs: true),
            execution: .init(program: { _ in XCTFail("Program was not selected"); return ([], [], false) },
                             footprintGone: { _ in false }, trash: { path, bytes in
                await calls.append(path)
                return (["fixture callback"], [], [path], bytes)
            }))
        let recorded = await calls.paths
        XCTAssertEqual(recorded, paths)
        XCTAssertEqual(result.trashedPaths, paths)
        XCTAssertEqual(result.movedToTrashBytes, 2)
        XCTAssertTrue(result.ok)
    }

    func testManualProgramStopsAfterCancellationOrUnknownResultWithoutMovingFixtureFiles() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("CliAuthorization-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [root.appendingPathComponent("first"), root.appendingPathComponent("second")]
        for file in files { try Data("fixture only".utf8).write(to: file) }
        let selected = tool(programs: files.map(\.path))
        for code in ["uninstall_authorization_cancelled", "uninstall_system_result_unknown"] {
            let calls = Calls()
            let result = await CliUninstallExecutor.uninstallManualProgram(selected, home: root.path) { source in
                await calls.append(source.path)
                return ([], [code + ":" + source.path], [], 0)
            }
            let recorded = await calls.paths
            XCTAssertEqual(recorded.count, 1)
            XCTAssertFalse(result.ok)
            XCTAssertEqual(result.errors.count, 1)
            XCTAssertTrue(result.errors[0].hasPrefix(code + ":"))
            for file in files { XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "fixture only") }
        }
    }
}
