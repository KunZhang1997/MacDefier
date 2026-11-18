import CleanupKit
import CoreGraphics
import Foundation
import XCTest
@testable import MacDefier

final class DiskTreemapLayoutTests: XCTestCase {
    func testWeightedRectanglesAndEqualWeights() {
        verify(items([60, 25, 10, 5]), in: CGRect(x: 19, y: -17, width: 760, height: 420))

        let equalTiles = verify(items([1, 1, 1, 1]), in: CGRect(x: 0, y: 0, width: 100, height: 100))
        for tile in equalTiles {
            XCTAssertLessThan(abs(tile.frame.width - 50), 1e-10)
            XCTAssertLessThan(abs(tile.frame.height - 50), 1e-10)
        }

        let bounds = CGRect(x: -80, y: 73, width: 350, height: 290)
        let single = verify([DiskTreemapItem(id: "only", weight: 27)], in: bounds)
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single[0].frame, bounds)
    }

    func testInvalidWeightsAndInvalidBoundsAreExcluded() {
        let input = [
            DiskTreemapItem(id: "zero", weight: 0),
            DiskTreemapItem(id: "negative", weight: -10),
            DiskTreemapItem(id: "nan", weight: .nan),
            DiskTreemapItem(id: "infinity", weight: .infinity),
            DiskTreemapItem(id: "negative-infinity", weight: -.infinity),
            DiskTreemapItem(id: "valid", weight: 10)
        ]
        let tiles = verify(input, in: CGRect(x: 0, y: 0, width: 300, height: 200))
        XCTAssertEqual(tiles.map(\.id), ["valid"])
        XCTAssertTrue(DiskTreemapLayout.layout(Array(input.dropLast()), in: .init(x: 0, y: 0, width: 10, height: 10)).isEmpty)

        let validInput = items([3, 2, 1])
        let invalidBounds: [CGRect] = [
            .zero, .null, .infinite,
            CGRect(x: 0, y: 0, width: -1, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: -1),
            CGRect(x: 0, y: 0, width: 0, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: 0),
            CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
            CGRect(x: 0, y: CGFloat.infinity, width: 100, height: 100),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: CGFloat.nan),
            CGRect(x: 0, y: 0, width: 1e300, height: 1e300),
            CGRect(x: 0, y: 0, width: 1e-300, height: 1e-300),
            CGRect(x: 1e300, y: 0, width: 1, height: 10),
            CGRect(x: 1e308, y: 0, width: 1e308, height: 1)
        ]
        for bounds in invalidBounds {
            XCTAssertTrue(DiskTreemapLayout.layout(validInput, in: bounds).isEmpty, "invalid bounds: \(bounds)")
        }
        XCTAssertTrue(DiskTreemapLayout.layout([], in: .init(x: 0, y: 0, width: 10, height: 10)).isEmpty)
    }

    func testExtremeWeightsNarrowCanvasesAndDeterminism() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 500)
        verify(items([1e308, 8e307, 5e307, 3e307]), in: bounds)
        verify(items([1e-300, 8e-301, 5e-301, 3e-301]), in: bounds)
        verify(items([
            Double.leastNonzeroMagnitude * 16,
            Double.leastNonzeroMagnitude * 8,
            Double.leastNonzeroMagnitude * 4,
            Double.leastNonzeroMagnitude * 2
        ]), in: bounds)

        let tinyInput = items([Double.greatestFiniteMagnitude, 1, Double.leastNonzeroMagnitude])
        let tinyTiles = verify(tinyInput, in: CGRect(x: 5, y: 7, width: 640, height: 480))
        XCTAssertEqual(tinyTiles.count, 3)
        XCTAssertEqual(tinyTiles[0].frame.width * tinyTiles[0].frame.height, 640 * 480)
        XCTAssertTrue(tinyTiles.dropFirst().allSatisfy { $0.frame.width * $0.frame.height == 0 })

        let narrowInput = items([44, 23, 17, 9, 4, 2, 1])
        verify(narrowInput, in: CGRect(x: -0.5, y: 10, width: 0.001, height: 1000))
        verify(narrowInput, in: CGRect(x: 10, y: -0.5, width: 1000, height: 0.001))
        verify(narrowInput, in: CGRect(x: 0, y: 0, width: 1e100, height: 1e-100))
        verify(narrowInput, in: CGRect(x: 0, y: 0, width: 1e-100, height: 1e100))

        let input96 = (0..<96).map {
            DiskTreemapItem(id: String(format: "file-%03d", $0), weight: Double(($0 * 37) % 17 + 1))
        }
        let permBounds = CGRect(x: 0, y: 0, width: 913, height: 527)
        let expected = verify(input96, in: permBounds)
        let evenOdd = input96.filter { Int($0.id.suffix(3))! % 2 == 0 }
            + input96.filter { Int($0.id.suffix(3))! % 2 != 0 }
        for permutation in [Array(input96.reversed()), evenOdd, Array(input96[31...] + input96[..<31])] {
            let result = verify(permutation, in: permBounds)
            XCTAssertEqual(result.count, expected.count)
            XCTAssertTrue(zip(result, expected).allSatisfy { $0.id == $1.id && $0.frame == $1.frame })
        }

        let tied = DiskTreemapLayout.layout([
            DiskTreemapItem(id: "z", weight: 4),
            DiskTreemapItem(id: "a", weight: 4),
            DiskTreemapItem(id: "m", weight: 8)
        ], in: permBounds)
        XCTAssertEqual(tied.map(\.id), ["m", "a", "z"])
    }

    func testScaleTranslationAndGeneratedDistributions() {
        let input = items([13, 8, 5, 3, 2, 1])
        let original = verify(input, in: CGRect(x: 0, y: 0, width: 320, height: 180))
        let transformed = verify(input, in: CGRect(x: 41, y: -29, width: 2240, height: 1260))
        for (first, second) in zip(original, transformed) {
            XCTAssertEqual(first.id, second.id)
            XCTAssertTrue(near(Double(second.frame.minX), Double(first.frame.minX) * 7 + 41, scale: 2240))
            XCTAssertTrue(near(Double(second.frame.minY), Double(first.frame.minY) * 7 - 29, scale: 1260))
            XCTAssertTrue(near(Double(second.frame.width), Double(first.frame.width) * 7, scale: 2240))
            XCTAssertTrue(near(Double(second.frame.height), Double(first.frame.height) * 7, scale: 1260))
        }

        for seed in 1...24 {
            let count = (seed * 13) % 96 + 1
            let generated = (0..<count).map {
                DiskTreemapItem(id: "\($0)", weight: pow(10, Double(($0 * 19 + seed * 7) % 61 - 30) / 5))
            }
            verify(generated, in: CGRect(x: 13, y: 17, width: 640, height: 360))
            verify(generated, in: CGRect(x: -23, y: -11, width: 360, height: 640))
        }
    }

    func testWholeDiskPresentationIncludesUnaccountedVolumeSpaceAndDenominator() {
        let users = CleanupKit.DiskUsageNode(
            path: "/Users", isDirectory: true, isSymbolicLink: false, isHardLinkDuplicate: false,
            allocatedBytes: 300_000_000_000, logicalBytes: 300_000_000_000,
            hardLinkBytesCountedElsewhere: 0, children: [], issues: [.cloudPlaceholder, .otherVolume]
        )
        let apps = CleanupKit.DiskUsageNode(
            path: "/Applications", isDirectory: true, isSymbolicLink: false, isHardLinkDuplicate: false,
            allocatedBytes: 80_000_000_000, logicalBytes: 80_000_000_000,
            hardLinkBytesCountedElsewhere: 0, children: [], issues: [.inProgress]
        )
        let root = CleanupKit.DiskUsageNode(
            path: "/", isDirectory: true, isSymbolicLink: false, isHardLinkDuplicate: false,
            allocatedBytes: 380_000_000_000, logicalBytes: 380_000_000_000,
            hardLinkBytesCountedElsewhere: 0, children: ["/Users", "/Applications"], issues: [.cloudPlaceholder, .otherVolume]
        )
        let snapshot = CleanupKit.DiskUsageSnapshot(
            rootPath: "/",
            nodes: ["/": root, "/Users": users, "/Applications": apps],
            scannedAt: Date(),
            elapsed: 1.2
        )
        let unaccounted: UInt64 = 45_000_000_000
        let presentation = DiskMapPresentation(
            parent: root,
            children: [users, apps],
            snapshot: snapshot,
            unaccountedVolumeBytes: unaccounted
        )
        XCTAssertEqual(presentation.unaccountedBytes, unaccounted)
        XCTAssertEqual(presentation.denominatorBytes, 425_000_000_000)
        XCTAssertTrue(presentation.entries.contains { $0.id == "__system_unaccounted__" && $0.isSystemUnaccounted })
        XCTAssertEqual(presentation.entries.first { $0.id == "/Users" }?.isPartial, false)
        XCTAssertEqual(presentation.entries.first { $0.id == "/Applications" }?.isPartial, true)
    }

    func testMultiLevelNestedPresentationCollapsesWrapperChainsAndKeepsAtomicPackages() {
        let caches = CleanupKit.DiskUsageNode(
            path: "/Users/alice/Library/Caches", isDirectory: true, isSymbolicLink: false, isHardLinkDuplicate: false,
            allocatedBytes: 80_000_000_000, logicalBytes: 80_000_000_000, hardLinkBytesCountedElsewhere: 0,
            children: [], issues: []
        )
        let appSupport = CleanupKit.DiskUsageNode(
            path: "/Users/alice/Library/Application Support", isDirectory: true, isSymbolicLink: false, isHardLinkDuplicate: false,
            allocatedBytes: 50_000_000_000, logicalBytes: 50_000_000_000, hardLinkBytesCountedElsewhere: 0,
            children: [], issues: []
        )
        let library = CleanupKit.DiskUsageNode(
            path: "/Users/alice/Library", isDirectory: true, isSymbolicLink: false, isHardLinkDuplicate: false,
            allocatedBytes: 130_000_000_000, logicalBytes: 130_000_000_000, hardLinkBytesCountedElsewhere: 0,
            children: [caches.path, appSupport.path], issues: []
        )
        let desktop = CleanupKit.DiskUsageNode(
            path: "/Users/alice/Desktop", isDirectory: true, isSymbolicLink: false, isHardLinkDuplicate: false,
            allocatedBytes: 100_000_000_000, logicalBytes: 100_000_000_000, hardLinkBytesCountedElsewhere: 0,
            children: [], issues: []
        )
        let ollama = CleanupKit.DiskUsageNode(
            path: "/Users/alice/.ollama", isDirectory: true, isSymbolicLink: false, isHardLinkDuplicate: false,
            allocatedBytes: 69_000_000_000, logicalBytes: 69_000_000_000, hardLinkBytesCountedElsewhere: 0,
            children: [], issues: []
        )
        let alice = CleanupKit.DiskUsageNode(
            path: "/Users/alice", isDirectory: true, isSymbolicLink: false, isHardLinkDuplicate: false,
            allocatedBytes: 299_000_000_000, logicalBytes: 299_000_000_000, hardLinkBytesCountedElsewhere: 0,
            children: [library.path, desktop.path, ollama.path], issues: []
        )
        let shared = CleanupKit.DiskUsageNode(
            path: "/Users/Shared", isDirectory: true, isSymbolicLink: false, isHardLinkDuplicate: false,
            allocatedBytes: 1_000_000_000, logicalBytes: 1_000_000_000, hardLinkBytesCountedElsewhere: 0,
            children: [], issues: []
        )
        let users = CleanupKit.DiskUsageNode(
            path: "/Users", isDirectory: true, isSymbolicLink: false, isHardLinkDuplicate: false,
            allocatedBytes: 300_000_000_000, logicalBytes: 300_000_000_000, hardLinkBytesCountedElsewhere: 0,
            children: [alice.path, shared.path], issues: []
        )
        let xcodeContents = CleanupKit.DiskUsageNode(
            path: "/Applications/Xcode.app/Contents", isDirectory: true, isSymbolicLink: false, isHardLinkDuplicate: false,
            allocatedBytes: 40_000_000_000, logicalBytes: 40_000_000_000, hardLinkBytesCountedElsewhere: 0,
            children: [], issues: []
        )
        let xcode = CleanupKit.DiskUsageNode(
            path: "/Applications/Xcode.app", isDirectory: true, isSymbolicLink: false, isHardLinkDuplicate: false,
            allocatedBytes: 40_000_000_000, logicalBytes: 40_000_000_000, hardLinkBytesCountedElsewhere: 0,
            children: [xcodeContents.path], issues: []
        )
        let docker = CleanupKit.DiskUsageNode(
            path: "/Applications/Docker.app", isDirectory: true, isSymbolicLink: false, isHardLinkDuplicate: false,
            allocatedBytes: 20_000_000_000, logicalBytes: 20_000_000_000, hardLinkBytesCountedElsewhere: 0,
            children: [], issues: []
        )
        let apps = CleanupKit.DiskUsageNode(
            path: "/Applications", isDirectory: true, isSymbolicLink: false, isHardLinkDuplicate: false,
            allocatedBytes: 60_000_000_000, logicalBytes: 60_000_000_000, hardLinkBytesCountedElsewhere: 0,
            children: [xcode.path, docker.path], issues: []
        )
        let root = CleanupKit.DiskUsageNode(
            path: "/", isDirectory: true, isSymbolicLink: false, isHardLinkDuplicate: false,
            allocatedBytes: 360_000_000_000, logicalBytes: 360_000_000_000, hardLinkBytesCountedElsewhere: 0,
            children: [users.path, apps.path], issues: []
        )
        let snapshot = CleanupKit.DiskUsageSnapshot(
            rootPath: "/",
            nodes: [
                "/": root, "/Users": users, "/Users/alice": alice, "/Users/Shared": shared,
                library.path: library, caches.path: caches, appSupport.path: appSupport,
                desktop.path: desktop, ollama.path: ollama,
                apps.path: apps, xcode.path: xcode, xcodeContents.path: xcodeContents, docker.path: docker
            ],
            scannedAt: Date(),
            elapsed: 1.0
        )

        let presentation = DiskMapPresentation(parent: root, children: [users, apps], snapshot: snapshot)

        let usersEntry = presentation.entries.first { $0.id == "/Users" }
        XCTAssertEqual(usersEntry?.title, "Users / alice")
        XCTAssertEqual(usersEntry?.effectiveNode?.path, "/Users/alice")
        XCTAssertEqual(usersEntry?.usesNeutralWrapperFrame, true)
        let usersChildrenSum = (usersEntry?.childrenEntries ?? []).reduce(0.0) { $0 + $1.weight }
        XCTAssertEqual(usersChildrenSum, 300_000_000_000, accuracy: 1.0)
        let childHues = Set((usersEntry?.childrenEntries ?? []).filter { $0.node != nil }.map(\.hueIndex))
        XCTAssertGreaterThanOrEqual(childHues.count, 3)

        // Depth 2 nested child (`Caches`) is indexed in entriesByID with full breadcrumb context.
        let cachesEntry = presentation.entriesByID[caches.path]
        XCTAssertNotNil(cachesEntry)
        XCTAssertEqual(cachesEntry?.depth, 2)
        XCTAssertEqual(cachesEntry?.parentContext, "Users / alice › Library")

        // `.app` bundles stay atomic leaf tiles on the overview rather than exploding into `Contents`.
        let xcodeEntry = presentation.entriesByID[xcode.path]
        XCTAssertNotNil(xcodeEntry)
        XCTAssertEqual(xcodeEntry?.symbol, "app.fill")
        XCTAssertTrue(xcodeEntry?.childrenEntries.isEmpty == true)
    }

    private func items(_ weights: [Double]) -> [DiskTreemapItem] {
        weights.enumerated().map { DiskTreemapItem(id: "item-\($0.offset)", weight: $0.element) }
    }

    @discardableResult
    private func verify(_ input: [DiskTreemapItem], in bounds: CGRect) -> [DiskTreemapTile] {
        let valid = input.filter { $0.weight.isFinite && $0.weight > 0 }.sorted {
            $0.weight == $1.weight ? $0.id < $1.id : $0.weight > $1.weight
        }
        let tiles = DiskTreemapLayout.layout(input, in: bounds)
        XCTAssertEqual(tiles.map(\.id), valid.map(\.id))
        let maximum = valid.map(\.weight).max() ?? 1
        let normalized = valid.map { $0.weight / maximum }
        let total = normalized.reduce(0, +)
        let canvasArea = Double(bounds.width) * Double(bounds.height)
        var actualTotal = 0.0
        for (index, tile) in tiles.enumerated() {
            let frame = tile.frame
            XCTAssertTrue([frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy(\.isFinite))
            XCTAssertGreaterThanOrEqual(frame.width, 0)
            XCTAssertGreaterThanOrEqual(frame.height, 0)
            XCTAssertTrue(
                frame.minX >= bounds.minX && frame.minY >= bounds.minY
                    && frame.maxX <= bounds.maxX && frame.maxY <= bounds.maxY
            )
            let actual = Double(frame.width) * Double(frame.height)
            let expected = canvasArea * (normalized[index] / total)
            XCTAssertTrue(near(actual, expected, scale: canvasArea))
            actualTotal += actual
            for previous in tiles[..<index] {
                let overlapWidth = max(0, min(frame.maxX, previous.frame.maxX) - max(frame.minX, previous.frame.minX))
                let overlapHeight = max(0, min(frame.maxY, previous.frame.maxY) - max(frame.minY, previous.frame.minY))
                XCTAssertTrue(overlapWidth == 0 || overlapHeight == 0)
            }
        }
        XCTAssertTrue(near(actualTotal, canvasArea, scale: canvasArea))
        return tiles
    }

    private func near(_ left: Double, _ right: Double, scale: Double) -> Bool {
        abs(left - right) <= max(abs(scale) * 1e-10, Double.leastNonzeroMagnitude)
    }
}
