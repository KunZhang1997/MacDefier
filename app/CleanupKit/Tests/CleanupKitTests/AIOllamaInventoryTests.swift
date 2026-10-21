import Darwin
import Foundation
import XCTest
@testable import CleanupKit

final class AIOllamaInventoryTests: XCTestCase {
    func testExclusiveResourcesAndStableNames() throws {
        let fixture = try StoreFixture(); defer { fixture.remove() }
        let a = try fixture.blob("a"), b = try fixture.blob("b")
        try fixture.model("registry.ollama.ai/library/alpaca/7b", layers: [a, b])
        let result = fixture.scan()
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(candidate.title, "alpaca:7b")
        XCTAssertEqual(candidate.state, .ready)
        XCTAssertTrue(candidate.canSelect)
        XCTAssertEqual(candidate.resources.count, 4) // config, two layers, manifest
        XCTAssertEqual(candidate.resources.last?.path, candidate.path)
        XCTAssertEqual(candidate.bytes, AIResourceTotals.bytes(candidate.resources))
        XCTAssertNotNil(candidate.lastActivity)
        XCTAssertTrue(AIOllamaInventory.validateModel(candidate, home: fixture.home))
        XCTAssertTrue(result.issues.contains("modelStandardRootOnly"))
    }

    func testSharedConfigAndLayerAreRetained() throws {
        let fixture = try StoreFixture(); defer { fixture.remove() }
        let shared = try fixture.blob("a"), unique = try fixture.blob("b")
        try fixture.model("registry.ollama.ai/library/alpha/latest", layers: [shared, unique])
        try fixture.model("registry.ollama.ai/team/beta/latest", layers: [shared])
        let candidates = fixture.scan().candidates
        let first = try XCTUnwrap(candidates.first { $0.title == "alpha:latest" })
        XCTAssertEqual(first.resources.count, 2)
        XCTAssertFalse(first.resources.contains { $0.path.hasSuffix(shared.replacingOccurrences(of: ":", with: "-")) })
        XCTAssertEqual(first.metadata["sharedBlobCount"], "2")
        XCTAssertTrue(candidates.contains { $0.title == "team/beta:latest" })
        XCTAssertTrue(AIOllamaInventory.validateModel(first, home: fixture.home))
    }

    func testCustomRegistryAndTagNamesAreNotGuessed() throws {
        let fixture = try StoreFixture(); defer { fixture.remove() }
        try fixture.model("localhost:5000/my_team/model.v2/q4_K", layers: [])
        XCTAssertEqual(fixture.scan().candidates.first?.title, "localhost:5000/my_team/model.v2:q4_K")
    }

    func testMalformedOrUnrecognizedManifestDeniesEveryModel() throws {
        let fixture = try StoreFixture(); defer { fixture.remove() }
        try fixture.model("registry.ollama.ai/library/good/latest", layers: [])
        try fixture.rawManifest("registry.ollama.ai/library/bad/latest", data: Data("not json".utf8))
        let result = fixture.scan()
        XCTAssertTrue(result.issues.contains("modelGraphIncomplete"))
        XCTAssertTrue(result.candidates.allSatisfy { $0.state == .unknown && !$0.canSelect && $0.resources.isEmpty })
    }

    func testMissingAndWrongSizeBlobsDenyEveryModel() throws {
        let fixture = try StoreFixture(); defer { fixture.remove() }
        let a = try fixture.blob("a")
        try fixture.model("registry.ollama.ai/library/good/latest", layers: [a])
        try Data([1]).write(to: URL(fileURLWithPath: fixture.blobPath(a)))
        XCTAssertTrue(fixture.scan().candidates.allSatisfy { !$0.canSelect })
        try FileManager.default.removeItem(atPath: fixture.blobPath(a))
        XCTAssertTrue(fixture.scan().candidates.allSatisfy { !$0.canSelect })
    }

    func testNewCrossModelReferenceInvalidatesOldSelection() throws {
        let fixture = try StoreFixture(); defer { fixture.remove() }
        let a = try fixture.blob("a")
        try fixture.model("registry.ollama.ai/library/first/latest", layers: [a])
        let original = try XCTUnwrap(fixture.scan().candidates.first)
        try fixture.model("registry.ollama.ai/library/second/latest", layers: [a])
        XCTAssertFalse(AIOllamaInventory.validateModel(original, home: fixture.home))
        XCTAssertTrue(fixture.scan().candidates.allSatisfy { $0.resources.count == 1 })
    }

    func testSameInodeBlobRewriteWithRestoredMtimeInvalidatesSelection() throws {
        let fixture = try StoreFixture(); defer { fixture.remove() }
        let a = try fixture.blob("a")
        try fixture.model("registry.ollama.ai/library/model/latest", layers: [a])
        let candidate = try XCTUnwrap(fixture.scan().candidates.first)
        let resource = try XCTUnwrap(candidate.resources.first { $0.path == fixture.blobPath(a) })
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: resource.path))
        try handle.write(contentsOf: Data(repeating: 2, count: 1024))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: resource.modifiedAt], ofItemAtPath: resource.path)
        XCTAssertTrue(resource.stillMatches(), "The inode alone has not changed")
        XCTAssertFalse(AIOllamaInventory.validateModel(candidate, home: fixture.home))
    }

    func testManifestContentRewriteInvalidatesGraph() throws {
        let fixture = try StoreFixture(); defer { fixture.remove() }
        try fixture.model("registry.ollama.ai/library/model/latest", layers: [])
        let candidate = try XCTUnwrap(fixture.scan().candidates.first)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: candidate.path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" ".utf8))
        try handle.close()
        XCTAssertFalse(AIOllamaInventory.validateModel(candidate, home: fixture.home))
    }

    func testSharedBlobChangesAlsoInvalidateSelectedExclusiveResources() throws {
        let fixture = try StoreFixture(); defer { fixture.remove() }
        let shared = try fixture.blob("a")
        try fixture.model("registry.ollama.ai/library/first/latest", layers: [shared])
        try fixture.model("registry.ollama.ai/library/second/latest", layers: [shared])
        let candidate = try XCTUnwrap(fixture.scan().candidates.first)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: fixture.blobPath(shared)))
        try handle.write(contentsOf: Data(repeating: 2, count: 1024))
        try handle.close()
        XCTAssertFalse(AIOllamaInventory.validateModel(candidate, home: fixture.home), "The whole graph includes shared blob proofs")
    }

    func testSymlinkStoreOrNestedManifestCannotBecomeSelectable() throws {
        let fixture = try StoreFixture(); defer { fixture.remove() }
        try fixture.model("registry.ollama.ai/library/model/latest", layers: [])
        let library = fixture.root + "/manifests/registry.ollama.ai/library"
        try FileManager.default.moveItem(atPath: library, toPath: library + "-moved")
        try FileManager.default.createSymbolicLink(atPath: library, withDestinationPath: library + "-moved")
        let result = fixture.scan()
        XCTAssertTrue(result.issues.contains("modelPathUnsafe"))
        XCTAssertTrue(result.candidates.allSatisfy { !$0.canSelect })
    }

    func testHardlinkedBlobsAreRetainedAndUnreferencedBlobsIgnored() throws {
        let fixture = try StoreFixture(); defer { fixture.remove() }
        let linked = try fixture.blob("a"), orphan = try fixture.blob("b")
        try FileManager.default.linkItem(atPath: fixture.blobPath(linked), toPath: fixture.home + "/external-link")
        try fixture.model("registry.ollama.ai/library/model/latest", layers: [linked])
        let candidate = try XCTUnwrap(fixture.scan().candidates.first)
        XCTAssertFalse(candidate.resources.contains { $0.path == fixture.blobPath(linked) || $0.path == fixture.blobPath(orphan) })
        XCTAssertTrue(AIOllamaInventory.validateModel(candidate, home: fixture.home))
    }

    func testCancellationAndBudgetsDenySelection() throws {
        let fixture = try StoreFixture(); defer { fixture.remove() }
        try fixture.model("registry.ollama.ai/library/model/latest", layers: [])
        let cancelled = AIOllamaInventory.scan(home: fixture.home, isCancelled: { true })
        XCTAssertTrue(cancelled.candidates.allSatisfy { !$0.canSelect })
        XCTAssertTrue(cancelled.issues.contains("modelGraphIncomplete"))
        for budget in [AIOllamaInventory.Budget(entries: 0), .init(manifestBytes: 1), .init(totalManifestBytes: 1), .init(seconds: 0)] {
            let inventory = AIOllamaInventory.scan(home: fixture.home, now: Date(), budget: budget, isCancelled: { false })
            XCTAssertTrue(inventory.candidates.allSatisfy { !$0.canSelect })
            XCTAssertTrue(inventory.issues.contains("modelGraphIncomplete"))
        }
    }

    func testForgedResourcesAndExcludedManifestAreRejected() throws {
        let fixture = try StoreFixture(); defer { fixture.remove() }
        try fixture.model("registry.ollama.ai/library/model/latest", layers: [])
        let candidate = try XCTUnwrap(fixture.scan().candidates.first)
        let forged = AICleanupCandidate(tool: .ollama, kind: .model, title: candidate.title,
            resources: [], state: .ready, reason: candidate.reason, metadata: candidate.metadata, contextPath: candidate.path)
        XCTAssertFalse(AIOllamaInventory.validateModel(forged, home: fixture.home))
        XCTAssertFalse(AIOllamaInventory.validateModel(candidate, home: fixture.home, excludingMovedPaths: [candidate.path]))
        XCTAssertFalse(AIOllamaInventory.validateModel(candidate, home: fixture.home, excludingMovedPaths: [fixture.home + "/other"]))
    }

    func testFixtureTrashSequenceRetainsSharedModelAndMovesManifestLast() throws {
        let fixture = try StoreFixture(); defer { fixture.remove() }
        let shared = try fixture.blob("a"), unique = try fixture.blob("b")
        try fixture.model("registry.ollama.ai/library/first/latest", layers: [shared, unique])
        try fixture.model("registry.ollama.ai/library/second/latest", layers: [shared])
        let candidate = try XCTUnwrap(fixture.scan().candidates.first { $0.title == "first:latest" })
        let trash = fixture.home + "/fixture-trash"
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var moved = Set<String>()
        for resource in candidate.resources {
            XCTAssertTrue(AIOllamaInventory.validateModel(candidate, home: fixture.home, excludingMovedPaths: moved))
            try UninstallFileBoundary.move(resource.boundary, toTrashDirectory: trash)
            moved.insert(resource.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.blobPath(shared)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertEqual(fixture.scan().candidates.first?.title, "second:latest")
        XCTAssertTrue(fixture.scan().candidates.first?.canSelect == true)
    }

    func testMultiModelBatchAcceptsOnlyCompletedOwnMutationsAndRetainsOriginalSharedBlobs() throws {
        let fixture = try StoreFixture(); defer { fixture.remove() }
        let shared = try fixture.blob("a"), unique = try fixture.blob("b")
        try fixture.model("registry.ollama.ai/library/first/latest", layers: [shared, unique])
        try fixture.model("registry.ollama.ai/library/second/latest", layers: [shared])
        let candidates = fixture.scan().candidates
        let trash = fixture.home + "/fixture-trash"
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var moved = Set<String>()
        for candidate in candidates {
            for resource in candidate.resources {
                XCTAssertTrue(AIOllamaInventory.validateModel(candidate, home: fixture.home, excludingMovedPaths: moved))
                try UninstallFileBoundary.move(resource.boundary, toTrashDirectory: trash)
                moved.insert(resource.path)
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.blobPath(shared)), "Originally shared blobs never become newly selected")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.blobPath(fixture.config)))
        XCTAssertTrue(fixture.scan().candidates.isEmpty)
    }

    func testUnknownRemovedManifestCannotBeExcusedByAnotherModelsPartialBlobSet() throws {
        let fixture = try StoreFixture(); defer { fixture.remove() }
        let unique = try fixture.blob("a")
        try fixture.model("registry.ollama.ai/library/first/latest", layers: [unique])
        try fixture.model("registry.ollama.ai/library/second/latest", layers: [])
        let candidates = fixture.scan().candidates
        let first = try XCTUnwrap(candidates.first { $0.title == "first:latest" })
        let second = try XCTUnwrap(candidates.first { $0.title == "second:latest" })
        try FileManager.default.removeItem(atPath: first.path)
        XCTAssertFalse(AIOllamaInventory.validateModel(second, home: fixture.home))
        XCTAssertFalse(AIOllamaInventory.validateModel(second, home: fixture.home, excludingMovedPaths: [first.path]),
                       "A completed model must account for every original exclusive resource")
    }
}

private final class StoreFixture {
    let home: String
    var root: String { home + "/.ollama/models" }
    let config = "sha256:" + String(repeating: "c", count: 64)
    init() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ollama-inventory-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let resolved = try XCTUnwrap(realpath(path, nil)); defer { free(resolved) }
        home = URL(fileURLWithPath: String(cString: resolved)).standardizedFileURL.path
        try FileManager.default.createDirectory(atPath: root + "/manifests", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/blobs", withIntermediateDirectories: true)
        try Data(repeating: 3, count: 1024).write(to: URL(fileURLWithPath: blobPath(config)))
    }
    func remove() { try? FileManager.default.removeItem(atPath: home) }
    func blobPath(_ digest: String) -> String { root + "/blobs/" + digest.replacingOccurrences(of: ":", with: "-") }
    func blob(_ char: Character) throws -> String {
        let digest = "sha256:" + String(repeating: String(char), count: 64)
        try Data(repeating: 1, count: 1024).write(to: URL(fileURLWithPath: blobPath(digest)))
        return digest
    }
    func model(_ relative: String, layers: [String]) throws {
        func descriptor(_ digest: String) -> [String: Any] {
            ["digest": digest, "size": 1024, "mediaType": "application/vnd.ollama.image.model"]
        }
        let object: [String: Any] = ["schemaVersion": 2, "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
                                     "config": descriptor(config), "layers": layers.map(descriptor)]
        try rawManifest(relative, data: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
    func rawManifest(_ relative: String, data: Data) throws {
        let path = root + "/manifests/" + relative
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
    }
    func scan() -> AICleanupInventory { AIOllamaInventory.scan(home: home) }
}
