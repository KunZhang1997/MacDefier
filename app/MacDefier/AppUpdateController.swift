import AppKit
import CleanupKit
import Combine
import Sparkle
import SwiftUI

/// Sparkle owns signed downloads and replacement; its UI stays next to the top tab bar.
/// All update checks, feeds, and packages strictly use the official website (kun97.tech).
@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUserDriver, SPUUpdaterDelegate {
    static let shared = AppUpdateController()
    static let officialWebsiteURL = URL(string: "https://kun97.tech/macdefier/")!
    static let officialWebsiteDisplay = "kun97.tech/macdefier/"
    static let officialFeedURL = URL(string: "https://kun97.tech/macdefier/releases/appcast.xml")!
    static let officialHost = "kun97.tech"
    static let officialReleasesPathPrefix = "/macdefier/releases/"

    nonisolated static func isOfficialUpdateURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == officialHost,
              components.port == nil,
              components.user == nil,
              components.password == nil else {
            return false
        }
        let path = components.percentEncodedPath
        guard path.hasPrefix(officialReleasesPathPrefix),
              !path.contains(".."),
              !path.contains("//") else {
            return false
        }
        let asset = String(path.dropFirst(officialReleasesPathPrefix.count))
        guard !asset.isEmpty, !asset.contains("/") else { return false }
        let lower = asset.lowercased()
        return lower.hasSuffix(".dmg") || lower.hasSuffix(".zip")
    }

    @Published private(set) var stage: AppUpdateStage = .idle
    @Published private(set) var errorDetail: String?
    private var transfer = AppUpdateState()
    private var updater: SPUUpdater?
    private enum CheckIntent { case none, information, download }
    private var intent = CheckIntent.none
    private var userRequested: Bool { intent == .download }
    private var probedVersion: String?
    private var nextInformationCheck = Date.distantPast
    private var cancellation: (() -> Void)?
    private var installReply: ((SPUUserUpdateChoice) -> Void)?
    private var installTask: Task<Void, Never>?
    private var mutationLease: UUID?
    private let isProductionBuild: Bool
    private let startUpdate: ((AppUpdateController) throws -> Void)?
    private let startInformationCheck: ((AppUpdateController) throws -> Void)?
    private let now: () -> Date

    // The optional launcher allows callback/coordination tests without a feed,
    // network request, package replacement or application termination.
    init(isProductionBuild: Bool = Bundle.main.bundleIdentifier == "com.macdefier.app",
         startUpdate: ((AppUpdateController) throws -> Void)? = nil,
         startInformationCheck: ((AppUpdateController) throws -> Void)? = nil,
         now: @escaping () -> Date = Date.init) {
        self.isProductionBuild = isProductionBuild
        self.startUpdate = startUpdate
        self.startInformationCheck = startInformationCheck
        self.now = now
        super.init()
    }

    /// Lifecycle-triggered metadata probe. No update UI, download or install.
    func checkForUpdateIfNeeded() {
        guard isProductionBuild, !stage.isBusy, intent == .none,
              updater?.sessionInProgress != true, now() >= nextInformationCheck,
              !ProcessInfo.processInfo.arguments.contains("--export-app-icon") else { return }
        intent = .information
        probedVersion = nil
        errorDetail = nil
        change { $0.setStage(.probing) }
        do {
            if let startInformationCheck { try startInformationCheck(self); return }
            try readyUpdater().checkForUpdateInformation()
        } catch {
            updater = nil
            finishInformationCheck(error: error)
        }
    }

    private func readyUpdater() throws -> SPUUpdater {
        if let updater { return updater }
        let next = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                              userDriver: self, delegate: self)
        try next.start()
        updater = next
        return next
    }

    private func finishInformationCheck(error: Error?) {
        guard intent == .information else { return }
        let noUpdate = (error as NSError?)?.code == 1001 // SUNoUpdateError
            && (error as NSError?)?.domain == SUSparkleErrorDomain
        let reason = (error as NSError?)?.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        let version = error == nil ? probedVersion : nil
        // Activation is the trigger, not a timer. Limit successful checks to
        // once per 15 minutes; retry failed/offline probes after one minute.
        nextInformationCheck = now().addingTimeInterval(error == nil || noUpdate ? 900 : 60)
        probedVersion = nil
        if let version { finish(.available(version)) }
        else if noUpdate { finish(reason?.intValue == 1 || reason?.intValue == 2 ? .current : .unavailable) }
        else { finish(.idle) }
    }

    func downloadAndInstall() {
        guard !stage.isBusy, updater?.sessionInProgress != true,
              !ProcessInfo.processInfo.arguments.contains("--export-app-icon") else { return }
        errorDetail = nil
        // Never replace the developer app with the different production bundle.
        guard isProductionBuild else {
            change { $0.setStage(.development) }
            return
        }
        intent = .download
        change { $0.begin() }
        do {
            if let startUpdate { try startUpdate(self); return }
            try readyUpdater().checkForUpdates()
        } catch {
            updater = nil
            finish(.failed, error: error)
        }
    }

    func cancel() {
        guard stage.isCancellable else { return }
        let cancel = cancellation
        cancellation = nil
        let reply = installReply
        installReply = nil
        finish(.cancelled)
        cancel?()
        reply?(.skip)
    }

    private func change(_ update: (inout AppUpdateState) -> Void) {
        update(&transfer)
        if stage != transfer.stage { stage = transfer.stage }
    }

    private func finish(_ result: AppUpdateStage, error: Error? = nil) {
        intent = .none
        cancellation = nil
        installTask?.cancel()
        installTask = nil
        installReply = nil
        if let lease = mutationLease {
            mutationLease = nil
            Task { await ResourceMutationCoordinator.shared.release(lease) }
        }
        errorDetail = error?.localizedDescription
        change { $0.setStage(result) }
    }

    private func installWhenIdle(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard userRequested, installReply == nil, installTask == nil else {
            reply(.skip)
            return
        }
        cancellation = nil
        installReply = reply
        change { $0.setStage(.waitingToInstall) }
        installTask = Task { [weak self] in
            // Logical lock only: '/' overlaps all cleanup/uninstall leases.
            // This never reads, writes or removes the filesystem root.
            while !Task.isCancelled {
                if let lease = await ResourceMutationCoordinator.shared.acquire(paths: ["/"]) {
                    guard let self, !Task.isCancelled, self.userRequested,
                          let reply = self.installReply else {
                        await ResourceMutationCoordinator.shared.release(lease)
                        return
                    }
                    self.mutationLease = lease
                    self.installReply = nil
                    self.change { $0.setStage(.installing) }
                    reply(.install)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
            }
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        Self.officialFeedURL.absoluteString
    }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        switch (intent, updateCheck) {
        case (.information, .updateInformation), (.download, .updates): return
        default: throw CancellationError()
        }
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard intent == .information else { return }
        guard !item.isInformationOnlyUpdate, !item.isMajorUpgrade,
              let fileURL = item.fileURL, Self.isOfficialUpdateURL(fileURL),
              !item.versionString.isEmpty else {
            probedVersion = nil
            return
        }
        probedVersion = item.displayVersionString.isEmpty ? item.versionString : item.displayVersionString
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: Error?) {
        guard updateCheck == .updateInformation else { return }
        finishInformationCheck(error: error)
    }
    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false,
                                         automaticUpdateDownloading: false,
                                         sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        guard userRequested else { cancellation(); return }
        self.cancellation = cancellation
    }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        handleUpdateFound(appcastItem, isInstalling: state.stage == .installing, reply: reply)
    }
    func handleUpdateFound(_ appcastItem: SUAppcastItem, isInstalling: Bool,
                           reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard userRequested else { reply(.dismiss); return }
        guard !appcastItem.isInformationOnlyUpdate, !appcastItem.isMajorUpgrade,
              let fileURL = appcastItem.fileURL, Self.isOfficialUpdateURL(fileURL) else {
            finish(.unavailable)
            reply(.dismiss)
            return
        }
        if isInstalling {
            installWhenIdle(reply: reply)
        } else {
            cancellation = nil
            reply(.install)
        }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        let isCurrent = reason?.intValue == 1 || reason?.intValue == 2
        if userRequested { finish(isCurrent ? .current : .unavailable, error: error) }
        acknowledgement()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        if userRequested { finish(.failed, error: error) }
        acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        guard userRequested else { cancellation(); return }
        self.cancellation = cancellation
        change { $0.beginDownload() }
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        change { $0.expectBytes(expectedContentLength) }
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        change { $0.receiveBytes(length) }
    }
    func showDownloadDidStartExtractingUpdate() {
        guard userRequested else { return }
        cancellation = nil
        change { $0.prepare() }
    }
    func showExtractionReceivedProgress(_ progress: Double) {
        change { $0.extractionProgress(progress) }
    }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        installWhenIdle(reply: reply)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                             retryTerminatingApplication: @escaping () -> Void) {
        if userRequested { change { $0.setStage(.installing) } }
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        finish(.current)
        acknowledgement()
    }
    func dismissUpdateInstallation() {
        guard intent != .information else { return }
        if stage.isBusy { finish(.cancelled) }
        else { intent = .none; cancellation = nil }
    }
}

struct UpdateDownloadControl: View {
    @ObservedObject private var updates = AppUpdateController.shared
    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.chinese.rawValue
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var cancelHovering = false

    private var availableVersion: String? {
        if case .available(let version) = updates.stage, !version.isEmpty {
            return version
        }
        return nil
    }

    private var progressFraction: Double? {
        switch updates.stage {
        case .downloading(let percent), .preparing(let percent):
            return percent.map { min(1.0, max(0.0, Double($0) / 100.0)) }
        default:
            return nil
        }
    }

    private var isFailed: Bool {
        updates.stage == .failed
    }

    private var tintColor: Color {
        isFailed ? MDTheme.warning : MDTheme.accent
    }

    private var status: String? {
        let _ = appLanguageRaw
        switch updates.stage {
        case .idle, .probing, .available, .current, .unavailable, .cancelled, .development: return nil
        case .checking: return L10n.t("update.connecting")
        case .downloading(let percent):
            return L10n.t("update.downloading") + (percent.map { " \($0)%" } ?? "")
        case .preparing(let percent):
            return L10n.t("update.preparing") + (percent.map { " \($0)%" } ?? "")
        case .waitingToInstall: return L10n.t("update.waiting")
        case .installing: return L10n.t("update.installing")
        case .failed: return L10n.t("update.failed")
        }
    }

    private var helpText: String {
        let _ = appLanguageRaw
        if let errorDetail = updates.errorDetail, !errorDetail.isEmpty {
            return errorDetail
        }
        if let version = availableVersion {
            return L10n.t("update.download_install_version_hint", version)
        }
        if let status {
            return status
        }
        return L10n.t("update.download_install_hint")
    }

    private var accessibilityLabelText: String {
        let _ = appLanguageRaw
        if let version = availableVersion {
            return L10n.t("update.download_install_version", version)
        }
        return L10n.t("update.download_install")
    }

    var body: some View {
        if updates.stage.showsControl {
            HStack(spacing: 6) {
                Button { updates.downloadAndInstall() } label: {
                    ZStack {
                        Circle()
                            .fill(tintColor.opacity(hovering && !updates.stage.isBusy ? 0.18 : 0.10))
                        if updates.stage.isBusy {
                            Circle()
                                .strokeBorder(MDTheme.accent.opacity(0.22), lineWidth: 2.2)
                            if let fraction = progressFraction {
                                Circle()
                                    .inset(by: 1.1)
                                    .trim(from: 0, to: max(0.05, fraction))
                                    .stroke(MDTheme.accent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: fraction)
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(MDTheme.accent)
                            } else {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.72)
                            }
                        } else {
                            Circle()
                                .strokeBorder(
                                    tintColor.opacity(contrast == .increased ? 1.0 : 0.78),
                                    lineWidth: contrast == .increased ? 2.0 : 1.25
                                )
                            Image(systemName: isFailed ? "arrow.clockwise" : "arrow.down.to.line")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(tintColor)
                        }
                    }
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(updates.stage.isBusy)
                .onHover { hovering = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
                .help(helpText)
                .accessibilityLabel(accessibilityLabelText)
                .accessibilityValue(status ?? "")
                .accessibilityIdentifier("app.downloadUpdate")

                if let status {
                    Text(status)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(isFailed ? MDTheme.warning : MDTheme.secondary)
                        .lineLimit(1)
                }

                if updates.stage.isCancellable {
                    Button { updates.cancel() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(MDTheme.secondary)
                            .frame(width: 24, height: 24)
                            .background(
                                Circle().fill(MDTheme.label.opacity(cancelHovering ? 0.10 : 0.05))
                            )
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .onHover { cancelHovering = $0 }
                    .help(L10n.t("update.cancel"))
                    .accessibilityLabel(L10n.t("update.cancel"))
                    .accessibilityIdentifier("app.cancelUpdate")
                }
            }
            .id(appLanguageRaw)
        }
    }
}
