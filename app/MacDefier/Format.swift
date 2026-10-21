import Foundation

enum Format {
    static func percent(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.0f%%", v * 100)
    }

    static func bytes(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(max(0, v)), countStyle: .memory)
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

    static func rateShort(_ bytesPerSec: Double?) -> String {
        guard let b = bytesPerSec, b.isFinite else { return "—" }
        if b < 1024 * 1024 {
            return String(format: "%.0fK", b / 1024)
        }
        return String(format: "%.1fM", b / (1024 * 1024))
    }

    static func timeHM(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func dayTime(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return L10n.t("format.today_time", timeHM(date))
        }
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }

    /// Stable duration since public IP confirmed
    static func stableDuration(since: Date?) -> String {
        guard let since else { return "—" }
        let s = max(0, Int(Date().timeIntervalSince(since)))
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
