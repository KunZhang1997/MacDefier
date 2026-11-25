import Foundation
import XCTest
@testable import CleanupKit

final class UserLaunchAgentServiceTests: XCTestCase {
    private var root: URL!
    private var home: String { root.appendingPathComponent("Home").path }
    private var launchAgentsDir: String { home + "/Library/LaunchAgents" }
    private var trash: String { root.appendingPathComponent("FixtureTrash").path }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchAgents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func writePlist(name: String, dict: [String: Any]) throws -> String {
        let path = launchAgentsDir + "/" + name
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    func testScanFiltersProtectedAndSymlinksAndParsesKeepAliveDictAndInterpreterTargets() throws {
        let scriptPath = root.appendingPathComponent("daemon.js").path
        let nodePath = root.appendingPathComponent("node").path
        try Data("console.log(1)".utf8).write(to: URL(fileURLWithPath: scriptPath))
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: nodePath))

        // 1. Valid KeepAlive dictionary + node interpreter script
        _ = try writePlist(name: "com.maitian.daemon.plist", dict: [
            "Label": "com.maitian.daemon",
            "ProgramArguments": [nodePath, "--expose-gc", scriptPath],
            "KeepAlive": ["SuccessfulExit": false],
            "RunAtLoad": true,
        ])

        // 2. Broken orphan agent (missing target binary)
        _ = try writePlist(name: "org.example.orphan.plist", dict: [
            "Label": "org.example.orphan",
            "Program": root.appendingPathComponent("missing-bin").path,
            "RunAtLoad": true,
        ])

        // 3. Protected Apple & MacDefier plists must be skipped
        _ = try writePlist(name: "com.apple.something.plist", dict: [
            "Label": "com.apple.something",
            "Program": "/usr/bin/true",
        ])
        _ = try writePlist(name: "com.macdefier.helper.plist", dict: [
            "Label": "com.macdefier.helper",
            "Program": "/usr/bin/true",
        ])

        // 4. Malicious domain-injection label must be rejected
        _ = try writePlist(name: "evil.plist", dict: [
            "Label": "../system/com.apple.sshd",
            "Program": "/usr/bin/true",
        ])

        // 5. Symlink plist must be rejected
        let outside = root.appendingPathComponent("outside.plist").path
        let outsideData = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.outside.agent", "Program": nodePath],
            format: .xml,
            options: 0
        )
        try outsideData.write(to: URL(fileURLWithPath: outside))
        try FileManager.default.createSymbolicLink(
            atPath: launchAgentsDir + "/com.outside.agent.plist",
            withDestinationPath: outside
        )

        let listOut = """
        PID\tStatus\tLabel
        4242\t0\tcom.maitian.daemon
        -\t0\tcom.apple.Finder
        """
        let env = UserLaunchAgentService.Environment(
            runLaunchctl: { args, _ in
                guard args == ["list"] else { return nil }
                return ProcessRunResult(exitCode: 0, stdout: Data(listOut.utf8), stderr: Data(), timedOut: false, wasCancelled: false, outputLimitExceeded: false)
            }
        )

        let scan = UserLaunchAgentService.scan(home: home, environment: env)
        XCTAssertFalse(scan.probeFailed)
        XCTAssertEqual(scan.items.count, 2)

        let daemon = try XCTUnwrap(scan.items.first { $0.label == "com.maitian.daemon" })
        XCTAssertEqual(daemon.runState, .running)
        XCTAssertEqual(daemon.pid, 4242)
        XCTAssertTrue(daemon.isKeepAlive)
        XCTAssertTrue(daemon.targetExistsOnDisk)
        XCTAssertEqual(daemon.programPath, nodePath)
        XCTAssertEqual(daemon.targetPath, scriptPath)

        let orphan = try XCTUnwrap(scan.items.first { $0.label == "org.example.orphan" })
        XCTAssertEqual(orphan.runState, .paused)
        XCTAssertFalse(orphan.targetExistsOnDisk)

        // Verify parent-PID chain supervisor attribution (e.g. Chrome PID 9001 -> wrapper 5000 -> daemon 4242)
        let parentMap: [Int: Int] = [9001: 5000, 5000: 4242, 4242: 1]
        let sup = UserLaunchAgentService.findSupervisorService(
            forPID: 9001,
            in: scan.items,
            parentPIDProvider: { parentMap[$0] }
        )
        XCTAssertEqual(sup?.label, "com.maitian.daemon")
    }

    func testPauseResumeAndMoveToTrashPreserveSafetyAndDetectTampering() async throws {
        let binPath = root.appendingPathComponent("worker").path
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: binPath))
        let plistPath = try writePlist(name: "com.demo.worker.plist", dict: [
            "Label": "com.demo.worker",
            "Program": binPath,
            "KeepAlive": true,
        ])

        final class MockLaunchd: @unchecked Sendable {
            private let lock = NSLock()
            private var loadedPID: Int? = 7788
            private(set) var commands: [[String]] = []

            func record(_ args: [String]) {
                lock.lock()
                commands.append(args)
                if args.first == "bootout" {
                    loadedPID = nil
                } else if args.first == "bootstrap" {
                    loadedPID = 8899
                }
                lock.unlock()
            }

            func listOutput() -> String {
                lock.lock()
                let pid = loadedPID
                lock.unlock()
                if let pid {
                    return "PID\tStatus\tLabel\n\(pid)\t0\tcom.demo.worker\n"
                }
                return "PID\tStatus\tLabel\n"
            }
        }

        let mock = MockLaunchd()
        let destinationTrash = trash
        let env = UserLaunchAgentService.Environment(
            runLaunchctl: { args, _ in
                if args == ["list"] {
                    let out = mock.listOutput()
                    return ProcessRunResult(exitCode: 0, stdout: Data(out.utf8), stderr: Data(), timedOut: false, wasCancelled: false, outputLimitExceeded: false)
                }
                mock.record(args)
                return ProcessRunResult(exitCode: 0, stdout: Data(), stderr: Data(), timedOut: false, wasCancelled: false, outputLimitExceeded: false)
            },
            recycle: { try UninstallFileBoundary.move($0, toTrashDirectory: destinationTrash) }
        )

        // 1. Initial scan sees running PID 7788
        let initial = UserLaunchAgentService.scan(home: home, environment: env)
        let item = try XCTUnwrap(initial.items.first)
        XCTAssertEqual(item.runState, .running)
        XCTAssertEqual(item.pid, 7788)

        // 2. Pause stops service WITHOUT deleting the plist!
        let pauseRes = await UserLaunchAgentService.pause(item, home: home, environment: env)
        XCTAssertTrue(pauseRes.ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plistPath), "Pause must keep plist on disk")

        let afterPause = try XCTUnwrap(UserLaunchAgentService.scan(home: home, environment: env).items.first)
        XCTAssertEqual(afterPause.runState, .paused)

        // 3. Resume reloads service via bootstrap
        let resumeRes = await UserLaunchAgentService.resume(afterPause, home: home, environment: env)
        XCTAssertTrue(resumeRes.ok)
        let afterResume = try XCTUnwrap(UserLaunchAgentService.scan(home: home, environment: env).items.first)
        XCTAssertEqual(afterResume.runState, .running)
        XCTAssertEqual(afterResume.pid, 8899)

        // 4. In-place tampering after scan is caught and rejected before mutation!
        _ = try writePlist(name: "com.demo.worker.plist", dict: [
            "Label": "com.demo.worker",
            "Program": "/bin/echo",
            "ProgramArguments": ["/bin/echo", "modified-size-payload"],
        ])
        let tamperedRes = await UserLaunchAgentService.moveToTrash(afterResume, home: home, environment: env)
        XCTAssertFalse(tamperedRes.ok)
        XCTAssertEqual(tamperedRes.errorCode, "changed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plistPath))

        // 5.Rescanning fresh evidence allows clean bootout + move to Trash
        let rescanned = try XCTUnwrap(UserLaunchAgentService.scan(home: home, environment: env).items.first)
        let trashRes = await UserLaunchAgentService.moveToTrash(rescanned, home: home, environment: env)
        XCTAssertTrue(trashRes.ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistPath))
        XCTAssertNotNil(trashRes.trashedPath)
    }

    func testVersionedHomebrewLabelsInlineShellsDenoRunAndDuplicateLabelDisambiguation() async throws {
        let serverTS = root.appendingPathComponent("server.ts").path
        try Data("export {}".utf8).write(to: URL(fileURLWithPath: serverTS))

        // 1. Versioned Homebrew service (`@` in Label) + inline `zsh -lc` command starting with `/`
        let pgPlist = try writePlist(name: "homebrew.mxcl.postgresql@15.plist", dict: [
            "Label": "homebrew.mxcl.postgresql@15",
            "ProgramArguments": ["/bin/zsh", "-lc", "/usr/bin/true --port 5432"],
            "KeepAlive": true,
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: pgPlist))

        // 2. `deno run -A /path/server.ts` must resolve `server.ts`, NOT `"run"`
        _ = try writePlist(name: "com.demo.deno.plist", dict: [
            "Label": "com.demo.deno",
            "ProgramArguments": ["/bin/sh", "-c", "/usr/bin/true"],
        ])
        let denoParsed = UserLaunchAgentService.extractProgramAndTarget(from: [
            "ProgramArguments": ["/opt/homebrew/bin/deno", "run", "-A", serverTS]
        ])
        XCTAssertEqual(denoParsed.target, serverTS)

        let nodeRequireParsed = UserLaunchAgentService.extractProgramAndTarget(from: [
            "ProgramArguments": ["/opt/homebrew/bin/node", "-r", "dotenv/config", serverTS]
        ])
        XCTAssertEqual(nodeRequireParsed.target, serverTS)

        // 3. Duplicate `Label` across two plist files: `launchctl print` disambiguates the active one
        //    so trashing the unloaded duplicate does NOT bootout the active service!
        let activeBin = root.appendingPathComponent("active-bin").path
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: activeBin))
        let activeDupPath = try writePlist(name: "com.dup.service.plist", dict: [
            "Label": "com.dup.service",
            "Program": activeBin,
            "KeepAlive": true,
        ])
        let staleDupPath = try writePlist(name: "com.dup.service.old.plist", dict: [
            "Label": "com.dup.service",
            "Program": root.appendingPathComponent("deleted-bin").path,
        ])

        final class DupTracker: @unchecked Sendable {
            let lock = NSLock()
            var bootoutCalls: [[String]] = []
            func record(_ args: [String]) {
                lock.lock()
                bootoutCalls.append(args)
                lock.unlock()
            }
        }
        let tracker = DupTracker()
        let destinationTrash = trash
        let listOut = """
        PID\tStatus\tLabel
        1156\t0\thomebrew.mxcl.postgresql@15
        2200\t0\tcom.dup.service
        """
        let printDupOut = """
        gui/501/com.dup.service = {
            active count = 1
            path = \(activeDupPath)
            state = running
        }
        """

        let env = UserLaunchAgentService.Environment(
            runLaunchctl: { args, _ in
                if args == ["list"] {
                    return ProcessRunResult(exitCode: 0, stdout: Data(listOut.utf8), stderr: Data(), timedOut: false, wasCancelled: false, outputLimitExceeded: false)
                }
                if args.first == "print", args.last?.hasSuffix("/com.dup.service") == true {
                    return ProcessRunResult(exitCode: 0, stdout: Data(printDupOut.utf8), stderr: Data(), timedOut: false, wasCancelled: false, outputLimitExceeded: false)
                }
                if args.first == "bootout" {
                    tracker.record(args)
                }
                return ProcessRunResult(exitCode: 0, stdout: Data(), stderr: Data(), timedOut: false, wasCancelled: false, outputLimitExceeded: false)
            },
            recycle: { try UninstallFileBoundary.move($0, toTrashDirectory: destinationTrash) }
        )

        let scan = UserLaunchAgentService.scan(home: home, environment: env)
        let pg = try XCTUnwrap(scan.items.first { $0.label == "homebrew.mxcl.postgresql@15" })
        XCTAssertEqual(pg.displayName, "PostgreSQL 15")
        XCTAssertEqual(pg.runState, .running)
        XCTAssertTrue(pg.targetExistsOnDisk, "zsh -lc inline script must NOT be flagged as missing target file")
        XCTAssertNil(pg.targetPath)

        let activeDup = try XCTUnwrap(scan.items.first { $0.plistPath == activeDupPath })
        let staleDup = try XCTUnwrap(scan.items.first { $0.plistPath == staleDupPath })
        XCTAssertEqual(activeDup.runState, .running)
        XCTAssertEqual(staleDup.runState, .paused, "Unloaded duplicate plist must be marked paused via launchctl print path")
        XCTAssertFalse(staleDup.targetExistsOnDisk)

        // Trashing staleDup must NOT call bootout on the active service!
        let trashStale = await UserLaunchAgentService.moveToTrash(staleDup, home: home, environment: env)
        XCTAssertTrue(trashStale.ok)
        XCTAssertTrue(tracker.bootoutCalls.isEmpty, "Must not bootout active sibling owning the same Label")
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeDupPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleDupPath))
    }
}
