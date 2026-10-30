import Foundation
import XCTest
@testable import CleanupKit

// Policy tests only: the filesystem contains only this test's temporary bundles.
// Container scan results and signatures are injected; no NSWorkspace lookup,
// system signing, real uninstall executor, or system Trash is used.
final class UninstallExtensionOwnershipTests: XCTestCase {
    private final class Fixture {
        static let parentID = "com.example.extension-parent"
        static let extensionID = parentID + ".finder-ext"
        static let team = "FIXTURE123"

        let root: URL
        let appURL: URL
        let extensionURL: URL
        let containerURL: URL

        init() throws {
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("UninstallExtensionOwnership-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
            root = URL(fileURLWithPath: PathGate.normalize(temporary.path), isDirectory: true)
            appURL = root.appendingPathComponent("Applications/Fixture.app", isDirectory: true)
            extensionURL = appURL.appendingPathComponent("Contents/PlugIns/finder-ext.appex", isDirectory: true)
            containerURL = root.appendingPathComponent("Home/Library/Containers/\(Self.extensionID)", isDirectory: true)
            do {
                try writeBundle(at: appURL, identifier: Self.parentID, extensionBundle: false)
                try writeBundle(at: extensionURL, identifier: Self.extensionID, extensionBundle: true)
                try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
                try writeMetadata(bundleID: Self.extensionID, signingID: Self.extensionID, team: Self.team)
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        }

        var app: InstalledApp {
            InstalledApp(name: "Fixture", bundleIdentifier: Self.parentID, path: appURL.path,
                         version: "1", bytes: 0, isSystemLocation: false, canTrashAppBundle: true)
        }

        var signatures: [String: UninstallTargetIdentity.Signature] {
            [appURL.path: .init(identifier: Self.parentID, teamIdentifier: Self.team),
             extensionURL.path: .init(identifier: Self.extensionID, teamIdentifier: Self.team)]
        }

        func identity(
            selected: [String]? = nil,
            signatures supplied: [String: UninstallTargetIdentity.Signature]? = nil
        ) -> UninstallTargetIdentity {
            let evidence = supplied ?? signatures
            return UninstallTargetIdentity(app: app, residualPaths: selected ?? [containerURL.path],
                                           signatureReader: { evidence[PathGate.normalize($0)] })
        }

        func ownership(
            path: String? = nil,
            bundleID: String = Fixture.extensionID,
            signingID: String = Fixture.extensionID,
            team: String = Fixture.team,
            applicationPaths: [String]? = nil,
            confidence: ContainerOwnershipConfidence = .verifiedOrphan,
            liveOwners: [String] = [],
            hasVerifiableApplicationPaths: Bool = true
        ) -> ContainerOwnership {
            let paths = applicationPaths ?? [extensionURL.path]
            return ContainerOwnership(path: path ?? containerURL.path, bundleID: bundleID,
                                      signingIdentifier: signingID, teamIdentifier: team,
                                      applicationBundlePath: paths.first, confidence: confidence,
                                      evidence: ["isolated ownership fixture"],
                                      applicationBundlePaths: paths, teamIdentifiers: [team],
                                      liveOwnerPaths: liveOwners,
                                      hasVerifiableApplicationPaths: hasVerifiableApplicationPaths)
        }

        func moveParentAside() throws {
            try FileManager.default.moveItem(at: appURL, to: root.appendingPathComponent("MovedParent.app"))
        }

        func writeMetadata(bundleID: String, signingID: String, team: String) throws {
            try writePlist([
                "MCMMetadataIdentifier": bundleID,
                "Owners": [["signingIdentifier": signingID, "teamIdentifier": team]],
                "application_bundle": extensionURL.path
            ], to: containerURL.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
        }

        func writeBundle(at url: URL, identifier: String, extensionBundle: Bool) throws {
            let contents = url.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var plist: [String: Any] = [
                "CFBundleIdentifier": identifier,
                "CFBundleName": "Fixture",
                "CFBundleVersion": "1",
                "CFBundleShortVersionString": "1",
                "CFBundlePackageType": extensionBundle ? "XPC!" : "APPL"
            ]
            if extensionBundle {
                plist["NSExtension"] = ["NSExtensionPointIdentifier": "com.apple.FinderSync"]
            }
            try writePlist(plist, to: contents.appendingPathComponent("Info.plist"))
        }

        private func writePlist(_ value: [String: Any], to url: URL) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
            try data.write(to: url, options: .atomic)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    func testVerifiedEmbeddedExtensionRemainsOwnedAfterParentMoved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let identity = fixture.identity()
        let preview = fixture.ownership(confidence: .installedOwner, liveOwners: [fixture.appURL.path])
        XCTAssertNil(identity.containerRetentionReason(preview, preview: true))

        try fixture.moveParentAside()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appURL.path))
        XCTAssertNil(identity.containerRetentionReason(fixture.ownership()),
                     "Frozen verified extension evidence must survive moving its parent")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.containerURL.path),
                      "Evaluating ownership must not move or delete the container")
    }

    func testUnknownBundleSuffixIsNotOwnedEvenWithMatchingTeam() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let unknownID = Fixture.parentID + ".not-embedded"
        let unknownPath = fixture.containerURL.deletingLastPathComponent().appendingPathComponent(unknownID).path
        let identity = fixture.identity(selected: [unknownPath])
        try fixture.moveParentAside()
        let ownership = fixture.ownership(path: unknownPath, bundleID: unknownID, signingID: unknownID,
                                          applicationPaths: [fixture.appURL.path])
        XCTAssertNotNil(identity.containerRetentionReason(ownership),
                        "A bundle-ID prefix and matching team do not prove an embedded extension")
    }

    func testForeignOrConflictingApplicationPathsRetainContainer() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let identity = fixture.identity()
        try fixture.moveParentAside()
        let foreign = fixture.root.appendingPathComponent("Applications/Foreign.app/Contents/PlugIns/finder-ext.appex").path
        XCTAssertNil(identity.containerRetentionReason(fixture.ownership()))
        for paths in [[foreign], [fixture.extensionURL.path, foreign]] {
            XCTAssertNotNil(identity.containerRetentionReason(fixture.ownership(applicationPaths: paths)),
                            "Every recorded application path must belong to the frozen parent")
        }
    }

    func testChangedContainerIdentifierSigningOrTeamIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let identity = fixture.identity()
        try fixture.moveParentAside()
        XCTAssertNil(identity.containerRetentionReason(fixture.ownership()))
        let foreignID = "com.example.foreign.finder-ext"
        // Simulate the freshly read scanner output; scanner/plist parsing has its own tests.
        try fixture.writeMetadata(bundleID: foreignID, signingID: foreignID, team: Fixture.team)
        XCTAssertNotNil(identity.containerRetentionReason(fixture.ownership(bundleID: foreignID, signingID: foreignID)))
        try fixture.writeMetadata(bundleID: Fixture.extensionID, signingID: foreignID, team: Fixture.team)
        XCTAssertNotNil(identity.containerRetentionReason(fixture.ownership(signingID: foreignID)))
        try fixture.writeMetadata(bundleID: Fixture.extensionID, signingID: Fixture.extensionID, team: "OTHERTEAM1")
        XCTAssertNotNil(identity.containerRetentionReason(fixture.ownership(team: "OTHERTEAM1")))
    }

    func testEmbeddedSignatureTeamOrIdentifierConflictCannotGrantOwnership() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for signature in [
            UninstallTargetIdentity.Signature(identifier: Fixture.extensionID, teamIdentifier: "OTHERTEAM1"),
            UninstallTargetIdentity.Signature(identifier: "com.example.foreign", teamIdentifier: Fixture.team)
        ] {
            var evidence = fixture.signatures
            evidence[fixture.extensionURL.path] = signature
            let identity = fixture.identity(signatures: evidence)
            XCTAssertNotNil(identity.containerRetentionReason(fixture.ownership(), preview: true))
        }
    }

    func testGroupContainerIsRetainedEvenWithKnownExtensionEvidence() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = fixture.root.appendingPathComponent("Home/Library/Group Containers/\(Fixture.extensionID)").path
        let identity = fixture.identity(selected: [path])
        try fixture.moveParentAside()
        let ownership = fixture.ownership(path: path)
        XCTAssertNotNil(identity.containerRetentionReason(ownership, preview: true))
        XCTAssertNotNil(identity.containerRetentionReason(ownership),
                        "Selecting a shared container must never turn it into private extension data")
    }

    func testOtherLiveOwnerBlocksPreviewAndExecution() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let identity = fixture.identity()
        let onlyParent = fixture.ownership(confidence: .installedOwner, liveOwners: [fixture.appURL.path])
        XCTAssertNil(identity.containerRetentionReason(onlyParent, preview: true))
        XCTAssertNotNil(identity.containerRetentionReason(onlyParent),
                        "Execution cannot accept installedOwner before the main app is gone")
        let foreign = fixture.root.appendingPathComponent("Applications/OtherLive.app").path
        let shared = fixture.ownership(confidence: .installedOwner, liveOwners: [fixture.appURL.path, foreign])
        XCTAssertNotNil(identity.containerRetentionReason(shared, preview: true))
        try fixture.moveParentAside()
        XCTAssertNotNil(identity.containerRetentionReason(shared))
    }

    func testUnverifiedExtensionPreviewIsDisabled() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let ownership = fixture.ownership(confidence: .installedOwner, liveOwners: [fixture.appURL.path])
        let verifiedReason = fixture.identity().containerRetentionReason(ownership, preview: true)
        let verified = ResidualItem(path: fixture.containerURL.path, kind: .containers, bytes: 0,
                                    note: "fixture", retentionReason: verifiedReason)
        XCTAssertNil(verifiedReason)
        XCTAssertTrue(verified.canSelect)
        XCTAssertFalse(verified.isSelected, "Verified data still requires the user's selection")

        for evidence in [[:], [fixture.appURL.path: fixture.signatures[fixture.appURL.path]!]] {
            let reason = fixture.identity(signatures: evidence).containerRetentionReason(ownership, preview: true)
            let unverified = ResidualItem(path: fixture.containerURL.path, kind: .containers, bytes: 0,
                                          note: "fixture", retentionReason: reason)
            XCTAssertNotNil(reason)
            XCTAssertFalse(unverified.canSelect)
            XCTAssertFalse(unverified.isSelected)
        }
    }

    func testPreviewRejectsMissingOrUnverifiableApplicationPathsForMainAndExtension() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let mainContainer = fixture.containerURL.deletingLastPathComponent()
            .appendingPathComponent(Fixture.parentID).path
        let identity = fixture.identity(selected: [mainContainer, fixture.containerURL.path])
        for (identifier, containerPath, originalPath) in [
            (Fixture.parentID, mainContainer, fixture.appURL.path),
            (Fixture.extensionID, fixture.containerURL.path, fixture.extensionURL.path)
        ] {
            let verified = fixture.ownership(path: containerPath, bundleID: identifier,
                signingID: identifier, applicationPaths: [originalPath], confidence: .installedOwner,
                liveOwners: [fixture.appURL.path], hasVerifiableApplicationPaths: true)
            XCTAssertNil(identity.containerRetentionReason(verified, preview: true))

            // Existing owner alone is not an execution-ready ownership proof. The
            // scanner must also verify every original installation path; even a
            // plausible-looking string is insufficient without that evidence.
            for paths in [[], ["relative/Fixture.app"], [originalPath]] {
                let unverified = fixture.ownership(path: containerPath, bundleID: identifier,
                    signingID: identifier, applicationPaths: paths, confidence: .installedOwner,
                    liveOwners: [fixture.appURL.path], hasVerifiableApplicationPaths: false)
                let reason = identity.containerRetentionReason(unverified, preview: true)
                XCTAssertNotNil(reason, "\(identifier) must retain data without verified original paths")
                let item = ResidualItem(path: containerPath, kind: .containers, bytes: 0,
                                        note: "unverified application-path fixture", retentionReason: reason)
                XCTAssertFalse(item.canSelect)
                XCTAssertFalse(item.isSelected)
            }
        }
    }

    func testSelectedPathGrantIsExactAndDoesNotCoverSiblingOrDescendant() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let identity = fixture.identity(selected: [fixture.containerURL.path])
        try fixture.moveParentAside()
        XCTAssertNil(identity.containerRetentionReason(fixture.ownership()))
        let sibling = fixture.containerURL.path + ".copy"
        let descendant = fixture.containerURL.appendingPathComponent("Data").path
        for unselected in [sibling, descendant] {
            XCTAssertNotNil(identity.containerRetentionReason(fixture.ownership(path: unselected)),
                            "A frozen container selection grants only its exact path")
        }
    }

    func testReplacingMainBundleFailsCapturedSnapshotCheck() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let identity = fixture.identity()
        let original = try UninstallFileBoundary.snapshot(fixture.appURL.path)
        XCTAssertTrue(identity.mainBundleMatchesSnapshot(original))
        // Preserve the original inode in our own directory, then create a replacement.
        try fixture.moveParentAside()
        try fixture.writeBundle(at: fixture.appURL, identifier: Fixture.parentID, extensionBundle: false)
        let replacement = try UninstallFileBoundary.snapshot(fixture.appURL.path)
        XCTAssertNotEqual(original.item, replacement.item)
        XCTAssertFalse(identity.mainBundleMatchesSnapshot(replacement))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.appURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.containerURL.path))
    }
}
