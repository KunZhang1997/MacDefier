import Foundation
import CoreGraphics

@main
enum DiskTreemapSmokeMain {
    private static var assertions = 0
    private static var cases = 0

    static func main() {
        test("weighted rectangles cover a translated canvas") {
            verify(items([60, 25, 10, 5]), in: CGRect(x: 19, y: -17, width: 760, height: 420))
        }
        test("equal weights form squares rather than long stripes") {
            let input = items([1, 1, 1, 1])
            let tiles = verify(input, in: CGRect(x: 0, y: 0, width: 100, height: 100))
            for tile in tiles {
                check(abs(tile.frame.width - 50) < 1e-10 && abs(tile.frame.height - 50) < 1e-10,
                      "four equal weights should produce 50 x 50 squares")
            }
        }
        test("one valid item occupies the canvas") {
            let bounds = CGRect(x: -80, y: 73, width: 350, height: 290)
            let tiles = verify([DiskTreemapItem(id: "only", weight: 27)], in: bounds)
            check(tiles.count == 1 && tiles[0].frame == bounds, "single item must match bounds")
        }
        test("invalid weights are excluded") {
            let input = [
                DiskTreemapItem(id: "zero", weight: 0),
                DiskTreemapItem(id: "negative", weight: -10),
                DiskTreemapItem(id: "nan", weight: .nan),
                DiskTreemapItem(id: "infinity", weight: .infinity),
                DiskTreemapItem(id: "negative-infinity", weight: -.infinity),
                DiskTreemapItem(id: "valid", weight: 10)
            ]
            let tiles = verify(input, in: CGRect(x: 0, y: 0, width: 300, height: 200))
            check(tiles.map(\.id) == ["valid"], "only positive finite weights are allowed")
            check(DiskTreemapLayout.layout(Array(input.dropLast()), in: .init(x: 0, y: 0, width: 10, height: 10)).isEmpty,
                  "an all-invalid set should be empty")
        }
        test("empty and invalid bounds produce no tiles") {
            let input = items([3, 2, 1])
            let invalid: [CGRect] = [
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
            for bounds in invalid {
                check(DiskTreemapLayout.layout(input, in: bounds).isEmpty, "invalid bounds: \(bounds)")
            }
            check(DiskTreemapLayout.layout([], in: .init(x: 0, y: 0, width: 10, height: 10)).isEmpty,
                  "an empty input should be empty")
        }
        test("huge and subnormal weights retain their proportions") {
            let bounds = CGRect(x: 0, y: 0, width: 800, height: 500)
            verify(items([1e308, 8e307, 5e307, 3e307]), in: bounds)
            verify(items([1e-300, 8e-301, 5e-301, 3e-301]), in: bounds)
            verify(items([Double.leastNonzeroMagnitude * 16, Double.leastNonzeroMagnitude * 8,
                          Double.leastNonzeroMagnitude * 4, Double.leastNonzeroMagnitude * 2]), in: bounds)
        }
        test("unrepresentably small tiles remain finite and do not steal area") {
            let input = items([Double.greatestFiniteMagnitude, 1, Double.leastNonzeroMagnitude])
            let tiles = verify(input, in: CGRect(x: 5, y: 7, width: 640, height: 480))
            check(tiles.count == 3, "valid IDs must survive a ratio underflow")
            check(tiles[0].frame.width * tiles[0].frame.height == 640 * 480,
                  "unrepresentable tiny weights must not enlarge their visible areas")
            check(tiles.dropFirst().allSatisfy { $0.frame.width * $0.frame.height == 0 },
                  "unrepresentable tiles should have zero area")
        }
        test("very narrow canvases remain disjoint and proportional") {
            let input = items([44, 23, 17, 9, 4, 2, 1])
            verify(input, in: CGRect(x: -0.5, y: 10, width: 0.001, height: 1000))
            verify(input, in: CGRect(x: 10, y: -0.5, width: 1000, height: 0.001))
            verify(input, in: CGRect(x: 0, y: 0, width: 1e100, height: 1e-100))
            verify(input, in: CGRect(x: 0, y: 0, width: 1e-100, height: 1e100))
        }
        test("96 items and deterministic input permutations") {
            let input = (0..<96).map {
                DiskTreemapItem(id: String(format: "file-%03d", $0), weight: Double(($0 * 37) % 17 + 1))
            }
            let bounds = CGRect(x: 0, y: 0, width: 913, height: 527)
            let expected = verify(input, in: bounds)
            let order = input.filter { Int($0.id.suffix(3))! % 2 == 0 }
                + input.filter { Int($0.id.suffix(3))! % 2 != 0 }
            for permutation in [Array(input.reversed()), order, Array(input[31...] + input[..<31])] {
                let result = verify(permutation, in: bounds)
                check(equal(expected, result), "input order must not change ID/frame output")
            }
            let tied = DiskTreemapLayout.layout([
                DiskTreemapItem(id: "z", weight: 4), DiskTreemapItem(id: "a", weight: 4),
                DiskTreemapItem(id: "m", weight: 8)
            ], in: bounds)
            check(tied.map(\.id) == ["m", "a", "z"], "sort by descending weight, then ascending ID")
        }
        test("scale and translation do not change partition proportions") {
            let input = items([13, 8, 5, 3, 2, 1])
            let original = verify(input, in: CGRect(x: 0, y: 0, width: 320, height: 180))
            let transformed = verify(input, in: CGRect(x: 41, y: -29, width: 2240, height: 1260))
            for (first, second) in zip(original, transformed) {
                check(first.id == second.id, "scaling must preserve order")
                check(near(Double(second.frame.minX), Double(first.frame.minX) * 7 + 41, scale: 2240),
                      "scaled x coordinate")
                check(near(Double(second.frame.minY), Double(first.frame.minY) * 7 - 29, scale: 1260),
                      "scaled y coordinate")
                check(near(Double(second.frame.width), Double(first.frame.width) * 7, scale: 2240),
                      "scaled width")
                check(near(Double(second.frame.height), Double(first.frame.height) * 7, scale: 1260),
                      "scaled height")
            }
        }
        test("generated distributions cover both canvas orientations") {
            // Deterministic fixtures exercise varied grouping boundaries without
            // depending on a random seed or on the implementation's row choices.
            for seed in 1...24 {
                let count = (seed * 13) % 96 + 1
                let input = (0..<count).map {
                    DiskTreemapItem(id: "\($0)", weight: pow(10, Double(($0 * 19 + seed * 7) % 61 - 30) / 5))
                }
                verify(input, in: CGRect(x: 13, y: 17, width: 640, height: 360))
                verify(input, in: CGRect(x: -23, y: -11, width: 360, height: 640))
            }
        }
        print("DiskTreemapSmoke: PASS (\(cases) cases, \(assertions) checks)")
    }

    private static func items(_ weights: [Double]) -> [DiskTreemapItem] {
        weights.enumerated().map { DiskTreemapItem(id: "item-\($0.offset)", weight: $0.element) }
    }

    @discardableResult
    private static func verify(_ input: [DiskTreemapItem], in bounds: CGRect) -> [DiskTreemapTile] {
        let valid = input.filter { $0.weight.isFinite && $0.weight > 0 }.sorted {
            $0.weight == $1.weight ? $0.id < $1.id : $0.weight > $1.weight
        }
        let tiles = DiskTreemapLayout.layout(input, in: bounds)
        check(tiles.map(\.id) == valid.map(\.id), "all and only valid items must be laid out in sorted order")
        let maximum = valid.map(\.weight).max() ?? 1
        let normalized = valid.map { $0.weight / maximum }
        let total = normalized.reduce(0, +)
        let canvasArea = Double(bounds.width) * Double(bounds.height)
        var actualTotal = 0.0
        for (index, tile) in tiles.enumerated() {
            let frame = tile.frame
            let values = [frame.origin.x, frame.origin.y, frame.width, frame.height]
            check(values.allSatisfy(\.isFinite), "tile \(tile.id) contains a non-finite coordinate")
            check(frame.width >= 0 && frame.height >= 0, "tile \(tile.id) has a negative size")
            check(frame.minX >= bounds.minX && frame.minY >= bounds.minY
                  && frame.maxX <= bounds.maxX && frame.maxY <= bounds.maxY,
                  "tile \(tile.id) extends outside the canvas")
            let actual = Double(frame.width) * Double(frame.height)
            let expected = canvasArea * (normalized[index] / total)
            check(near(actual, expected, scale: canvasArea),
                  "tile \(tile.id) area \(actual) should match \(expected)")
            actualTotal += actual
            for previous in tiles[..<index] {
                let overlapWidth = max(0, min(frame.maxX, previous.frame.maxX) - max(frame.minX, previous.frame.minX))
                let overlapHeight = max(0, min(frame.maxY, previous.frame.maxY) - max(frame.minY, previous.frame.minY))
                check(overlapWidth == 0 || overlapHeight == 0,
                      "tiles \(previous.id) and \(tile.id) overlap")
            }
        }
        check(near(actualTotal, canvasArea, scale: canvasArea), "tiles must cover the entire canvas")
        return tiles
    }

    private static func equal(_ left: [DiskTreemapTile], _ right: [DiskTreemapTile]) -> Bool {
        left.count == right.count && zip(left, right).allSatisfy { $0.id == $1.id && $0.frame == $1.frame }
    }

    private static func near(_ left: Double, _ right: Double, scale: Double) -> Bool {
        abs(left - right) <= max(abs(scale) * 1e-10, Double.leastNonzeroMagnitude)
    }

    private static func test(_ name: String, _ body: () -> Void) {
        body()
        cases += 1
        print("PASS: \(name)")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else {
            fputs("DiskTreemapSmoke: FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
