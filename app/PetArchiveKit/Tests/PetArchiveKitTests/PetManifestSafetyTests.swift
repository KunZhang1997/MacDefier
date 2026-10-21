import XCTest
@testable import PetArchiveKit

final class PetManifestSafetyTests: XCTestCase {
    func testGridRejectsOverflowAndUnboundedCellCounts() {
        XCTAssertNil(PetManifestSafety.cellCount(columns: Int.max, rows: 2))
        XCTAssertNil(PetManifestSafety.cellCount(columns: 20, rows: 20))
        XCTAssertNil(PetManifestSafety.cellCount(columns: 0, rows: 1))
        XCTAssertEqual(PetManifestSafety.cellCount(columns: 10, rows: 20), 200)
    }

    func testAnimationRejectsOverflowAndOutOfBoundsIndices() {
        XCTAssertNil(PetManifestSafety.resolvedFrames(
            frames: nil,
            start: Int.max,
            count: 1,
            totalCells: 1
        ))
        XCTAssertNil(PetManifestSafety.resolvedFrames(
            frames: [0, Int.max],
            start: nil,
            count: nil,
            totalCells: 2
        ))
        XCTAssertEqual(PetManifestSafety.resolvedFrames(
            frames: nil,
            start: 1,
            count: 20,
            totalCells: 3
        ), [1, 2])
    }

    func testMoodFrameMapMustStayInsideGrid() {
        XCTAssertTrue(PetManifestSafety.frameMapIsValid(["idle": 0, "talk": 1], totalCells: 2))
        XCTAssertFalse(PetManifestSafety.frameMapIsValid(["idle": -1], totalCells: 2))
        XCTAssertFalse(PetManifestSafety.frameMapIsValid(["idle": 2], totalCells: 2))
    }
}
