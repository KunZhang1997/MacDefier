// ScanReusePolicy — don't re-scan / re-hit AI when a recent result is still usable.
// Kit TTLs (cleanup / software / aiNarrative) live in CleanupKit.CleanupReusePolicy.

import Foundation
import CleanupKit

enum ScanReusePolicy {
    /// Diagnostic home / chat reuse window (app-owned; kit has no diagnostic scan).
    static let diagnosticTTL: TimeInterval = 10 * 60
    /// Cleanup preview reuse — single source: CleanupReusePolicy.
    static var cleanupTTL: TimeInterval { CleanupReusePolicy.cleanupTTL }
    /// Software inventory reuse.
    static var softwareTTL: TimeInterval { CleanupReusePolicy.softwareTTL }
    /// AI narrative reuse (even if rules result is slightly older within same scan).
    static var aiNarrativeTTL: TimeInterval { CleanupReusePolicy.aiNarrativeTTL }

    static func isFresh(_ date: Date?, ttl: TimeInterval) -> Bool {
        CleanupReusePolicy.isFresh(date, ttl: ttl)
    }
}
