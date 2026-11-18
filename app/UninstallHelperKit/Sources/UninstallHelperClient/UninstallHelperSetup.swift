import AppKit
import CryptoKit
import Darwin
import Foundation
import ServiceManagement
import UninstallHelperIPC
import OSLog

@MainActor public enum UninstallHelperSetup {
    public enum State: Sendable, Equatable { case unavailable, notRegistered, requiresApproval, enabled }
    private static let log = Logger(subsystem: "com.macdefier.app", category: "uninstall-helper-setup")

    public static var state: State {
        guard let endpoint = try? UninstallHelperTrust.current(role: .client),
              (try? UninstallHelperTrust.validateBundledHelper(endpoint: endpoint)) != nil else { return .unavailable }
        return presentationState(status: service(endpoint).status,
                                 configurationAvailable: configurationAvailable(serviceName: endpoint.serviceName))
    }

    static func presentationState(status: SMAppService.Status, configurationAvailable: Bool) -> State {
        guard configurationAvailable else { return .unavailable }
        switch status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        // NotFound can also describe a missing registration record. A valid
        // bundled service may offer registration again, never assume approval.
        case .notRegistered, .notFound: return .notRegistered
        default: return .unavailable
        }
    }

    public static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// Refresh an already-approved helper after an in-place app update/rebuild so
    /// launchd reaps any stale unlinked daemon and registers the current binary.
    /// Never registers a helper that the user has not already enabled.
    static func synchronizeEnabledRegistrationIfNeeded(_ endpoint: UninstallHelperEndpoint) async {
        let configOK = configurationAvailable(serviceName: endpoint.serviceName)
        guard configOK, (try? UninstallHelperTrust.validateBundledHelper(endpoint: endpoint)) != nil else {
            setStoredFingerprint(nil, for: endpoint.serviceName)
            return
        }
        let helper = service(endpoint)
        let fingerprint = bundledServiceFingerprint(serviceName: endpoint.serviceName)
        await synchronizeEnabledRegistration(
            status: { helper.status },
            unregister: { try await helper.unregister() },
            register: { try helper.register() },
            configurationAvailable: configOK,
            currentFingerprint: fingerprint,
            storedFingerprint: storedFingerprint(for: endpoint.serviceName),
            saveFingerprint: { setStoredFingerprint($0, for: endpoint.serviceName) },
            retryDelaysMs: [250, 500, 1000]
        )
    }

    static func synchronizeEnabledRegistration(status: () -> SMAppService.Status,
                                               unregister: () async throws -> Void,
                                               register: () throws -> Void,
                                               configurationAvailable: Bool,
                                               currentFingerprint: String?,
                                               storedFingerprint: String?,
                                               saveFingerprint: (String?) -> Void,
                                               retryDelaysMs: [UInt64] = []) async {
        guard configurationAvailable, let currentFingerprint else {
            saveFingerprint(nil)
            return
        }
        let initial = status()
        guard initial == .enabled else {
            if initial == .notRegistered || initial == .notFound {
                saveFingerprint(nil)
            }
            return
        }
        guard storedFingerprint != currentFingerprint else { return }
        log.info("refreshing enabled helper registration for updated binary")
        do { try await unregister() }
        catch {
            let nsError = error as NSError
            log.warning("unregister before refresh reported domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
        }
        do {
            try await registerAfterUnregister(status: status, register: register, retryDelaysMs: retryDelaysMs)
        } catch {
            let nsError = error as NSError
            log.error("register during refresh failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
        }
        if status() == .enabled {
            saveFingerprint(currentFingerprint)
        } else {
            saveFingerprint(nil)
        }
    }

    static func prepare(_ endpoint: UninstallHelperEndpoint) async throws {
        let configOK = configurationAvailable(serviceName: endpoint.serviceName)
        guard configOK else { throw UninstallHelperFailure("uninstall_helper_configuration_missing") }
        try UninstallHelperTrust.validateBundledHelper(endpoint: endpoint)
        guard let fingerprint = bundledServiceFingerprint(serviceName: endpoint.serviceName) else {
            throw UninstallHelperFailure("uninstall_helper_configuration_missing")
        }
        let helper = service(endpoint)
        try await prepareRegistration(
            status: { helper.status },
            unregister: { try await helper.unregister() },
            register: { try helper.register() },
            configurationAvailable: configOK,
            currentFingerprint: fingerprint,
            storedFingerprint: storedFingerprint(for: endpoint.serviceName),
            saveFingerprint: { setStoredFingerprint($0, for: endpoint.serviceName) },
            retryDelaysMs: [250, 500, 1000],
            confirmEnable: {
                await confirm(title: text("启用卸载助手？", "Enable the uninstall helper?"),
                                message: text("部分应用需要管理员权限才能移入废纸篓。助手仅处理你确认过的应用。首次启用可能还需在系统设置的‘登录项与扩展’中批准后台项目；这不会立即删除任何文件。", "Some apps need administrator permission to move to Trash. The helper handles only apps you confirm. First-time setup may also need approval in System Settings > Login Items & Extensions. Enabling it does not delete any files."),
                                action: text("启用助手", "Enable Helper"))
            },
            confirmApproval: {
                openSystemSettings()
                return await confirm(title: text("请先批准后台卸载助手", "Approve the background helper first"),
                                message: text("请在打开的系统设置中允许 MacDefier 的后台项目，再点‘已批准，继续’。接下来卸载所需的管理员密码由 macOS 单独请求；你也可以取消并保留应用。", "Allow MacDefier's background item in System Settings, then choose Continue. macOS will separately request administrator authorization for the uninstall when needed. You can cancel to keep the app."),
                                action: text("已批准，继续", "Approved, Continue"))
            }
        )
    }

    /// Force an unregister + register cycle when an XPC handshake discovers a
    /// stale or unlinked running daemon despite SMAppService reporting .enabled.
    static func reinstallRegistration(_ endpoint: UninstallHelperEndpoint) async throws {
        let configOK = configurationAvailable(serviceName: endpoint.serviceName)
        guard configOK else { throw UninstallHelperFailure("uninstall_helper_configuration_missing") }
        try UninstallHelperTrust.validateBundledHelper(endpoint: endpoint)
        guard let fingerprint = bundledServiceFingerprint(serviceName: endpoint.serviceName) else {
            throw UninstallHelperFailure("uninstall_helper_configuration_missing")
        }
        let helper = service(endpoint)
        try await reinstallRegistration(
            status: { helper.status },
            unregister: { try await helper.unregister() },
            register: { try helper.register() },
            configurationAvailable: configOK,
            currentFingerprint: fingerprint,
            saveFingerprint: { setStoredFingerprint($0, for: endpoint.serviceName) },
            retryDelaysMs: [250, 500, 1000],
            confirmApproval: {
                openSystemSettings()
                return await confirm(title: text("请先批准后台卸载助手", "Approve the background helper first"),
                                message: text("请在打开的系统设置中允许 MacDefier 的后台项目，再点‘已批准，继续’。接下来卸载所需的管理员密码由 macOS 单独请求；你也可以取消并保留应用。", "Allow MacDefier's background item in System Settings, then choose Continue. macOS will separately request administrator authorization for the uninstall when needed. You can cancel to keep the app."),
                                action: text("已批准，继续", "Approved, Continue"))
            }
        )
    }

    /// Inject only setup effects in tests; no fixture registers a real daemon.
    static func prepareRegistration(status: () -> SMAppService.Status,
                                    unregister: () async throws -> Void = {},
                                    register: () throws -> Void,
                                    configurationAvailable: Bool,
                                    currentFingerprint: String? = nil,
                                    storedFingerprint: String? = nil,
                                    saveFingerprint: (String?) -> Void = { _ in },
                                    retryDelaysMs: [UInt64] = [],
                                    confirmEnable: () async -> Bool,
                                    confirmApproval: () async -> Bool) async throws {
        guard configurationAvailable else { throw UninstallHelperFailure("uninstall_helper_configuration_missing") }
        try Task.checkCancellation()
        var current = status()
        log.info("prepare status=\(current.rawValue, privacy: .public)")
        if current == .enabled, let currentFingerprint, storedFingerprint != currentFingerprint {
            log.info("prepare cycling enabled helper registration for updated binary")
            saveFingerprint(nil)
            do { try await unregister() }
            catch {
                let nsError = error as NSError
                log.warning("prepare unregister reported domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
            }
            try Task.checkCancellation()
            do {
                try await registerAfterUnregister(status: status, register: register, retryDelaysMs: retryDelaysMs)
            } catch {
                let nsError = error as NSError
                log.error("prepare re-register failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
                current = status()
                guard current == .requiresApproval || current == .enabled else {
                    throw UninstallHelperFailure("uninstall_helper_registration_failed")
                }
            }
            current = status()
        } else if current == .notRegistered || current == .notFound {
            guard await confirmEnable() else {
                throw UninstallHelperFailure("uninstall_authorization_cancelled")
            }
            try Task.checkCancellation()
            do { try register() }
            catch {
                let nsError = error as NSError
                log.error("register failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
                // SMAppService can report launch denied while registration has
                // entered requiresApproval. That is a setup step, not failure.
                current = status()
                guard current == .requiresApproval || current == .enabled else {
                    throw UninstallHelperFailure("uninstall_helper_registration_failed")
                }
            }
            current = status()
        }
        if current == .requiresApproval {
            guard await confirmApproval() else {
                throw UninstallHelperFailure("uninstall_authorization_cancelled")
            }
            current = status()
        }
        try Task.checkCancellation()
        log.info("prepared status=\(current.rawValue, privacy: .public)")
        guard current == .enabled else {
            saveFingerprint(nil)
            throw UninstallHelperFailure(current == .requiresApproval
                ? "uninstall_helper_approval_required" : "uninstall_helper_registration_failed")
        }
        if let currentFingerprint {
            saveFingerprint(currentFingerprint)
        }
    }

    static func reinstallRegistration(status: () -> SMAppService.Status,
                                      unregister: () async throws -> Void,
                                      register: () throws -> Void,
                                      configurationAvailable: Bool,
                                      currentFingerprint: String? = nil,
                                      saveFingerprint: (String?) -> Void = { _ in },
                                      retryDelaysMs: [UInt64] = [],
                                      confirmApproval: () async -> Bool) async throws {
        guard configurationAvailable else { throw UninstallHelperFailure("uninstall_helper_configuration_missing") }
        try Task.checkCancellation()
        saveFingerprint(nil)
        log.info("reinstalling helper registration to clear stale daemon")
        do { try await unregister() }
        catch {
            let nsError = error as NSError
            log.warning("reinstall unregister reported domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
        }
        try Task.checkCancellation()
        do {
            try await registerAfterUnregister(status: status, register: register, retryDelaysMs: retryDelaysMs)
        } catch {
            let nsError = error as NSError
            log.error("reinstall register failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
            let afterRegister = status()
            guard afterRegister == .requiresApproval || afterRegister == .enabled else {
                throw UninstallHelperFailure("uninstall_helper_registration_failed")
            }
        }
        var current = status()
        if current == .requiresApproval {
            guard await confirmApproval() else {
                throw UninstallHelperFailure("uninstall_authorization_cancelled")
            }
            current = status()
        }
        try Task.checkCancellation()
        guard current == .enabled else {
            throw UninstallHelperFailure(current == .requiresApproval
                ? "uninstall_helper_approval_required" : "uninstall_helper_registration_failed")
        }
        if let currentFingerprint {
            saveFingerprint(currentFingerprint)
        }
    }

    /// BTM updates effective disposition asynchronously (~500ms) after unregister().
    /// Immediate register() can transiently receive SMAppServiceErrorDomain code=1
    /// before BTMManager.userDataDidChange settles; retry across that window.
    private static func registerAfterUnregister(status: () -> SMAppService.Status,
                                                register: () throws -> Void,
                                                retryDelaysMs: [UInt64]) async throws {
        var lastError: Error?
        for attempt in 0...retryDelaysMs.count {
            if attempt > 0 {
                try Task.checkCancellation()
                let delay = retryDelaysMs[attempt - 1]
                if delay > 0 {
                    try await Task.sleep(nanoseconds: delay * 1_000_000)
                }
            }
            do {
                try register()
                let current = status()
                if current == .enabled || current == .requiresApproval {
                    return
                }
            } catch {
                lastError = error
                let current = status()
                if current == .enabled || current == .requiresApproval {
                    return
                }
            }
        }
        if let lastError { throw lastError }
    }

    static func bundledServiceFingerprint(serviceName: String, bundleURL: URL = Bundle.main.bundleURL) -> String? {
        guard configurationAvailable(serviceName: serviceName, bundleURL: bundleURL) else { return nil }
        let root = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let definition = root.appendingPathComponent("Contents/Library/LaunchDaemons/\(serviceName).plist")
        let executable = root.appendingPathComponent("Contents/MacOS/MacDefier-UninstallHelper")
        var st = stat()
        guard lstat(executable.path, &st) == 0,
              let plistData = try? Data(contentsOf: definition),
              let executableData = try? Data(contentsOf: executable) else { return nil }
        var hasher = SHA256()
        hasher.update(data: plistData)
        hasher.update(data: Data([0]))
        hasher.update(data: executableData)
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "v1:\(digest):\(st.st_dev):\(st.st_ino)"
    }

    static func configurationAvailable(serviceName: String, bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        let root = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let definition = root.appendingPathComponent("Contents/Library/LaunchDaemons/\(serviceName).plist")
        let executable = root.appendingPathComponent("Contents/MacOS/MacDefier-UninstallHelper")
        for url in [definition, executable] {
            guard url.resolvingSymlinksInPath().standardizedFileURL == url,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              let data = try? Data(contentsOf: definition),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              plist["Label"] as? String == serviceName,
              plist["BundleProgram"] as? String == "Contents/MacOS/MacDefier-UninstallHelper",
              plist["Program"] == nil, plist["ProgramArguments"] == nil,
              let services = plist["MachServices"] as? [String: Bool],
              services.count == 1, services[serviceName] == true else { return false }
        return true
    }

    static func unregister(_ endpoint: UninstallHelperEndpoint) async throws {
        setStoredFingerprint(nil, for: endpoint.serviceName)
        do { try await service(endpoint).unregister() }
        catch { throw UninstallHelperFailure("uninstall_helper_registration_failed") }
    }

    private static func registrationFingerprintKey(_ serviceName: String) -> String {
        "uninstallHelper.registeredFingerprint." + serviceName
    }

    private static func storedFingerprint(for serviceName: String) -> String? {
        UserDefaults.standard.string(forKey: registrationFingerprintKey(serviceName))
    }

    private static func setStoredFingerprint(_ value: String?, for serviceName: String) {
        let key = registrationFingerprintKey(serviceName)
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func service(_ endpoint: UninstallHelperEndpoint) -> SMAppService {
        SMAppService.daemon(plistName: endpoint.serviceName + ".plist")
    }

    private static func text(_ chinese: String, _ english: String) -> String {
        let saved = UserDefaults.standard.string(forKey: "app.language")
        let language = ["en", "zh-Hans"].contains(saved ?? "") ? saved! : (Locale.preferredLanguages.first ?? "zh-Hans")
        return language.hasPrefix("en") ? english : chinese
    }

    private static func confirm(title: String, message: String, action: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: text("取消", "Cancel"))
        if var window = NSApp.keyWindow ?? NSApp.mainWindow {
            while let sheet = window.attachedSheet { window = sheet }
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
            }
        }
        return alert.runModal() == .alertFirstButtonReturn
    }
}
