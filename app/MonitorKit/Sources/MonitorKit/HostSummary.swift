// Host summary for Dashboard「本机硬件摘要」.
// 型号命名对齐 Stats SystemKit：IORegistry 取 ID + system_profiler 取市面名/芯片（不手写整本型号字典当主源）。

import Darwin
import Foundation
import IOKit

private final class HostProcessOutput: @unchecked Sendable {
    let lock = NSLock()
    var data = Data()
}

public struct HostSummary: Sendable, Equatable {
    public var modelName: String
    public var chip: String
    public var cpuCoreLabel: String
    public var gpuCoreLabel: String
    public var memoryLabel: String
    public var storageLabel: String
    public var macos: String
    public var uptimeLabel: String
    /// Seconds since boot — UI formats via L10n
    public var uptimeSeconds: TimeInterval
    /// 内部型号标识（如 MacBookPro18,1），仅悬停/调试
    public var modelIdentifier: String

    public init(
        modelName: String = "—",
        chip: String = "—",
        cpuCoreLabel: String = "—",
        gpuCoreLabel: String = "—",
        memoryLabel: String = "—",
        storageLabel: String = "—",
        macos: String = "—",
        uptimeLabel: String = "—",
        uptimeSeconds: TimeInterval = 0,
        modelIdentifier: String = ""
    ) {
        self.modelName = modelName
        self.chip = chip
        self.cpuCoreLabel = cpuCoreLabel
        self.gpuCoreLabel = gpuCoreLabel
        self.memoryLabel = memoryLabel
        self.storageLabel = storageLabel
        self.macos = macos
        self.uptimeLabel = uptimeLabel
        self.uptimeSeconds = uptimeSeconds
        self.modelIdentifier = modelIdentifier
    }

    public static func read(disks: [DiskVolume] = [], gpus: [GPUInfo] = []) -> HostSummary {
        let identity = MacHardwareIdentity.resolve()

        let physical = Int(Sysctl.byName("hw.physicalcpu"))
        let logical = Int(Sysctl.byName("hw.logicalcpu"))
        let pCores = Int(Sysctl.byName("hw.perflevel0.logicalcpu"))
        let eCores = Int(Sysctl.byName("hw.perflevel1.logicalcpu"))
        let cpuCoreLabel: String = {
            if pCores > 0 || eCores > 0 {
                let total = max(physical, pCores + eCores)
                return "\(total) (\(pCores)P + \(eCores)E)"
            }
            if physical > 0, logical > 0, physical != logical {
                // Language-neutral (UI can rephrase via L10n if needed)
                return "\(logical)/\(physical)"
            }
            return "\(max(logical, physical, 1))"
        }()

        let memBytes = UInt64(bitPattern: Sysctl.byName("hw.memsize"))
        let memoryLabel: String = {
            if memBytes == 0 { return "—" }
            let gb = Double(memBytes) / 1_073_741_824
            if gb >= 1 { return String(format: "%.0f GB", gb) }
            return ByteCountFormatter.string(fromByteCount: Int64(memBytes), countStyle: .memory)
        }()

        let storageLabel: String = {
            if let d = disks.primary ?? disks.physical.first {
                let gb = d.total / 1_073_741_824
                if gb >= 1000 { return String(format: "%.1f TB", gb / 1000) }
                return String(format: "%.0f GB", gb)
            }
            return "—"
        }()

        let gpuCoreLabel: String = {
            if let c = gpus.first?.cores, c > 0 { return "\(c)" }
            if let m = gpus.first?.model, !m.isEmpty { return m }
            return "—"
        }()

        let v = ProcessInfo.processInfo.operatingSystemVersion
        let macos = "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"

        let uptimeSeconds: TimeInterval = {
            var boot = timeval()
            var size = MemoryLayout<timeval>.size
            var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
            guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return 0 }
            let bootDate = Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
            return max(0, Date().timeIntervalSince(bootDate))
        }()
        let uptimeLabel: String = {
            let sec = Int(uptimeSeconds)
            let h = sec / 3600
            let m = (sec % 3600) / 60
            if h >= 24 {
                let d = h / 24
                let rh = h % 24
                return "\(d)d \(rh)h"
            }
            return "\(h)h \(m)m"
        }()

        return HostSummary(
            modelName: identity.displayModel,
            chip: identity.displayChip,
            cpuCoreLabel: cpuCoreLabel,
            gpuCoreLabel: gpuCoreLabel,
            memoryLabel: memoryLabel,
            storageLabel: storageLabel,
            macos: macos,
            uptimeLabel: uptimeLabel,
            uptimeSeconds: uptimeSeconds,
            modelIdentifier: identity.modelID
        )
    }
}

// MARK: - 读系统（对齐 Stats SystemKit 思路）

/// 从本机系统读「叫什么 / 什么芯片 / 几寸」，不靠手写整本 MacBookPro18,1 字典当主源。
///
/// **冷启动原则**：`resolve()` **绝不**在调用线程同步跑 `system_profiler`（可堵主线程数秒）。
/// 顺序：
/// 1. 进程内缓存  
/// 2. UserDefaults 持久化（机型几乎不变，跨启动复用）  
/// 3. 快路径：IORegistry + sysctl（无 Process）  
/// 4. 后台 `system_profiler` 刷新市面名/英寸，写回缓存与磁盘  
public enum MacHardwareIdentity {
    public struct Result: Sendable, Equatable {
        public var modelID: String
        /// 例：MacBook Pro · 14 英寸
        public var displayModel: String
        /// 例：M1 Pro
        public var displayChip: String
    }

    private static let lock = NSLock()
    private static var cache: Result?
    private static var backgroundRefreshStarted = false
    private static var backgroundRefreshFinished = false
    private static var warmUpWaiters: [CheckedContinuation<Void, Never>] = []
    private static let persistKey = "monitor.macHardwareIdentity.v2"
    /// 后台刷新完成后回调（主线程安全由调用方保证）
    public static var onIdentityUpdated: (() -> Void)?

    /// 非阻塞：内存 → 磁盘 → 快路径；并触发后台 profiler（最多一次并发）。
    /// **绝不在持 lock 时写 UserDefaults**（会 post 通知 → SwiftUI 抢主线程 → 与主线程 resolve 死锁）。
    public static func resolve() -> Result {
        lock.lock()
        if let cache {
            let hit = cache
            lock.unlock()
            scheduleBackgroundRefreshIfNeeded()
            return hit
        }
        lock.unlock()

        // 读磁盘/IO 在锁外，避免与 warmUp 写缓存互锁
        if let disk = loadPersisted() {
            lock.lock()
            if cache == nil { cache = disk }
            let hit = cache ?? disk
            lock.unlock()
            scheduleBackgroundRefreshIfNeeded()
            return hit
        }

        let fast = resolveFastUnlocked()
        lock.lock()
        if cache == nil { cache = fast }
        let hit = cache ?? fast
        lock.unlock()
        persist(hit) // 锁外
        scheduleBackgroundRefreshIfNeeded()
        return hit
    }

    /// 供 MonitorService 启动后 await：确保至少跑完一轮 profiler（若尚未缓存完整市面名）。
    public static func warmUpAsync() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if backgroundRefreshFinished {
                lock.unlock()
                cont.resume()
                return
            }
            warmUpWaiters.append(cont)
            if backgroundRefreshStarted {
                lock.unlock()
                return
            }
            backgroundRefreshStarted = true
            lock.unlock()
            runBackgroundRefresh()
        }
    }

    // MARK: - Fast / full resolve

    /// IORegistry + sysctl only — 可安全在主线程调用。
    private static func resolveFastUnlocked() -> Result {
        let modelID = ioRegistryModelID()
            ?? Sysctl.string("hw.model")
            ?? "Mac"
        let chip = shortChip(
            Sysctl.string("machdep.cpu.brand_string")
                ?? fallbackChip(for: modelID)
                ?? "—"
        )
        let family = productFamily(from: modelID)
        let inches = fallbackInches(for: modelID)
        let displayModel = formatDisplayModel(family: family, inches: inches)
        return Result(modelID: modelID, displayModel: displayModel, displayChip: chip)
    }

    /// 含 system_profiler（可能数秒）— **仅**后台队列调用。
    private static func resolveFullAndStore() -> Result {
        let modelID = ioRegistryModelID()
            ?? Sysctl.string("hw.model")
            ?? "Mac"

        var machineName: String?
        var chipType: String?

        if let hw = systemProfilerHardware() {
            machineName = hw.name
            chipType = hw.chip
        }

        let chip = shortChip(
            chipType
                ?? Sysctl.string("machdep.cpu.brand_string")
                ?? fallbackChip(for: modelID)
                ?? "—"
        )

        let product = machineName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let family = (product?.isEmpty == false) ? product! : productFamily(from: modelID)

        // 型号确定尺寸；合盖、缩放或外接屏不应改变机型。
        let inches = fallbackInches(for: modelID)
            ?? displayInchesHint()

        let displayModel = formatDisplayModel(family: family, inches: inches)

        let result = Result(modelID: modelID, displayModel: displayModel, displayChip: chip)
        lock.lock()
        cache = result
        lock.unlock()
        persist(result) // 必须锁外：UserDefaults 会触发主线程 SwiftUI 观察者
        return result
    }

    private static func scheduleBackgroundRefreshIfNeeded() {
        lock.lock()
        if backgroundRefreshStarted {
            lock.unlock()
            return
        }
        backgroundRefreshStarted = true
        lock.unlock()

        runBackgroundRefresh()
    }

    private static func runBackgroundRefresh() {
        DispatchQueue.global(qos: .utility).async {
            let before: Result?
            lock.lock()
            before = cache
            lock.unlock()

            let full = resolveFullAndStore()
            lock.lock()
            backgroundRefreshFinished = true
            let waiters = warmUpWaiters
            warmUpWaiters.removeAll()
            lock.unlock()
            waiters.forEach { $0.resume() }
            if before != full {
                DispatchQueue.main.async {
                    onIdentityUpdated?()
                }
            }
        }
    }

    // MARK: - Disk cache（机型极少变；读写均在 lock 外）

    private static func loadPersisted() -> Result? {
        guard let data = UserDefaults.standard.data(forKey: persistKey),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let id = obj["modelID"], !id.isEmpty,
              let model = obj["displayModel"], !model.isEmpty,
              let chip = obj["displayChip"], !chip.isEmpty
        else { return nil }
        // 若用户换机：hw.model 对不上则丢弃缓存
        let currentID = ioRegistryModelID() ?? Sysctl.string("hw.model")
        if let currentID, currentID != id { return nil }
        return Result(modelID: id, displayModel: model, displayChip: chip)
    }

    private static func persist(_ r: Result) {
        let obj: [String: String] = [
            "modelID": r.modelID,
            "displayModel": r.displayModel,
            "displayChip": r.displayChip,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        // 后台线程写 UD 也可能同步踢到主线程观察者；尽量短、且绝不持 identity lock
        UserDefaults.standard.set(data, forKey: persistKey)
    }

    // 兼容旧调用名
    public static func marketingName(for identifier: String) -> String {
        // 若与缓存 ID 相同直接用缓存（已含系统 profiler）
        let r = resolve()
        if r.modelID == identifier || identifier.isEmpty {
            return r.displayModel
        }
        // 仅传了别的 ID：做产品线兜底
        if let inch = fallbackInches(for: identifier) {
            return formatDisplayModel(family: productFamily(from: identifier), inches: inch)
        }
        return productFamily(from: identifier)
    }

    /// Neutral display: "MacBook Pro · 14\"" — no zh/en hardcode (inch mark is universal).
    private static func formatDisplayModel(family: String, inches: String?) -> String {
        guard let inches, !inches.isEmpty else { return family }
        return "\(family) · \(inches)\""
    }

    public static func shortChip(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("apple ") {
            s = String(s.dropFirst(6))
        }
        return s.isEmpty ? "—" : s
    }

    // MARK: IORegistry（Stats modelAndSerialNumber）

    private static func ioRegistryModelID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let cf = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0)?.takeUnretainedValue() else {
            return nil
        }
        if let data = cf as? Data,
           let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines)),
           !s.isEmpty {
            return s
        }
        if let s = cf as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return nil
    }

    // MARK: system_profiler（Stats getModel）

    private static func systemProfilerHardware() -> (name: String, chip: String, model: String?)? {
        guard let jsonText = runProcess(
            path: "/usr/sbin/system_profiler",
            arguments: ["SPHardwareDataType", "-json"]
        ) else { return nil }

        guard let data = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = root["SPHardwareDataType"] as? [[String: Any]],
              let first = arr.first
        else { return nil }

        let name = (first["machine_name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let chip = (first["chip_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (first["machine_model"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let name, !name.isEmpty else { return nil }
        return (name, chip ?? "", model)
    }

    /// 内建屏分辨率 → 粗推 13/14/15/16（系统不直接给英寸时的辅助）
    private static func displayInchesHint() -> String? {
        guard let jsonText = runProcess(
            path: "/usr/sbin/system_profiler",
            arguments: ["SPDisplaysDataType", "-json"]
        ) else { return nil }

        guard let data = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gpus = root["SPDisplaysDataType"] as? [[String: Any]]
        else { return nil }

        for gpu in gpus {
            guard let displays = gpu["spdisplays_ndrvs"] as? [[String: Any]] else { continue }
            for d in displays {
                let builtIn: Bool = {
                    if let t = d["spdisplays_display_type"] as? String {
                        let l = t.lowercased()
                        if l.contains("built-in") || l.contains("internal") { return true }
                    }
                    if let t = d["_name"] as? String {
                        let l = t.lowercased()
                        if l.contains("built-in") || l.contains("color lcd") || l.contains("liquid retina") {
                            return true
                        }
                    }
                    // spdisplays_main / connection
                    if let c = d["spdisplays_connection_type"] as? String,
                       c.lowercased().contains("internal") {
                        return true
                    }
                    return false
                }()
                guard builtIn else { continue }

                // 分辨率字符串 "3024 x 1964" 或类似
                let res = (d["_spdisplays_resolution"] as? String)
                    ?? (d["spdisplays_resolution"] as? String)
                    ?? ""
                if let w = parseMaxDimension(res) {
                    // 常见内建逻辑宽 → 英寸（粗映射，仅辅助）
                    switch w {
                    case 2560: return "13"          // 旧 Air / 13" Pro
                    case 2880: return "15"          // 15" Air
                    case 3024: return "14"          // 14" Pro
                    case 3456: return "16"          // 16" Pro
                    case 2940, 3420: return "14"    // 部分新 14"
                    case 2000...2700: return "13"
                    case 2701...3200: return "14"
                    case 3201...3600: return "16"
                    default: break
                    }
                }
            }
        }
        return nil
    }

    private static func parseMaxDimension(_ res: String) -> Int? {
        // "3024 x 1964 Retina" / "3024x1964"
        let nums = res.split { !$0.isNumber }.compactMap { Int($0) }
        return nums.max()
    }

    private static func runProcess(path: String, arguments: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return nil
        }

        let output = HostProcessOutput()
        let drain = DispatchGroup()
        drain.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            output.lock.lock()
            output.data = data
            output.lock.unlock()
            drain.leave()
        }

        let deadline = Date().addingTimeInterval(8)
        while p.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning {
            p.terminate()
            let terminateDeadline = Date().addingTimeInterval(0.5)
            while p.isRunning, Date() < terminateDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            _ = drain.wait(timeout: .now() + 1)
            return nil
        }

        guard drain.wait(timeout: .now() + 1) == .success else { return nil }
        output.lock.lock()
        let data = output.data
        output.lock.unlock()
        guard p.terminationStatus == 0, !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func productFamily(from id: String) -> String {
        if id.hasPrefix("MacBookPro") || fallbackInches(for: id) != nil { return "MacBook Pro" }
        if id.hasPrefix("MacBookAir") { return "MacBook Air" }
        if id.hasPrefix("MacBook") { return "MacBook" }
        if id.hasPrefix("Macmini") || id.hasPrefix("MacMini") { return "Mac mini" }
        if id.hasPrefix("iMac") { return "iMac" }
        if id.hasPrefix("MacPro") { return "Mac Pro" }
        if id.hasPrefix("Mac") { return "Mac" }
        return "Mac"
    }

    /// Apple 已确认的 14/16 英寸 MacBook Pro 型号；未知型号仍走系统探测。
    /// https://support.apple.com/en-ca/108052
    private static func fallbackInches(for id: String) -> String? {
        switch id {
        case "MacBookPro18,3", "MacBookPro18,4",
             "Mac14,5", "Mac14,9",
             "Mac15,3", "Mac15,6", "Mac15,8", "Mac15,10",
             "Mac16,1", "Mac16,6", "Mac16,8",
             "Mac17,2", "Mac17,7", "Mac17,9":
            return "14"
        case "MacBookPro16,1", "MacBookPro16,4",
             "MacBookPro18,1", "MacBookPro18,2",
             "Mac14,6", "Mac14,10",
             "Mac15,7", "Mac15,9", "Mac15,11",
             "Mac16,5", "Mac16,7",
             "Mac17,6", "Mac17,8":
            return "16"
        default:
            return nil
        }
    }

    private static func fallbackChip(for id: String) -> String? {
        // 极少用：profiler / brand_string 都空时
        if id.hasPrefix("MacBookPro18") {
            if id.hasSuffix(",1") || id.hasSuffix(",2") { return "M1 Pro" }
            if id.hasSuffix(",3") || id.hasSuffix(",4") { return "M1 Max" }
        }
        return nil
    }
}

/// 旧名兼容（设置/别处若引用）
public enum MacModelNames {
    public static func marketingName(for identifier: String) -> String {
        MacHardwareIdentity.marketingName(for: identifier)
    }

    public static func simpleModelLine(for identifier: String) -> String {
        MacHardwareIdentity.marketingName(for: identifier)
    }

    public static func chipHint(for identifier: String) -> String? {
        let r = MacHardwareIdentity.resolve()
        if r.modelID == identifier { return r.displayChip }
        return nil
    }

    public static func shortChip(_ raw: String) -> String {
        MacHardwareIdentity.shortChip(raw)
    }
}
