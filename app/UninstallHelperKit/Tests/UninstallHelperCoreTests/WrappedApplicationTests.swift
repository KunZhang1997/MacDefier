import Darwin
import Foundation
import XCTest
@testable import UninstallHelperCore

final class WrappedApplicationTests: XCTestCase {
    private struct Fixture {
        let root: URL
        var applications: URL { root.appendingPathComponent("Applications") }
        var home: URL { root.appendingPathComponent("home") }
        var trash: URL { home.appendingPathComponent(".Trash") }
        var anchor: URL { root.appendingPathComponent("protected") }
        var source: URL { applications.appendingPathComponent("WrappedFixture.app") }
        var wrapper: URL { source.appendingPathComponent("Wrapper") }
        var inner: URL { wrapper.appendingPathComponent("Fixture.app") }
        var wrappedLink: URL { source.appendingPathComponent("WrappedBundle") }
        var metadata: URL { inner.appendingPathComponent("Info.plist") }
        var executable: URL { inner.appendingPathComponent("Fixture") }
        var context: TrustedUninstallContext {
            .fixture(userUID: geteuid(), homeDirectory: home.path,
                     applicationsDirectory: applications.path, stagingAnchor: anchor.path)
        }
    }

    private func fixture() throws -> Fixture {
        let value = Fixture(root: URL(fileURLWithPath: "/private/tmp/MacDefier-wrapped-fixture-" + UUID().uuidString))
        for directory in [value.root, value.applications, value.home, value.trash, value.anchor, value.inner] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: value.root) }
        try writeMetadata(value.metadata)
        // Inert placeholder for the metadata's executable entry; never executed.
        try Data("fixture executable; never run\n".utf8).write(to: value.executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: value.executable.path)
        try Data("outer-wrapper-marker".utf8).write(to: value.source.appendingPathComponent("wrapper-marker"))
        try FileManager.default.createSymbolicLink(atPath: value.wrappedLink.path,
                                                   withDestinationPath: "Wrapper/Fixture.app")
        return value
    }

    private func writeMetadata(_ url: URL, mutate: (inout [String: Any]) -> Void = { _ in }) throws {
        var value: [String: Any] = [
            "CFBundlePackageType": "APPL", "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "CFBundleIdentifier": "com.fixture.wrapped", "CFBundleExecutable": "Fixture"
        ]
        mutate(&value)
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: url)
    }

    private func replaceWrappedLink(_ fixture: Fixture, destination: String) throws {
        try FileManager.default.removeItem(at: fixture.wrappedLink)
        try FileManager.default.createSymbolicLink(atPath: fixture.wrappedLink.path, withDestinationPath: destination)
    }

    private func assertRejectedWithoutMovement(_ fixture: Fixture,
                                               file: StaticString = #filePath, line: UInt = #line) throws {
        let request = try UninstallEngine.captureRequest(sourcePath: fixture.source.path)
        let result = UninstallEngine.moveToTrash(request: request, context: fixture.context)
        XCTAssertEqual(result.disposition, .rejected, result.reason ?? "", file: file, line: line)
        XCTAssertNil(result.transactionID, "Invalid structure must be rejected before staging", file: file, line: line)
        XCTAssertNil(result.destinationPath, file: file, line: line)
        XCTAssertEqual(try UninstallEngine.captureRequest(sourcePath: fixture.source.path).expectedItem,
                       request.expectedItem, file: file, line: line)
        XCTAssertEqual(try String(contentsOf: fixture.source.appendingPathComponent("wrapper-marker"), encoding: .utf8),
                       "outer-wrapper-marker", file: file, line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path), [], file: file, line: line)
    }

    func testValidWrappedApplicationMovesEntireOuterBundleAndPreservesIdentity() throws {
        let fixture = try fixture()
        let request = try UninstallEngine.captureRequest(sourcePath: fixture.source.path)
        let innerIdentity = try UninstallEngine.captureRequest(sourcePath: fixture.inner.path).expectedItem
        let result = UninstallEngine.moveToTrash(request: request, context: fixture.context)
        XCTAssertEqual(result.disposition, .moved, result.reason ?? "")
        let destination = URL(fileURLWithPath: try XCTUnwrap(result.destinationPath))
        XCTAssertEqual(destination.path, fixture.trash.appendingPathComponent("WrappedFixture.app").path)
        XCTAssertEqual(try UninstallEngine.captureRequest(sourcePath: destination.path).expectedItem, request.expectedItem)
        XCTAssertEqual(try UninstallEngine.captureRequest(sourcePath: destination.appendingPathComponent("Wrapper/Fixture.app").path).expectedItem,
                       innerIdentity)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("WrappedBundle").path),
                       "Wrapper/Fixture.app")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("wrapper-marker"), encoding: .utf8), "outer-wrapper-marker")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Wrapper/Fixture.app/Fixture").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
        let journal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(result.journalPath)))) as? [String: Any])
        XCTAssertEqual(journal["state"] as? String, "moved")
    }

    func testWrappedLinkCannotPointOutsideOuterBundle() throws {
        let fixture = try fixture()
        let outside = fixture.applications.appendingPathComponent("Outside.app")
        try FileManager.default.moveItem(at: fixture.inner, to: outside)
        let identity = try UninstallEngine.captureRequest(sourcePath: outside.path).expectedItem
        try replaceWrappedLink(fixture, destination: "../Outside.app")
        try assertRejectedWithoutMovement(fixture)
        XCTAssertEqual(try UninstallEngine.captureRequest(sourcePath: outside.path).expectedItem, identity)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("Fixture").path))
    }

    func testWrappedLinkRejectsAbsoluteTargetEvenInsideSameBundle() throws {
        let fixture = try fixture()
        try replaceWrappedLink(fixture, destination: fixture.inner.path)
        try assertRejectedWithoutMovement(fixture)
    }

    func testWrappedLinkRejectsParentTraversalEvenWhenItResolvesInsideBundle() throws {
        let fixture = try fixture()
        try replaceWrappedLink(fixture, destination: "Wrapper/../Wrapper/Fixture.app")
        try assertRejectedWithoutMovement(fixture)
    }

    func testWrapperDirectoryCannotBeSymlink() throws {
        let fixture = try fixture()
        let moved = fixture.root.appendingPathComponent("ActualWrapper")
        try FileManager.default.moveItem(at: fixture.wrapper, to: moved)
        try FileManager.default.createSymbolicLink(at: fixture.wrapper, withDestinationURL: moved)
        try assertRejectedWithoutMovement(fixture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("Fixture.app/Fixture").path))
    }

    func testInnerApplicationCannotBeSymlink() throws {
        let fixture = try fixture()
        let moved = fixture.root.appendingPathComponent("ActualInner.app")
        try FileManager.default.moveItem(at: fixture.inner, to: moved)
        try FileManager.default.createSymbolicLink(at: fixture.inner, withDestinationURL: moved)
        try assertRejectedWithoutMovement(fixture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("Fixture").path))
    }

    func testWrappedMetadataAndExecutableCannotBeSymlinks() throws {
        for useMetadata in [true, false] {
            let fixture = try fixture()
            let original = useMetadata ? fixture.metadata : fixture.executable
            let moved = fixture.root.appendingPathComponent("OutsideFile")
            try FileManager.default.moveItem(at: original, to: moved)
            let identity = try UninstallEngine.captureRequest(sourcePath: moved.path).expectedItem
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: moved)
            try assertRejectedWithoutMovement(fixture)
            XCTAssertEqual(try UninstallEngine.captureRequest(sourcePath: moved.path).expectedItem, identity)
        }
    }

    func testBrokenWrappedLinkIsRejected() throws {
        let fixture = try fixture()
        try replaceWrappedLink(fixture, destination: "Wrapper/Missing.app")
        try assertRejectedWithoutMovement(fixture)
    }

    func testWrappedLinkMustBeSymlinkRatherThanCopiedDirectory() throws {
        let fixture = try fixture()
        try FileManager.default.removeItem(at: fixture.wrappedLink)
        try FileManager.default.copyItem(at: fixture.inner, to: fixture.wrappedLink)
        try assertRejectedWithoutMovement(fixture)
    }

    func testWrappedMetadataMustDeclareIOSApplication() throws {
        let invalid: [(String, Any)] = [
            ("CFBundleSupportedPlatforms", ["MacOSX"]), ("CFBundleSupportedPlatforms", [String]()),
            ("CFBundleSupportedPlatforms", "iPhoneOS"), ("CFBundlePackageType", "BNDL")
        ]
        for (key, value) in invalid {
            let fixture = try fixture()
            try writeMetadata(fixture.metadata) { $0[key] = value }
            try assertRejectedWithoutMovement(fixture)
        }
    }

    func testWrappedAppleAndMacDefierIdentifiersRemainProtected() throws {
        for identifier in ["com.apple.fixture", "com.macdefier.app", "COM.APPLE.fixture", "COM.MACDEFIER.fixture"] {
            let fixture = try fixture()
            try writeMetadata(fixture.metadata) { $0["CFBundleIdentifier"] = identifier }
            try assertRejectedWithoutMovement(fixture)
        }
    }

    func testWrappedExecutableMustExistAndBeRegularFile() throws {
        for kind in ["missing", "directory"] {
            let fixture = try fixture()
            try FileManager.default.removeItem(at: fixture.executable)
            if kind == "directory" {
                try FileManager.default.createDirectory(at: fixture.executable, withIntermediateDirectories: false)
            }
            try assertRejectedWithoutMovement(fixture)
        }
    }

    func testContentsSymlinkCannotFallBackToOtherwiseValidWrapper() throws {
        let fixture = try fixture()
        let contents = fixture.root.appendingPathComponent("ExternalContents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: false)
        try writeMetadata(contents.appendingPathComponent("Info.plist"))
        try FileManager.default.createSymbolicLink(at: fixture.source.appendingPathComponent("Contents"), withDestinationURL: contents)
        try assertRejectedWithoutMovement(fixture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: contents.appendingPathComponent("Info.plist").path))
    }

    func testWrappedLinkChangedAfterCaptureRestoresOuterBundleInsteadOfTrashing() throws {
        let fixture = try fixture()
        let outside = fixture.root.appendingPathComponent("Outside.app")
        try FileManager.default.copyItem(at: fixture.inner, to: outside)
        let outsideIdentity = try UninstallEngine.captureRequest(sourcePath: outside.path).expectedItem
        let request = try UninstallEngine.captureRequest(sourcePath: fixture.source.path)
        let capturedLink = fixture.anchor.appendingPathComponent("fixture-helper/staging/\(request.requestID.uuidString)/item/WrappedBundle")
        let result = UninstallEngine.moveToTrash(request: request, context: fixture.context, hooks: .init(afterCapture: {
            try FileManager.default.removeItem(at: capturedLink)
            try FileManager.default.createSymbolicLink(at: capturedLink, withDestinationURL: outside)
        }))
        XCTAssertEqual(result.disposition, .recoveredOriginal, result.reason ?? "")
        XCTAssertNil(result.destinationPath)
        XCTAssertNil(result.recoveryPath)
        XCTAssertEqual(try UninstallEngine.captureRequest(sourcePath: fixture.source.path).expectedItem, request.expectedItem)
        XCTAssertEqual(try UninstallEngine.captureRequest(sourcePath: outside.path).expectedItem, outsideIdentity)
        XCTAssertEqual(try String(contentsOf: fixture.source.appendingPathComponent("wrapper-marker"), encoding: .utf8), "outer-wrapper-marker")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path), [])
        let journal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(result.journalPath)))) as? [String: Any])
        XCTAssertEqual(journal["state"] as? String, "recovered_original")
    }
}
