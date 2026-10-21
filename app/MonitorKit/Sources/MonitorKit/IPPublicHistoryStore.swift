// Local-only public IP exit history (self-written). App Support JSON + FIFO.

import Foundation

public struct IPGeoCacheEntry: Codable, Sendable, Equatable {
    public var city: String?
    public var country: String?
    /// ISO 3166-1 alpha-2（如 JP）— 用于国旗
    public var countryCode: String?
    public var updatedAt: Date

    public init(city: String? = nil, country: String? = nil, countryCode: String? = nil, updatedAt: Date = Date()) {
        self.city = city
        self.country = country
        self.countryCode = CountryFlag.normalizedCode(countryCode)
            ?? CountryFlag.code(fromCountryName: country)
        self.updatedAt = updatedAt
    }

    public var placeLabel: String? {
        CountryFlag.placeLabel(city: city, country: country, countryCode: countryCode)
    }

    public var flagEmoji: String? {
        CountryFlag.emoji(forCode: countryCode)
            ?? CountryFlag.emoji(forCode: CountryFlag.code(fromCountryName: country))
    }
}

struct IPPublicHistoryDisk: Codable, Sendable {
    var confirmedPublicIP: String?
    var confirmedSince: Date?
    var currentCity: String?
    var currentCountry: String?
    var currentCountryCode: String?
    var entries: [IPHistoryEntry]
    var geoCache: [String: IPGeoCacheEntry]

    static let empty = IPPublicHistoryDisk(
        confirmedPublicIP: nil,
        confirmedSince: nil,
        currentCity: nil,
        currentCountry: nil,
        currentCountryCode: nil,
        entries: [],
        geoCache: [:]
    )
}

enum IPPublicHistoryStore {
    /// Max retained change rows (FIFO).
    static let maxEntries = 200
    /// Drop entries older than this even under maxEntries.
    static let maxAgeDays: Int = 30

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        #if DEBUG
        let dir = base.appendingPathComponent("MacDefier-Dev", isDirectory: true)
        #else
        let dir = base.appendingPathComponent("MacDefier", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ip-public-history.json")
    }

    static func load() -> IPPublicHistoryDisk {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              var disk = try? JSONDecoder().decode(IPPublicHistoryDisk.self, from: data)
        else {
            return .empty
        }
        disk.entries = prune(disk.entries)
        disk.geoCache = pruneGeo(disk.geoCache)
        return disk
    }

    static func save(_ disk: IPPublicHistoryDisk) {
        var copy = disk
        copy.entries = prune(copy.entries)
        copy.geoCache = pruneGeo(copy.geoCache)
        guard let data = try? JSONEncoder().encode(copy) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    static func prune(_ entries: [IPHistoryEntry]) -> [IPHistoryEntry] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -maxAgeDays, to: Date()) ?? .distantPast
        var list = entries
            .filter { $0.date >= cutoff }
            .sorted { $0.date > $1.date }
        if list.count > maxEntries {
            list = Array(list.prefix(maxEntries))
        }
        return list
    }

    /// geoCache 此前无界增长：30 天 TTL + 上限 500 条，按 updatedAt 淘汰最旧
    static let maxGeoEntries = 500

    static func pruneGeo(_ cache: [String: IPGeoCacheEntry]) -> [String: IPGeoCacheEntry] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -maxAgeDays, to: Date()) ?? .distantPast
        var fresh = cache.filter { $0.value.updatedAt >= cutoff }
        if fresh.count > maxGeoEntries {
            let keep = fresh.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(maxGeoEntries)
            fresh = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        return fresh
    }
}
