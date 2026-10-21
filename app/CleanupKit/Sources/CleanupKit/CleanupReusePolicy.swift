// CleanupReusePolicy — single source of truth for kit-layer scan reuse TTLs.

import Foundation

/// Kit-owned reuse windows (seconds). App-layer diagnostic TTL stays in `ScanReusePolicy`.
public enum CleanupReusePolicy {
    /// Cleanup junk preview list.
    public static let cleanupTTL: TimeInterval = 10 * 60
    /// Software inventory list.
    public static let softwareTTL: TimeInterval = 15 * 60
    /// AI narrative attached to a kit scan (cleanup / software).
    public static let aiNarrativeTTL: TimeInterval = 10 * 60

    public static func isFresh(_ date: Date?, ttl: TimeInterval) -> Bool {
        guard let date, date > .distantPast else { return false }
        return Date().timeIntervalSince(date) < ttl
    }
}
