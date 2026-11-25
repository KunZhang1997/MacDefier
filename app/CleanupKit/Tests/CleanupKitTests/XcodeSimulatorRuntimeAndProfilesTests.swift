import Foundation
import XCTest
@testable import CleanupKit

final class XcodeSimulatorRuntimeAndProfilesTests: XCTestCase {
    private var root: URL!
    private var home: String { root.appendingPathComponent("Home").path }
    private var trash: String { root.appendingPathComponent("FixtureTrash").path }
    private let idle = AIToolCleanupGuard(processState: { _ in .idle }, openFileState: { _ in .idle })

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AIProfiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ relative: String, contents: String = "fixture") throws -> String {
        let path = home + "/" + relative
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path,
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    func testWorkBuddyChatGPTVSCodeAntigravityAndXcodeProtectDurableDataWhileCleaningCaches() async throws {
        // Durable user treasures that MUST NEVER be scanned or deleted as cache:
        let memory = try write(".workbuddy/MEMORY.md", contents: "precious memory")
        let soul = try write(".workbuddy/SOUL.md", contents: "soul")
        let userMd = try write(".workbuddy/USER.md", contents: "user")
        let chatgptTask = try write("Library/Application Support/com.openai.chat/codex-taskDetails-v1-abc/state.json")
        let chatgptWebKit = try write("Library/WebKit/com.openai.chat/WebsiteData/IndexedDB/session.db")
        let agyBrain = try write(".gemini/antigravity/brain/conv-1/plan.md")
        let agyConv = try write(".gemini/antigravity/conversations/conv-1.pb")
        let vscodeSettings = try write("Library/Application Support/Code/User/settings.json")
        let xcodeDevices = try write("Library/Developer/CoreSimulator/Devices/device-1/data/keep")

        // Safe rebuildable leaves:
        let wbCache = try write(".workbuddy/cache/blob.bin")
        let gptCache = try write("Library/Caches/com.openai.chat/fsCachedData/chunk")
        let agyCache = try write(".gemini/antigravity/cache/index.bin")
        let vsCache = try write("Library/Application Support/Code/CachedData/v1/cache.bin")
        let xcodeDS = try write("Library/Developer/Xcode/iOS DeviceSupport/18.6 (22G86)/Symbols/sym")

        let inv = AIToolCleanupScanner.scan(home: home, cliInventory: [], cleanupGuard: idle)
        let candidatePaths = Set(inv.candidates.map(\.path))

        // Verify caches found
        XCTAssertTrue(candidatePaths.contains(home + "/.workbuddy/cache"))
        XCTAssertTrue(candidatePaths.contains(home + "/Library/Caches/com.openai.chat/fsCachedData"))
        XCTAssertTrue(candidatePaths.contains(home + "/.gemini/antigravity/cache"))
        XCTAssertTrue(candidatePaths.contains(home + "/Library/Application Support/Code/CachedData"))
        XCTAssertTrue(candidatePaths.contains(home + "/Library/Developer/Xcode/iOS DeviceSupport"))

        // Verify none of the durable files or parents are in candidates
        for protectedPath in [memory, soul, userMd, chatgptTask, chatgptWebKit, agyBrain, agyConv, vscodeSettings, xcodeDevices] {
            XCTAssertFalse(inv.candidates.contains { protectedPath.hasPrefix($0.path + "/") || $0.path == protectedPath })
            XCTAssertEqual(idle.blockingReason(for: protectedPath, home: home), "dedicated_preview_required")
        }

        // Execute cleanup into fixture Trash and confirm durable files stay untouched
        let destination = trash
        let exec = AIToolCleanupExecutor.Execution(
            cleanupGuard: idle,
            recycle: { try UninstallFileBoundary.move($0.boundary, toTrashDirectory: destination) }
        )
        let res = await AIToolCleanupExecutor.execute(candidates: inv.candidates, home: home, execution: exec)
        XCTAssertEqual(res.cleanedCount, 5)
        XCTAssertTrue(res.errors.isEmpty)

        for protectedPath in [memory, soul, userMd, chatgptTask, chatgptWebKit, agyBrain, agyConv, vscodeSettings, xcodeDevices] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: protectedPath))
        }
        for cleanedLeaf in [wbCache, gptCache, agyCache, vsCache, xcodeDS] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: cleanedLeaf))
        }

        // Ensure generic word "code" or "chatgpt" in unrelated CLI arguments does NOT falsely lock VS Code / ChatGPT
        XCTAssertFalse(AIToolCleanupGuard.matches(tool: .vscode, command: "git commit -m fix code issue"))
        XCTAssertFalse(AIToolCleanupGuard.matches(tool: .chatgpt, command: "python3 analyze.py chatgpt"))
        XCTAssertTrue(AIToolCleanupGuard.matches(tool: .vscode, bundleID: "com.microsoft.VSCode", command: "Electron"))
        XCTAssertTrue(AIToolCleanupGuard.matches(tool: .workbuddy, bundleID: "com.tencent.workbuddy.mac", command: "WorkBuddy"))
        XCTAssertTrue(AIToolCleanupGuard.matches(tool: .cursor, bundleID: "com.todesktop.230313mzl4w4u92", command: "Cursor"))
        XCTAssertTrue(AIToolCleanupGuard.matches(tool: .xcode, command: "/Library/Developer/CoreSimulator/Volumes/iOS_22G86/SpringBoard"))
        XCTAssertTrue(AIToolCleanupGuard.matches(tool: .xcode, command: "/Applications/Xcode-16.2.app/Contents/Developer/usr/bin/simctl"))

        // OpenAI unified ChatGPT.app (`com.openai.codex`) must lock BOTH `.codex` and `.chatgpt`
        XCTAssertTrue(AIToolCleanupGuard.matches(tool: .codex, bundleID: "com.openai.codex", command: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"))
        XCTAssertTrue(AIToolCleanupGuard.matches(tool: .chatgpt, bundleID: "com.openai.codex", command: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"))

        // Explicit orphan removal check allows idle leftover directories while blocking active ones
        let orphanClaw = try write(".openclaw/config.json")
        let orphanDir = home + "/.openclaw"
        let orphanSnap = try UninstallFileBoundary.snapshot(orphanDir)
        XCTAssertNil(idle.blockingReasonForExplicitRemoval(orphanSnap, home: home))
        let busyClaw = AIToolCleanupGuard(processState: { $0 == .openclaw ? .inUse : .idle }, openFileState: { _ in .idle })
        XCTAssertEqual(busyClaw.blockingReasonForExplicitRemoval(orphanSnap, home: home), "in_use")
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanClaw))
    }

    func testSimulatorRuntimeVerboseAndJSONParsingStatesAndExecution() async throws {
        let verboseSample = """
        iOS 27.1 (24A94425) - 1F2867E1-21E0-47F0-9192-C4A4FCA39326
            State: Ready
            Last Used At: 2026-11-15 17:30:19 +0000
            Size: 7.3G
        iOS 26.4 (23E244) - 3B9C7FC0-B78E-4DD8-BB96-2D1607F93AF2 (Deleting)
            State: Deleting
            Size: 7.9G
        iOS 27.0 (24A434) - AE5BC3D9-60F9-4662-BF7D-C13D5818DF05
            State: Ready
            Size: 7.5G
        """
        let parsed = XcodeSimulatorRuntimeInventory.parseVerboseText(verboseSample)
        XCTAssertEqual(parsed.count, 3)

        let jsonSample = """
        {
          "1F2867E1-21E0-47F0-9192-C4A4FCA39326": {
            "identifier": "1F2867E1-21E0-47F0-9192-C4A4FCA39326",
            "platformIdentifier": "com.apple.platform.iphonesimulator",
            "version": "27.1",
            "build": "24A94425",
            "state": "Ready",
            "sizeBytes": 7300000000,
            "deletable": true,
            "lastUsedAt": "2026-11-15T17:30:19Z"
          },
          "3B9C7FC0-B78E-4DD8-BB96-2D1607F93AF2": {
            "identifier": "3B9C7FC0-B78E-4DD8-BB96-2D1607F93AF2",
            "platformIdentifier": "com.apple.platform.iphonesimulator",
            "version": "26.4",
            "build": "23E244",
            "state": "Deleting",
            "sizeBytes": 7900000000,
            "deletable": true
          },
          "BUNDLED0-0000-0000-0000-000000000000": {
            "identifier": "11111111-2222-3333-4444-555555555555",
            "version": "18.0",
            "build": "22A1",
            "state": "Ready",
            "sizeBytes": 8000000000,
            "deletable": false,
            "kind": "bundled"
          },
          "evil": {
            "identifier": "not-a-uuid; rm -rf /",
            "state": "Ready",
            "sizeBytes": 5000000000
          }
        }
        """.data(using: .utf8)!

        final class MockSimctlState: @unchecked Sendable {
            let lock = NSLock()
            var isDeleting = false
            var deletedIDs: [String] = []
            func reset() {
                lock.lock()
                isDeleting = false
                deletedIDs.removeAll()
                lock.unlock()
            }
        }
        let simState = MockSimctlState()

        let env = XcodeSimulatorRuntimeInventory.Environment(
            isInstalled: { true },
            runSimctl: { args, _ in
                if args == ["runtime", "list", "-j"] {
                    simState.lock.lock()
                    let deleting = simState.isDeleting
                    simState.lock.unlock()
                    if deleting {
                        let after = """
                        {
                          "1F2867E1-21E0-47F0-9192-C4A4FCA39326": {
                            "identifier": "1F2867E1-21E0-47F0-9192-C4A4FCA39326",
                            "version": "27.1",
                            "build": "24A94425",
                            "state": "Deleting",
                            "sizeBytes": 7300000000,
                            "deletable": true
                          }
                        }
                        """.data(using: .utf8)!
                        return ProcessRunResult(exitCode: 0, stdout: after, stderr: Data(), timedOut: false, wasCancelled: false, outputLimitExceeded: false)
                    }
                    return ProcessRunResult(exitCode: 0, stdout: jsonSample, stderr: Data(), timedOut: false, wasCancelled: false, outputLimitExceeded: false)
                }
                if args.count == 3, args[0] == "runtime", args[1] == "delete" {
                    simState.lock.lock()
                    simState.deletedIDs.append(args[2])
                    simState.isDeleting = true
                    simState.lock.unlock()
                    return ProcessRunResult(exitCode: 0, stdout: Data(), stderr: Data(), timedOut: false, wasCancelled: false, outputLimitExceeded: false)
                }
                return nil
            }
        )

        let inv = XcodeSimulatorRuntimeInventory.scan(cleanupGuard: idle, environment: env)
        XCTAssertEqual(inv.candidates.count, 3, "Malicious non-UUID entry must be ignored")

        let readyItem = try XCTUnwrap(inv.candidates.first { $0.metadata["version"] == "27.1" })
        let deletingItem = try XCTUnwrap(inv.candidates.first { $0.metadata["version"] == "26.4" })
        let bundledItem = try XCTUnwrap(inv.candidates.first { $0.metadata["version"] == "18.0" })

        XCTAssertTrue(readyItem.canSelect)
        XCTAssertEqual(readyItem.dataSection, .devRuntimes)
        XCTAssertEqual(readyItem.bytes, 7_300_000_000)

        XCTAssertFalse(deletingItem.canSelect)
        XCTAssertEqual(deletingItem.reason, "runtime_deleting")

        XCTAssertFalse(bundledItem.canSelect)
        XCTAssertEqual(bundledItem.reason, "xcode_bundled_runtime")

        // When Xcode/Simulator is running, ready runtimes become .inUse and cannot be selected
        let busyXcode = AIToolCleanupGuard(processState: { $0 == .xcode ? .inUse : .idle }, openFileState: { _ in .idle })
        let busyInv = XcodeSimulatorRuntimeInventory.scan(cleanupGuard: busyXcode, environment: env)
        XCTAssertTrue(busyInv.candidates.allSatisfy { !$0.canSelect })

        // Execute deletion via AIToolCleanupExecutor -> records freedBytes (not movedToTrashBytes!)
        let exec = AIToolCleanupExecutor.Execution(
            cleanupGuard: idle,
            runtimeProof: { XcodeSimulatorRuntimeInventory.validateRuntime($0, environment: env) },
            deleteRuntime: { XcodeSimulatorRuntimeInventory.deleteRuntime($0, environment: env) }
        )
        let result = await AIToolCleanupExecutor.execute(candidates: [readyItem], home: home, execution: exec)
        XCTAssertEqual(result.cleanedCount, 1)
        XCTAssertEqual(result.freedBytes, 7_300_000_000)
        XCTAssertEqual(result.movedToTrashBytes, 0, "simctl runtime delete does not move to Trash")
        XCTAssertEqual(simState.deletedIDs, ["1F2867E1-21E0-47F0-9192-C4A4FCA39326"])

        // Duplicate runtime candidate in a single batch must be rejected without double-counting freedBytes
        simState.reset()
        let dupResult = await AIToolCleanupExecutor.execute(candidates: [readyItem, readyItem], home: home, execution: exec)
        XCTAssertEqual(dupResult.cleanedCount, 1)
        XCTAssertEqual(dupResult.freedBytes, 7_300_000_000)
        XCTAssertEqual(dupResult.errors.count, 1)
    }

    func testFractionalISO8601UnmountingWrapperFallbackAndLargeDirectoryBudget() throws {
        // 1. Wrapper JSON object unknown to parser returns nil so `fetchEntries` falls back to `-v`
        let unknownWrapper = #"{"runtimes": []}"#.data(using: .utf8)!
        XCTAssertNil(XcodeSimulatorRuntimeInventory.parseJSON(unknownWrapper))

        // 2. Fractional ISO8601 date + Unmounting state
        let fracJSON = """
        {
          "AA11BB22-3344-5566-7788-99AABBCCDDEE": {
            "identifier": "AA11BB22-3344-5566-7788-99AABBCCDDEE",
            "version": "18.2",
            "build": "22C150",
            "state": "Ready",
            "sizeBytes": 6100000000,
            "deletable": true,
            "lastUsedAt": "2026-11-15T17:30:19.123Z"
          },
          "BB22CC33-4455-6677-8899-AABBCCDDEEFF": {
            "identifier": "BB22CC33-4455-6677-8899-AABBCCDDEEFF",
            "version": "18.1",
            "build": "22B81",
            "state": "Unmounting",
            "sizeBytes": 6000000000,
            "deletable": true
          }
        }
        """.data(using: .utf8)!
        let parsed = try XCTUnwrap(XcodeSimulatorRuntimeInventory.parseJSON(fracJSON))
        XCTAssertEqual(parsed.count, 2)
        let fracEntry = try XCTUnwrap(parsed.first { $0.version == "18.2" })
        XCTAssertNotNil(fracEntry.lastUsedAt, "Fractional-second ISO8601 timestamp must parse")
        XCTAssertTrue(fracEntry.hasRawLastUsedAt)
        let unmountEntry = try XCTUnwrap(parsed.first { $0.version == "18.1" })
        XCTAssertTrue(unmountEntry.isDeleting, "Unmounting state must be treated as background deletion")

        // 3. Multi-folder >6,000-entry Xcode DeviceSupport directory stays ready & sizeComplete under 100k budget
        let dsBase = home + "/Library/Developer/Xcode/iOS DeviceSupport/18.6 (22G86)/Symbols"
        try FileManager.default.createDirectory(atPath: dsBase, withIntermediateDirectories: true)
        for idx in 0..<6_100 {
            let file = dsBase + "/sym_\(idx).dylib"
            FileManager.default.createFile(atPath: file, contents: Data("abcd".utf8))
        }
        let inv = AIToolCleanupScanner.scan(home: home, cliInventory: [], cleanupGuard: idle)
        let dsCandidate = try XCTUnwrap(inv.candidates.first { $0.path == home + "/Library/Developer/Xcode/iOS DeviceSupport" })
        XCTAssertEqual(dsCandidate.state, .ready)
        XCTAssertEqual(dsCandidate.metadata["sizeComplete"], "true")
        XCTAssertTrue(dsCandidate.canSelect)
    }
}
