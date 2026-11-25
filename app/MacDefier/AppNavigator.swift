// App-wide navigation for Mr. Defier action buttons (deep link into real UI).

import AppKit
import Combine
import Foundation
import CleanupKit
import MonitorKit

@MainActor
final class AppNavigator: ObservableObject {
    static let shared = AppNavigator()

    @Published var route: AppRoute = .diagnostic
    @Published var monitorTab: MonitorTab = .dashboard
    @Published var misterOpen = false

    /// Diagnostic deep links keep the user on the same object after changing pages.
    @Published var monitorFocusPID: Int?
    @Published var monitorFocusName: String?
    @Published var cleanupFocusCategory: CleanupCategory?
    @Published var softwareFocusPath: String?
    @Published var softwareFocusBundleID: String?
    @Published var softwareFocusName: String?
    @Published var softwareServiceFocusLabel: String?

    /// Software page should present uninstall sheet for this app when ready.
    @Published var pendingUninstallPath: String?
    @Published var pendingUninstallBundleID: String?
    @Published var pendingUninstallName: String?

    /// Cleanup page should start a rules scan when opened via action.
    /// Set only when there is no ready preview yet (avoid double scan after chat).
    @Published var shouldStartCleanupScan = false

    func openMonitor(focus finding: DiagnosticFinding?) {
        monitorFocusPID = finding?.processPID
        monitorFocusName = finding?.processName
        monitorTab = Self.monitorTab(for: finding)
        route = .monitor
    }

    func openCleanup(focus finding: DiagnosticFinding?) {
        cleanupFocusCategory = finding?.id == "trash-bin" ? .trash : nil
        shouldStartCleanupScan = false
        route = .cleanup
    }

    func focusSoftware(path: String?, bundleID: String?, name: String?) {
        softwareFocusPath = path
        softwareFocusBundleID = bundleID
        softwareFocusName = name
        route = .software
    }

    func openAIToolsStorage() {
        AIToolCleanupService.shared.activeTab = .storage
        route = .aiTools
    }

    func openSoftwareServices(focusLabel: String? = nil) {
        clearPendingUninstall()
        _ = consumeSoftwareFocus()
        softwareServiceFocusLabel = focusLabel
        AIToolCleanupService.shared.activeTab = .services
        route = .aiTools
    }

    func consumeSoftwareServiceFocus() -> String? {
        defer { softwareServiceFocusLabel = nil }
        return softwareServiceFocusLabel
    }

    func clearMonitorFocus() {
        monitorFocusPID = nil
        monitorFocusName = nil
    }

    func consumeCleanupFocusCategory() -> CleanupCategory? {
        defer { cleanupFocusCategory = nil }
        return cleanupFocusCategory
    }

    func consumeSoftwareFocus() -> (path: String?, bundleID: String?, name: String?)? {
        guard softwareFocusPath != nil || softwareFocusBundleID != nil || softwareFocusName != nil else { return nil }
        defer {
            softwareFocusPath = nil
            softwareFocusBundleID = nil
            softwareFocusName = nil
        }
        return (softwareFocusPath, softwareFocusBundleID, softwareFocusName)
    }

    private static func monitorTab(for finding: DiagnosticFinding?) -> MonitorTab {
        guard let finding else { return .dashboard }
        let id = finding.id
        if id.hasPrefix("ram") || id.hasPrefix("swap") || id.hasPrefix("simulator") || id.hasPrefix("family-ram-") || id.hasPrefix("auto-browser-") { return .ram }
        if finding.processPID != nil || id.hasPrefix("cpu") || id.hasPrefix("proc-") || id.hasPrefix("windowserver") || id.hasPrefix("family-cpu-") { return .cpu }
        if id.hasPrefix("disk") || id == "storage-incomplete" { return .disk }
        if id.contains("network") { return .network }
        return .dashboard
    }

    func handle(_ action: DefierAction) {
        let a = DefierActionGuard.sanitize(action)
        switch a.kind {
        case .cleanup:
            // Navigation only — never trash/delete. Fresh preview → don't re-scan / re-AI.
            cleanupFocusCategory = nil
            shouldStartCleanupScan = !Self.cleanupPreviewReady && !CleanupService.shared.hasFreshPreview
            route = .cleanup
            // Keep chat usable; user asked to jump to page without losing the assistant flow.
            // Still bring main window content to cleanup.
            misterOpen = false
        case .openAITools:
            openAIToolsStorage()
            misterOpen = false
        case .uninstall:
            // 仅采纳真实存在的 .app path；否则靠 bundle/name 在软件页查找
            _ = consumeSoftwareFocus()
            pendingUninstallPath = a.appPath
            pendingUninstallBundleID = a.bundleID
            pendingUninstallName = a.appName
            route = .software
            misterOpen = false
        case .openSoftware:
            _ = consumeSoftwareFocus()
            if a.appPath != nil || a.bundleID != nil || a.appName != nil {
                pendingUninstallPath = a.appPath
                pendingUninstallBundleID = a.bundleID
                pendingUninstallName = a.appName
            }
            route = .software
            misterOpen = false
        case .openSoftwareServices:
            openSoftwareServices(focusLabel: a.bundleID ?? a.appName)
            misterOpen = false
        case .openMonitor:
            clearMonitorFocus()
            route = .monitor
            monitorTab = .dashboard
            misterOpen = false
        case .openDiagnostic:
            route = .diagnostic
            misterOpen = false
        case .openSettings:
            route = .settings
            misterOpen = false
        case .quitProcess:
            guard let pid = a.processPID, let identity = a.processIdentity,
                  let pid32 = pid_t(exactly: pid),
                  let app = NSRunningApplication(processIdentifier: pid32) else { return }
            let shown = app.localizedName ?? identity.ownerName
            let alert = NSAlert()
            alert.messageText = L10n.t("process.quit_title", shown)
            alert.informativeText = L10n.t("process.quit_body")
            alert.addButton(withTitle: L10n.t("process.quit_action"))
            alert.addButton(withTitle: L10n.t("common.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if MonitoredApplicationExit.request(identity) == .requested {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    _ = await DiagnosticScanService.shared.scan(monitor: MonitorService.shared, useAI: false, force: true)
                }
            }
        case .quitAutomatedBrowser:
            guard let pid = a.processPID, let identity = a.processIdentity else { return }
            let shown = identity.ownerName
            let alert = NSAlert()
            alert.messageText = L10n.t("diag.auto_browser.confirm", shown)
            alert.informativeText = L10n.t("diag.auto_browser.confirm_body", pid)
            alert.addButton(withTitle: L10n.t("diag.act.quit_auto_browser"))
            alert.addButton(withTitle: L10n.t("common.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if AutomatedBrowserExit.terminate(identity) == .requested {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    _ = await DiagnosticScanService.shared.scan(monitor: MonitorService.shared, useAI: false, force: true)
                }
            }
        case .shutdownSimulators:
            guard SimulatorControl.isSimulatorEnvironmentInstalled else { return }
            let alert = NSAlert()
            alert.messageText = L10n.t("diag.sim.confirm")
            alert.informativeText = L10n.t("diag.sim.confirm_body")
            alert.addButton(withTitle: L10n.t("diag.act.shutdown_sim"))
            alert.addButton(withTitle: L10n.t("common.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            Task.detached(priority: .userInitiated) {
                _ = SimulatorControl.shutdownBooted()
                try? await Task.sleep(nanoseconds: 900_000_000)
                _ = await DiagnosticScanService.shared.scan(monitor: MonitorService.shared, useAI: false, force: true)
            }
        case .none:
            break
        }
    }

    func consumeCleanupScanFlag() -> Bool {
        guard shouldStartCleanupScan else { return false }
        // If chat already filled preview while flag was sitting, still skip.
        if Self.cleanupPreviewReady {
            shouldStartCleanupScan = false
            return false
        }
        shouldStartCleanupScan = false
        return true
    }

    func clearPendingUninstall() {
        pendingUninstallPath = nil
        pendingUninstallBundleID = nil
        pendingUninstallName = nil
    }

    /// Shared CleanupService already has a usable preview (from chat or prior page scan).
    private static var cleanupPreviewReady: Bool {
        let c = CleanupService.shared
        if c.phase.isBusy || c.isAIEnriching { return true } // open page, don't start a second job
        if c.hasFreshPreview { return true }
        if case .preview = c.phase, !c.groups.isEmpty { return true }
        return false
    }
}
