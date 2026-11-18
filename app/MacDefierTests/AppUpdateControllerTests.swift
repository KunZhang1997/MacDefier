import CleanupKit
import Foundation
import Sparkle
import XCTest
@testable import MacDefier

@MainActor
final class AppUpdateControllerTests: XCTestCase {
    private func settle(_ milliseconds: Int = 30) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }

    private func waitUntil(_ message: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate() && ContinuousClock.now < deadline {
            try await settle(10)
        }
        XCTAssertTrue(predicate(), message)
    }

    private func makeController() -> AppUpdateController {
        AppUpdateController(isProductionBuild: true, startUpdate: { _ in })
    }

    private func acquireLease(_ name: String) async throws -> UUID {
        let path = "/private/tmp/MacDefier-update-controller-logical-\(name)-\(UUID().uuidString)"
        guard let lease = await ResourceMutationCoordinator.shared.acquire(paths: [path]) else {
            XCTFail("Could not acquire isolated logical resource lease")
            throw CancellationError()
        }
        return lease
    }

    private func assertNoLeaseLeak(_ message: String) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if let lease = await ResourceMutationCoordinator.shared.acquire(paths: ["/"]) {
                await ResourceMutationCoordinator.shared.release(lease)
                return
            }
            try await settle(10)
        }
        XCTFail(message)
    }

    func testLaunchReentryDevelopmentGuardAndSparkleProbing() throws {
        var launches = 0
        let launch = AppUpdateController(isProductionBuild: true, startUpdate: { _ in launches += 1 })
        launch.downloadAndInstall()
        launch.downloadAndInstall()
        XCTAssertEqual(launch.stage, .checking)
        XCTAssertEqual(launches, 1)

        var checkingCancels = 0
        launch.showUserInitiatedUpdateCheck { checkingCancels += 1 }
        launch.cancel()
        launch.cancel()
        XCTAssertEqual(launch.stage, .cancelled)
        XCTAssertEqual(checkingCancels, 1)

        launch.downloadAndInstall()
        XCTAssertEqual(launch.stage, .checking)
        XCTAssertEqual(launches, 2)
        launch.cancel()

        let dev = AppUpdateController(isProductionBuild: false, startUpdate: { _ in launches += 100 })
        dev.downloadAndInstall()
        XCTAssertEqual(dev.stage, .development)
        XCTAssertEqual(launches, 2)

        var clock = Date(timeIntervalSince1970: 10_000)
        var probes = 0
        var installs = 0
        let probe = AppUpdateController(
            isProductionBuild: true,
            startUpdate: { _ in installs += 1 },
            startInformationCheck: { _ in probes += 1 },
            now: { clock }
        )
        let sdk = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: probe, delegate: probe)
        XCTAssertTrue(probe.responds(to: NSSelectorFromString("feedURLStringForUpdater:")))
        XCTAssertEqual(probe.feedURLString(for: sdk), "https://kun97.tech/macdefier/releases/appcast.xml")
        XCTAssertEqual(AppUpdateController.officialWebsiteURL.absoluteString, "https://kun97.tech/macdefier/")
        XCTAssertTrue(probe.responds(to: NSSelectorFromString("updater:didFindValidUpdate:")))
        XCTAssertTrue(probe.responds(to: NSSelectorFromString("updater:didFinishUpdateCycleForUpdateCheck:error:")))

        probe.checkForUpdateIfNeeded()
        probe.checkForUpdateIfNeeded()
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(installs, 0)
        XCTAssertEqual(probe.stage, .probing)
        XCTAssertFalse(probe.stage.showsControl)

        XCTAssertNoThrow(try probe.updater(sdk, mayPerform: .updateInformation))
        XCTAssertThrowsError(try probe.updater(sdk, mayPerform: .updatesInBackground)) { error in
            XCTAssertTrue(error is CancellationError)
        }

        let currentError = NSError(
            domain: SUSparkleErrorDomain,
            code: 1001,
            userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: 1)]
        )
        probe.updater(sdk, didFinishUpdateCycleFor: .updateInformation, error: currentError)
        XCTAssertFalse(probe.stage.showsControl)
        XCTAssertFalse(probe.stage.isBusy)

        probe.checkForUpdateIfNeeded()
        XCTAssertEqual(probes, 1)
        clock.addTimeInterval(901)
        probe.checkForUpdateIfNeeded()
        XCTAssertEqual(probes, 2)

        let next = try XCTUnwrap(SUAppcastItem(dictionary: [
            "sparkle:version": "0.18",
            "enclosure": [
                "url": "https://kun97.tech/macdefier/releases/MacDefier-0.18.dmg",
                "sparkle:version": "0.18",
                "length": "100"
            ]
        ]))
        probe.updater(sdk, didFindValidUpdate: next)
        XCTAssertFalse(probe.stage.showsControl)
        probe.updater(sdk, didFinishUpdateCycleFor: .updateInformation, error: nil)
        XCTAssertEqual(probe.stage, .available("0.18"))
        XCTAssertTrue(probe.stage.showsControl)
        XCTAssertEqual(installs, 0)

        probe.downloadAndInstall()
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(probe.stage, .checking)
        probe.checkForUpdateIfNeeded()
        XCTAssertEqual(probes, 2)
        probe.cancel()

        clock.addTimeInterval(901)
        probe.checkForUpdateIfNeeded()
        probe.updater(sdk, didFindValidUpdate: next)
        probe.updater(sdk, didFinishUpdateCycleFor: .updateInformation, error: NSError(domain: "Probe", code: 1))
        XCTAssertFalse(probe.stage.showsControl)

        clock.addTimeInterval(61)
        probe.checkForUpdateIfNeeded()
        XCTAssertEqual(probes, 4)
        probe.updater(sdk, didFinishUpdateCycleFor: .updateInformation, error: nil)
        XCTAssertFalse(probe.stage.showsControl)

        let devProbe = AppUpdateController(isProductionBuild: false, startInformationCheck: { _ in probes += 100 })
        devProbe.checkForUpdateIfNeeded()
        XCTAssertEqual(probes, 4)
        XCTAssertFalse(devProbe.stage.showsControl)
    }

    func testOfficialWebsiteOriginEnforcementRejectsGitHubAndInsecureURLs() throws {
        XCTAssertTrue(AppUpdateController.isOfficialUpdateURL(
            URL(string: "https://kun97.tech/macdefier/releases/MacDefier-0.20.dmg")!
        ))
        XCTAssertTrue(AppUpdateController.isOfficialUpdateURL(
            URL(string: "https://kun97.tech/macdefier/releases/MacDefier-0.20.zip")!
        ))
        for rejected in [
            "https://github.com/KunZhang1997/MacDefier/releases/download/v0.20/MacDefier-0.20.dmg",
            "http://kun97.tech/macdefier/releases/MacDefier-0.20.dmg",
            "https://kun97.tech/dl/macdefier",
            "https://kun97.tech/speaksend/releases/MacDefier-0.20.dmg",
            "https://kun97.tech:8443/macdefier/releases/MacDefier-0.20.dmg",
            "https://user@kun97.tech/macdefier/releases/MacDefier-0.20.dmg",
            "https://kun97.tech/macdefier/releases/nested/MacDefier-0.20.dmg",
            "https://kun97.tech/macdefier/releases/appcast.xml"
        ] {
            XCTAssertFalse(
                AppUpdateController.isOfficialUpdateURL(URL(string: rejected)!),
                "Expected non-official update URL to be rejected: \(rejected)"
            )
        }

        let githubItem = try XCTUnwrap(SUAppcastItem(dictionary: [
            "sparkle:version": "0.20",
            "enclosure": [
                "url": "https://github.com/KunZhang1997/MacDefier/releases/download/v0.20/MacDefier-0.20.dmg",
                "sparkle:version": "0.20",
                "length": "100"
            ]
        ]))

        let probe = AppUpdateController(
            isProductionBuild: true,
            startUpdate: { _ in },
            startInformationCheck: { _ in }
        )
        let sdk = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: probe, delegate: probe)
        probe.checkForUpdateIfNeeded()
        probe.updater(sdk, didFindValidUpdate: githubItem)
        probe.updater(sdk, didFinishUpdateCycleFor: .updateInformation, error: nil)
        XCTAssertEqual(probe.stage, .idle)
        XCTAssertFalse(probe.stage.showsControl)

        let download = makeController()
        download.downloadAndInstall()
        var choices: [SPUUserUpdateChoice] = []
        download.handleUpdateFound(githubItem, isInstalling: false) { choices.append($0) }
        XCTAssertEqual(choices, [.dismiss])
        XCTAssertEqual(download.stage, .unavailable)

        let officialItem = try XCTUnwrap(SUAppcastItem(dictionary: [
            "sparkle:version": "0.20",
            "enclosure": [
                "url": "https://kun97.tech/macdefier/releases/MacDefier-0.20.dmg",
                "sparkle:version": "0.20",
                "length": "100"
            ]
        ]))
        let officialDownload = makeController()
        officialDownload.downloadAndInstall()
        var officialChoices: [SPUUserUpdateChoice] = []
        officialDownload.handleUpdateFound(officialItem, isInstalling: false) { officialChoices.append($0) }
        XCTAssertEqual(officialChoices, [.install])
    }

    func testDownloadCancellationAndErrorMapping() {
        let download = makeController()
        download.downloadAndInstall()
        var downloadCancels = 0
        download.showDownloadInitiated { downloadCancels += 1 }
        download.showDownloadDidReceiveExpectedContentLength(100)
        download.showDownloadDidReceiveData(ofLength: 25)
        XCTAssertEqual(download.stage, .downloading(25))
        download.cancel()
        download.cancel()
        download.showDownloadDidReceiveData(ofLength: 75)
        download.showDownloadDidReceiveExpectedContentLength(400)
        download.showDownloadDidStartExtractingUpdate()
        download.showExtractionReceivedProgress(1)
        var lateCancel = 0
        download.showDownloadInitiated { lateCancel += 1 }
        var lateReady: [SPUUserUpdateChoice] = []
        download.showReady { lateReady.append($0) }
        var lateAck = 0
        download.showUpdaterError(NSError(domain: "Probe", code: 1)) { lateAck += 1 }
        XCTAssertEqual(download.stage, .cancelled)
        XCTAssertEqual(downloadCancels, 1)
        XCTAssertEqual(lateCancel, 1)
        XCTAssertEqual(lateReady, [.skip])
        XCTAssertEqual(lateAck, 1)

        for reason in [1, 2, 0, 3] {
            let update = makeController()
            update.downloadAndInstall()
            var ack = 0
            let error = NSError(
                domain: SUSparkleErrorDomain,
                code: 1001,
                userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: reason)]
            )
            update.showUpdateNotFoundWithError(error) { ack += 1 }
            XCTAssertEqual(update.stage, (reason == 1 || reason == 2) ? .current : .unavailable)
            update.dismissUpdateInstallation()
            XCTAssertEqual(ack, 1)
            XCTAssertTrue(update.stage.isTerminal)
        }

        let missingReason = makeController()
        missingReason.downloadAndInstall()
        missingReason.showUpdateNotFoundWithError(NSError(domain: "Probe", code: 1)) {}
        XCTAssertEqual(missingReason.stage, .unavailable)

        let errorUpdate = makeController()
        errorUpdate.downloadAndInstall()
        var errorAck = 0
        errorUpdate.showUpdaterError(
            NSError(domain: "Probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Synthetic failure"])
        ) { errorAck += 1 }
        errorUpdate.dismissUpdateInstallation()
        XCTAssertEqual(errorUpdate.stage, .failed)
        XCTAssertEqual(errorUpdate.errorDetail, "Synthetic failure")
        XCTAssertEqual(errorAck, 1)

        let launchError = AppUpdateController(isProductionBuild: true, startUpdate: { _ in
            throw NSError(domain: "Probe", code: 2)
        })
        launchError.downloadAndInstall()
        XCTAssertEqual(launchError.stage, .failed)
    }

    func testMutationLeaseCoordinationAndCancelReleaseRace() async throws {
        let cancelledBlocker = try await acquireLease("cancel")
        let waiting = makeController()
        waiting.downloadAndInstall()
        var waitingReplies: [SPUUserUpdateChoice] = []
        waiting.showReady { waitingReplies.append($0) }
        try await settle(300)
        XCTAssertEqual(waiting.stage, .waitingToInstall)
        XCTAssertTrue(waitingReplies.isEmpty)
        waiting.cancel()
        waiting.cancel()
        XCTAssertEqual(waiting.stage, .cancelled)
        XCTAssertEqual(waitingReplies, [.skip])
        await ResourceMutationCoordinator.shared.release(cancelledBlocker)
        try await settle(300)
        XCTAssertEqual(waitingReplies, [.skip])
        try await assertNoLeaseLeak("cancelled wait leaked global mutation lease")

        let completedBlocker = try await acquireLease("install")
        let ready = makeController()
        ready.downloadAndInstall()
        ready.showDownloadDidStartExtractingUpdate()
        var readyReplies: [SPUUserUpdateChoice] = []
        ready.showReady { readyReplies.append($0) }
        try await settle(300)
        XCTAssertEqual(ready.stage, .waitingToInstall)
        XCTAssertTrue(readyReplies.isEmpty)
        await ResourceMutationCoordinator.shared.release(completedBlocker)
        try await waitUntil("releasing cleanup must install once") { readyReplies == [.install] }
        XCTAssertEqual(ready.stage, .installing)
        let blockedMutation = await ResourceMutationCoordinator.shared.acquire(paths: ["/private/tmp/update-probe-new-mutation"])
        XCTAssertNil(blockedMutation)
        ready.cancel()
        XCTAssertEqual(readyReplies, [.install])
        XCTAssertEqual(ready.stage, .installing)
        ready.dismissUpdateInstallation()
        try await assertNoLeaseLeak("installer dismissal did not release mutation lease")
        XCTAssertEqual(readyReplies, [.install])

        for attempt in 0..<8 {
            let blocker = try await acquireLease("race-\(attempt)")
            let racing = makeController()
            racing.downloadAndInstall()
            var replies: [SPUUserUpdateChoice] = []
            racing.showReady { replies.append($0) }
            await Task.yield()
            await ResourceMutationCoordinator.shared.release(blocker)
            racing.cancel()
            try await waitUntil("cancel/release race did not resolve") { !replies.isEmpty }
            try await settle(30)
            XCTAssertTrue(replies == [.skip] || replies == [.install], "race must resolve exactly once")
            racing.dismissUpdateInstallation()
            try await assertNoLeaseLeak("cancel/release race leaked mutation lease")
        }
    }
}
