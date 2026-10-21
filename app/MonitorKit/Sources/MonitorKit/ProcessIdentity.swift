import AppKit
import Darwin
import Foundation

/// Identity is captured at sample time, never reconstructed from a historical PID alone.
public struct MonitoredProcessIdentity: Codable, Hashable, Sendable, Identifiable {
    public var pid: Int32
    public var startSeconds: UInt64
    public var startMicroseconds: UInt64
    public var executable: String
    public var appPath: String?
    public var bundleID: String?
    public var ownerName: String
    public var id: String { "\(pid):\(startSeconds):\(startMicroseconds):\(executable)" }

    public static func read(pid: Int32) -> Self? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
        // Outermost .app owns embedded helpers; no fuzzy name or parent-process attribution.
        let parts = URL(fileURLWithPath: path).pathComponents
        let appPath = parts.firstIndex(where: { $0.hasSuffix(".app") }).map {
            NSString.path(withComponents: Array(parts.prefix($0 + 1)))
        }
        let bundle = appPath.flatMap { Bundle(path: $0) }
        let name = appPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ?? ProcessOwnerRegistry.owner(for: path) ?? URL(fileURLWithPath: path).lastPathComponent
        return .init(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec,
                     executable: path, appPath: appPath, bundleID: bundle?.bundleIdentifier, ownerName: name)
    }

    public func isCurrent() -> Bool { Self.read(pid: pid)?.id == id }
}

/// The application supplies already-scanned CLI package roots. MonitorKit has no CleanupKit dependency.
public enum ProcessOwnerRegistry {
    private static let lock = NSLock()
    private static var roots: [String: String] = [:]
    public static func replaceCLIInventory(_ inventory: [String: String]) {
        let resolved = inventory.reduce(into: [String: String]()) { result, item in
            let path = URL(fileURLWithPath: item.key).resolvingSymlinksInPath().path
            if path != "/", !path.isEmpty { result[path] = item.value }
        }
        lock.lock(); roots = resolved; lock.unlock()
    }
    static func owner(for path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return roots.filter { path == $0.key || path.hasPrefix($0.key + "/") }
            .max(by: { $0.key.count < $1.key.count })?.value
    }
}

/// Shared normal-quit primitive. Callers show confirmation before invoking it.
@MainActor public enum MonitoredApplicationExit {
    public enum Result: String, Codable, Sendable { case requested, identityChanged, unavailable, rejected }
    public static func request(_ identity: MonitoredProcessIdentity) -> Result {
        guard identity.isCurrent() else { return .identityChanged }
        guard identity.pid > 1, identity.pid != getpid(),
              let app = NSRunningApplication(processIdentifier: identity.pid),
              app.activationPolicy == .regular,
              let bid = app.bundleIdentifier, bid == identity.bundleID,
              !bid.hasPrefix("com.apple."), !bid.hasPrefix("com.macdefier."),
              app.bundleURL?.resolvingSymlinksInPath().path == identity.appPath,
              app.executableURL?.resolvingSymlinksInPath().path == identity.executable else { return .unavailable }
        // Recheck after resolving AppKit metadata as well as after the user's confirmation.
        guard identity.isCurrent() else { return .identityChanged }
        return app.terminate() ? .requested : .rejected
    }
}
