import CoreGraphics
import XCTest
@testable import MacDefier

final class PetOverlayGeometryTests: XCTestCase {
    func testClampAndPetFrameStayWithinWindowMargins() {
        let window = CGSize(width: 1000, height: 700)
        let petSize = CGSize(width: 110, height: 120)
        let margin: CGFloat = 16

        // Default zero offset anchors at bottom-right inside margins
        let originFrame = PetOverlayGeometry.petFrame(offset: .zero, window: window, size: petSize, margin: margin)
        XCTAssertEqual(originFrame, CGRect(x: 874, y: 564, width: 110, height: 120))

        // Positive drag offsets clamp to 0 (cannot push past bottom/right margin)
        let positiveClamped = PetOverlayGeometry.clamp(
            CGSize(width: 250, height: 400),
            window: window,
            size: petSize,
            margin: margin
        )
        XCTAssertEqual(positiveClamped, .zero)

        // Large negative drag offsets clamp to top-left margin
        let topLeftFrame = PetOverlayGeometry.petFrame(
            offset: CGSize(width: -9999, height: -9999),
            window: window,
            size: petSize,
            margin: margin
        )
        XCTAssertEqual(topLeftFrame.minX, margin)
        XCTAssertEqual(topLeftFrame.minY, margin)

        // Tiny window smaller than pet + 2*margin does not invert clamp range
        let tinyClamped = PetOverlayGeometry.clamp(
            CGSize(width: -50, height: -50),
            window: CGSize(width: 80, height: 80),
            size: petSize,
            margin: margin
        )
        XCTAssertEqual(tinyClamped, .zero)
    }

    func testPopupFramePlacementAboveBelowSideAndTinyWindow() {
        let window = CGSize(width: 1000, height: 700)
        let preferred = CGSize(width: 320, height: 240)
        let margin: CGFloat = 16

        // Pet at bottom-right -> popup placed above pet
        let bottomRightPet = CGRect(x: 874, y: 564, width: 110, height: 120)
        let above = PetOverlayGeometry.popupFrame(near: bottomRightPet, window: window, preferred: preferred, margin: margin)
        XCTAssertLessThanOrEqual(above.maxY, bottomRightPet.minY - 10)
        XCTAssertGreaterThanOrEqual(above.minX, margin)
        XCTAssertLessThanOrEqual(above.maxX, window.width - margin)

        // Pet dragged to top-right -> popup placed below pet
        let topRightPet = CGRect(x: 874, y: 20, width: 110, height: 120)
        let below = PetOverlayGeometry.popupFrame(near: topRightPet, window: window, preferred: preferred, margin: margin)
        XCTAssertGreaterThanOrEqual(below.minY, topRightPet.maxY + 10)
        XCTAssertLessThanOrEqual(below.maxY, window.height - margin)

        // Short window where neither above nor below fits -> popup placed to the left of pet
        let shortWindow = CGSize(width: 900, height: 300)
        let rightMidPet = CGRect(x: 760, y: 90, width: 110, height: 120)
        let leftSide = PetOverlayGeometry.popupFrame(near: rightMidPet, window: shortWindow, preferred: preferred, margin: margin)
        XCTAssertLessThanOrEqual(leftSide.maxX, rightMidPet.minX - 10)
        XCTAssertGreaterThanOrEqual(leftSide.minX, margin)
        XCTAssertGreaterThanOrEqual(leftSide.minY, margin)
        XCTAssertLessThanOrEqual(leftSide.maxY, shortWindow.height - margin)

        // Short window with pet on far left -> popup placed to the right of pet
        let leftMidPet = CGRect(x: 20, y: 90, width: 110, height: 120)
        let rightSide = PetOverlayGeometry.popupFrame(near: leftMidPet, window: shortWindow, preferred: preferred, margin: margin)
        XCTAssertGreaterThanOrEqual(rightSide.minX, leftMidPet.maxX + 10)
        XCTAssertLessThanOrEqual(rightSide.maxX, shortWindow.width - margin)
    }
}
