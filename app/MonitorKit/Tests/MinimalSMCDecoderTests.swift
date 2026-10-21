import XCTest
@testable import MonitorKit

final class MinimalSMCDecoderTests: XCTestCase {
    func testSignedFixedPointTemperatures() {
        XCTAssertEqual(MinimalSMC.decode(type: "sp78", bytes: [0x3c, 0x80]), 60.5)
        XCTAssertEqual(MinimalSMC.decode(type: "sp87", bytes: [0x1e, 0x40]), 60.5)
        XCTAssertEqual(MinimalSMC.decode(type: "sp96", bytes: [0x0f, 0x20]), 60.5)
        XCTAssertEqual(MinimalSMC.decode(type: "sp78", bytes: [0xfe, 0x80]), -1.5)
    }

    func testFanFPE2AndLittleEndianFloat() {
        XCTAssertEqual(MinimalSMC.decode(type: "fpe2", bytes: [0x1f, 0x40]), 2000)
        XCTAssertEqual(MinimalSMC.decode(type: "flt", bytes: [0, 0, 0x2a, 0x42]), 42.5)
    }

    func testUnsignedValuesIncludeMeasuredZero() {
        XCTAssertEqual(MinimalSMC.decode(type: "ui8", bytes: [0]), 0)
        XCTAssertEqual(MinimalSMC.decode(type: "ui16", bytes: [0xff, 0xff]), 65535)
        XCTAssertEqual(MinimalSMC.decode(type: "ui32", bytes: [0xff, 0xff, 0xff, 0xff]), 4294967295)
    }

    func testUnknownTypeAndWrongPayloadSizesAreRejected() {
        XCTAssertNil(MinimalSMC.decode(type: "unknown", bytes: [0x3c, 0]))
        XCTAssertNil(MinimalSMC.decode(type: "sp78", bytes: [0x3c]))
        XCTAssertNil(MinimalSMC.decode(type: "flt", bytes: [0, 0, 0x2a]))
        XCTAssertNil(MinimalSMC.decode(type: "ui8", bytes: []))
        XCTAssertNil(MinimalSMC.decode(type: "ui16", bytes: [1, 2, 3]))
        XCTAssertNil(MinimalSMC.decode(type: "ui32", bytes: [1, 2]))
        XCTAssertNil(MinimalSMC.decode(type: "fpe2", bytes: []))
    }

    func testNonFiniteFloatPayloadsAreUnavailable() {
        XCTAssertNil(MinimalSMC.decode(type: "flt", bytes: [0, 0, 0x80, 0x7f]))
        XCTAssertNil(MinimalSMC.decode(type: "flt", bytes: [0, 0, 0xc0, 0x7f]))
    }

    func testTemperatureRangeAndFanZeroAreDistinctFromMissing() {
        let values: [String: Double] = ["TC0P": 60, "TC0D": .nan, "TC0E": 121, "TC0F": 4,
                                        "FNum": 2, "F0Ac": 0, "F1Ac": 2500]
        let readings = MinimalSMC.readings { values[$0] }
        XCTAssertEqual(readings.filter { $0.unit == "°C" }.map(\.key), ["TC0P"])
        let fans = readings.filter { $0.unit == "RPM" }
        XCTAssertEqual(Set(fans.map(\.key)), Set(["F0Ac", "F1Ac"]))
        XCTAssertEqual(fans.first { $0.key == "F0Ac" }?.value, 0)
        XCTAssertTrue(fans.allSatisfy { $0.group == "Fans" })
    }

    func testInvalidFanCountCannotCauseUnboundedProbes() {
        for count in [-1.0, 1.5, 9, .infinity, .nan] {
            var requestedFanKeys: [String] = []
            let readings = MinimalSMC.readings { key in
                if key == "FNum" { return count }
                if key.hasPrefix("F") { requestedFanKeys.append(key); return 2000 }
                return nil
            }
            XCTAssertTrue(requestedFanKeys.isEmpty)
            XCTAssertTrue(readings.isEmpty)
        }
    }

    func testInvalidFanSpeedIsNotMeasuredZero() {
        let values: [String: Double] = ["FNum": 3, "F0Ac": -1, "F1Ac": .nan, "F2Ac": 30_001]
        XCTAssertTrue(MinimalSMC.readings { values[$0] }.isEmpty)
        XCTAssertTrue(MinimalSMC.readings { $0 == "FNum" ? 2 : nil }.isEmpty)
    }

    func testCatalogueIsBoundedAndDoesNotMislabelIntelKeysAsCoreTypes() {
        for chip in ["Apple M1 Pro", "Apple M2", "Apple M3 Max", "Apple M4 Pro", "Apple M5 Max"] {
            let keys = MinimalSMC.temperatureKeys(forChip: chip)
            XCTAssertLessThanOrEqual(keys.count, 40)
            XCTAssertEqual(Set(keys.map(\.key)).count, keys.count)
            XCTAssertTrue(keys.allSatisfy { $0.key.utf8.count == 4 && $0.key.hasPrefix("T") })
        }
        let keys = MinimalSMC.temperatureKeys(forChip: "Apple M1 Pro")
        XCTAssertEqual(keys.first { $0.key == "TC0E" }?.name, "CPU diode virtual")
        XCTAssertEqual(keys.first { $0.key == "TC0F" }?.name, "CPU diode filtered")
        XCTAssertTrue(keys.contains { $0.key == "Tp01" && $0.group == "CPU" })
        XCTAssertTrue(keys.contains { $0.key == "Tg05" && $0.group == "GPU" })
    }

    func testChipFamilySelectionCannotReuseOtherGenerationsOrGuessUnknownChip() {
        let m1 = Set(MinimalSMC.temperatureKeys(forChip: "Apple M1 Pro").map(\.key))
        XCTAssertFalse(m1.contains("Tp0Y"))
        XCTAssertFalse(m1.contains("Tp00"))
        let m4 = Set(MinimalSMC.temperatureKeys(forChip: "Apple M4").map(\.key))
        let m4Pro = Set(MinimalSMC.temperatureKeys(forChip: "Apple M4 Pro").map(\.key))
        XCTAssertTrue(m4.contains("Tg0G"))
        XCTAssertFalse(m4.contains("Tg1U"))
        XCTAssertTrue(m4Pro.contains("Tg1U"))
        XCTAssertFalse(m4Pro.contains("Tg0G"))
        XCTAssertEqual(MinimalSMC.temperatureKeys(forChip: nil).count, 11)
        XCTAssertEqual(MinimalSMC.temperatureKeys(forChip: "Apple M10").count, 11)
    }
}
