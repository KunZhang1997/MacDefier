import Foundation

enum Format {
    private static let formatterLock = NSLock()
    private static let fileByteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
    private static let memoryByteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        return f
    }()
    private static var timeHMFormatters: [String: DateFormatter] = [:]
    private static var dayTimeFormatters: [String: DateFormatter] = [:]

    static func percent(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.0f%%", v * 100)
    }

    /// Decimal (1000-based `.file`) byte formatting — matches macOS Finder & `CleanupKit` item sizes.
    static func bytes(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        let clamped = Int64(min(Double(Int64.max), max(0, v)))
        formatterLock.lock()
        defer { formatterLock.unlock() }
        return fileByteFormatter.string(fromByteCount: clamped)
    }

    /// Binary (1024-based `.memory`) byte formatting — exclusively for physical RAM / Swap metrics.
    static func memoryBytes(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        let clamped = Int64(min(Double(Int64.max), max(0, v)))
        formatterLock.lock()
        defer { formatterLock.unlock() }
        return memoryByteFormatter.string(fromByteCount: clamped)
    }

    /// Throughput: B/s · KB/s · MB/s (wireframe style)
    static func rate(_ bytesPerSec: Double?) -> String {
        guard let b = bytesPerSec, b.isFinite, b >= 0 else { return "—" }
        if b < 1024 {
            return String(format: "%.0f B/s", b)
        }
        if b < 1024 * 1024 {
            return String(format: "%.1f KB/s", b / 1024)
        }
        return String(format: "%.1f MB/s", b / (1024 * 1024))
    }

    static func timeHM(_ date: Date) -> String {
        let loc = L10n.locale
        let key = loc.identifier
        formatterLock.lock()
        let f: DateFormatter
        if let cached = timeHMFormatters[key] {
            f = cached
        } else {
            let created = DateFormatter()
            created.locale = loc
            created.dateFormat = "HH:mm"
            timeHMFormatters[key] = created
            f = created
        }
        let result = f.string(from: date)
        formatterLock.unlock()
        return result
    }

    static func dayTime(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return L10n.t("format.today_time", timeHM(date))
        }
        let loc = L10n.locale
        let key = loc.identifier
        formatterLock.lock()
        let f: DateFormatter
        if let cached = dayTimeFormatters[key] {
            f = cached
        } else {
            let created = DateFormatter()
            created.locale = loc
            created.dateFormat = "MM-dd HH:mm"
            dayTimeFormatters[key] = created
            f = created
        }
        let result = f.string(from: date)
        formatterLock.unlock()
        return result
    }

    /// Stable duration since public IP confirmed
    static func stableDuration(since: Date?, now: Date = Date()) -> String {
        guard let since else { return "—" }
        let s = max(0, Int(now.timeIntervalSince(since)))
        if s < 60 { return L10n.t("format.under_1m") }
        if s < 3600 { return L10n.t("format.minutes", s / 60) }
        if s < 86400 {
            let h = s / 3600
            let m = (s % 3600) / 60
            return m == 0 ? L10n.t("format.hours", h) : L10n.t("format.hours_mins", h, m)
        }
        let d = s / 86400
        let h = (s % 86400) / 3600
        return h == 0 ? L10n.t("format.days", d) : L10n.t("format.days_hours", d, h)
    }

    /// Uptime from seconds
    static func uptime(seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 3600 {
            return L10n.t("format.minutes", max(1, s / 60))
        }
        if s < 86400 {
            let h = s / 3600
            let m = (s % 3600) / 60
            return m == 0 ? L10n.t("format.hours", h) : L10n.t("format.hours_mins", h, m)
        }
        let d = s / 86400
        let h = (s % 86400) / 3600
        return h == 0 ? L10n.t("format.days", d) : L10n.t("format.days_hours", d, h)
    }
}
