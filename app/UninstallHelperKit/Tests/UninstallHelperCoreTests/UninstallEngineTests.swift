import Darwin
import Foundation
import XCTest
@testable import UninstallHelperCore

final class UninstallEngineTests: XCTestCase {
    private struct Fixture {
        let root: URL
        var applications: URL { root.appendingPathComponent("Applications") }
        var home: URL { root.appendingPathComponent("home") }
        var trash: URL { home.appendingPathComponent(".Trash") }
        var anchor: URL { root.appendingPathComponent("protected") }
        var context: TrustedUninstallContext {
            .fixture(userUID: geteuid(), homeDirectory: home.path, applicationsDirectory: applications.path, stagingAnchor: anchor.path)
        }
        func transaction(_ request: UninstallRequest) -> URL {
            anchor.appendingPathComponent("fixture-helper/staging/" + request.requestID.uuidString)
        }
    }

    private func fixture() throws -> Fixture {
        // Explicit physical /private/tmp avoids Foundation's /var alias spelling.
        let value = Fixture(root: URL(fileURLWithPath: "/private/tmp/MacDefier-helper-fixture-" + UUID().uuidString))
        for directory in [value.root, value.applications, value.home, value.trash, value.anchor] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: value.root) }
        return value
    }

    @discardableResult
    private func app(_ url: URL, marker: String = "confirmed", identifier: String = "test.example.fixture") throws -> URL {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0)
        try plist.write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data(marker.utf8).write(to: url.appendingPathComponent("payload"))
        return url
    }
    private func marker(_ url: URL) throws -> String { try String(contentsOf: url.appendingPathComponent("payload"), encoding: .utf8) }
    private func journal(_ result: UninstallResult) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(result.journalPath)))) as? [String: Any])
    }
    private func emptyTrash(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path), [], file: file, line: line)
    }

    func testUnchangedApplicationMovesOnlyIntoTrustedUsersTrash() throws {
        let f = try fixture()
        let source = try app(f.applications.appendingPathComponent("Fixture.app"))
        let request = try UninstallEngine.captureRequest(sourcePath: source.path)
        let result = UninstallEngine.moveToTrash(request: request, context: f.context)
        XCTAssertEqual(result.disposition, .moved, result.reason ?? "")
        XCTAssertEqual(result.requestID, request.requestID)
        let destination = URL(fileURLWithPath: try XCTUnwrap(result.destinationPath))
        XCTAssertEqual(destination.deletingLastPathComponent().path, f.trash.path)
        XCTAssertEqual(try marker(destination), "confirmed")
        XCTAssertEqual(try UninstallEngine.captureRequest(sourcePath: destination.path).expectedItem, request.expectedItem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try journal(result)["state"] as? String, "moved")
    }

    func testReplacementWhileAuthorizationPendingIsRejectedWithoutMovement() throws {
        let f = try fixture()
        let source = try app(f.applications.appendingPathComponent("Fixture.app"))
        let request = try UninstallEngine.captureRequest(sourcePath: source.path)
        let saved = f.root.appendingPathComponent("confirmed.app")
        try FileManager.default.moveItem(at: source, to: saved)
        try app(source, marker: "replacement")
        let result = UninstallEngine.moveToTrash(request: request, context: f.context)
        XCTAssertEqual(result.disposition, .rejected)
        XCTAssertEqual(result.reason, "helper_source_identity_changed")
        XCTAssertEqual(try marker(source), "replacement")
        XCTAssertEqual(try marker(saved), "confirmed")
        try emptyTrash(f)
    }

    func testLeafReplacedAfterStatIsCapturedThenRestoredNotTrashed() throws {
        let f = try fixture()
        let source = try app(f.applications.appendingPathComponent("Fixture.app"))
        let saved = f.root.appendingPathComponent("confirmed.app")
        let request = try UninstallEngine.captureRequest(sourcePath: source.path)
        let result = UninstallEngine.moveToTrash(request: request, context: f.context, hooks: .init(beforeCapture: {
            try FileManager.default.moveItem(at: source, to: saved)
            try self.app(source, marker: "replacement")
        }))
        XCTAssertEqual(result.disposition, .recoveredOriginal)
        XCTAssertEqual(result.reason, "helper_source_identity_changed")
        XCTAssertEqual(try marker(source), "replacement")
        XCTAssertEqual(try marker(saved), "confirmed")
        XCTAssertEqual(try journal(result)["state"] as? String, "recovered_original")
        try emptyTrash(f)
    }

    func testWrongCapturedObjectAndRollbackConflictPreserveAllThreeObjects() throws {
        let f = try fixture()
        let source = try app(f.applications.appendingPathComponent("Fixture.app"))
        let saved = f.root.appendingPathComponent("confirmed.app")
        let request = try UninstallEngine.captureRequest(sourcePath: source.path)
        let result = UninstallEngine.moveToTrash(request: request, context: f.context, hooks: .init(beforeCapture: {
            try FileManager.default.moveItem(at: source, to: saved)
            try self.app(source, marker: "wrong-captured-object")
        }, afterCapture: {
            try self.app(source, marker: "new-object-at-original-path")
        }))
        XCTAssertEqual(result.disposition, .retainedStaging)
        XCTAssertEqual(result.reason, "helper_source_identity_changed")
        XCTAssertEqual(try marker(source), "new-object-at-original-path")
        XCTAssertEqual(try marker(saved), "confirmed")
        XCTAssertEqual(try marker(URL(fileURLWithPath: XCTUnwrap(result.recoveryPath))), "wrong-captured-object")
        XCTAssertEqual(try journal(result)["state"] as? String, "retained_staging")
        try emptyTrash(f)
    }

    func testReinstallationBeforeCommitKeepsNewAppAndRetainsConfirmedApp() throws {
        let f = try fixture()
        let source = try app(f.applications.appendingPathComponent("Fixture.app"))
        let request = try UninstallEngine.captureRequest(sourcePath: source.path)
        let result = UninstallEngine.moveToTrash(request: request, context: f.context, hooks: .init(beforeCommit: {
            try self.app(source, marker: "reinstalled")
        }))
        XCTAssertEqual(result.disposition, .retainedStaging)
        XCTAssertEqual(result.reason, "helper_source_reappeared")
        XCTAssertEqual(try marker(source), "reinstalled")
        XCTAssertEqual(try marker(URL(fileURLWithPath: XCTUnwrap(result.recoveryPath))), "confirmed")
        try emptyTrash(f)
    }

    func testParentReplacementBeforeCommitRetainsStagingInsteadOfRestoringIntoWrongParent() throws {
        let f = try fixture()
        let source = try app(f.applications.appendingPathComponent("Fixture.app"))
        let request = try UninstallEngine.captureRequest(sourcePath: source.path)
        let oldParent = f.root.appendingPathComponent("old-applications")
        let result = UninstallEngine.moveToTrash(request: request, context: f.context, hooks: .init(beforeCommit: {
            try FileManager.default.moveItem(at: f.applications, to: oldParent)
            try self.app(source, marker: "new-parent-app")
        }))
        XCTAssertEqual(result.disposition, .retainedStaging)
        XCTAssertEqual(result.reason, "helper_directory_binding_changed")
        XCTAssertEqual(try marker(source), "new-parent-app")
        XCTAssertEqual(try marker(URL(fileURLWithPath: XCTUnwrap(result.recoveryPath))), "confirmed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: oldParent.path), [])
        try emptyTrash(f)
    }

    func testTrashReplacementBeforeCommitRestoresSourceAndNeverFollowsSymlink() throws {
        let f = try fixture()
        let source = try app(f.applications.appendingPathComponent("Fixture.app"))
        let request = try UninstallEngine.captureRequest(sourcePath: source.path)
        let oldTrash = f.home.appendingPathComponent("old-trash")
        let outside = f.root.appendingPathComponent("other-directory")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let result = UninstallEngine.moveToTrash(request: request, context: f.context, hooks: .init(beforeCommit: {
            try FileManager.default.moveItem(at: f.trash, to: oldTrash)
            try FileManager.default.createSymbolicLink(at: f.trash, withDestinationURL: outside)
        }))
        XCTAssertEqual(result.disposition, .recoveredOriginal)
        XCTAssertEqual(try marker(source), "confirmed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: oldTrash.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testTrashReplacedInFinalRenameWindowReturnsCommittedUnknownWithoutRollback() throws {
        let f = try fixture()
        let source = try app(f.applications.appendingPathComponent("Fixture.app"))
        let request = try UninstallEngine.captureRequest(sourcePath: source.path)
        let originalTrashIdentity = try UninstallEngine.captureRequest(sourcePath: f.trash.path).expectedItem
        let renamedTrash = f.home.appendingPathComponent("renamed-original-trash")
        let result = UninstallEngine.moveToTrash(request: request, context: f.context, hooks: .init(immediatelyBeforeCommitRename: {
            try FileManager.default.moveItem(at: f.trash, to: renamedTrash)
            try FileManager.default.createDirectory(at: f.trash, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }))
        XCTAssertEqual(result.disposition, .committedUnknown)
        XCTAssertNil(result.destinationPath, "Do not report the new .Trash as the completed destination")
        XCTAssertNil(result.recoveryPath, "Committed item must not be described as still staged")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "No rollback of a committed entry")
        XCTAssertEqual(try marker(renamedTrash.appendingPathComponent("Fixture.app")), "confirmed")
        try emptyTrash(f)
        let record = try journal(result)
        XCTAssertEqual(record["state"] as? String, "committed_unknown")
        XCTAssertEqual(record["destinationName"] as? String, "Fixture.app")
        let savedIdentity = try JSONDecoder().decode(UninstallFileIdentity.self,
                                                     from: JSONSerialization.data(withJSONObject: XCTUnwrap(record["originalTrashIdentity"])))
        XCTAssertEqual(savedIdentity, originalTrashIdentity)
    }

    func testExistingTrashNameNeverOverwritten() throws {
        let f = try fixture()
        let source = try app(f.applications.appendingPathComponent("Fixture.app"))
        let existing = try app(f.trash.appendingPathComponent("Fixture.app"), marker: "previous-trash-item")
        let result = UninstallEngine.moveToTrash(request: try UninstallEngine.captureRequest(sourcePath: source.path), context: f.context)
        XCTAssertEqual(result.disposition, .moved)
        XCTAssertNotEqual(result.destinationPath, existing.path)
        XCTAssertEqual(try marker(existing), "previous-trash-item")
        XCTAssertEqual(try marker(URL(fileURLWithPath: XCTUnwrap(result.destinationPath))), "confirmed")
    }

    func testSourceParentSymlinkIsRejected() throws {
        let f = try fixture()
        let source = try app(f.applications.appendingPathComponent("Fixture.app"))
        let request = try UninstallEngine.captureRequest(sourcePath: source.path)
        let old = f.root.appendingPathComponent("real-applications")
        try FileManager.default.moveItem(at: f.applications, to: old)
        try FileManager.default.createSymbolicLink(at: f.applications, withDestinationURL: old)
        let result = UninstallEngine.moveToTrash(request: request, context: f.context)
        XCTAssertEqual(result.disposition, .rejected)
        XCTAssertEqual(try marker(old.appendingPathComponent("Fixture.app")), "confirmed")
        try emptyTrash(f)
    }

    func testPreexistingTrashSymlinkAndWorldWritableStagingAreRejected() throws {
        let f = try fixture()
        let source = try app(f.applications.appendingPathComponent("Fixture.app"))
        let request = try UninstallEngine.captureRequest(sourcePath: source.path)
        let old = f.home.appendingPathComponent("real-trash")
        try FileManager.default.moveItem(at: f.trash, to: old)
        try FileManager.default.createSymbolicLink(at: f.trash, withDestinationURL: old)
        XCTAssertEqual(UninstallEngine.moveToTrash(request: request, context: f.context).disposition, .rejected)
        try FileManager.default.removeItem(at: f.trash)
        try FileManager.default.moveItem(at: old, to: f.trash)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: f.anchor.path)
        let result = UninstallEngine.moveToTrash(request: request, context: f.context)
        XCTAssertEqual(result.disposition, .rejected)
        XCTAssertEqual(result.reason, "helper_directory_unsafe")
        XCTAssertEqual(try marker(source), "confirmed")
        try emptyTrash(f)
    }

    func testSymlinkLeafNestedApplicationAndCLIFileNeverReachStaging() throws {
        let f = try fixture()
        let target = try app(f.root.appendingPathComponent("target.app"))
        let link = f.applications.appendingPathComponent("Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let nested = try app(f.applications.appendingPathComponent("Nested/Other.app"))
        let cli = f.applications.appendingPathComponent("codex")
        try Data("keep".utf8).write(to: cli)
        for source in [link, nested, cli] {
            let result = UninstallEngine.moveToTrash(request: try UninstallEngine.captureRequest(sourcePath: source.path), context: f.context)
            XCTAssertEqual(result.disposition, .rejected)
            XCTAssertNil(result.transactionID)
        }
        XCTAssertEqual(try marker(target), "confirmed")
        XCTAssertEqual(try marker(nested), "confirmed")
        try emptyTrash(f)
    }

    func testAppleAndMacDefierApplicationsAreProtected() throws {
        let f = try fixture()
        for (name, identifier) in [("Apple.app", "com.apple.fixture"), ("Renamed.app", "com.macdefier.app.dev"),
                                    ("MacDefier-Fake.app", "test.other")] {
            let source = try app(f.applications.appendingPathComponent(name), identifier: identifier)
            let result = UninstallEngine.moveToTrash(request: try UninstallEngine.captureRequest(sourcePath: source.path), context: f.context)
            XCTAssertEqual(result.disposition, .rejected)
            XCTAssertEqual(result.reason, "helper_protected_application")
            XCTAssertEqual(try marker(source), "confirmed")
        }
        try emptyTrash(f)
    }

    func testPreparedJournalExistsBeforeCaptureAndSameRequestIsNotReplayed() throws {
        enum Stop: Error { case fixture }
        let f = try fixture()
        let source = try app(f.applications.appendingPathComponent("Fixture.app"))
        let request = try UninstallEngine.captureRequest(sourcePath: source.path)
        let result = UninstallEngine.moveToTrash(request: request, context: f.context, hooks: .init(beforeCapture: {
            let path = f.transaction(request).appendingPathComponent("journal.json")
            let journal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            XCTAssertEqual(journal["state"] as? String, "prepared")
            XCTAssertEqual((journal["request"] as? [String: Any])?["requestID"] as? String, request.requestID.uuidString)
            let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.uint16Value, 0o600)
            XCTAssertEqual((attrs[.ownerAccountID] as? NSNumber)?.uint32Value, geteuid())
            throw Stop.fixture
        }))
        XCTAssertEqual(result.disposition, .rejected)
        let replay = UninstallEngine.moveToTrash(request: request, context: f.context)
        XCTAssertEqual(replay.disposition, .rejected)
        XCTAssertEqual(replay.errno, EEXIST)
        XCTAssertEqual(try marker(source), "confirmed")
        try emptyTrash(f)
    }

    func testInterruptedPreparedTransactionRetainsItemAndJournalWithoutAutomaticReplay() throws {
        let f = try fixture()
        let source = try app(f.applications.appendingPathComponent("Fixture.app"))
        let request = try UninstallEngine.captureRequest(sourcePath: source.path)
        // Reconstruct the on-disk state at a process interruption immediately after
        // capture: no process is killed and no real Applications or Trash is used.
        let staging = try FileOperations.prepareStaging(f.context)
        let transaction = try Transaction.create(in: staging, context: f.context, request: request)
        let parent = try FileOperations.openDirectory(f.applications.path)
        try FileOperations.renameExclusive(from: parent.fd, name: "Fixture.app", to: transaction.directory.fd, newName: "item")
        let result = UninstallEngine.moveToTrash(request: request, context: f.context)
        XCTAssertEqual(result.disposition, .rejected)
        XCTAssertEqual(try marker(f.transaction(request).appendingPathComponent("item")), "confirmed")
        let journal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.transaction(request).appendingPathComponent("journal.json"))) as? [String: Any])
        XCTAssertEqual(journal["state"] as? String, "prepared")
        try emptyTrash(f)
    }

    func testTrustedContextRejectsUnknownProductionService() {
        XCTAssertThrowsError(try TrustedUninstallContext.production(userUID: 501, homeDirectory: "/Users/fixture",
                                                                   serviceIdentifier: "client.selected.service"))
    }

    func testFIFOInfoPlistIsRejectedWithoutBlocking() throws {
        let f = try fixture()
        let source = try app(f.applications.appendingPathComponent("Fixture.app"))
        let plist = source.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.removeItem(at: plist)
        XCTAssertEqual(mkfifo(plist.path, 0o600), 0)
        let request = try UninstallEngine.captureRequest(sourcePath: source.path)
        let start = Date()
        let result = UninstallEngine.moveToTrash(request: request, context: f.context)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(result.disposition, .rejected)
        XCTAssertEqual(result.reason, "helper_application_metadata_invalid")
        XCTAssertEqual(try marker(source), "confirmed")
        try emptyTrash(f)
    }

    func testStagingAllowACLIsRejectedEvenWithPrivatePOSIXMode() throws {
        let f = try fixture()
        let source = try app(f.applications.appendingPathComponent("Fixture.app"))
        // chmod sees only this test-owned UUID fixture, never a real user directory.
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/bin/chmod")
        command.arguments = ["+a", "everyone allow add_file,add_subdirectory,delete_child", f.anchor.path]
        try command.run()
        command.waitUntilExit()
        XCTAssertEqual(command.terminationStatus, 0)
        let attributes = try FileManager.default.attributesOfItem(atPath: f.anchor.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.uint16Value, 0o700)
        let result = UninstallEngine.moveToTrash(request: try UninstallEngine.captureRequest(sourcePath: source.path), context: f.context)
        XCTAssertEqual(result.disposition, .rejected)
        XCTAssertEqual(result.reason, "helper_staging_acl_unsafe")
        XCTAssertEqual(try marker(source), "confirmed")
        try emptyTrash(f)
    }
}
