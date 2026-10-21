// AISettings — Keychain key + UserDefaults; intensity is conversation-level default.

import Foundation
import Security

public enum AIIntensity: String, CaseIterable, Sendable, Identifiable {
    case light   // 轻：短答、少推演
    case standard // 标准
    case deep    // 深：多步分析（可触发模型思考，但 UI 不默认展示思考过程）

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .light: return L10n.t("intensity.light")
        case .standard: return L10n.t("intensity.standard")
        case .deep: return L10n.t("intensity.deep")
        }
    }

    public var subtitle: String {
        switch self {
        case .light: return L10n.t("intensity.light.sub")
        case .standard: return L10n.t("intensity.standard.sub")
        case .deep: return L10n.t("intensity.deep.sub")
        }
    }
}

/// 云端配置档案（可多份，设置页单独弹窗管理）
public struct AICloudProfile: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var model: String
    /// 运行时填入；持久化走 Keychain，不进 Codable JSON
    public var apiKey: String

    /// UI label: maps stored "默认"/Default → current UI language name.
    public var localizedDisplayName: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return L10n.t("settings.api_unnamed") }
        if n == "默认" || n.caseInsensitiveCompare("Default") == .orderedSame {
            return L10n.t("settings.api_default_name")
        }
        // "配置 2" / "Profile 2" style — if starts with 配置, re-localize
        if n.hasPrefix("配置 ") {
            let rest = String(n.dropFirst(3))
            return L10n.t("settings.api_config_n", rest)
        }
        return n
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        baseURL: String = "https://api.openai.com/v1",
        model: String = "gpt-4o-mini",
        apiKey: String = ""
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL, model
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        model = try c.decode(String.self, forKey: .model)
        apiKey = ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(model, forKey: .model)
    }
}

public struct AISettings: Equatable, Sendable {
    public var enabled: Bool
    public var mode: Mode
    public var apiKey: String
    public var baseURL: String
    public var cloudModel: String
    public var localEndpoint: String
    public var localModel: String
    public var defaultIntensity: AIIntensity
    /// Keep last N user+assistant turns raw; older compressed into summary.
    public var keepRecentTurns: Int
    /// Soft cap on estimated chars sent in history (after compression).
    public var historyCharBudget: Int
    /// 多份云端配置
    public var cloudProfiles: [AICloudProfile]
    public var activeCloudProfileId: String?
    /// Cloud requests are gated here, not only by the Settings view.
    public var cloudPrivacyAcknowledged: Bool

    public enum Mode: String, CaseIterable, Sendable {
        case localFirst
        case localOnly
        case cloud
        case off

        public var title: String {
            switch self {
            case .localFirst: return L10n.t("settings.mode_local_first")
            case .localOnly: return L10n.t("settings.mode_local")
            case .cloud: return L10n.t("settings.mode_cloud")
            case .off: return L10n.t("settings.mode_off")
            }
        }

        /// 设置页分段：仅云端 / 本地
        public static var settingsSwitchCases: [Mode] { [.cloud, .localOnly] }
    }

    public static let `default` = AISettings(
        enabled: true,
        mode: .cloud,
        apiKey: "",
        baseURL: "https://api.openai.com/v1",
        cloudModel: "gpt-4o-mini",
        localEndpoint: "http://127.0.0.1:11434/v1",
        // 默认空串：逼用户填 ollama list 里的真实名，避免默认 llama3 造成 404 误导
        localModel: "",
        defaultIntensity: .standard,
        keepRecentTurns: 12,
        historyCharBudget: 12_000,
        cloudProfiles: [
            AICloudProfile(name: "Default", baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini")
        ],
        activeCloudProfileId: nil,
        cloudPrivacyAcknowledged: false
    )

    public var isConfiguredForCloud: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !cloudModel.isEmpty
    }

    public var isConfiguredForLocal: Bool {
        let ep = localEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = localModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ep.isEmpty, !model.isEmpty else { return false }
        // M08-1: 公网 URL 不算「已配置本地」——须改走 cloud + 隐私 ack
        return AIEndpointPolicy.isAllowedAsLocalModeEndpoint(ep)
    }

    public var activeCloudProfile: AICloudProfile? {
        if let id = activeCloudProfileId, let p = cloudProfiles.first(where: { $0.id == id }) {
            return p
        }
        return cloudProfiles.first
    }

    /// 把当前启用云端档案同步到 apiKey / baseURL / cloudModel（给 AIClient 用）
    public mutating func applyActiveCloudProfile() {
        guard let p = activeCloudProfile else { return }
        // 保证 id 一致
        if activeCloudProfileId == nil { activeCloudProfileId = p.id }
        // A profile without a key must stay unconfigured. The top-level key
        // may belong to the previously selected endpoint.
        baseURL = p.baseURL
        cloudModel = p.model
        apiKey = p.apiKey
    }
}

public enum AISettingsStore {
    private static let suite = UserDefaults.standard
    private static let keyEnabled = "ai.enabled"
    private static let keyMode = "ai.mode"
    private static let keyBaseURL = "ai.baseURL"
    private static let keyCloudModel = "ai.cloudModel"
    private static let keyLocalEndpoint = "ai.localEndpoint"
    private static let keyLocalModel = "ai.localModel"
    private static let keyIntensity = "ai.defaultIntensity"
    private static let keyKeepTurns = "ai.keepRecentTurns"
    private static let keyBudget = "ai.historyCharBudget"
    private static let keyProfiles = "ai.cloudProfiles"
    private static let keyActiveProfile = "ai.activeCloudProfileId"
    private static let keyCloudPrivacyAcknowledged = "ai.cloudPrivacyAcknowledged"
    /// Keychain service 从 Bundle ID 派生：生产 `com.macdefier.app.ai`，Dev `com.macdefier.app.dev.ai`。
    /// 禁止 delete/re-add 迁移；现有 Key 只 SecItemUpdate。
    private static var keychainService: String {
        let bid = Bundle.main.bundleIdentifier ?? "com.macdefier.app"
        return bid + ".ai"
    }
    /// 旧：单 key / 每档案一个 item（会连弹 N 次钥匙串）— account 名生产保持不变
    private static let keychainAccount = "cloudAPIKey"
    /// 新：所有 API Key 打成一份 JSON，进程内缓存，读写各最多 1 次钥匙串交互
    private static let keychainKeysBlobAccount = "cloudAPIKeys.v2"
    private static let legacyAccountPrefix = "cloudAPIKey."

    private static let keysLock = NSLock()
    private static var keysMemory: [String: String]?
    private static var keysMemoryPersisted = false
    private static var keysReadFailed = false

    private static func keychainAccount(forProfile id: String) -> String {
        legacyAccountPrefix + id
    }

    /// 一次取出全部 key：内存 → blob →（仅迁移时）旧 per-profile
    private static func loadAllAPIKeys(profileIDs: [String]) -> [String: String] {
        keysLock.lock()
        if let keysMemory, !keysReadFailed, (keysMemoryPersisted || keysMemory.isEmpty) {
            keysLock.unlock()
            return keysMemory
        }
        keysLock.unlock()

        // 1) 新 blob（优先）
        if let raw = Keychain.get(service: keychainService, account: keychainKeysBlobAccount),
           let dict = try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8)) {
            keysLock.lock()
            keysMemory = dict
            keysMemoryPersisted = true
            keysReadFailed = false
            keysLock.unlock()
            return dict
        }

        // 2) 旧格式迁移（可能仍弹 1×档案数；有数据才写 blob，避免「点取消」写成空包锁死）
        var dict: [String: String] = [:]
        var readFailed = false
        for id in profileIDs {
            let result = Keychain.read(service: keychainService, account: keychainAccount(forProfile: id))
            if result.status != errSecSuccess && result.status != errSecItemNotFound {
                readFailed = true
            }
            if let k = result.value, !k.isEmpty {
                dict[id] = k
            }
        }
        let legacyResult = Keychain.read(service: keychainService, account: keychainAccount)
        if legacyResult.status != errSecSuccess && legacyResult.status != errSecItemNotFound {
            readFailed = true
        }
        if let legacy = legacyResult.value, !legacy.isEmpty {
            dict["_legacy"] = legacy
        }

        keysLock.lock()
        keysReadFailed = readFailed
        keysLock.unlock()
        if !dict.isEmpty && !readFailed {
            let persisted = persistKeysBlob(dict)
            keysLock.lock()
            keysMemory = dict
            keysMemoryPersisted = persisted
            keysLock.unlock()
        } else if !readFailed {
            keysLock.lock()
            keysMemory = dict
            keysMemoryPersisted = false
            keysLock.unlock()
        }
        return dict
    }

    @discardableResult
    private static func persistKeysBlob(_ dict: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(dict),
              let raw = String(data: data, encoding: .utf8) else { return false }
        return Keychain.set(raw, service: keychainService, account: keychainKeysBlobAccount)
    }

    @discardableResult
    private static func saveAllAPIKeys(_ dict: [String: String]) -> Bool {
        if dict.isEmpty {
            keysLock.lock()
            keysMemory = dict
            keysMemoryPersisted = false
            keysReadFailed = false
            keysLock.unlock()
            // Do not create an empty Keychain blob for local/off installations.
            return true
        }
        keysLock.lock()
        if keysMemory == dict, keysMemoryPersisted {
            keysLock.unlock()
            return true
        }
        keysLock.unlock()
        guard persistKeysBlob(dict) else { return false }
        keysLock.lock()
        keysMemory = dict
        keysMemoryPersisted = true
        keysLock.unlock()
        return true
    }

    public static func load() -> AISettings {
        load(from: suite, loadAPIKeys: { loadAllAPIKeys(profileIDs: $0) })
    }

    /// Dependency boundary for isolated persistence regression tests.
    static func load(from suite: UserDefaults, loadAPIKeys: ([String]) -> [String: String]) -> AISettings {
        var s = AISettings.default
        if suite.object(forKey: keyEnabled) != nil {
            s.enabled = suite.bool(forKey: keyEnabled)
        }
        if let m = suite.string(forKey: keyMode), let mode = AISettings.Mode(rawValue: m) {
            s.mode = mode
        }
        if let v = suite.string(forKey: keyBaseURL), !v.isEmpty { s.baseURL = v }
        if let v = suite.string(forKey: keyCloudModel), !v.isEmpty { s.cloudModel = v }
        if let v = suite.string(forKey: keyLocalEndpoint), !v.isEmpty { s.localEndpoint = v }
        if let v = suite.string(forKey: keyLocalModel), !v.isEmpty { s.localModel = v }
        if let i = suite.string(forKey: keyIntensity), let intensity = AIIntensity(rawValue: i) {
            s.defaultIntensity = intensity
        }
        let turns = suite.integer(forKey: keyKeepTurns)
        if turns > 0 { s.keepRecentTurns = turns }
        let budget = suite.integer(forKey: keyBudget)
        if budget > 0 { s.historyCharBudget = budget }

        // 档案元数据（无 key）先解码，再一次性灌 key
        var profileIDs: [String] = []
        if let data = suite.data(forKey: keyProfiles),
           var profiles = try? JSONDecoder().decode([AICloudProfile].self, from: data),
           !profiles.isEmpty {
            profileIDs = profiles.map(\.id)
            let keys = loadAPIKeys(profileIDs)
            for i in profiles.indices {
                let id = profiles[i].id
                profiles[i].apiKey = keys[id] ?? ""
                if profiles[i].name == "默认" {
                    profiles[i].name = "Default"
                }
            }
            // Existing profiles can only use their own credential. The legacy
            // single key is migrated only when no profile metadata exists.
            s.cloudProfiles = profiles
            s.activeCloudProfileId = suite.string(forKey: keyActiveProfile)
        } else {
            let keys = loadAPIKeys([])
            let legacyKey = keys["_legacy"] ?? ""
            var p = AICloudProfile(
                name: "Default",
                baseURL: s.baseURL,
                model: s.cloudModel,
                apiKey: legacyKey
            )
            s.cloudProfiles = [p]
            s.activeCloudProfileId = p.id
            s.apiKey = legacyKey
        }

        if s.activeCloudProfileId == nil || !(s.cloudProfiles.contains { $0.id == s.activeCloudProfileId }) {
            s.activeCloudProfileId = s.cloudProfiles.first?.id
        }
        s.applyActiveCloudProfile()
        // Preserve existing configured users during upgrade. An installation
        // with no key remains unacknowledged until the first cloud setup.
        let persistedMode = suite.string(forKey: keyMode)
        let hadLegacyCloudSettings = persistedMode == AISettings.Mode.cloud.rawValue
            && (suite.object(forKey: keyEnabled) != nil
                || suite.object(forKey: keyProfiles) != nil
                || suite.object(forKey: keyActiveProfile) != nil
                || suite.object(forKey: keyBaseURL) != nil
                || suite.object(forKey: keyCloudModel) != nil)
        let hasExistingCloudKey = !s.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || s.cloudProfiles.contains { !$0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if suite.object(forKey: keyCloudPrivacyAcknowledged) == nil,
           hadLegacyCloudSettings || hasExistingCloudKey {
            suite.set(true, forKey: keyCloudPrivacyAcknowledged)
        }
        s.cloudPrivacyAcknowledged = suite.bool(forKey: keyCloudPrivacyAcknowledged)
        return s
    }

    @discardableResult
    public static func save(_ s: AISettings) -> Bool {
        var s = s
        let persistedProfiles: [AICloudProfile] = {
            guard let data = suite.data(forKey: keyProfiles) else { return [] }
            return (try? JSONDecoder().decode([AICloudProfile].self, from: data)) ?? []
        }()
        let persistedIDs = Set(persistedProfiles.map(\.id))
        let currentIDs = Set(s.cloudProfiles.map(\.id))
        let deletedIDs = persistedIDs.subtracting(currentIDs)
        let deletedActiveProfile = suite.string(forKey: keyActiveProfile).map(deletedIDs.contains) ?? false

        if let id = s.activeCloudProfileId, let idx = s.cloudProfiles.firstIndex(where: { $0.id == id }) {
            s.cloudProfiles[idx].baseURL = s.baseURL
            s.cloudProfiles[idx].model = s.cloudModel
            s.cloudProfiles[idx].apiKey = s.apiKey
        } else if let first = s.cloudProfiles.first {
            s.activeCloudProfileId = first.id
        }
        s.applyActiveCloudProfile()

        // 只写一份 blob；空 key 保留内存/盘里旧值（防锁屏读空写丢）
        var dict = loadAllAPIKeys(profileIDs: s.cloudProfiles.map(\.id))
        if !deletedIDs.isEmpty {
            keysLock.lock()
            let readFailed = keysReadFailed
            keysLock.unlock()
            // Explicit profile deletion must never turn a temporary Keychain
            // read failure into broad credential loss.
            guard !readFailed else { return false }
            for id in deletedIDs { dict.removeValue(forKey: id) }
            if deletedActiveProfile { dict.removeValue(forKey: "_legacy") }
        }
        for p in s.cloudProfiles {
            if !p.apiKey.isEmpty {
                dict[p.id] = p.apiKey
            }
        }
        if !s.apiKey.isEmpty {
            dict["_legacy"] = s.apiKey
            if let id = s.activeCloudProfileId {
                dict[id] = s.apiKey
            }
        }
        let blobSaved: Bool
        if !deletedIDs.isEmpty, dict.isEmpty {
            blobSaved = Keychain.delete(service: keychainService, account: keychainKeysBlobAccount)
            if blobSaved {
                keysLock.lock()
                keysMemory = [:]
                keysMemoryPersisted = false
                keysReadFailed = false
                keysLock.unlock()
            }
        } else {
            blobSaved = saveAllAPIKeys(dict)
        }
        guard blobSaved else { return false }

        // Clean up legacy per-profile items only after the authoritative blob
        // has been updated. These accounts are migration leftovers, but they
        // still contain the user's secret and must honor explicit deletion.
        for id in deletedIDs {
            guard Keychain.delete(service: keychainService, account: keychainAccount(forProfile: id)) else {
                return false
            }
        }
        if deletedActiveProfile {
            guard Keychain.delete(service: keychainService, account: keychainAccount) else { return false }
        }

        suite.set(s.enabled, forKey: keyEnabled)
        suite.set(s.mode.rawValue, forKey: keyMode)
        suite.set(s.baseURL, forKey: keyBaseURL)
        suite.set(s.cloudModel, forKey: keyCloudModel)
        suite.set(s.localEndpoint, forKey: keyLocalEndpoint)
        suite.set(s.localModel, forKey: keyLocalModel)
        suite.set(s.defaultIntensity.rawValue, forKey: keyIntensity)
        suite.set(s.keepRecentTurns, forKey: keyKeepTurns)
        suite.set(s.historyCharBudget, forKey: keyBudget)
        suite.set(s.activeCloudProfileId, forKey: keyActiveProfile)
        suite.set(s.cloudPrivacyAcknowledged, forKey: keyCloudPrivacyAcknowledged)
        if let data = try? JSONEncoder().encode(s.cloudProfiles) {
            suite.set(data, forKey: keyProfiles)
        }
        return true
    }

    /// Delete only after an explicit user confirmation. Ordinary saves keep an
    /// existing key when the input is empty, so a temporary Keychain read
    /// failure can never erase credentials.
    @discardableResult
    public static func deleteAPIKey(profileID: String, removeLegacy: Bool = true) -> Bool {
        var dict = loadAllAPIKeys(profileIDs: [profileID])
        keysLock.lock()
        let readFailed = keysReadFailed
        keysLock.unlock()
        guard !readFailed else { return false }
        dict.removeValue(forKey: profileID)
        if removeLegacy { dict.removeValue(forKey: "_legacy") }

        let blobOK: Bool
        if dict.isEmpty {
            blobOK = Keychain.delete(service: keychainService, account: keychainKeysBlobAccount)
        } else {
            blobOK = persistKeysBlob(dict)
        }
        guard blobOK else { return false }

        let profileOK = Keychain.delete(service: keychainService, account: keychainAccount(forProfile: profileID))
        var legacyOK = true
        if removeLegacy {
            legacyOK = Keychain.delete(service: keychainService, account: keychainAccount)
        }
        guard profileOK, legacyOK else { return false }
        keysLock.lock()
        keysMemory = dict
        keysMemoryPersisted = true
        keysLock.unlock()
        return true
    }
}

enum Keychain {
    /// 进程内缓存：避免设置页多次 load/save、多页 onAppear 反复 SecItem → 连弹钥匙串
    private static let lock = NSLock()
    private static var memory: [String: String] = [:]

    private static func cacheKey(service: String, account: String) -> String {
        service + "\u{1e}" + account
    }

    /// Store API keys so day-to-day **ad-hoc / re-sign rebuilds** do not spam
    /// "MacDefier wants to use your confidential information".
    @discardableResult
    static func set(_ value: String, service: String, account: String) -> Bool {
        let ck = cacheKey(service: service, account: account)
        lock.lock()
        if memory[ck] == value {
            lock.unlock()
            return true
        }
        lock.unlock()

        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Existing credentials: update only the value and preserve their ACL.
        // Never broaden/recreate an existing Key during an ordinary save.
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        let finalStatus: OSStatus
        if status == errSecItemNotFound {
            // New credentials fail closed when an App-bound ACL cannot be
            // created.  Debug's isolated service has its explicit fallback in
            // openAccess; Release never adds an unbound item.
            guard let access = openAccess(label: "\(service).\(account)") else {
                return false
            }
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrAccess as String] = access
            finalStatus = SecItemAdd(add as CFDictionary, nil)
        } else {
            // Never delete/recreate after an authentication or locked-keychain
            // error: doing so can destroy a valid existing credential.
            finalStatus = status
        }

        guard finalStatus == errSecSuccess else { return false }

        lock.lock()
        memory[ck] = value
        lock.unlock()
        return true
    }

    static func get(service: String, account: String) -> String? {
        read(service: service, account: account).value
    }

    static func read(service: String, account: String) -> (value: String?, status: OSStatus) {
        let ck = cacheKey(service: service, account: account)
        lock.lock()
        if let hit = memory[ck] {
            lock.unlock()
            return (hit, errSecSuccess)
        }
        lock.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return (nil, status)
        }
        lock.lock()
        memory[ck] = value
        lock.unlock()
        return (value, errSecSuccess)
    }

    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let ck = cacheKey(service: service, account: account)
        lock.lock()
        memory.removeValue(forKey: ck)
        lock.unlock()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// 新 Key：绑定当前签名 App 路径。Debug 的 ad-hoc 开发包才允许
    /// 回退到当前调用应用；Release 失败关闭，绝不创建宽信任 Key。
    /// 现有 Key 只走 SecItemUpdate，不 delete/re-add。
    private static func openAccess(label: String) -> SecAccess? {
        var trusted: SecTrustedApplication?
        let bundlePath = Bundle.main.bundlePath
        let tStatus: OSStatus = bundlePath.withCString { cPath in
            SecTrustedApplicationCreateFromPath(cPath, &trusted)
        }
        if tStatus != errSecSuccess || trusted == nil {
            #if DEBUG
            // ad-hoc 开发包的兼容回退；Dev 使用独立 service，无法读取正式 Key。
            let fallback = SecTrustedApplicationCreateFromPath(nil, &trusted)
            guard fallback == errSecSuccess, let trusted else { return nil }
            var access: SecAccess?
            let aStatus = SecAccessCreate(label as CFString, [trusted] as CFArray, &access)
            guard aStatus == errSecSuccess else { return nil }
            return access
            #else
            return nil
            #endif
        }
        guard let trusted else { return nil }
        var access: SecAccess?
        let aStatus = SecAccessCreate(label as CFString, [trusted] as CFArray, &access)
        guard aStatus == errSecSuccess else { return nil }
        return access
    }
}
