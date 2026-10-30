import AppKit
import CleanupKit
import Combine
import Sparkle
import SwiftUI

/// Sparkle owns signed downloads and replacement; its UI stays in our header.
@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUserDriver, SPUUpdaterDelegate {
    static let shared = AppUpdateController()
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

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        switch (intent, updateCheck) {
        case (.information, .updateInformation), (.download, .updates): return
        default: throw CancellationError()
        }
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard intent == .information else { return }
        guard !item.isInformationOnlyUpdate, !item.isMajorUpgrade,
              item.fileURL != nil, !item.versionString.isEmpty else {
            probedVersion = nil
            return
        }
        probedVersion = item.versionString
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
        guard userRequested else { reply(.dismiss); return }
        guard !appcastItem.isInformationOnlyUpdate, !appcastItem.isMajorUpgrade else {
            finish(.unavailable)
            reply(.dismiss)
            return
        }
        if state.stage == .installing {
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
    private var status: String? {
        switch updates.stage {
        case .idle, .probing, .available, .current, .unavailable, .cancelled, .development: return nil
        case .checking: return L10n.t("update.connecting")
        case .downloading(let percent):
            return L10n.t("update.downloading") + (percent.map { " \($0)%" } ?? "")
        case .preparing: return L10n.t("update.preparing")
        case .waitingToInstall: return L10n.t("update.waiting")
        case .installing: return L10n.t("update.installing")
        case .failed: return L10n.t("update.failed")
        }
    }
    var body: some View {
        if updates.stage.showsControl {
          HStack(spacing: 6) {
            if let status {
                Text(status).font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(MDTheme.secondary).lineLimit(1)
            }
            Button { updates.downloadAndInstall() } label: {
                ZStack {
                    if updates.stage.isBusy {
                        ProgressView().controlSize(.small).scaleEffect(0.75)
                    } else {
                        Image(systemName: "arrow.down.circle").font(.system(size: 16, weight: .medium))
                    }
                }.frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(updates.stage.isBusy)
            .help(updates.errorDetail ?? L10n.t("update.download_install_hint"))
            .accessibilityLabel(L10n.t("update.download_install"))
            .accessibilityValue(status ?? "")
            .accessibilityIdentifier("app.downloadUpdate")
            if updates.stage.isCancellable {
                Button { updates.cancel() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(L10n.t("update.cancel"))
                .accessibilityLabel(L10n.t("update.cancel"))
                .accessibilityIdentifier("app.cancelUpdate")
            }
          }
        }
    }
}
