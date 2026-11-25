import AppKit
import Darwin
import Foundation

public struct BootedSimulatorDevice: Codable, Equatable, Sendable, Identifiable {
    public var id: String { udid }
    public var udid: String
    public var name: String
    public var runtime: String

    public init(udid: String, name: String, runtime: String) {
        self.udid = udid
        self.name = name
        self.runtime = runtime
    }
}

public enum ProcessFamilyKind: String, Codable, Equatable, Sendable {
    case userApp
    case automatedBrowser
    case iosSimulator
    case systemService
    case cliOrDaemon
}

public struct ProcessFamilySummary: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: ProcessFamilyKind
    public var processCount: Int
    public var footprintBytes: Double
    public var cpuUsage: Double
    public var rootPID: Int?
    public var rootIdentity: MonitoredProcessIdentity?
    public var appPath: String?
    public var bundleID: String?
    public var automationHint: String?
    public var bootedSimulators: [BootedSimulatorDevice]
    public var hasActiveSimulatedOS: Bool

    public init(
        id: String,
        name: String,
        kind: ProcessFamilyKind,
        processCount: Int,
        footprintBytes: Double,
        cpuUsage: Double,
        rootPID: Int? = nil,
        rootIdentity: MonitoredProcessIdentity? = nil,
        appPath: String? = nil,
        bundleID: String? = nil,
        automationHint: String? = nil,
        bootedSimulators: [BootedSimulatorDevice] = [],
        hasActiveSimulatedOS: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.processCount = processCount
        self.footprintBytes = footprintBytes
        self.cpuUsage = cpuUsage
        self.rootPID = rootPID
        self.rootIdentity = rootIdentity
        self.appPath = appPath
        self.bundleID = bundleID
        self.automationHint = automationHint
        self.bootedSimulators = bootedSimulators
        self.hasActiveSimulatedOS = hasActiveSimulatedOS
    }
}

public struct BrowserAutomationInfo: Equatable, Sendable {
    public var debugPort: Int?
    public var profileHint: String?
    public var isHeadless: Bool

    public var displayHint: String {
        var parts: [String] = []
        if let debugPort {
            parts.append(":\(debugPort)")
        } else if isHeadless {
            parts.append("headless")
        }
        if let profileHint, !profileHint.isEmpty {
            parts.append(profileHint)
        }
        return parts.isEmpty ? "automation" : parts.joined(separator: " · ")
    }
}

public enum BrowserAutomationClassifier {
    private static let browserBundleNames: Set<String> = [
        "Google Chrome.app",
        "Google Chrome Canary.app",
        "Chromium.app",
        "Brave Browser.app",
        "Microsoft Edge.app",
        "Arc.app",
        "Vivaldi.app",
        "Opera.app",
    ]

    public static func isBrowserBundle(appPath: String?) -> Bool {
        guard let appPath else { return false }
        let leaf = URL(fileURLWithPath: appPath).lastPathComponent
        return browserBundleNames.contains(leaf)
    }

    /// Parses raw `KERN_PROCARGS2` buffer safely without unsafe pointer overreads.
    /// Rejects truncated buffers where any `argv` entry lacks a terminating NUL or `args.count != argc`.
    public static func parseProcArgs2Buffer(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > 4 else { return nil }
        let argc = Int(Int32(littleEndian: bytes.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: 0, as: Int32.self)
        }))
        guard argc >= 1, argc <= 4096 else { return nil }

        var idx = 4
        // Skip exec_path up to first NUL
        while idx < bytes.count && bytes[idx] != 0 {
            idx += 1
        }
        guard idx < bytes.count else { return nil }
        // Skip NUL alignment padding before argv[0]
        while idx < bytes.count && bytes[idx] == 0 {
            idx += 1
        }
        guard idx < bytes.count else { return nil }

        var args: [String] = []
        args.reserveCapacity(min(argc, 64))
        while idx < bytes.count && args.count < argc {
            let start = idx
            while idx < bytes.count && bytes[idx] != 0 {
                idx += 1
            }
            // Truncated buffer without NUL terminator -> reject instead of guessing partial path/flag
            guard idx < bytes.count, bytes[idx] == 0 else { return nil }
            let str = String(decoding: bytes[start..<idx], as: UTF8.self)
            args.append(str)
            idx += 1
        }
        guard args.count == argc else { return nil }
        return args
    }

    public static func readProcessArguments(pid: Int32) -> [String]? {
        guard pid > 1 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        let maxArgBytes = 1024 * 1024 // KERN_ARGMAX (1 MiB)
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= maxArgBytes else { return nil }
        let allocSize = min(size + 1024, maxArgBytes)
        var buffer = [UInt8](repeating: 0, count: allocSize)
        var actual = allocSize
        let rc = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, 3, raw.baseAddress, &actual, nil, 0)
        }
        guard rc == 0, actual > 4, actual <= buffer.count else { return nil }
        if actual < buffer.count {
            buffer.removeSubrange(actual..<buffer.count)
        }
        return parseProcArgs2Buffer(buffer)
    }

    public static func classify(
        executablePath: String,
        appPath: String?,
        arguments: [String],
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> BrowserAutomationInfo? {
        guard isBrowserBundle(appPath: appPath) else { return nil }
        // Never classify a renderer/GPU/utility child helper directly.
        if executablePath.contains("Helper") || executablePath.contains(".xpc/") {
            return nil
        }
        if arguments.contains(where: { $0.hasPrefix("--type=") }) {
            return nil
        }

        var isHeadless = false
        var hasEnableAutomation = false
        var hasNoStartupWindow = false
        var debugPort: Int?
        var userDataDir: String?

        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            if arg == "--headless" || arg.hasPrefix("--headless=") {
                isHeadless = true
            } else if arg == "--enable-automation" || arg == "--remote-debugging-pipe" {
                hasEnableAutomation = true
            } else if arg == "--no-startup-window" {
                hasNoStartupWindow = true
            } else if let value = Self.flagValue(arg: arg, next: i + 1 < arguments.count ? arguments[i + 1] : nil, prefix: "--remote-debugging-port", consumedNext: &i) {
                if let port = Int(value), (0...65535).contains(port) {
                    debugPort = port
                }
            } else if let value = Self.flagValue(arg: arg, next: i + 1 < arguments.count ? arguments[i + 1] : nil, prefix: "--user-data-dir", consumedNext: &i) {
                userDataDir = value
            }
            i += 1
        }

        let isCustomProfile = Self.isNonDefaultBrowserDataDir(userDataDir, homeDirectory: homeDirectory)
        // CRITICAL SAFETY INVARIANT:
        // A non-headless browser running on the user's default profile (or omitted --user-data-dir)
        // shares SingletonLock with all normal user windows. NEVER classify it as an isolated background browser!
        let isAutomated = isHeadless
            || (isCustomProfile && (hasEnableAutomation || debugPort != nil || hasNoStartupWindow))

        guard isAutomated else { return nil }
        let hint = isCustomProfile ? Self.sanitizeProfileHint(userDataDir) : nil
        return BrowserAutomationInfo(debugPort: debugPort, profileHint: hint, isHeadless: isHeadless)
    }

    private static func flagValue(arg: String, next: String?, prefix: String, consumedNext: inout Int) -> String? {
        if arg.hasPrefix(prefix + "=") {
            return String(arg.dropFirst(prefix.count + 1))
        }
        if arg == prefix, let next, !next.hasPrefix("--") {
            consumedNext += 1
            return next
        }
        return nil
    }

    private static func normalizeCanonicalPath(_ raw: String) -> String {
        let resolved = URL(fileURLWithPath: raw).resolvingSymlinksInPath().standardizedFileURL.path
        if resolved.hasPrefix("/System/Volumes/Data/") {
            return String(resolved.dropFirst("/System/Volumes/Data".count))
        }
        return resolved
    }

    private static func isNonDefaultBrowserDataDir(_ rawPath: String?, homeDirectory: String) -> Bool {
        guard let rawPath, !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let expanded: String
        if rawPath == "~" {
            expanded = homeDirectory
        } else if rawPath.hasPrefix("~/") {
            expanded = homeDirectory + String(rawPath.dropFirst(1))
        } else {
            expanded = rawPath
        }
        let std = normalizeCanonicalPath(expanded)
        let stdHome = normalizeCanonicalPath(homeDirectory)
        let defaultRoots = [
            "\(stdHome)/Library/Application Support/Google/Chrome",
            "\(stdHome)/Library/Application Support/Google/Chrome Canary",
            "\(stdHome)/Library/Application Support/Chromium",
            "\(stdHome)/Library/Application Support/BraveSoftware/Brave-Browser",
            "\(stdHome)/Library/Application Support/Microsoft Edge",
            "\(stdHome)/Library/Application Support/Arc",
            "\(stdHome)/Library/Application Support/Arc/User Data",
            "\(stdHome)/Library/Application Support/Vivaldi",
            "\(stdHome)/Library/Application Support/com.operasoftware.Opera",
            "\(stdHome)/Library/Application Support/com.operasoftware.OperaGX",
        ]
        for def in defaultRoots where std == def || std.hasPrefix(def + "/") {
            return false
        }
        return true
    }

    private static func sanitizeProfileHint(_ rawPath: String?) -> String? {
        guard let rawPath, !rawPath.isEmpty else { return nil }
        let components = URL(fileURLWithPath: rawPath).standardizedFileURL.pathComponents
            .filter { $0 != "/" && $0 != "Users" && $0 != "System" && $0 != "Volumes" && $0 != "Data" && $0 != "private" && $0 != "tmp" && $0 != "var" }
        guard let leaf = components.last else { return nil }
        let genericLeaves: Set<String> = ["chrome-profile", "profile", "Default", "user-data", "browser-profile"]
        let chosen: String
        if genericLeaves.contains(leaf), components.count >= 2 {
            chosen = components[components.count - 2]
        } else {
            chosen = leaf
        }
        let clean = chosen.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        guard !clean.isEmpty else { return nil }
        return String(clean.prefix(28))
    }
}

public enum SimulatorControl {
    public enum ShutdownResult: Equatable, Sendable {
        case shutDown(count: Int)
        case noneBooted
        case invalidIdentifier
        case failed
    }

    private static let cacheLock = NSLock()
    private static var cachedDevices: (at: Date, devices: [BootedSimulatorDevice])?

    /// Guard against invoking `/usr/bin/xcrun` on Macs without CoreSimulator/Xcode, which would trigger a system CLT install dialog.
    public static var isSimulatorEnvironmentInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Developer/CoreSimulator")
            && FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun")
    }

    public static func parseSimctlBootedJSON(_ data: Data) -> [BootedSimulatorDevice] {
        struct Root: Decodable {
            struct Device: Decodable {
                let udid: String
                let name: String
                let state: String
            }
            let devices: [String: [Device]]
        }
        guard let decoded = try? JSONDecoder().decode(Root.self, from: data) else { return [] }
        var list: [BootedSimulatorDevice] = []
        for (runtimeKey, entries) in decoded.devices {
            let runtimeLabel = Self.humanRuntimeLabel(from: runtimeKey)
            for dev in entries where dev.state == "Booted" && UUID(uuidString: dev.udid) != nil {
                list.append(BootedSimulatorDevice(udid: dev.udid, name: dev.name, runtime: runtimeLabel))
            }
        }
        return list.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.udid < $1.udid
        }
    }

    public static func listBootedDevices(useCache: Bool = true) -> [BootedSimulatorDevice] {
        guard isSimulatorEnvironmentInstalled else { return [] }
        let now = Date()
        if useCache {
            cacheLock.lock()
            if let cached = cachedDevices, now.timeIntervalSince(cached.at) <= 4.0 {
                cacheLock.unlock()
                return cached.devices
            }
            cacheLock.unlock()
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        proc.arguments = ["simctl", "list", "devices", "booted", "-j"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return []
        }
        guard let data = readProcessOutput(from: outPipe.fileHandleForReading, process: proc, timeout: 2.0) else {
            return []
        }
        let devices = parseSimctlBootedJSON(data)
        cacheLock.lock()
        cachedDevices = (now, devices)
        cacheLock.unlock()
        return devices
    }

    public static func invalidateCache() {
        cacheLock.lock()
        cachedDevices = nil
        cacheLock.unlock()
    }

    public static func shutdownBooted(udids: [String]? = nil) -> ShutdownResult {
        if let udids, !udids.isEmpty {
            for id in udids where UUID(uuidString: id) == nil {
                return .invalidIdentifier
            }
        }
        guard isSimulatorEnvironmentInstalled else { return .failed }

        let targets: [String]
        if let udids, !udids.isEmpty {
            targets = udids
        } else {
            let booted = listBootedDevices(useCache: false)
            if booted.isEmpty {
                return .noneBooted
            }
            targets = booted.map(\.udid)
        }

        var okCount = 0
        for udid in targets {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            proc.arguments = ["simctl", "shutdown", udid]
            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
            } catch {
                continue
            }
            if readProcessOutput(from: outPipe.fileHandleForReading, process: proc, timeout: 5.0) != nil {
                okCount += 1
            }
        }
        invalidateCache()
        return okCount > 0 ? .shutDown(count: okCount) : .failed
    }

    private static func humanRuntimeLabel(from key: String) -> String {
        let suffix = key.components(separatedBy: "SimRuntime.").last ?? key
        let parts = suffix.split(separator: "-").map(String.init)
        guard let os = parts.first, parts.count >= 2 else { return suffix }
        let ver = parts.dropFirst().joined(separator: ".")
        return "\(os) \(ver)"
    }
}

public enum AutomatedBrowserExit {
    /// Terminates ONLY a verified automated/headless browser root process owned by the current user.
    /// Re-verifies start time, executable path, UID, and live `KERN_PROCARGS2` automation flags to eliminate PID-reuse risk.
    public static func terminate(_ identity: MonitoredProcessIdentity) -> MonitoredApplicationExit.Result {
        guard identity.pid > 1, identity.pid != getpid() else { return .unavailable }
        guard identity.isCurrent() else { return .identityChanged }

        var bsd = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(identity.pid, PROC_PIDTBSDINFO, 0, &bsd, expectedSize) == expectedSize,
              bsd.pbi_uid == getuid(),
              bsd.pbi_start_tvsec == identity.startSeconds,
              bsd.pbi_start_tvusec == identity.startMicroseconds
        else {
            return .identityChanged
        }

        guard let args = BrowserAutomationClassifier.readProcessArguments(pid: identity.pid),
              BrowserAutomationClassifier.classify(
                  executablePath: identity.executable,
                  appPath: identity.appPath,
                  arguments: args
              ) != nil
        else {
            return .unavailable
        }

        guard identity.isCurrent() else { return .identityChanged }
        return kill(identity.pid, SIGTERM) == 0 ? .requested : .rejected
    }
}

public enum ProcessFamilyInspector {
    private struct ProcRecord {
        let pid: Int32
        let ppid: Int32
        let uid: uid_t
        let startSec: UInt64
        let startUsec: UInt64
        let footprint: Double
        let path: String
        let fallbackName: String
        let appPath: String?
    }

    public static func capture(
        cpuByPID: [Int: Double] = [:],
        querySimulators: Bool = true,
        limit: Int = 16
    ) -> [ProcessFamilySummary] {
        guard limit > 0 else { return [] }
        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0 else { return [] }
        let cappedCount = min(Int(estimated) + 128, 131_072)
        var pids = [Int32](repeating: 0, count: cappedCount)
        let actual = pids.withUnsafeMutableBytes { raw -> Int32 in
            let byteCap = Int32(min(raw.count, Int(Int32.max)))
            return proc_listallpids(raw.baseAddress, byteCap)
        }
        guard actual > 0 else { return [] }
        let effectiveCount = min(Int(actual), pids.count)

        var records: [Int32: ProcRecord] = [:]
        records.reserveCapacity(effectiveCount)

        var pathBuf = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for i in 0..<effectiveCount {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var bsdBefore = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdBefore, bsdSize) == bsdSize else { continue }

            var usage = rusage_info_current()
            let rrc = withUnsafeMutablePointer(to: &usage) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
                }
            }
            let footprint = rrc == 0 ? Double(usage.ri_phys_footprint) : 0

            var bsdAfter = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdAfter, bsdSize) == bsdSize,
                  bsdBefore.pbi_start_tvsec == bsdAfter.pbi_start_tvsec,
                  bsdBefore.pbi_start_tvusec == bsdAfter.pbi_start_tvusec
            else {
                continue
            }

            let pathLen = pathBuf.withUnsafeMutableBytes { raw in
                proc_pidpath(pid, raw.baseAddress, UInt32(raw.count))
            }
            let resolvedPath: String
            if pathLen > 0, Int(pathLen) <= pathBuf.count {
                let rawStr = String(decoding: pathBuf[0..<Int(pathLen)], as: UTF8.self)
                resolvedPath = URL(fileURLWithPath: rawStr).resolvingSymlinksInPath().path
            } else {
                resolvedPath = ""
            }

            let fallbackName = Self.safeTupleString(bsdAfter.pbi_name)
                ?? Self.safeTupleString(bsdAfter.pbi_comm)
                ?? "pid \(pid)"

            let appPath: String? = {
                guard !resolvedPath.isEmpty else { return nil }
                if Self.isSimulatedOSProcess(path: resolvedPath) { return nil }
                let parts = URL(fileURLWithPath: resolvedPath).pathComponents
                if Self.isSimulatorHostGUI(path: resolvedPath),
                   let simIdx = parts.lastIndex(where: { $0 == "Simulator.app" }) {
                    return NSString.path(withComponents: Array(parts.prefix(simIdx + 1)))
                }
                guard let idx = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
                return NSString.path(withComponents: Array(parts.prefix(idx + 1)))
            }()

            records[pid] = ProcRecord(
                pid: pid,
                ppid: Int32(bitPattern: bsdAfter.pbi_ppid),
                uid: bsdAfter.pbi_uid,
                startSec: bsdAfter.pbi_start_tvsec,
                startUsec: bsdAfter.pbi_start_tvusec,
                footprint: footprint,
                path: resolvedPath,
                fallbackName: fallbackName,
                appPath: appPath
            )
        }

        var mainExecCache: [String: String?] = [:]
        func mainExecutablePath(for appPath: String) -> String? {
            if let cached = mainExecCache[appPath] { return cached }
            let resolved = Bundle(path: appPath)?.executableURL?.resolvingSymlinksInPath().path
            mainExecCache[appPath] = .some(resolved)
            return resolved
        }

        // Resolve browser root PIDs for multi-instance separation without merging independent main instances.
        func browserRootPID(for rec: ProcRecord) -> Int32 {
            guard let appPath = rec.appPath else { return rec.pid }
            let bundleExec = mainExecutablePath(for: appPath)
            var current = rec.pid
            var visited: Set<Int32> = [current]
            var hops = 0
            while hops < 16, let curRec = records[current] {
                if let bundleExec, curRec.path == bundleExec, !curRec.path.contains("Helper") {
                    break
                }
                let parent = curRec.ppid
                guard parent > 1, !visited.contains(parent),
                      let parentRec = records[parent],
                      parentRec.appPath == appPath
                else {
                    break
                }
                visited.insert(parent)
                current = parent
                hops += 1
            }
            return current
        }

        var browserAutomationByRoot: [Int32: BrowserAutomationInfo?] = [:]
        func automationInfo(forBrowserRoot rootPID: Int32) -> BrowserAutomationInfo? {
            if let cached = browserAutomationByRoot[rootPID] {
                return cached
            }
            guard let rootRec = records[rootPID], rootRec.uid == getuid(),
                  let args = BrowserAutomationClassifier.readProcessArguments(pid: rootPID)
            else {
                browserAutomationByRoot[rootPID] = .some(nil)
                return nil
            }
            let info = BrowserAutomationClassifier.classify(
                executablePath: rootRec.path,
                appPath: rootRec.appPath,
                arguments: args
            )
            browserAutomationByRoot[rootPID] = .some(info)
            return info
        }

        struct Bucket {
            var id: String
            var name: String
            var kind: ProcessFamilyKind
            var count: Int = 0
            var footprint: Double = 0
            var cpu: Double = 0
            var rootPID: Int32?
            var rootIsRegularApp: Bool = false
            var appPath: String?
            var bundleID: String?
            var automationHint: String?
            var hasSimulatedVolumeProcess: Bool = false
        }

        let recentRunCPU = CPUProcessSampler.recentPerProcessCPU()
        var buckets: [String: Bucket] = [:]
        // Deterministic sorted PID order prevents hash-seed flip-flopping of rootPID.
        for pid in records.keys.sorted() {
            guard let rec = records[pid] else { continue }
            let runKey = "\(rec.pid):\(rec.startSec):\(rec.startUsec)"
            let procCPU = recentRunCPU[runKey] ?? cpuByPID[Int(rec.pid)] ?? 0

            if Self.isSimulatorFamilyProcess(path: rec.path) {
                let key = "simulator:ios"
                var b = buckets[key] ?? Bucket(id: key, name: "iOS Simulator", kind: .iosSimulator)
                b.count += 1
                b.footprint += rec.footprint
                b.cpu += procCPU
                if Self.isSimulatedOSProcess(path: rec.path) {
                    b.hasSimulatedVolumeProcess = true
                }
                if rec.path.hasSuffix("/Simulator.app/Contents/MacOS/Simulator") {
                    b.rootPID = rec.pid
                    b.appPath = rec.appPath
                }
                buckets[key] = b
                continue
            }

            if let appPath = rec.appPath {
                if BrowserAutomationClassifier.isBrowserBundle(appPath: appPath) {
                    let root = browserRootPID(for: rec)
                    let baseName = Self.displayAppName(appPath: appPath)
                    if let autoInfo = automationInfo(forBrowserRoot: root), let rootRec = records[root] {
                        let key = "automated-browser:\(root):\(rootRec.startSec)"
                        var b = buckets[key] ?? Bucket(
                            id: key,
                            name: baseName,
                            kind: .automatedBrowser,
                            rootPID: root,
                            appPath: appPath,
                            bundleID: Bundle(path: appPath)?.bundleIdentifier,
                            automationHint: autoInfo.displayHint
                        )
                        b.count += 1
                        b.footprint += rec.footprint
                        b.cpu += procCPU
                        buckets[key] = b
                        continue
                    }
                }

                let bundleID = Bundle(path: appPath)?.bundleIdentifier
                let isAppleSystem = appPath.hasPrefix("/System/")
                    || ((bundleID ?? "").hasPrefix("com.apple.") && appPath != "/Applications/Xcode.app")
                let kind: ProcessFamilyKind = isAppleSystem ? .systemService : .userApp
                let key = "app:\(appPath)"
                var b = buckets[key] ?? Bucket(
                    id: key,
                    name: Self.displayAppName(appPath: appPath),
                    kind: kind,
                    appPath: appPath,
                    bundleID: bundleID
                )
                b.count += 1
                b.footprint += rec.footprint
                b.cpu += procCPU
                if let bundleExec = mainExecutablePath(for: appPath), rec.path == bundleExec {
                    let isRegular = NSRunningApplication(processIdentifier: rec.pid)?.activationPolicy == .regular
                    if b.rootPID == nil || (isRegular && !b.rootIsRegularApp) {
                        b.rootPID = rec.pid
                        b.rootIsRegularApp = isRegular
                    }
                }
                buckets[key] = b
                continue
            }

            if rec.path.hasSuffix("/WindowServer") {
                let key = "sys:WindowServer"
                var b = buckets[key] ?? Bucket(id: key, name: "WindowServer", kind: .systemService, rootPID: rec.pid)
                b.count += 1
                b.footprint += rec.footprint
                b.cpu += procCPU
                buckets[key] = b
                continue
            }

            let owner = (!rec.path.isEmpty ? ProcessOwnerRegistry.owner(for: rec.path) : nil)
                ?? (!rec.path.isEmpty ? URL(fileURLWithPath: rec.path).lastPathComponent : rec.fallbackName)
            let isSys = rec.uid == 0 || rec.path.hasPrefix("/System/") || rec.path.hasPrefix("/usr/libexec/") || rec.path.hasPrefix("/sbin/") || rec.path.hasPrefix("/usr/sbin/")
            let kind: ProcessFamilyKind = isSys ? .systemService : .cliOrDaemon
            let key = "\(kind.rawValue):\(owner):\(rec.pid)"
            buckets[key] = Bucket(
                id: key,
                name: owner,
                kind: kind,
                count: 1,
                footprint: rec.footprint,
                cpu: procCPU,
                rootPID: rec.pid
            )
        }

        // Only query `xcrun simctl` if simulated volume processes were actually seen.
        var bootedDevices: [BootedSimulatorDevice] = []
        if querySimulators, let simBucket = buckets["simulator:ios"], simBucket.hasSimulatedVolumeProcess {
            bootedDevices = SimulatorControl.listBootedDevices()
        }
        // Drop idle simulator bucket when no simulated OS processes are booted.
        if let simBucket = buckets["simulator:ios"], !simBucket.hasSimulatedVolumeProcess, bootedDevices.isEmpty {
            buckets.removeValue(forKey: "simulator:ios")
        }

        let sortedBuckets = buckets.values.sorted {
            if $0.footprint != $1.footprint { return $0.footprint > $1.footprint }
            if $0.cpu != $1.cpu { return $0.cpu > $1.cpu }
            return $0.id < $1.id
        }

        var selectedBuckets: [Bucket] = []
        var seenIDs: Set<String> = []
        for b in sortedBuckets.prefix(limit) {
            seenIDs.insert(b.id)
            selectedBuckets.append(b)
        }
        for b in sortedBuckets.dropFirst(min(limit, sortedBuckets.count)) {
            let mustKeep = b.cpu >= 15.0 || b.kind == .iosSimulator || b.kind == .automatedBrowser
            if mustKeep, seenIDs.insert(b.id).inserted {
                selectedBuckets.append(b)
            }
        }

        var result: [ProcessFamilySummary] = []
        result.reserveCapacity(selectedBuckets.count)
        for b in selectedBuckets {
            let rootIdentity = b.rootPID.flatMap { MonitoredProcessIdentity.read(pid: $0) }
            let hasActiveSim = b.kind == .iosSimulator && (b.hasSimulatedVolumeProcess || !bootedDevices.isEmpty)
            result.append(ProcessFamilySummary(
                id: b.id,
                name: b.name,
                kind: b.kind,
                processCount: b.count,
                footprintBytes: b.footprint,
                cpuUsage: b.cpu,
                rootPID: b.rootPID.map(Int.init),
                rootIdentity: rootIdentity,
                appPath: b.appPath,
                bundleID: b.bundleID,
                automationHint: b.automationHint,
                bootedSimulators: b.kind == .iosSimulator ? bootedDevices : [],
                hasActiveSimulatedOS: hasActiveSim
            ))
        }
        return result
    }

    private static func safeTupleString<T>(_ tuple: T) -> String? {
        withUnsafeBytes(of: tuple) { raw in
            let prefix = raw.prefix { $0 != 0 }
            guard !prefix.isEmpty else { return nil }
            return String(decoding: prefix, as: UTF8.self)
        }
    }

    static func isSimulatedOSProcess(path: String) -> Bool {
        path.hasPrefix("/Library/Developer/CoreSimulator/Volumes/")
            || path.contains("/CoreSimulator/Profiles/Runtimes/")
    }

    static func isSimulatorHostGUI(path: String) -> Bool {
        path.hasSuffix("/Applications/Simulator.app/Contents/MacOS/Simulator")
            || path.contains("/Applications/Simulator.app/Contents/")
    }

    static func isSimulatorFamilyProcess(path: String) -> Bool {
        isSimulatedOSProcess(path: path) || isSimulatorHostGUI(path: path)
    }

    private static func displayAppName(appPath: String) -> String {
        if let bundle = Bundle(path: appPath) {
            if let disp = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !disp.isEmpty {
                return disp
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
                return name
            }
        }
        return URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
    }
}
