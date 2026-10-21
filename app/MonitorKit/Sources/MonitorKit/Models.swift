// Models adapted from Stats (exelban/stats) MIT — Copyright (c) 2019 Serhiy Mytrovtsiy.
// RemoteType / Store / popup coupling removed for MacDefier.

import Foundation

// MARK: - CPU

public struct CPULoad: Sendable, Equatable {
    public var sampledAt: Date
    public var freshnessLimit: TimeInterval = 15
    public var totalUsage: Double = 0
    public var usagePerCore: [Double] = []
    public var usageECores: Double?
    public var usagePCores: Double?
    public var usageSCores: Double?
    public var systemLoad: Double = 0
    public var userLoad: Double = 0
    public var idleLoad: Double = 0

    public init(sampledAt: Date = .distantPast) { self.sampledAt = sampledAt }
}

public struct CPUAverageLoad: Sendable, Equatable {
    public var load1: Double = 0
    public var load5: Double = 0
    public var load15: Double = 0

    public init(load1: Double = 0, load5: Double = 0, load15: Double = 0) {
        self.load1 = load1
        self.load5 = load5
        self.load15 = load15
    }
}

// MARK: - RAM

public enum MemoryPressure: String, Codable, Sendable, Equatable {
    case unknown
    case normal
    case warning
    case critical
}

public struct SwapUsage: Sendable, Equatable {
    public var isAvailable: Bool
    public var total: Double
    public var used: Double
    public var free: Double

    public init(total: Double = 0, used: Double = 0, free: Double = 0, isAvailable: Bool = false) {
        self.isAvailable = isAvailable
        self.total = total
        self.used = used
        self.free = free
    }
}

public struct MemoryPressureInfo: Sendable, Equatable {
    public var level: Int
    public var value: MemoryPressure

    public init(level: Int = 0, value: MemoryPressure = .unknown) {
        self.level = level
        self.value = value
    }
}

public struct RAMUsage: Sendable, Equatable {
    public var sampledAt: Date
    public var freshnessLimit: TimeInterval = 15
    public var total: Double
    public var used: Double
    public var free: Double
    public var active: Double
    public var inactive: Double
    public var wired: Double
    public var compressed: Double
    public var app: Double
    public var cache: Double
    public var swap: SwapUsage
    public var pressure: MemoryPressureInfo
    public var swapRate: IORate? = nil
    public var swapins: Int64
    public var swapouts: Int64

    public var usage: Double {
        guard total > 0 else { return 0 }
        return (total - free) / total
    }

    public init(
        total: Double = 0,
        used: Double = 0,
        free: Double = 0,
        active: Double = 0,
        inactive: Double = 0,
        wired: Double = 0,
        compressed: Double = 0,
        app: Double = 0,
        cache: Double = 0,
        swap: SwapUsage = .init(),
        pressure: MemoryPressureInfo = .init(),
        swapins: Int64 = 0,
        swapouts: Int64 = 0,
        sampledAt: Date = .distantPast
    ) {
        self.sampledAt = sampledAt
        self.total = total
        self.used = used
        self.free = free
        self.active = active
        self.inactive = inactive
        self.wired = wired
        self.compressed = compressed
        self.app = app
        self.cache = cache
        self.swap = swap
        self.pressure = pressure
        self.swapins = swapins
        self.swapouts = swapouts
    }
}

// MARK: - Process

public struct TopProcess: Identifiable, Codable, Sendable, Equatable {
    public var id: String { identity?.id ?? "unverified:\(pid)" }
    public var identity: MonitoredProcessIdentity?
    public var pid: Int
    public var name: String
    public var usage: Double

    public init(pid: Int, name: String, usage: Double, identity: MonitoredProcessIdentity? = nil) {
        self.identity = identity
        self.pid = pid
        self.name = name
        self.usage = usage
    }
}

// MARK: - Disk

/// Volume role for UI labels — monitor may list many; diagnostic must not merge them.
public enum DiskVolumeKind: String, Sendable, Equatable, CaseIterable {
    case system
    case internalVol
    case external
    case diskImage
    case network
    case other

    /// Short Chinese label for UI.
    public var label: String {
        switch self {
        case .system: return "系统盘"
        case .internalVol: return "本机卷"
        case .external: return "外置盘"
        case .diskImage: return "磁盘映像"
        case .network: return "网络卷"
        case .other: return "其他卷"
        }
    }

    /// True for DMG / network — not “your Mac storage” for health score.
    public var isVirtual: Bool {
        self == .diskImage || self == .network
    }

    public var sortRank: Int {
        switch self {
        case .system: return 0
        case .internalVol: return 1
        case .external: return 2
        case .other: return 3
        case .diskImage: return 4
        case .network: return 5
        }
    }
}

public struct DiskVolume: Identifiable, Sendable, Equatable {
    public var id: String { bsdName.isEmpty ? path : "\(bsdName):\(path)" }
    public var name: String
    public var path: String
    public var bsdName: String
    public var total: Double
    public var free: Double
    public var removable: Bool
    public var kind: DiskVolumeKind
    /// Device protocol e.g. "PCI", "USB", "Disk Image"
    public var protocolName: String

    public var used: Double { max(0, total - free) }
    public var usage: Double {
        guard total > 0 else { return 0 }
        return used / total
    }

    public var kindLabel: String { kind.label }

    public init(
        name: String,
        path: String,
        bsdName: String = "",
        total: Double,
        free: Double,
        removable: Bool = false,
        kind: DiskVolumeKind = .other,
        protocolName: String = ""
    ) {
        self.name = name
        self.path = path
        self.bsdName = bsdName
        self.total = total
        self.free = free
        self.removable = removable
        self.kind = kind
        self.protocolName = protocolName
    }
}

public extension Array where Element == DiskVolume {
    /// System root volume (not a mounted DMG).
    var primary: DiskVolume? {
        first(where: { $0.kind == .system })
            ?? first(where: { $0.path == "/" })
            ?? first(where: { !$0.kind.isVirtual })
    }

    /// Real storage volumes for health/alerts (excludes disk images & network).
    var physical: [DiskVolume] {
        filter { !$0.kind.isVirtual }
    }
}

// MARK: - Network

public struct NetworkInterfaceUsage: Identifiable, Sendable, Equatable {
    public var id: String { interface }
    public var interface: String
    public var displayName: String
    public var bytesInPerSec: Double
    public var bytesOutPerSec: Double
    public var totalIn: UInt64
    public var totalOut: UInt64
    public var ip: String?
    public var isPrimary: Bool

    public init(
        interface: String,
        displayName: String? = nil,
        bytesInPerSec: Double = 0,
        bytesOutPerSec: Double = 0,
        totalIn: UInt64 = 0,
        totalOut: UInt64 = 0,
        ip: String? = nil,
        isPrimary: Bool = false
    ) {
        self.interface = interface
        self.displayName = displayName ?? interface
        self.bytesInPerSec = bytesInPerSec
        self.bytesOutPerSec = bytesOutPerSec
        self.totalIn = totalIn
        self.totalOut = totalOut
        self.ip = ip
        self.isPrimary = isPrimary
    }
}

public struct NetworkTrafficSample: Identifiable, Sendable, Equatable {
    public var id: Date { date }
    public var date: Date
    public var downBytesPerSec: Double
    public var upBytesPerSec: Double

    public init(date: Date = Date(), downBytesPerSec: Double, upBytesPerSec: Double) {
        self.date = date
        self.downBytesPerSec = downBytesPerSec
        self.upBytesPerSec = upBytesPerSec
    }
}

public struct NetworkConnectionDetails: Sendable, Equatable {
    public var mediaLabel: String
    public var linkKind: String
    public var ssid: String?
    public var security: String?
    public var band: String?
    public var channel: String?
    public var rssi: Int?
    public var noise: Int?
    public var phyMode: String?
    public var transmitRateMbps: Double?
    public var linkSpeedBps: Double?
    public var localIPv4: String?
    public var publicIP: String?
    public var mac: String?
    public var gateway: String?
    public var dns: [String]
    public var interfaceName: String?

    public init(
        mediaLabel: String = "—",
        linkKind: String = "—",
        ssid: String? = nil,
        security: String? = nil,
        band: String? = nil,
        channel: String? = nil,
        rssi: Int? = nil,
        noise: Int? = nil,
        phyMode: String? = nil,
        transmitRateMbps: Double? = nil,
        linkSpeedBps: Double? = nil,
        localIPv4: String? = nil,
        publicIP: String? = nil,
        mac: String? = nil,
        gateway: String? = nil,
        dns: [String] = [],
        interfaceName: String? = nil
    ) {
        self.mediaLabel = mediaLabel
        self.linkKind = linkKind
        self.ssid = ssid
        self.security = security
        self.band = band
        self.channel = channel
        self.rssi = rssi
        self.noise = noise
        self.phyMode = phyMode
        self.transmitRateMbps = transmitRateMbps
        self.linkSpeedBps = linkSpeedBps
        self.localIPv4 = localIPv4
        self.publicIP = publicIP
        self.mac = mac
        self.gateway = gateway
        self.dns = dns
        self.interfaceName = interfaceName
    }
}

public struct IPHistoryEntry: Identifiable, Sendable, Equatable, Codable {
    public var id: UUID
    public var date: Date
    public var from: String?
    public var to: String?
    public var note: String?
    public var city: String?
    public var country: String?
    public var countryCode: String?
    public var interfaceName: String?
    public var localIPv4: String?
    public var ssid: String?

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        from: String? = nil,
        to: String? = nil,
        note: String? = nil,
        city: String? = nil,
        country: String? = nil,
        countryCode: String? = nil,
        interfaceName: String? = nil,
        localIPv4: String? = nil,
        ssid: String? = nil
    ) {
        self.id = id
        self.date = date
        self.from = from
        self.to = to
        self.note = note
        self.city = city
        self.country = country
        self.countryCode = CountryFlag.normalizedCode(countryCode)
            ?? CountryFlag.code(fromCountryName: country)
        self.interfaceName = interfaceName
        self.localIPv4 = localIPv4
        self.ssid = ssid
    }

    /// 🇯🇵 城市 · 国家
    public var placeLabel: String? {
        CountryFlag.placeLabel(city: city, country: country, countryCode: countryCode)
    }

    public var flagEmoji: String? {
        CountryFlag.emoji(forCode: countryCode)
            ?? CountryFlag.emoji(forCode: CountryFlag.code(fromCountryName: country))
    }
}

public struct NetworkOverview: Sendable, Equatable {
    /// Throughput sample time; republishing IP/settings metadata does not refresh this timestamp.
    public var sampledAt: Date
    public var freshnessLimit: TimeInterval
    public var interfaces: [NetworkInterfaceUsage]
    public var primary: NetworkInterfaceUsage?
    public var details: NetworkConnectionDetails
    public var history: [NetworkTrafficSample]
    /// Full retained change list (FIFO pruned). UI filters by time window.
    public var ipHistory: [IPHistoryEntry]
    /// 0...1 estimated bandwidth use vs link speed
    public var bandwidthUsage: Double
    public var publicIPCity: String?
    public var publicIPCountry: String?
    public var publicIPCountryCode: String?
    public var publicIPConfirmedSince: Date?

    public var totalThroughput: Double {
        (primary?.bytesInPerSec ?? 0) + (primary?.bytesOutPerSec ?? 0)
    }

    public var publicIPPlaceLabel: String? {
        CountryFlag.placeLabel(
            city: publicIPCity,
            country: publicIPCountry,
            countryCode: publicIPCountryCode
        )
    }

    public var publicIPFlagEmoji: String? {
        CountryFlag.emoji(forCode: publicIPCountryCode)
            ?? CountryFlag.emoji(forCode: CountryFlag.code(fromCountryName: publicIPCountry))
    }

    public init(
        interfaces: [NetworkInterfaceUsage] = [],
        primary: NetworkInterfaceUsage? = nil,
        details: NetworkConnectionDetails = .init(),
        history: [NetworkTrafficSample] = [],
        ipHistory: [IPHistoryEntry] = [],
        bandwidthUsage: Double = 0,
        publicIPCity: String? = nil,
        publicIPCountry: String? = nil,
        publicIPCountryCode: String? = nil,
        publicIPConfirmedSince: Date? = nil,
        sampledAt: Date = .distantPast,
        freshnessLimit: TimeInterval = 15
    ) {
        self.interfaces = interfaces
        self.primary = primary
        self.details = details
        self.history = history
        self.ipHistory = ipHistory
        self.bandwidthUsage = bandwidthUsage
        self.publicIPCity = publicIPCity
        self.publicIPCountry = publicIPCountry
        self.publicIPCountryCode = CountryFlag.normalizedCode(publicIPCountryCode)
            ?? CountryFlag.code(fromCountryName: publicIPCountry)
        self.publicIPConfirmedSince = publicIPConfirmedSince
        self.sampledAt = sampledAt
        self.freshnessLimit = freshnessLimit
    }

    /// Entries within the last `days` (nil/0 = all retained).
    public func ipHistory(inLastDays days: Int?) -> [IPHistoryEntry] {
        guard let days, days > 0 else { return ipHistory }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
        return ipHistory.filter { $0.date >= cutoff }
    }
}

// MARK: - GPU

public struct GPUInfo: Identifiable, Codable, Sendable, Equatable {
    public var id: String { model + (vendor ?? "") }
    public var vendor: String?
    public var model: String
    public var utilization: Double?
    public var cores: Int?

    public init(vendor: String? = nil, model: String, utilization: Double? = nil, cores: Int? = nil) {
        self.vendor = vendor
        self.model = model
        self.utilization = utilization
        self.cores = cores
    }
}

// MARK: - Sensors

public struct SensorReading: Identifiable, Codable, Sendable, Equatable {
    public var id: String { key }
    public var key: String
    public var name: String
    public var value: Double
    public var unit: String
    public var group: String

    public init(key: String, name: String, value: Double, unit: String, group: String) {
        self.key = key
        self.name = name
        self.value = value
        self.unit = unit
        self.group = group
    }
}

// MARK: - Dashboard aggregate

/// Public IOKit power-source information. Absent battery and failed reads remain distinct.
public struct BatteryInfo: Sendable, Equatable {
    public var isPresent: Bool
    public var charge: Double?
    public var isCharging: Bool?
    public var isOnACPower: Bool?
    public var timeToEmptyMinutes: Int?
    public var timeToFullMinutes: Int?
    public var sampledAt: Date
    public var freshnessLimit: TimeInterval = 15

    public init(isPresent: Bool, charge: Double? = nil, isCharging: Bool? = nil,
                isOnACPower: Bool? = nil, timeToEmptyMinutes: Int? = nil,
                timeToFullMinutes: Int? = nil, sampledAt: Date = .distantPast) {
        self.isPresent = isPresent
        self.charge = charge
        self.isCharging = isCharging
        self.isOnACPower = isOnACPower
        self.timeToEmptyMinutes = timeToEmptyMinutes
        self.timeToFullMinutes = timeToFullMinutes
        self.sampledAt = sampledAt
    }
}

public struct MonitorSnapshot: Sendable, Equatable {
    public var cpu: CPULoad?
    public var averageLoad: CPUAverageLoad?
    public var ram: RAMUsage?
    public var topCPU: [TopProcess]
    public var topRAM: [TopProcess]
    public var topCPUSampledAt: Date
    public var topRAMSampledAt: Date
    public var topCPUFreshnessLimit: TimeInterval = 15
    public var topRAMFreshnessLimit: TimeInterval = 15
    public var diskActivity: DiskActivity? = nil
    public var disks: [DiskVolume]
    public var disksSampledAt: Date
    public var disksFreshnessLimit: TimeInterval = 15
    public var network: [NetworkInterfaceUsage]
    public var networkOverview: NetworkOverview
    public var networkSampledAt: Date
    public var gpus: [GPUInfo]
    public var gpusSampledAt: Date
    public var gpusFreshnessLimit: TimeInterval = 15
    public var sensors: [SensorReading]
    public var sensorsSampledAt: Date
    public var sensorsFreshnessLimit: TimeInterval = 15
    public var battery: BatteryInfo?
    /// Whether the read-only sensor transport is available; individual metrics can still be absent.
    public var sensorsAvailable: Bool
    public var host: HostSummary
    /// ~60s Dashboard 综合占用序列（0...1）
    public var dashCPUSeries: [Double]
    public var dashRAMSeries: [Double]
    public var dashGPUSeries: [Double]
    public var updatedAt: Date

    /// A refreshed aggregate does not make its retained CPU/RAM samples fresh.
    public func cpuIsFresh(at now: Date = Date()) -> Bool {
        guard let cpu, cpu.totalUsage.isFinite, (0...1).contains(cpu.totalUsage) else { return false }
        return Self.isFresh(cpu.sampledAt, at: now, limit: cpu.freshnessLimit)
    }

    public func ramIsFresh(at now: Date = Date()) -> Bool {
        guard let ram, ram.total.isFinite, ram.total > 0,
              ram.used.isFinite, (0...ram.total).contains(ram.used) else { return false }
        return Self.isFresh(ram.sampledAt, at: now, limit: ram.freshnessLimit)
    }

    public func hasFreshCoreMetrics(at now: Date = Date()) -> Bool {
        cpuIsFresh(at: now) && ramIsFresh(at: now)
            && ram?.pressure.value != .unknown && ram?.swap.isAvailable == true
    }

    public func systemDiskIsFresh(at now: Date = Date()) -> Bool {
        guard let disk = disks.first(where: { $0.kind == .system || $0.path == "/" }),
              disk.total.isFinite, disk.total > 0, disk.free.isFinite,
              (0...disk.total).contains(disk.free) else { return false }
        return Self.isFresh(disksSampledAt, at: now, limit: disksFreshnessLimit)
    }

    public func hasFreshDiagnosticMetrics(at now: Date = Date()) -> Bool {
        hasFreshCoreMetrics(at: now) && systemDiskIsFresh(at: now)
    }

    public func topCPUIsFresh(at now: Date = Date()) -> Bool {
        Self.isFresh(topCPUSampledAt, at: now, limit: topCPUFreshnessLimit)
            && topCPU.allSatisfy { $0.pid > 0 && $0.usage.isFinite && $0.usage >= 0 }
    }

    public func topRAMIsFresh(at now: Date = Date()) -> Bool {
        Self.isFresh(topRAMSampledAt, at: now, limit: topRAMFreshnessLimit)
            && topRAM.allSatisfy { $0.pid > 0 && $0.usage.isFinite && $0.usage >= 0 }
    }

    public func gpusAreFresh(at now: Date = Date()) -> Bool {
        !gpus.isEmpty && Self.isFresh(gpusSampledAt, at: now, limit: gpusFreshnessLimit)
            && gpus.allSatisfy { $0.utilization.map { $0.isFinite && (0...1).contains($0) } ?? true }
    }

    public func sensorsAreFresh(at now: Date = Date()) -> Bool {
        sensorsAvailable && !sensors.isEmpty && sensors.allSatisfy { $0.value.isFinite }
            && Self.isFresh(sensorsSampledAt, at: now, limit: sensorsFreshnessLimit)
    }

    public func networkIsFresh(at now: Date = Date()) -> Bool {
        guard let primary = networkOverview.primary,
              primary.bytesInPerSec.isFinite, primary.bytesInPerSec >= 0,
              primary.bytesOutPerSec.isFinite, primary.bytesOutPerSec >= 0 else { return false }
        return Self.isFresh(networkSampledAt, at: now, limit: networkOverview.freshnessLimit)
    }

    public func batteryIsFresh(at now: Date = Date()) -> Bool {
        guard let battery, battery.charge.map({ $0.isFinite && (0...1).contains($0) }) ?? true else { return false }
        return Self.isFresh(battery.sampledAt, at: now, limit: battery.freshnessLimit)
    }

    private static func isFresh(_ sampledAt: Date, at now: Date, limit: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(sampledAt)
        return limit.isFinite && limit > 0 && age >= 0 && age <= limit
    }

    public init(
        cpu: CPULoad? = nil,
        averageLoad: CPUAverageLoad? = nil,
        ram: RAMUsage? = nil,
        topCPU: [TopProcess] = [],
        topRAM: [TopProcess] = [],
        disks: [DiskVolume] = [],
        disksSampledAt: Date = .distantPast,
        network: [NetworkInterfaceUsage] = [],
        networkOverview: NetworkOverview = .init(),
        gpus: [GPUInfo] = [],
        sensors: [SensorReading] = [],
        sensorsAvailable: Bool = true,
        host: HostSummary = .init(),
        dashCPUSeries: [Double] = [],
        dashRAMSeries: [Double] = [],
        dashGPUSeries: [Double] = [],
        updatedAt: Date = Date(),
        topCPUSampledAt: Date = .distantPast,
        topRAMSampledAt: Date = .distantPast,
        networkSampledAt: Date = .distantPast,
        gpusSampledAt: Date = .distantPast,
        sensorsSampledAt: Date = .distantPast,
        battery: BatteryInfo? = nil
    ) {
        self.cpu = cpu
        self.averageLoad = averageLoad
        self.ram = ram
        self.topCPU = topCPU
        self.topRAM = topRAM
        self.topCPUSampledAt = topCPUSampledAt
        self.topRAMSampledAt = topRAMSampledAt
        self.disks = disks
        self.disksSampledAt = disksSampledAt
        self.network = network
        self.networkOverview = networkOverview
        self.networkSampledAt = networkSampledAt
        self.gpus = gpus
        self.gpusSampledAt = gpusSampledAt
        self.sensors = sensors
        self.sensorsSampledAt = sensorsSampledAt
        self.battery = battery
        self.sensorsAvailable = sensorsAvailable
        self.host = host
        self.dashCPUSeries = dashCPUSeries
        self.dashRAMSeries = dashRAMSeries
        self.dashGPUSeries = dashGPUSeries
        self.updatedAt = updatedAt
    }
}
