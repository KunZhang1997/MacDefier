// MonitorService — product-facing hub over Stats-derived samplers.

import Combine
import Foundation

enum MonitorSamplerID: CaseIterable, Hashable {
    case cpuLoad, cpuAverage, ram, topCPU, topRAM, disks, diskActivity, network, gpus, sensors, battery
}

extension MonitorSnapshot {
    /// A stopped interval is a break in the series, not part of the next live trend.
    mutating func prepareForSamplingRestart(_ samplers: Set<MonitorSamplerID>) {
        if samplers.contains(.cpuLoad) { cpu = nil; dashCPUSeries = [] }
        if samplers.contains(.cpuAverage) { averageLoad = nil }
        if samplers.contains(.ram) { ram = nil; dashRAMSeries = [] }
        if samplers.contains(.topCPU) { topCPU = []; topCPUSampledAt = .distantPast }
        if samplers.contains(.topRAM) { topRAM = []; topRAMSampledAt = .distantPast }
        if samplers.contains(.diskActivity) { diskActivity = nil }
        if samplers.contains(.disks) { disks = []; disksSampledAt = .distantPast }
        if samplers.contains(.gpus) { gpus = []; gpusSampledAt = .distantPast; dashGPUSeries = [] }
        if samplers.contains(.sensors) { sensors = []; sensorsSampledAt = .distantPast }
        if samplers.contains(.battery) { battery = nil }
        if samplers.contains(.network) {
            network = []
            networkOverview.interfaces = []
            networkOverview.primary = nil
            networkOverview.history = []
            networkOverview.bandwidthUsage = 0
            networkOverview.sampledAt = .distantPast
            networkSampledAt = .distantPast
        }
    }
}

struct MonitorDemandState: Equatable {
    var mainWindowVisible = false
    var monitorPageVisible = false
    var menuBarPanelVisible = false
    var menuBarCPU = false
    var menuBarRAM = false
    var diagnosticDemandCount = 0
    var historyEnabled = false
    var historyBoosted = false
    var sleeping = false
}

enum MonitorDemandPolicy {
    static func activeSamplers(for state: MonitorDemandState) -> Set<MonitorSamplerID> {
        if state.sleeping { return [] }
        if (state.mainWindowVisible && state.monitorPageVisible) || state.menuBarPanelVisible {
            return Set(MonitorSamplerID.allCases)
        }

        var result = Set<MonitorSamplerID>()
        // The horizontal workbench displays these on every route.
        // Do not run processes, GPU, SMC sensors or battery for this small strip.
        if state.mainWindowVisible {
            result.formUnion([.cpuLoad, .ram, .disks, .network])
        }
        if state.menuBarCPU { result.insert(.cpuLoad) }
        if state.menuBarRAM { result.insert(.ram) }
        if state.diagnosticDemandCount > 0 {
            result.formUnion([.cpuLoad, .ram, .topCPU, .disks, .network])
        }
        if state.historyEnabled { result.formUnion([.cpuLoad, .ram, .topCPU, .topRAM, .diskActivity, .gpus, .sensors]) }
        return result
    }

    static func interval(
        for sampler: MonitorSamplerID,
        state: MonitorDemandState,
        foregroundInterval: Int
    ) -> Int {
        let foreground = (state.mainWindowVisible && state.monitorPageVisible) || state.menuBarPanelVisible
        if state.historyEnabled {
            // Recording bounds source age even if the foreground picker is set to 30 seconds.
            switch sampler {
            case .cpuLoad, .ram: return foreground ? min(max(1, foregroundInterval), state.historyBoosted ? 2 : 5) : (state.historyBoosted ? 2 : 5)
            case .diskActivity: return state.historyBoosted ? 2 : 5
            case .topCPU: return foreground ? min(max(4, foregroundInterval), state.historyBoosted ? 4 : 10) : (state.historyBoosted ? 4 : 10)
            case .topRAM: return 10
            case .gpus: return foreground ? min(max(3, foregroundInterval), 5) : 5
            case .sensors: return 5
            default: break
            }
        }
        if !foreground, state.diagnosticDemandCount == 0 {
            return 5
        }

        let base = max(1, foregroundInterval)
        switch sampler {
        case .cpuLoad, .ram, .network: return base
        case .cpuAverage: return max(base, 2)
        case .topCPU: return max(base, 4)
        case .topRAM: return max(base, 10)
        case .disks, .diskActivity, .sensors: return max(base, 5)
        case .gpus: return max(base, 3)
        case .battery: return max(base, 15)
        }
    }
}

public enum MonitorSamplingMode: Sendable, Equatable {
    case stopped
    case recording
    case workbench
    case menuBar(cpu: Bool, ram: Bool)
    case diagnostic
    case foreground
    case menuBarPanel
}

@MainActor
public final class MonitorService: ObservableObject {
    public static let shared = MonitorService()

    @Published public private(set) var snapshot = MonitorSnapshot()
    @Published public private(set) var isRunning = false
    @Published public private(set) var refreshInterval: Int = 1
    @Published public private(set) var samplingMode: MonitorSamplingMode = .stopped

    private let cpuLoad = CPULoadSampler(interval: 1)
    private let cpuAvg = CPUAverageLoadSampler(interval: 2)
    private let ram = RAMUsageSampler(interval: 1)
    private let topCPU = CPUProcessSampler(limit: 8, interval: 4)
    private let topRAM = RAMProcessSampler(limit: 8, interval: 10)
    public let history: MonitorHistoryRecorder
    private let diskActivity = DiskActivitySampler(interval: 5)
    private let disks = DiskCapacitySampler(interval: 5)
    private let network = NetworkUsageSampler(interval: 1)
    private let gpus = GPUInfoSampler(interval: 3)
    private let sensors = SensorsSampler(interval: 5)
    private let battery = BatteryUsageSampler(interval: 15)

    private var samplers: [MonitorSamplerID: any Sampling] = [:]
    private var activeSamplers = Set<MonitorSamplerID>()
    private var demand = MonitorDemandState()
    private var diagnosticTokens = Set<UUID>()

    private let seriesLimit = 60
    private var lastHostRefresh: Date = .distantPast
    private var diskIdentity = ""
    private var gpuIdentity = ""

    private var stagedSnapshot = MonitorSnapshot()
    private var snapshotCommitTask: Task<Void, Never>?

    /// 设置页公网 IP 开关：关闭时取消查询并清除发布态。
    public func applyPublicIPLookupPreference(enabled: Bool) {
        network.applyPublicIPLookupPreference(enabled: enabled)
    }

    public init(history: MonitorHistoryRecorder? = nil) {
        self.history = history ?? MonitorHistoryRecorder()
        samplers = [
            .cpuLoad: cpuLoad,
            .cpuAverage: cpuAvg,
            .ram: ram,
            .topCPU: topCPU,
            .topRAM: topRAM,
            .disks: disks,
            .diskActivity: diskActivity,
            .network: network,
            .gpus: gpus,
            .sensors: sensors,
            .battery: battery,
        ]

        snapshot.host = HostSummary.read()
        stagedSnapshot = snapshot
        MacHardwareIdentity.onIdentityUpdated = { [weak self] in
            Task { @MainActor in
                self?.refreshHostIfNeeded(force: true)
            }
        }

        cpuLoad.publicationCallback = { [weak self] value, generation, _ in
            Task { @MainActor in
                guard let self, self.cpuLoad.isPublicationCurrent(generation) else { return }
                self.stage { snapshot in
                    snapshot.cpu = value
                    if let usage = value?.totalUsage {
                        Self.pushSeries(&snapshot.dashCPUSeries, usage, limit: self.seriesLimit)
                    }
                }
            }
        }
        cpuAvg.publicationCallback = { [weak self] value, generation, _ in
            Task { @MainActor in
                guard let self, self.cpuAvg.isPublicationCurrent(generation) else { return }
                self.stage { $0.averageLoad = value }
            }
        }
        ram.publicationCallback = { [weak self] value, generation, _ in
            Task { @MainActor in
                guard let self, self.ram.isPublicationCurrent(generation) else { return }
                self.stage { snapshot in
                    snapshot.ram = value
                    if let usage = value?.usage {
                        Self.pushSeries(&snapshot.dashRAMSeries, usage, limit: self.seriesLimit)
                    }
                }
            }
        }
        topCPU.publicationCallback = { [weak self] value, generation, sampledAt in
            Task { @MainActor in
                guard let self, self.topCPU.isPublicationCurrent(generation) else { return }
                self.stage {
                    $0.topCPU = value ?? []
                    $0.topCPUSampledAt = value == nil ? .distantPast : sampledAt
                    $0.topCPUFreshnessLimit = max(15, Double(self.topCPU.interval) * 2)
                }
            }
        }
        topRAM.publicationCallback = { [weak self] value, generation, sampledAt in
            Task { @MainActor in
                guard let self, self.topRAM.isPublicationCurrent(generation) else { return }
                self.stage {
                    $0.topRAM = value ?? []
                    $0.topRAMSampledAt = value == nil ? .distantPast : sampledAt
                    $0.topRAMFreshnessLimit = max(15, Double(self.topRAM.interval) * 2)
                }
            }
        }
        disks.publicationCallback = { [weak self] value, generation, sampledAt in
            Task { @MainActor in
                guard let self, self.disks.isPublicationCurrent(generation) else { return }
                let next = value ?? []
                let identity = Self.diskIdentity(for: next)
                self.stage {
                    $0.disks = next
                    $0.disksSampledAt = value == nil ? .distantPast : sampledAt
                    $0.disksFreshnessLimit = max(15, Double(self.disks.interval) * 2)
                }
                if identity != self.diskIdentity {
                    self.diskIdentity = identity
                    self.refreshHostIfNeeded(force: true)
                }
            }
        }
        network.publicationCallback = { [weak self] value, generation, _ in
            Task { @MainActor in
                guard let self, self.network.isPublicationCurrent(generation) else { return }
                self.stage {
                    $0.networkOverview = value ?? .init()
                    $0.network = value?.interfaces ?? []
                    $0.networkSampledAt = value?.sampledAt ?? .distantPast
                }
            }
        }
        gpus.publicationCallback = { [weak self] value, generation, sampledAt in
            Task { @MainActor in
                guard let self, self.gpus.isPublicationCurrent(generation) else { return }
                let next = value ?? []
                let identity = Self.gpuIdentity(for: next)
                self.stage { snapshot in
                    snapshot.gpus = next
                    snapshot.gpusSampledAt = value == nil ? .distantPast : sampledAt
                    snapshot.gpusFreshnessLimit = max(15, Double(self.gpus.interval) * 2)
                    if let usage = next.first?.utilization {
                        Self.pushSeries(&snapshot.dashGPUSeries, usage, limit: self.seriesLimit)
                    }
                }
                if identity != self.gpuIdentity {
                    self.gpuIdentity = identity
                    self.refreshHostIfNeeded(force: true)
                }
            }
        }
        sensors.publicationCallback = { [weak self] value, generation, sampledAt in
            Task { @MainActor in
                guard let self, self.sensors.isPublicationCurrent(generation) else { return }
                self.stage {
                    $0.sensors = value ?? []
                    $0.sensorsAvailable = self.sensors.isAvailable
                    $0.sensorsSampledAt = value == nil ? .distantPast : sampledAt
                    $0.sensorsFreshnessLimit = max(15, Double(self.sensors.interval) * 2)
                }
            }
        }
        diskActivity.publicationCallback = { [weak self] value, generation, _ in
            Task { @MainActor in
                guard let self, self.diskActivity.isPublicationCurrent(generation) else { return }
                self.stage { $0.diskActivity = value }
            }
        }
        battery.publicationCallback = { [weak self] value, generation, _ in
            Task { @MainActor in
                guard let self, self.battery.isPublicationCurrent(generation) else { return }
                self.stage { $0.battery = value }
            }
        }
        self.history.attach(self)
    }

    func setHistoryDemand(_ enabled: Bool, boosted: Bool) {
        guard demand.historyEnabled != enabled || demand.historyBoosted != boosted else { return }
        demand.historyEnabled = enabled; demand.historyBoosted = boosted; applyDemand()
    }
    func setSystemSleeping(_ sleeping: Bool) {
        demand.sleeping = sleeping; applyDemand()
    }

    /// Compatibility entry point. Starting the service does not itself create sampling demand.
    public func start() {
        applyDemand()
    }

    public func stop() {
        setMonitorPageVisible(false)
    }

    public func setApplicationActive(_ active: Bool) {
        // Full sampling follows main-window visibility, not focus. Kept for source compatibility.
    }

    public func setMainWindowVisible(_ visible: Bool) {
        guard demand.mainWindowVisible != visible else { return }
        demand.mainWindowVisible = visible
        applyDemand()
    }

    public func setMonitorPageVisible(_ visible: Bool) {
        guard demand.monitorPageVisible != visible else { return }
        demand.monitorPageVisible = visible
        applyDemand()
    }

    public func setMenuBarMetrics(cpu: Bool, ram: Bool) {
        guard demand.menuBarCPU != cpu || demand.menuBarRAM != ram else { return }
        demand.menuBarCPU = cpu
        demand.menuBarRAM = ram
        applyDemand()
    }

    /// The transient menu-bar panel owns this demand independently of main-window visibility.
    public func setMenuBarPanelVisible(_ visible: Bool) {
        guard demand.menuBarPanelVisible != visible else { return }
        demand.menuBarPanelVisible = visible
        applyDemand()
    }

    /// Diagnostic owns the returned token and must release it with `endDiagnosticSampling`.
    /// This demand intentionally excludes top-RAM, GPU, and sensors.
    @discardableResult
    public func beginDiagnosticSampling() -> UUID {
        let token = UUID()
        diagnosticTokens.insert(token)
        demand.diagnosticDemandCount = diagnosticTokens.count
        applyDemand()
        return token
    }

    public func endDiagnosticSampling(_ token: UUID) {
        guard diagnosticTokens.remove(token) != nil else { return }
        demand.diagnosticDemandCount = diagnosticTokens.count
        applyDemand()
    }

    public func setRefreshInterval(_ seconds: Int) {
        let next = max(1, seconds)
        guard refreshInterval != next else { return }
        refreshInterval = next
        applyDemand()
    }

    /// Clear public-exit history while retaining the currently confirmed address as baseline.
    public func clearIPHistory() {
        network.clearIPHistory()
    }

    private func applyDemand() {
        let desired = MonitorDemandPolicy.activeSamplers(for: demand)

        for id in activeSamplers.subtracting(desired) {
            samplers[id]?.stop()
        }
        for id in desired {
            samplers[id]?.setInterval(MonitorDemandPolicy.interval(
                for: id,
                state: demand,
                foregroundInterval: refreshInterval
            ))
        }
        let restarting = desired.subtracting(activeSamplers)
        if !restarting.isEmpty {
            stage { $0.prepareForSamplingRestart(restarting) }
        }
        for id in restarting {
            samplers[id]?.start()
        }
        activeSamplers = desired

        let nextMode: MonitorSamplingMode
        if demand.sleeping {
            nextMode = .stopped
        } else if demand.mainWindowVisible && demand.monitorPageVisible {
            nextMode = .foreground
        } else if demand.menuBarPanelVisible {
            nextMode = .menuBarPanel
        } else if demand.diagnosticDemandCount > 0 {
            nextMode = .diagnostic
        } else if demand.historyEnabled {
            nextMode = .recording
        } else if demand.mainWindowVisible {
            nextMode = .workbench
        } else if demand.menuBarCPU || demand.menuBarRAM {
            nextMode = .menuBar(cpu: demand.menuBarCPU, ram: demand.menuBarRAM)
        } else {
            nextMode = .stopped
        }
        if samplingMode != nextMode { samplingMode = nextMode }
        let nowRunning = !desired.isEmpty
        if isRunning != nowRunning { isRunning = nowRunning }
    }

    private func stage(_ update: (inout MonitorSnapshot) -> Void) {
        update(&stagedSnapshot)
        scheduleSnapshotCommit()
    }

    private func scheduleSnapshotCommit() {
        guard snapshotCommitTask == nil else { return }
        snapshotCommitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            self?.commitStagedSnapshot()
        }
    }

    private func commitStagedSnapshot() {
        snapshotCommitTask = nil
        if Date().timeIntervalSince(lastHostRefresh) >= 30 {
            refreshHostIfNeeded(force: false, scheduleCommit: false)
        }
        guard stagedSnapshot != snapshot else { return }
        stagedSnapshot.updatedAt = Date()
        snapshot = stagedSnapshot
    }

    private func refreshHostIfNeeded(force: Bool, scheduleCommit: Bool = true) {
        let now = Date()
        guard force || now.timeIntervalSince(lastHostRefresh) >= 30 else { return }
        lastHostRefresh = now
        stagedSnapshot.host = HostSummary.read(
            disks: stagedSnapshot.disks,
            gpus: stagedSnapshot.gpus
        )
        if scheduleCommit { scheduleSnapshotCommit() }
    }

    private static func pushSeries(_ series: inout [Double], _ value: Double, limit: Int) {
        series.append(min(1, max(0, value)))
        if series.count > limit {
            series.removeFirst(series.count - limit)
        }
    }

    private static func diskIdentity(for disks: [DiskVolume]) -> String {
        disks.map { "\($0.bsdName)|\($0.path)|\(Int64($0.total))" }.joined(separator: ";")
    }

    private static func gpuIdentity(for gpus: [GPUInfo]) -> String {
        gpus.map { "\($0.vendor ?? "")|\($0.model)|\($0.cores ?? 0)" }.joined(separator: ";")
    }
}
