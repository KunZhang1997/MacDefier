import Foundation
import CoreGraphics

struct DiskTreemapItem {
    let id: String
    let weight: Double
}

struct DiskTreemapTile: Identifiable {
    let id: String
    let frame: CGRect
}

/// A padding-free squarified treemap. The caller supplies unique IDs and groups
/// small entries before laying out the map; no minimum area distorts the weights.
enum DiskTreemapLayout {
    private struct Entry {
        let id: String
        let weight: Double
    }

    private struct Region {
        var left: Double
        var top: Double
        let right: Double
        let bottom: Double

        var width: Double { max(0, right - left) }
        var height: Double { max(0, bottom - top) }
    }

    static func layout(_ items: [DiskTreemapItem], in bounds: CGRect) -> [DiskTreemapTile] {
        let x = Double(bounds.origin.x)
        let y = Double(bounds.origin.y)
        let width = Double(bounds.size.width)
        let height = Double(bounds.size.height)
        let right = x + width
        let bottom = y + height
        let area = width * height
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width > 0, height > 0, right.isFinite, bottom.isFinite,
              right > x, bottom > y, area.isFinite, area > 0 else { return [] }

        let sorted = items.filter { $0.weight.isFinite && $0.weight > 0 }.sorted {
            if $0.weight != $1.weight { return $0.weight > $1.weight }
            return $0.id < $1.id
        }
        guard let largest = sorted.first?.weight else { return [] }

        // Scaling first prevents a finite input set from overflowing its sum.
        let entries = sorted.map { Entry(id: $0.id, weight: $0.weight / largest) }
        let positiveCount = entries.firstIndex { $0.weight == 0 } ?? entries.count
        var region = Region(left: x, top: y, right: right, bottom: bottom)
        var tiles: [DiskTreemapTile] = []
        tiles.reserveCapacity(entries.count)
        var start = 0

        while start < positiveCount {
            guard region.width > 0, region.height > 0 else { break }
            // Recompute the suffix rather than subtracting large rows: a small
            // final row must not lose its weight through cancellation.
            let remainingWeight = sum(entries[start..<positiveCount])
            var end = start + 1
            var rowWeight = entries[start].weight
            var rowWorst = worstAspect(
                maximum: entries[start].weight, minimum: entries[start].weight,
                rowWeight: rowWeight, remainingWeight: remainingWeight, region: region
            )
            while end < positiveCount {
                let nextWeight = sum(entries[start...end])
                let nextWorst = worstAspect(
                    maximum: entries[start].weight, minimum: entries[end].weight,
                    rowWeight: nextWeight, remainingWeight: remainingWeight, region: region
                )
                guard nextWorst <= rowWorst else { break }
                rowWeight = nextWeight
                rowWorst = nextWorst
                end += 1
            }
            place(
                entries[start..<end], rowWeight: rowWeight,
                remainingWeight: remainingWeight, finalRow: end == positiveCount,
                region: &region, tiles: &tiles
            )
            start = end
        }

        // A positive weight can be smaller than Double's representable ratio or
        // the remaining coordinate precision. Preserve its ID as a zero-area
        // tile instead of inventing a minimum area or returning an invalid rect.
        for entry in entries[start...] {
            tiles.append(DiskTreemapTile(
                id: entry.id, frame: CGRect(x: region.left, y: region.top, width: 0, height: 0)
            ))
        }
        return tiles
    }

    /// Log aspect ratios avoid overflow in squared-side/squared-weight formulas.
    private static func worstAspect(
        maximum: Double, minimum: Double, rowWeight: Double,
        remainingWeight: Double, region: Region
    ) -> Double {
        let shortSide = min(region.width, region.height)
        let longSide = max(region.width, region.height)
        let logThickness = log(longSide) + log(rowWeight) - log(remainingWeight)
        let logMinimumSide = log(shortSide) + log(minimum) - log(rowWeight)
        let logMaximumSide = log(shortSide) + log(maximum) - log(rowWeight)
        return max(logThickness - logMinimumSide, logMaximumSide - logThickness)
    }

    private static func place(
        _ row: ArraySlice<Entry>, rowWeight: Double, remainingWeight: Double,
        finalRow: Bool, region: inout Region, tiles: inout [DiskTreemapTile]
    ) {
        let fraction = min(1, max(0, rowWeight / remainingWeight))
        var accumulated = 0.0
        var correction = 0.0
        if region.width >= region.height {
            let edge = finalRow ? region.right : min(region.right, region.left + region.width * fraction)
            var cursor = region.top
            for index in row.indices {
                add(row[index].weight, to: &accumulated, correction: &correction)
                let next = index == row.index(before: row.endIndex)
                    ? region.bottom
                    : min(region.bottom, max(cursor, region.top + region.height * (accumulated / rowWeight)))
                tiles.append(DiskTreemapTile(
                    id: row[index].id,
                    frame: CGRect(x: region.left, y: cursor, width: edge - region.left, height: next - cursor)
                ))
                cursor = next
            }
            region.left = edge
        } else {
            let edge = finalRow ? region.bottom : min(region.bottom, region.top + region.height * fraction)
            var cursor = region.left
            for index in row.indices {
                add(row[index].weight, to: &accumulated, correction: &correction)
                let next = index == row.index(before: row.endIndex)
                    ? region.right
                    : min(region.right, max(cursor, region.left + region.width * (accumulated / rowWeight)))
                tiles.append(DiskTreemapTile(
                    id: row[index].id,
                    frame: CGRect(x: cursor, y: region.top, width: next - cursor, height: edge - region.top)
                ))
                cursor = next
            }
            region.top = edge
        }
    }

    private static func sum(_ entries: ArraySlice<Entry>) -> Double {
        var total = 0.0
        var correction = 0.0
        for entry in entries { add(entry.weight, to: &total, correction: &correction) }
        return total
    }

    private static func add(_ value: Double, to total: inout Double, correction: inout Double) {
        let adjusted = value - correction
        let next = total + adjusted
        correction = (next - total) - adjusted
        total = next
    }
}
