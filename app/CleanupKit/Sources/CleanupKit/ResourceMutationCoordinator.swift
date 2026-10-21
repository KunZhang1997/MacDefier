import Foundation

/// Product surfaces may discover the same resources. Mutations share these leases.
public actor ResourceMutationCoordinator {
    public static let shared = ResourceMutationCoordinator()
    private struct Lease {
        let paths: [String]
        let identities: Set<String>
    }
    private var leases: [UUID: Lease] = [:]

    public init() {}

    public func acquire(paths: [String]) -> UUID? {
        let normalized = Array(Set(paths.filter { $0.hasPrefix("/") }.map(PathGate.normalize))).sorted()
        guard !normalized.isEmpty else { return nil }
        let identities = Set(normalized.compactMap { path -> String? in
            guard let s = try? UninstallFileBoundary.snapshot(path) else { return nil }
            return "\(s.item.device):\(s.item.inode):\(s.item.kind)"
        })
        guard !leases.values.contains(where: { lease in
            !identities.isDisjoint(with: lease.identities)
                || normalized.contains { path in lease.paths.contains { Self.overlaps(path, $0) } }
        }) else { return nil }
        let token = UUID()
        leases[token] = Lease(paths: normalized, identities: identities)
        return token
    }

    public func release(_ token: UUID) { leases.removeValue(forKey: token) }

    public static func overlaps(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs == "/" || rhs == "/" || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }
}

public enum CleanupResourceEvents {
    public static let didChange = Notification.Name("com.macdefier.resourcesChanged")
    public static func publish(paths: [String]) {
        let paths = Array(Set(paths)).sorted()
        guard !paths.isEmpty else { return }
        NotificationCenter.default.post(name: didChange, object: nil, userInfo: ["paths": paths])
    }
}
