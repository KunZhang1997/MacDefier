import Foundation

/// Immutable scan metadata. Filesystem work happens during preparation, never
/// during row rendering or checkbox changes. Execution still uses live PathGate checks.
struct CleanupPreviewIndex: Sendable {
    struct Location: Sendable {
        let group: Int
        let item: Int
    }

    struct SelectionIdentity: Hashable, Sendable {
        let paths: Set<String>
        let category: CleanupCategory
        let risk: CleanupRisk
        let appName: String?
    }

    struct Prepared: Sendable {
        let groups: [CleanupCategoryGroup]
        let index: CleanupPreviewIndex
    }

    private struct Record: Sendable {
        let id: String
        let path: String
        let components: [Substring]
        let bytes: UInt64
    }

    private(set) var locations: [String: Location] = [:]
    private(set) var paths: [String: [String]] = [:]
    private(set) var identities: [String: SelectionIdentity] = [:]
    private var records: [Record] = []
    private(set) var totalBytes: UInt64 = 0

    /// Called on a utility task; a cancelled/superseded scan stops preparation too.
    static func prepare(
        _ result: [CleanupCategoryGroup],
        preserving selections: Set<SelectionIdentity> = []
    ) throws -> Prepared {
        var canonicalPaths: [String: String] = [:]
        func canonical(_ path: String) throws -> String {
            try Task.checkCancellation()
            if let cached = canonicalPaths[path] { return cached }
            let resolved = PathGate.normalize(path)
            canonicalPaths[path] = resolved
            return resolved
        }
        var groups = result
        var seenPaths = Set<String>()
        // Keep the established orphan-first cross-category ownership rule.
        for gi in groups.indices.sorted(by: {
            (groups[$0].category == .orphans ? 0 : 1) < (groups[$1].category == .orphans ? 0 : 1)
        }) {
            var items: [CleanableItem] = []
            for item in groups[gi].items {
                if try seenPaths.insert(canonical(item.path)).inserted { items.append(item) }
            }
            groups[gi].items = items
        }
        groups.removeAll { $0.items.isEmpty && !$0.isPartial }

        var index = CleanupPreviewIndex()
        for gi in groups.indices {
            for ii in groups[gi].items.indices {
                let item = groups[gi].items[ii]
                var uniquePaths = Set<String>()
                var displayPaths: [String] = []
                for path in [item.path] + item.extraPaths {
                    if try uniquePaths.insert(canonical(path)).inserted { displayPaths.append(path) }
                }
                let identity = SelectionIdentity(paths: uniquePaths, category: item.category,
                                                 risk: item.risk, appName: item.appName)
                groups[gi].items[ii].isSelected = item.risk != .skip && selections.contains(identity)
                index.locations[item.id] = Location(group: gi, item: ii)
                index.paths[item.id] = displayPaths
                index.identities[item.id] = identity
                let primary = try canonical(item.path)
                index.records.append(Record(id: item.id, path: primary,
                                            components: primary.split(separator: "/"), bytes: item.bytes))
            }
        }
        try Task.checkCancellation()
        index.records.sort { lhs, rhs in
            if lhs.path == rhs.path { return lhs.bytes > rhs.bytes }
            return lhs.components.lexicographicallyPrecedes(rhs.components)
        }
        index.totalBytes = index.bytes(selectedIDs: nil)
        return Prepared(groups: groups, index: index)
    }

    /// Linear pass over the already ordered path tree; parents cover descendants.
    /// A sibling such as /a-foo must never interrupt the /a subtree.
    func bytes(selectedIDs: Set<String>?) -> UInt64 {
        var lastKept: String?
        var total: UInt64 = 0
        for record in records {
            if let selectedIDs, !selectedIDs.contains(record.id) { continue }
            if let parent = lastKept,
               record.path == parent || parent == "/" || record.path.hasPrefix(parent + "/") {
                continue
            }
            total &+= record.bytes
            lastKept = record.path
        }
        return total
    }
}
