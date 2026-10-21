import Foundation

/// Numeric and frame-index validation for untrusted `pet.json` manifests.
/// Keep this in the import boundary so render code never receives values that
/// can overflow or allocate an unbounded frame range.
public enum PetManifestSafety {
    public static let maximumCells = 200

    public static func cellCount(
        columns: Int,
        rows: Int,
        maximum: Int = maximumCells
    ) -> Int? {
        guard columns > 0, rows > 0, maximum > 0 else { return nil }
        let (cells, overflow) = columns.multipliedReportingOverflow(by: rows)
        guard !overflow, cells > 0, cells <= maximum else { return nil }
        return cells
    }

    public static func resolvedFrames(
        frames: [Int]?,
        start: Int?,
        count: Int?,
        totalCells: Int
    ) -> [Int]? {
        guard totalCells > 0, totalCells <= maximumCells else { return nil }

        if let frames, !frames.isEmpty {
            guard frames.allSatisfy({ $0 >= 0 && $0 < totalCells }) else { return nil }
            return frames
        }

        let safeStart = start ?? 0
        let safeCount = count ?? 1
        guard safeStart >= 0, safeStart < totalCells, safeCount > 0 else { return nil }
        let (rawEnd, overflow) = safeStart.addingReportingOverflow(safeCount)
        guard !overflow else { return nil }
        let end = min(totalCells, rawEnd)
        guard safeStart < end else { return nil }
        return Array(safeStart..<end)
    }

    public static func frameMapIsValid(_ frameMap: [String: Int]?, totalCells: Int) -> Bool {
        guard totalCells > 0, totalCells <= maximumCells else { return false }
        return frameMap?.values.allSatisfy { $0 >= 0 && $0 < totalCells } ?? true
    }
}
