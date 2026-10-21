// PathReclaimDeduper — non-overlapping reclaimable byte totals (parent covers children).

import Foundation

public enum PathReclaimDeduper {
    public struct Entry: Sendable {
        public let path: String
        public let bytes: UInt64
        public init(path: String, bytes: UInt64) {
            self.path = path
            self.bytes = bytes
        }
    }

    /// 解析后组件边界路径树：父目录已覆盖子项时子项不计入总量。
    public static func uniqueReclaimableBytes(_ entries: [Entry]) -> UInt64 {
        // path → max bytes (同路径取较大值)
        var byPath: [String: UInt64] = [:]
        for e in entries {
            let p = PathGate.normalize(e.path)
            byPath[p] = max(byPath[p] ?? 0, e.bytes)
        }
        // Component ordering keeps every parent's full subtree contiguous and
        // places the parent before descendants, even for siblings such as
        // `/a-foo` whose raw string order would otherwise split `/a`'s subtree.
        let paths = componentSorted(Array(byPath.keys))
        var kept: [String] = []
        for p in paths {
            if let previous = kept.last,
               isSameOrDescendant(p, of: previous) {
                continue
            }
            kept.append(p)
        }
        return kept.reduce(UInt64(0)) { $0 &+ (byPath[$1] ?? 0) }
    }

    /// 从路径列表去掉被父路径覆盖的子路径（executor 防双重处理）。
    public static func nonOverlappingPaths(_ paths: [String]) -> [String] {
        let normalized = Array(Set(paths.map { PathGate.normalize($0) }))
        let sorted = componentSorted(normalized)
        var kept: [String] = []
        for p in sorted {
            if let previous = kept.last,
               isSameOrDescendant(p, of: previous) {
                continue
            }
            kept.append(p)
        }
        return kept
    }

    private static func componentSorted(_ paths: [String]) -> [String] {
        let records = paths.map { path in
            (path: path, components: path.split(separator: "/").map(String.init))
        }
        return records.sorted { lhs, rhs in
            lhs.components.lexicographicallyPrecedes(rhs.components)
        }.map(\.path)
    }

    private static func isSameOrDescendant(_ path: String, of parent: String) -> Bool {
        if path == parent { return true }
        if parent == "/" { return path.hasPrefix("/") }
        return path.hasPrefix(parent + "/")
    }
}
