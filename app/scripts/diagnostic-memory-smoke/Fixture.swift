// Compile once with -D CLEANUP_KIT_STUB -module-name CleanupKit -emit-module -emit-object,
// then without that flag beside the real diagnostic sources. No scans or actions run.
#if CLEANUP_KIT_STUB
public struct InstalledApp: Sendable {
    public var name: String
    public var path: String
    public var bundleIdentifier: String
    public var totalBytes: UInt64
    public var formattedSizeDetail: String?
    public var formattedSize: String { "unused" }
}
public enum CleanupCategory: Sendable { case largeAppData, trash, other }
public struct CleanupCategoryGroup: Sendable {
    public var category: CleanupCategory
    public var totalBytes: UInt64
    public var isPartial: Bool
}
public enum JunkScanProfile { case diagnosticLite }
public struct JunkScanner {
    public init() {}
    public func scan(profile: JunkScanProfile, progress: @escaping @Sendable (Double, String) -> Void) async -> [CleanupCategoryGroup] { [] }
}
public enum AppInventory {
    public static func fetchInstalledApps(includeSystemApps: Bool = true, computeSize: Bool = true) -> [InstalledApp] { [] }
}
#else
import Foundation
import MonitorKit

enum L10n {
    static func t(_ key: String, _ args: CVarArg...) -> String { key }
}
struct AppLanguage {
    static let current = AppLanguage()
    let isEnglish = true
    let rawValue = "en"
    let aiLanguageRule = "English"
    func yesNo(_ value: Bool) -> String { String(value) }
}
struct AISettings { enum Mode { case off }; var enabled = false; var mode = Mode.off }
enum AISettingsStore { static func load() -> AISettings { AISettings() } }
struct AIMessage { var role: Role; var content: String; enum Role { case user } }
struct AIReply { var content: String; var actions: [DefierAction] }
enum AIClient {
    enum Intensity { case standard }
    static func resolveEndpoint(_ settings: AISettings) -> String? { nil }
    static func chat(messages: [AIMessage], settings: AISettings, intensity: Intensity, systemExtra: String) async throws -> AIReply {
        fatalError("This smoke test must never call AI")
    }
}
struct DefierAction: Sendable {
    enum Kind: Sendable { case cleanup, uninstall, openSoftware, openMonitor, quitProcess, openDiagnostic, openSettings, none }
    var id: String = "fixture"
    var kind: Kind
    var title: String
    var detail: String
    var appName: String? = nil
    var bundleID: String? = nil
    var appPath: String? = nil
    var processPID: Int? = nil
    var processName: String? = nil
    var metric: String? = nil
    var buttonLabel: String { title }
}
struct ModuleChatResult { var summary: String; var actions: [DefierAction]; var errorHint: String?; var wasBusy: Bool }
enum DefierActionGuard {
    static func sanitizeAll(_ actions: [DefierAction], knownAppPaths: Set<String>) -> [DefierAction] { actions }
}
struct ActionPayload { var summary: String; var actions: [DefierAction] }
enum DefierActionParser {
    static func userVisibleProse(_ raw: String) -> String { raw }
    static func parse(from: String) -> (displayText: String, payload: ActionPayload?) { (from, nil) }
}
enum ScanReusePolicy {
    static let diagnosticTTL: TimeInterval = 600
    static func isFresh(_ date: Date, ttl: TimeInterval) -> Bool { Date().timeIntervalSince(date) < ttl }
}
enum ScanProgressL10n { static func localize(_ text: String) -> String { text } }
extension DiskVolume {
    var localizedKindLabel: String { kindLabel }
}
#endif
