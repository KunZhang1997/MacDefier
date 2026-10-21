// Network sampling — Stats Net pattern + product Network 详情/IP 抖动（自研落盘·城市·清历史）.

import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

public final class NetworkUsageSampler: Sampler<NetworkOverview> {
    /// 是否查询公网 IP / 归属地（ipify + 多源 geo 回退）。默认开；设置里可关。
    public static let publicIPLookupDefaultsKey = "monitor.publicIPLookupEnabled"

    private struct Counters {
        var bytesIn: UInt64   // 回绕补偿后的有效累计值
        var bytesOut: UInt64  // 回绕补偿后的有效累计值
        var rawIn: UInt64     // 内核 32 位原始值
        var rawOut: UInt64
        var timestamp: Date
    }

    private var previous: [String: Counters] = [:]
    /// ifi_ibytes/ifi_obytes 为 32 位计数器（4.29GB 回绕）：每接口累计补偿的 2^32 次数
    private var wrapOffsets: [String: (in: UInt64, out: UInt64)] = [:]
    private var history: [NetworkTrafficSample] = []
    private var measuredRateInterfaces = Set<String>()
    private let historyLimit = 60

    private let stateLock = NSLock()
    private var confirmedPublicIP: String?
    private var confirmedSince: Date?
    private var currentCity: String?
    private var currentCountry: String?
    private var currentCountryCode: String?
    private var pendingPublicIP: String?
    private var pendingHits = 0
    private let confirmNeeded = 2
    private var ipHistory: [IPHistoryEntry] = []
    private var geoCache: [String: IPGeoCacheEntry] = [:]
    private var lastPublicFetch: Date = .distantPast
    private let publicFetchMinInterval: TimeInterval = 20
    private var isFetchingPublic = false
    private var isFetchingGeo = false
    /// 关闭查询时递增；旧回调不得重新发布
    private var publicIPLookupGeneration: UInt64 = 0
    private var lastContextSSID: String?
    private var lastContextInterface: String?
    private var lastContextLocalIP: String?

    public override func setup() {
        // 关闭时：不加载磁盘公网数据到发布态（重启后关闭状态不回显旧 IP）
        if !isPublicIPLookupEnabled {
            stateLock.lock()
            clearPublicIPPublishStateLocked(clearDisk: false)
            stateLock.unlock()
            return
        }
        let disk = IPPublicHistoryStore.load()
        stateLock.lock()
        confirmedPublicIP = disk.confirmedPublicIP
        confirmedSince = disk.confirmedSince
        currentCity = disk.currentCity
        currentCountry = disk.currentCountry
        currentCountryCode = CountryFlag.normalizedCode(disk.currentCountryCode)
            ?? CountryFlag.code(fromCountryName: disk.currentCountry)
        ipHistory = disk.entries
        geoCache = disk.geoCache
        if let ip = confirmedPublicIP, let cached = geoCache[ip] {
            if currentCity == nil { currentCity = cached.city }
            if currentCountry == nil { currentCountry = cached.country }
            if currentCountryCode == nil {
                currentCountryCode = cached.countryCode
                    ?? CountryFlag.code(fromCountryName: cached.country)
            }
        }
        // 旧历史无 code：反填国旗码
        for i in ipHistory.indices where ipHistory[i].countryCode == nil {
            if let code = CountryFlag.code(fromCountryName: ipHistory[i].country) {
                ipHistory[i].countryCode = code
            }
        }
        stateLock.unlock()
    }

    /// 设置页开关：关闭则取消查询、递增 generation、清内存与磁盘发布态。
    public func applyPublicIPLookupPreference(enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self.publicIPLookupGeneration &+= 1
            self.isFetchingPublic = false
            self.isFetchingGeo = false
            if !enabled {
                self.clearPublicIPPublishStateLocked(clearDisk: true)
                let disk = self.diskSnapshotLocked()
                let snap = self.publishSnapshotLocked(
                    interfaces: self.value?.interfaces ?? [],
                    primary: self.value?.primary,
                    details: self.value?.details ?? .init(),
                    traffic: self.value?.history ?? [],
                    bandwidth: self.value?.bandwidthUsage ?? 0
                )
                self.stateLock.unlock()
                IPPublicHistoryStore.save(disk)
                self.publish(snap)
            } else {
                self.stateLock.unlock()
                self.setup()
            }
        }
    }

    private func clearPublicIPPublishStateLocked(clearDisk: Bool) {
        confirmedPublicIP = nil
        confirmedSince = nil
        currentCity = nil
        currentCountry = nil
        currentCountryCode = nil
        pendingPublicIP = nil
        pendingHits = 0
        if clearDisk {
            ipHistory = []
            geoCache = [:]
        }
    }

    public func clearIPHistory() {
        // 编组到采样串行队列：避免与 read() 并发读写 value（此前主线程直改，存在竞争）
        queue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self.ipHistory = []
            self.confirmedSince = Date()
            let disk = self.diskSnapshotLocked()
            let snap = self.publishSnapshotLocked(
                interfaces: self.value?.interfaces ?? [],
                primary: self.value?.primary,
                details: self.value?.details ?? .init(),
                traffic: self.value?.history ?? [],
                bandwidth: self.value?.bandwidthUsage ?? 0
            )
            self.stateLock.unlock()
            IPPublicHistoryStore.save(disk)
            self.publish(snap)
        }
    }

    public override func read() {
        let raw = collectInterfaces()
        let primaryName = pickPrimary(raw)
        var list = raw.map { iface -> NetworkInterfaceUsage in
            NetworkInterfaceUsage(
                interface: iface.interface,
                displayName: iface.displayName,
                bytesInPerSec: iface.bytesInPerSec,
                bytesOutPerSec: iface.bytesOutPerSec,
                totalIn: iface.totalIn,
                totalOut: iface.totalOut,
                ip: iface.ip,
                isPrimary: iface.interface == primaryName
            )
        }
        list.sort {
            if $0.isPrimary != $1.isPrimary { return $0.isPrimary && !$1.isPrimary }
            return ($0.bytesInPerSec + $0.bytesOutPerSec) > ($1.bytesInPerSec + $1.bytesOutPerSec)
        }

        let primary = list.first(where: \.isPrimary) ?? list.first
        let wifi = readWiFiDetails()
        // gateway/DNS/MAC 是慢变信息，走 10s 缓存（此前每秒全量查 SCDynamicStore/getifaddrs）
        let ctx = networkContext(for: primary?.interface)

        // 仅 Wi‑Fi 协商速率已知时才给链路容量；未知不填 1Gbps（避免带宽环假满格/假比例）
        let linkBytesPerSec: Double? = {
            if let mbps = wifi.transmitRateMbps, mbps > 0 {
                return mbps * 1_000_000 / 8
            }
            return nil
        }()

        stateLock.lock()
        lastContextSSID = wifi.ssid
        lastContextInterface = primary?.interface
        lastContextLocalIP = primary?.ip
        let confirmed = confirmedPublicIP
        let city = currentCity
        let country = currentCountry
        let countryCode = currentCountryCode
        let since = confirmedSince
        let hist = ipHistory
        stateLock.unlock()

        var details = NetworkConnectionDetails(
            mediaLabel: wifi.mediaLabel ?? (primary.map { defaultMedia($0.interface) } ?? "—"),
            linkKind: wifi.linkKind ?? "Network",
            ssid: wifi.ssid,
            security: wifi.security,
            band: wifi.band,
            channel: wifi.channel,
            rssi: wifi.rssi,
            noise: wifi.noise,
            phyMode: wifi.phyMode,
            transmitRateMbps: wifi.transmitRateMbps,
            linkSpeedBps: linkBytesPerSec,
            localIPv4: primary?.ip,
            publicIP: confirmed,
            mac: ctx.mac,
            gateway: ctx.gateway,
            dns: ctx.dns,
            interfaceName: primary?.interface
        )

        if let primary, measuredRateInterfaces.contains(primary.interface) {
            history.append(NetworkTrafficSample(
                downBytesPerSec: primary.bytesInPerSec,
                upBytesPerSec: primary.bytesOutPerSec
            ))
            if history.count > historyLimit {
                history.removeFirst(history.count - historyLimit)
            }
        }

        let thr = (primary?.bytesInPerSec ?? 0) + (primary?.bytesOutPerSec ?? 0)
        // 无已知链路容量 → bandwidthUsage = 0（UI 显示「—」而非假百分比）
        let usage: Double = {
            guard let cap = linkBytesPerSec, cap > 0 else { return 0 }
            return min(1, thr / cap)
        }()

        if isPublicIPLookupEnabled {
            maybeFetchPublicIP()
            details.publicIP = confirmed
        } else {
            // 关闭时永不发布公网 IP / geo
            details.publicIP = nil
        }

        let visible = list.filter { $0.interface.hasPrefix("en") || $0.interface.hasPrefix("utun") || $0.isPrimary }

        publish(NetworkOverview(
            interfaces: visible,
            primary: primary,
            details: details,
            history: history,
            ipHistory: hist,
            bandwidthUsage: usage,
            publicIPCity: city,
            publicIPCountry: country,
            publicIPCountryCode: countryCode,
            publicIPConfirmedSince: since,
            sampledAt: primary.map { measuredRateInterfaces.contains($0.interface) ? Date() : .distantPast } ?? .distantPast,
            freshnessLimit: max(15, Double(interval) * 2)
        ))
    }

    public override func samplingDidStart() {
        previous.removeAll()
        wrapOffsets.removeAll()
        measuredRateInterfaces.removeAll()
        history.removeAll()
        var restarted = value ?? .init()
        restarted.interfaces = []
        restarted.primary = nil
        restarted.history = []
        restarted.bandwidthUsage = 0
        restarted.sampledAt = .distantPast
        publish(restarted)
    }

    private func publishSnapshotLocked(
        interfaces: [NetworkInterfaceUsage],
        primary: NetworkInterfaceUsage?,
        details: NetworkConnectionDetails,
        traffic: [NetworkTrafficSample],
        bandwidth: Double
    ) -> NetworkOverview {
        var d = details
        d.publicIP = confirmedPublicIP
        return NetworkOverview(
            interfaces: interfaces,
            primary: primary,
            details: d,
            history: traffic,
            ipHistory: ipHistory,
            bandwidthUsage: bandwidth,
            publicIPCity: currentCity,
            publicIPCountry: currentCountry,
            publicIPCountryCode: currentCountryCode,
            publicIPConfirmedSince: confirmedSince,
            sampledAt: value?.sampledAt ?? .distantPast,
            freshnessLimit: value?.freshnessLimit ?? 15
        )
    }

    /// 锁内调用：仅生成写盘快照；JSON 编码 + 原子写放锁外做（每秒采样要抢同一把锁）
    private func diskSnapshotLocked() -> IPPublicHistoryDisk {
        IPPublicHistoryDisk(
            confirmedPublicIP: confirmedPublicIP,
            confirmedSince: confirmedSince,
            currentCity: currentCity,
            currentCountry: currentCountry,
            currentCountryCode: currentCountryCode,
            entries: ipHistory,
            geoCache: geoCache
        )
    }

    private func defaultMedia(_ iface: String) -> String {
        iface.hasPrefix("en") ? "Ethernet / Wi‑Fi" : iface
    }

    // MARK: - Interfaces

    private func collectInterfaces() -> [NetworkInterfaceUsage] {
        measuredRateInterfaces.removeAll()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            previous.removeAll()
            wrapOffsets.removeAll()
            return []
        }
        defer { freeifaddrs(ifaddr) }

        var totals: [String: (in: UInt64, out: UInt64)] = [:]
        var ipv4: [String: String] = [:]

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let name = String(cString: current.pointee.ifa_name)
            let flags = Int32(current.pointee.ifa_flags)
            if (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 {
                if let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0,
                       ipv4[name] == nil {
                        ipv4[name] = String(cString: hostname)
                    }
                }
                if let data = current.pointee.ifa_data {
                    let ifdata = data.assumingMemoryBound(to: if_data.self)
                    let existing = totals[name] ?? (0, 0)
                    totals[name] = (
                        max(existing.in, UInt64(ifdata.pointee.ifi_ibytes)),
                        max(existing.out, UInt64(ifdata.pointee.ifi_obytes))
                    )
                }
            }
            ptr = current.pointee.ifa_next
        }

        let now = Date()
        var result: [NetworkInterfaceUsage] = []
        for (name, counters) in totals {
            // 32 位计数器回绕补偿：原始值比上次小即累计 +2^32（万兆网约 3.4s 回绕一次）
            var off = wrapOffsets[name] ?? (in: 0, out: 0)
            if let prev = previous[name] {
                if counters.in < prev.rawIn { off.in &+= UInt64(UInt32.max) &+ 1 }
                if counters.out < prev.rawOut { off.out &+= UInt64(UInt32.max) &+ 1 }
            }
            wrapOffsets[name] = off
            let effIn = counters.in &+ off.in
            let effOut = counters.out &+ off.out

            var inRate = 0.0
            var outRate = 0.0
            if let prev = previous[name] {
                let dt = now.timeIntervalSince(prev.timestamp)
                if dt > 0 {
                    measuredRateInterfaces.insert(name)
                    if effIn >= prev.bytesIn { inRate = Double(effIn - prev.bytesIn) / dt }
                    if effOut >= prev.bytesOut { outRate = Double(effOut - prev.bytesOut) / dt }
                }
            }
            previous[name] = Counters(bytesIn: effIn, bytesOut: effOut, rawIn: counters.in, rawOut: counters.out, timestamp: now)
            result.append(NetworkInterfaceUsage(
                interface: name,
                displayName: name.hasPrefix("en") ? "Ethernet/Wi‑Fi (\(name))" : name,
                bytesInPerSec: inRate,
                bytesOutPerSec: outRate,
                totalIn: effIn,
                totalOut: effOut,
                ip: ipv4[name]
            ))
        }
        previous = previous.filter { totals[$0.key] != nil }
        wrapOffsets = wrapOffsets.filter { totals[$0.key] != nil }
        return result
    }

    private func pickPrimary(_ list: [NetworkInterfaceUsage]) -> String? {
        if let en = list.first(where: { $0.interface.hasPrefix("en") && $0.ip != nil }) { return en.interface }
        if let en = list.first(where: { $0.interface.hasPrefix("en") }) { return en.interface }
        return list.sorted { ($0.bytesInPerSec + $0.bytesOutPerSec) > ($1.bytesInPerSec + $1.bytesOutPerSec) }.first?.interface
    }

    // MARK: - Wi‑Fi

    private struct WiFiPack {
        var mediaLabel: String?
        var linkKind: String?
        var ssid: String?
        var security: String?
        var band: String?
        var channel: String?
        var rssi: Int?
        var noise: Int?
        var phyMode: String?
        var transmitRateMbps: Double?
    }

    private func readWiFiDetails() -> WiFiPack {
        var pack = WiFiPack()
        guard let iface = CWWiFiClient.shared().interface(), iface.powerOn() else { return pack }
        pack.linkKind = "Wi‑Fi"
        pack.ssid = iface.ssid()
        pack.rssi = Int(iface.rssiValue())
        pack.noise = Int(iface.noiseMeasurement())
        let rate = iface.transmitRate()
        if rate > 0 { pack.transmitRateMbps = rate }

        if let ch = iface.wlanChannel() {
            let width: String
            switch ch.channelWidth {
            case .width20MHz: width = "20 MHz"
            case .width40MHz: width = "40 MHz"
            case .width80MHz: width = "80 MHz"
            case .width160MHz: width = "160 MHz"
            default: width = "—"
            }
            pack.channel = "\(ch.channelNumber) (\(width))"
            switch ch.channelBand {
            case .band2GHz:
                pack.band = "2.4 GHz"
                pack.mediaLabel = "Wi‑Fi"
            case .band5GHz:
                pack.band = "5 GHz"
                pack.mediaLabel = "Wi‑Fi 5/6"
            case .band6GHz:
                pack.band = "6 GHz"
                pack.mediaLabel = "Wi‑Fi 6E"
            default:
                pack.mediaLabel = "Wi‑Fi"
            }
        } else {
            pack.mediaLabel = "Wi‑Fi"
        }

        pack.security = securityName(iface.security())
        pack.phyMode = phyName(iface.activePHYMode())
        return pack
    }

    private func securityName(_ s: CWSecurity) -> String {
        switch s {
        case .none: return "Open"
        case .WEP: return "WEP"
        case .wpaPersonal: return "WPA Personal"
        case .wpaPersonalMixed: return "WPA Personal Mixed"
        case .wpa2Personal: return "WPA2 Personal"
        case .wpa3Personal: return "WPA3 Personal"
        case .wpaEnterprise: return "WPA Enterprise"
        case .wpa2Enterprise: return "WPA2 Enterprise"
        case .wpa3Enterprise: return "WPA3 Enterprise"
        default: return "—"
        }
    }

    private func phyName(_ mode: CWPHYMode) -> String {
        switch mode {
        case .mode11a: return "802.11a"
        case .mode11b: return "802.11b"
        case .mode11g: return "802.11g"
        case .mode11n: return "802.11n (HT)"
        case .mode11ac: return "802.11ac (VHT)"
        case .mode11ax: return "802.11ax (HE)"
        default: return "—"
        }
    }

    // MARK: - System config

    private var cachedGateway: String?
    private var cachedDNS: [String] = []
    private var cachedMAC: String?
    private var cachedMACInterface: String?
    private var lastContextRefresh: Date = .distantPast

    /// 慢变网络上下文缓存：≥10s 或主接口变化才重查（gateway/DNS/MAC 不会每秒变）
    private func networkContext(for iface: String?) -> (gateway: String?, dns: [String], mac: String?) {
        let now = Date()
        if now.timeIntervalSince(lastContextRefresh) >= 10 || iface != cachedMACInterface {
            cachedGateway = defaultGateway()
            cachedDNS = dnsServers()
            cachedMACInterface = iface
            cachedMAC = iface.flatMap { macAddress(for: $0) }
            lastContextRefresh = now
        }
        return (cachedGateway, cachedDNS, cachedMAC)
    }

    private func defaultGateway() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "com.macdefier.MonitorKit" as CFString, nil, nil) else { return nil }
        guard let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let router = value["Router"] as? String else { return nil }
        return router
    }

    private func dnsServers() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "com.macdefier.MonitorKit.dns" as CFString, nil, nil) else { return [] }
        guard let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
              let servers = value["ServerAddresses"] as? [String] else { return [] }
        return servers
    }

    private func macAddress(for ifaceName: String) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let current = ptr {
            let name = String(cString: current.pointee.ifa_name)
            if name == ifaceName,
               let addr = current.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_LINK) {
                let sdl = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_dl.self)
                let alen = Int(sdl.pointee.sdl_alen)
                guard alen == 6 else {
                    ptr = current.pointee.ifa_next
                    continue
                }
                let nlen = Int(sdl.pointee.sdl_nlen)
                let base = UnsafeRawPointer(sdl).advanced(by: MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)! + nlen)
                let bytes = base.bindMemory(to: UInt8.self, capacity: 6)
                return (0..<6).map { String(format: "%02x", bytes[$0]) }.joined(separator: ":")
            }
            ptr = current.pointee.ifa_next
        }
        return nil
    }

    // MARK: - Public IP debounce + geo + persistence

    private var isPublicIPLookupEnabled: Bool {
        // 缺省 = 关（opt-in）；仅显式 true 才查公网 IP（审查 F07-1）
        if UserDefaults.standard.object(forKey: Self.publicIPLookupDefaultsKey) == nil {
            return false
        }
        return UserDefaults.standard.bool(forKey: Self.publicIPLookupDefaultsKey)
    }

    private func maybeFetchPublicIP() {
        guard isPublicIPLookupEnabled else { return }
        let now = Date()
        stateLock.lock()
        guard now.timeIntervalSince(lastPublicFetch) >= publicFetchMinInterval, !isFetchingPublic else {
            stateLock.unlock()
            return
        }
        lastPublicFetch = now
        isFetchingPublic = true
        let gen = publicIPLookupGeneration
        stateLock.unlock()
        let url = URL(string: "https://api.ipify.org")!
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self else { return }
            defer {
                self.stateLock.lock()
                self.isFetchingPublic = false
                self.stateLock.unlock()
            }
            self.stateLock.lock()
            let stillValid = self.publicIPLookupGeneration == gen && self.isPublicIPLookupEnabled
            self.stateLock.unlock()
            guard stillValid else { return }
            guard let data,
                  let ip = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !ip.isEmpty, ip.count < 64
            else { return }
            self.handlePublicIPCandidate(ip, generation: gen)
        }.resume()
    }

    private func handlePublicIPCandidate(_ ip: String, generation: UInt64) {
        stateLock.lock()
        guard publicIPLookupGeneration == generation, isPublicIPLookupEnabled else {
            stateLock.unlock()
            return
        }

        if ip == confirmedPublicIP {
            pendingPublicIP = nil
            pendingHits = 0
            var disk: IPPublicHistoryDisk?
            if let cached = geoCache[ip] {
                if currentCity == nil { currentCity = cached.city }
                if currentCountry == nil { currentCountry = cached.country }
                if currentCountryCode == nil {
                    currentCountryCode = cached.countryCode
                        ?? CountryFlag.code(fromCountryName: cached.country ?? currentCountry)
                }
                // 旧缓存无 code：用国名反填，避免无意义重拉
                if cached.countryCode == nil, let code = currentCountryCode {
                    geoCache[ip] = IPGeoCacheEntry(
                        city: cached.city ?? currentCity,
                        country: cached.country ?? currentCountry,
                        countryCode: code,
                        updatedAt: cached.updatedAt
                    )
                    disk = diskSnapshotLocked()
                } else if currentCity == nil || currentCountry == nil {
                    disk = diskSnapshotLocked()
                }
            }
            let needGeo = geoCache[ip] == nil
                && currentCity == nil
                && currentCountry == nil
            stateLock.unlock()
            if let disk { IPPublicHistoryStore.save(disk) }
            if needGeo {
                fetchGeoIfNeeded(for: ip)
            }
            return
        }
        if ip == pendingPublicIP {
            pendingHits += 1
        } else {
            pendingPublicIP = ip
            pendingHits = 1
        }
        guard pendingHits >= confirmNeeded else {
            stateLock.unlock()
            return
        }

        let old = confirmedPublicIP
        confirmedPublicIP = ip
        confirmedSince = Date()
        pendingPublicIP = nil
        pendingHits = 0

        let cached = geoCache[ip]
        currentCity = cached?.city
        currentCountry = cached?.country
        currentCountryCode = cached?.countryCode
            ?? CountryFlag.code(fromCountryName: cached?.country)

        if let old, old != ip {
            let entry = IPHistoryEntry(
                from: old,
                to: ip,
                city: currentCity,
                country: currentCountry,
                countryCode: currentCountryCode,
                interfaceName: lastContextInterface,
                localIPv4: lastContextLocalIP,
                ssid: lastContextSSID
            )
            ipHistory.insert(entry, at: 0)
        } else if old == nil {
            let entry = IPHistoryEntry(
                from: nil,
                to: ip,
                note: "first_confirm",
                city: currentCity,
                country: currentCountry,
                countryCode: currentCountryCode,
                interfaceName: lastContextInterface,
                localIPv4: lastContextLocalIP,
                ssid: lastContextSSID
            )
            ipHistory.insert(entry, at: 0)
        }

        ipHistory = IPPublicHistoryStore.prune(ipHistory)
        let disk = diskSnapshotLocked()
        let needGeo = geoCache[ip] == nil
        stateLock.unlock()
        IPPublicHistoryStore.save(disk)
        if needGeo {
            fetchGeoIfNeeded(for: ip)
        }
    }

    private func fetchGeoIfNeeded(for ip: String) {
        guard isPublicIPLookupEnabled else { return }
        stateLock.lock()
        if isFetchingGeo || geoCache[ip] != nil {
            stateLock.unlock()
            return
        }
        isFetchingGeo = true
        let gen = publicIPLookupGeneration
        stateLock.unlock()

        // Multi-provider fallback: ipwho.is often fails TLS on some networks.
        let providers = Self.geoProviderURLs(for: ip)
        guard !providers.isEmpty else {
            stateLock.lock()
            isFetchingGeo = false
            stateLock.unlock()
            return
        }
        fetchGeoFromProviders(ip: ip, urls: providers, index: 0, generation: gen)
    }

    /// Free HTTPS geo endpoints (no API key). First success wins.
    private static func geoProviderURLs(for ip: String) -> [URL] {
        let enc = ip.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ip
        let raw = [
            "https://get.geojs.io/v1/ip/geo/\(enc).json",
            "https://ipwhois.app/json/\(enc)",
            "https://ipwho.is/\(enc)"
        ]
        return raw.compactMap { URL(string: $0) }
    }

    private func fetchGeoFromProviders(ip: String, urls: [URL], index: Int, generation: UInt64) {
        guard index < urls.count else {
            stateLock.lock()
            isFetchingGeo = false
            stateLock.unlock()
            return
        }
        var req = URLRequest(url: urls[index])
        req.timeoutInterval = 8
        req.setValue("MacDefier/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { return }
            self.stateLock.lock()
            let stillValid = self.publicIPLookupGeneration == generation && self.isPublicIPLookupEnabled
            self.stateLock.unlock()
            guard stillValid else {
                self.stateLock.lock()
                self.isFetchingGeo = false
                self.stateLock.unlock()
                return
            }
            if let data, let parsed = Self.parseGeoJSON(data) {
                self.applyGeoResult(
                    ip: ip,
                    city: parsed.city,
                    country: parsed.country,
                    countryCode: parsed.countryCode,
                    generation: generation
                )
                return
            }
            // Try next provider
            self.fetchGeoFromProviders(ip: ip, urls: urls, index: index + 1, generation: generation)
        }.resume()
    }

    /// Parse geojs / ipwhois.app / ipwho.is (and similar) JSON.
    private static func parseGeoJSON(_ data: Data) -> (city: String?, country: String?, countryCode: String?)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Explicit failure flags
        if let success = obj["success"] as? Bool, success == false { return nil }
        if let status = obj["status"] as? String, status == "fail" || status == "error" { return nil }
        if obj["error"] != nil, obj["city"] == nil, obj["country"] == nil { return nil }

        func str(_ keys: String...) -> String? {
            for k in keys {
                if let s = obj[k] as? String {
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty, t.lowercased() != "null", t != "-" { return t }
                }
            }
            return nil
        }

        var city = str("city")
        if city == nil {
            city = str("region", "regionName") // geojs often has region; use if city empty
        }
        let country = str("country", "country_name")
        let code = CountryFlag.normalizedCode(
            str("country_code", "countryCode", "country_code2", "countrycode")
        ) ?? CountryFlag.code(fromCountryName: country)
        guard city != nil || country != nil || code != nil else { return nil }
        return (city, country, code)
    }

    private func applyGeoResult(
        ip: String,
        city: String?,
        country: String?,
        countryCode: String?,
        generation: UInt64
    ) {
        stateLock.lock()
        isFetchingGeo = false
        guard publicIPLookupGeneration == generation, isPublicIPLookupEnabled else {
            stateLock.unlock()
            return
        }
        let code = CountryFlag.normalizedCode(countryCode)
            ?? CountryFlag.code(fromCountryName: country)
        let cache = IPGeoCacheEntry(city: city, country: country, countryCode: code)
        geoCache[ip] = cache
        if confirmedPublicIP == ip {
            currentCity = city
            currentCountry = country
            currentCountryCode = code
        }
        // Backfill history rows that still lack place for this IP
        for i in ipHistory.indices where ipHistory[i].to == ip {
            if ipHistory[i].city == nil { ipHistory[i].city = city }
            if ipHistory[i].country == nil { ipHistory[i].country = country }
            if ipHistory[i].countryCode == nil { ipHistory[i].countryCode = code }
        }
        geoCache = IPPublicHistoryStore.pruneGeo(geoCache)
        let disk = diskSnapshotLocked()
        stateLock.unlock()
        IPPublicHistoryStore.save(disk)
    }
}
