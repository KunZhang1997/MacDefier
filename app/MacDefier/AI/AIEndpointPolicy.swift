// AIEndpointPolicy — classify AI base URLs: loopback / private LAN / remote / invalid.
// Only true loopback may skip “data leaves machine” privacy ack.
// Public HTTP is forbidden; LAN HTTP is allowed with explicit risk.

import Foundation
import Network

public enum AIEndpointKind: String, Sendable, Equatable {
    /// 127.0.0.0/8, localhost, ::1 — 数据不出本机
    case loopback
    /// RFC1918 / link-local / unique-local — 数据离开本机进程，但仍在局域网
    case privateLAN
    /// 公网或未识别主机 — 数据离开本机
    case remote
    case invalid
}

public enum AIEndpointPolicy {
    public struct Classification: Sendable, Equatable {
        public let kind: AIEndpointKind
        public let host: String
        public let usesTLS: Bool
        /// 是否必须先走「数据离开本机」摘要确认
        public var requiresRemotePrivacyAck: Bool {
            switch kind {
            case .privateLAN, .remote: return true
            case .loopback, .invalid: return false
            }
        }
        /// 是否允许发起请求（公网 HTTP 禁止）
        public var isRequestAllowed: Bool {
            switch kind {
            case .invalid: return false
            case .remote: return usesTLS
            case .loopback, .privateLAN: return true
            }
        }
        public var isLANHTTPRisk: Bool {
            kind == .privateLAN && !usesTLS
        }
    }

    /// 解析 base URL（可带 /v1 等路径）。
    public static func classify(_ raw: String) -> Classification {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Classification(kind: .invalid, host: "", usesTLS: false)
        }
        var s = trimmed
        if !s.contains("://") {
            // 无 scheme：本机默认 http，其它默认 https
            let hostGuess = s.split(separator: "/").first.map(String.init) ?? s
            if isLoopbackHost(hostGuess) {
                s = "http://" + s
            } else {
                s = "https://" + s
            }
        }
        guard let url = URL(string: s), let host = url.host, !host.isEmpty else {
            return Classification(kind: .invalid, host: "", usesTLS: false)
        }
        let scheme = (url.scheme ?? "").lowercased()
        let usesTLS = scheme == "https"
        if scheme != "http", scheme != "https" {
            return Classification(kind: .invalid, host: host, usesTLS: false)
        }

        let kind: AIEndpointKind
        if isLoopbackHost(host) {
            kind = .loopback
        } else if isPrivateOrLinkLocalHost(host) {
            kind = .privateLAN
        } else {
            kind = .remote
        }

        // 公网 HTTP 直接标 invalid（禁止请求）
        if kind == .remote, !usesTLS {
            return Classification(kind: .invalid, host: host, usesTLS: false)
        }
        return Classification(kind: kind, host: host, usesTLS: usesTLS)
    }

    /// 是否可按「本机模式」无远程摘要直接使用（仅 loopback）。
    public static func isTrueLocalEndpoint(_ raw: String) -> Bool {
        classify(raw).kind == .loopback
    }

    /// M08-1：localOnly / localFirst 的「本地 Endpoint」仅允许 loopback / 私网·link-local。
    /// 公网主机必须走 cloud 模式 + 隐私确认，禁止挂在「本地」标签下出站。
    public static func isAllowedAsLocalModeEndpoint(_ raw: String) -> Bool {
        let cls = classify(raw)
        guard cls.isRequestAllowed else { return false }
        switch cls.kind {
        case .loopback, .privateLAN: return true
        case .remote, .invalid: return false
        }
    }

    /// local 模式是否可对端点发请求（含隐私 ack 门闩）。公网恒 false。
    public static func mayRequestAsLocalMode(_ raw: String, privacyAcknowledged: Bool) -> Bool {
        guard isAllowedAsLocalModeEndpoint(raw) else { return false }
        let cls = classify(raw)
        if cls.requiresRemotePrivacyAck { return privacyAcknowledged }
        return true
    }

    /// 数据是否会离开本机（LAN + 公网）。
    public static func dataLeavesDevice(_ raw: String) -> Bool {
        let k = classify(raw).kind
        return k == .privateLAN || k == .remote
    }

    public static func isLoopbackHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h == "::1" { return true }
        // 127.0.0.0/8
        if h.hasPrefix("127.") {
            let parts = h.split(separator: ".")
            if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) { return true }
        }
        return false
    }

    public static func isPrivateOrLinkLocalHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        // IPv4 private / link-local（只认解析后的地址，不认域名字符串）
        if let ipv4 = IPv4Address(h) {
            let bytes = ipv4.rawValue
            guard bytes.count == 4 else { return false }
            let b0 = bytes[0], b1 = bytes[1]
            // 10.0.0.0/8
            if b0 == 10 { return true }
            // 172.16.0.0/12
            if b0 == 172, b1 >= 16, b1 <= 31 { return true }
            // 192.168.0.0/16
            if b0 == 192, b1 == 168 { return true }
            // 169.254.0.0/16 link-local
            if b0 == 169, b1 == 254 { return true }
            return false
        }
        // IPv6：必须能解析为地址后再判 ULA / link-local（禁止 fc.example.com 前缀误伤）
        if let ipv6 = IPv6Address(h) {
            return isPrivateOrLinkLocalIPv6(ipv6)
        }
        // .local mDNS（主机名，非 IPv6 字面量）
        if h.hasSuffix(".local") { return true }
        return false
    }

    /// fc00::/7 unique local · fe80::/10 link-local
    private static func isPrivateOrLinkLocalIPv6(_ addr: IPv6Address) -> Bool {
        let raw = addr.rawValue
        guard raw.count >= 2 else { return false }
        let b0 = raw[0]
        let b1 = raw[1]
        // fc00::/7 → first 7 bits 1111 110x
        if (b0 & 0xFE) == 0xFC { return true }
        // fe80::/10 → 1111 1110 10xx xxxx
        if b0 == 0xFE, (b1 & 0xC0) == 0x80 { return true }
        return false
    }
}
