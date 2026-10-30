#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd -- "$script_dir/.." && pwd)"
debug_dir="$app_dir/build/DerivedData/Build/Products/Debug"
[[ -f "$debug_dir/CleanupKit.o" && -d "$debug_dir/Sparkle.framework" ]] || {
  echo "Build the Debug app first; the callback probe uses its CleanupKit and Sparkle artifacts." >&2
  exit 1
}
update_controller_scratch="$(mktemp -d /private/tmp/MacDefier-update-controller.XXXXXX)"
trap 'rm -rf -- "$update_controller_scratch"' EXIT

# Compile the controller verbatim, omitting only the unrelated header View.
# Every controller instance below has an injected no-op launcher: no SPUUpdater
# is created, no feed is fetched and no installer/application is launched.
ruby -e 'source = File.read(ARGV.fetch(0)); marker = "\nstruct UpdateDownloadControl: View {"; abort "Controller/View boundary not found" unless source.include?(marker); File.write(ARGV.fetch(1), source.split(marker, 2).first)' \
  "$app_dir/MacDefier/AppUpdateController.swift" "$update_controller_scratch/AppUpdateController.swift"
ruby -e 'File.write(ARGV.fetch(0), STDIN.read)' "$update_controller_scratch/Probe.swift" <<'SWIFT'
import Foundation
import CleanupKit
import Sparkle

@main
@MainActor
enum AppUpdateControllerSmoke {
    enum Failure: Error { case assertion(String) }
    static var passed = 0

    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure.assertion(message) }
    }

    static func settle(_ milliseconds: Int = 30) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }

    static func waitUntil(_ message: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate() && ContinuousClock.now < deadline { try await settle(10) }
        try expect(predicate(), message)
    }

    static func controller() -> AppUpdateController {
        AppUpdateController(isProductionBuild: true, startUpdate: { _ in })
    }

    static func acquire(_ name: String) async throws -> UUID {
        let path = "/private/tmp/MacDefier-update-controller-logical-\(name)-\(UUID().uuidString)"
        guard let lease = await ResourceMutationCoordinator.shared.acquire(paths: [path]) else {
            throw Failure.assertion("Could not acquire isolated logical resource lease")
        }
        return lease
    }

    static func assertNoLeaseLeak(_ message: String) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if let lease = await ResourceMutationCoordinator.shared.acquire(paths: ["/"]) {
                await ResourceMutationCoordinator.shared.release(lease)
                return
            }
            try await settle(10)
        }
        throw Failure.assertion(message)
    }

    static func main() async throws {
        var launches = 0
        let launch = AppUpdateController(isProductionBuild: true, startUpdate: { _ in launches += 1 })
        launch.downloadAndInstall(); launch.downloadAndInstall()
        try expect(launch.stage == .checking && launches == 1, "reentry must not start another update")
        var checkingCancels = 0
        launch.showUserInitiatedUpdateCheck { checkingCancels += 1 }
        launch.cancel(); launch.cancel()
        try expect(launch.stage == .cancelled && checkingCancels == 1, "checking cancellation must run once")
        launch.downloadAndInstall()
        try expect(launch.stage == .checking && launches == 2, "terminal retry must start a fresh attempt")
        launch.cancel()
        let dev = AppUpdateController(isProductionBuild: false, startUpdate: { _ in launches += 100 })
        dev.downloadAndInstall()
        try expect(dev.stage == .development && launches == 2, "developer app must never launch production updater")
        passed += 1

        var clock = Date(timeIntervalSince1970: 10_000)
        var probes = 0
        var installs = 0
        let probe = AppUpdateController(isProductionBuild: true,
                                        startUpdate: { _ in installs += 1 },
                                        startInformationCheck: { _ in probes += 1 },
                                        now: { clock })
        let sdk = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: probe, delegate: probe)
        try expect(probe.responds(to: NSSelectorFromString("updater:didFindValidUpdate:")), "valid-update callback must implement the actual Sparkle selector")
        try expect(probe.responds(to: NSSelectorFromString("updater:didFinishUpdateCycleForUpdateCheck:error:")), "finish callback must implement the actual Sparkle selector")
        probe.checkForUpdateIfNeeded(); probe.checkForUpdateIfNeeded()
        try expect(probes == 1 && installs == 0 && probe.stage == .probing && !probe.stage.showsControl,
                   "launch/activation must coalesce and remain invisible without starting a download")
        try probe.updater(sdk, mayPerform: .updateInformation)
        do { try probe.updater(sdk, mayPerform: .updatesInBackground); throw Failure.assertion("scheduled downloads must be rejected") }
        catch is CancellationError {}
        let currentError = NSError(domain: SUSparkleErrorDomain, code: 1001,
                                   userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: 1)])
        probe.updater(sdk, didFinishUpdateCycleFor: .updateInformation, error: currentError)
        try expect(!probe.stage.showsControl && !probe.stage.isBusy, "already-current result must remove the entire control")
        probe.checkForUpdateIfNeeded()
        try expect(probes == 1, "rapid focus changes must not refetch the feed")
        clock.addTimeInterval(901)
        probe.checkForUpdateIfNeeded()
        try expect(probes == 2, "activation after cooldown should refresh metadata")
        guard let next = SUAppcastItem(dictionary: ["sparkle:version": "0.18", "enclosure": ["url": "https://example.invalid/MacDefier-0.18.zip", "sparkle:version": "0.18", "length": "100"]]) else {
            throw Failure.assertion("could not construct isolated Sparkle update fixture")
        }
        probe.updater(sdk, didFindValidUpdate: next)
        try expect(!probe.stage.showsControl, "finding an item must not expose a button before probe session ends")
        probe.updater(sdk, didFinishUpdateCycleFor: .updateInformation, error: nil)
        try expect(probe.stage == .available("0.18") && probe.stage.showsControl && installs == 0,
                   "only a successful valid newer item shows download without installing")
        probe.downloadAndInstall()
        try expect(installs == 1 && probe.stage == .checking, "explicit click is the only download trigger")
        probe.checkForUpdateIfNeeded()
        try expect(probes == 2, "activation must not interrupt a requested download")
        probe.cancel()
        clock.addTimeInterval(901)
        probe.checkForUpdateIfNeeded()
        probe.updater(sdk, didFindValidUpdate: next)
        probe.updater(sdk, didFinishUpdateCycleFor: .updateInformation, error: NSError(domain: "Probe", code: 1))
        try expect(!probe.stage.showsControl, "failed probe must not leave a stale update affordance or visible error")
        clock.addTimeInterval(61)
        probe.checkForUpdateIfNeeded()
        try expect(probes == 4, "failed metadata checks retry after a shorter cooldown")
        probe.updater(sdk, didFinishUpdateCycleFor: .updateInformation, error: nil)
        try expect(!probe.stage.showsControl, "successful check with no candidate stays hidden")
        let devProbe = AppUpdateController(isProductionBuild: false, startInformationCheck: { _ in probes += 100 })
        devProbe.checkForUpdateIfNeeded()
        try expect(probes == 4 && !devProbe.stage.showsControl, "developer builds must not offer production updates")
        passed += 1

        let download = controller()
        download.downloadAndInstall()
        var downloadCancels = 0
        download.showDownloadInitiated { downloadCancels += 1 }
        download.showDownloadDidReceiveExpectedContentLength(100)
        download.showDownloadDidReceiveData(ofLength: 25)
        try expect(download.stage == .downloading(25), "controller must expose actual download progress")
        download.cancel(); download.cancel()
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
        try expect(download.stage == .cancelled && downloadCancels == 1 && lateCancel == 1,
                   "late callbacks must neither revive cancelled transfer nor duplicate its cancel")
        try expect(lateReady == [.skip] && lateAck == 1, "late installer reply/error acknowledgement must drain")
        passed += 1

        for reason in [1, 2, 0, 3] {
            let update = controller()
            update.downloadAndInstall()
            var ack = 0
            let error = NSError(domain: SUSparkleErrorDomain, code: 1001,
                                userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: reason)])
            update.showUpdateNotFoundWithError(error) { ack += 1 }
            try expect(update.stage == ((reason == 1 || reason == 2) ? .current : .unavailable),
                       "no-update reason \(reason) must map correctly")
            update.dismissUpdateInstallation()
            try expect(ack == 1 && update.stage.isTerminal, "no-update teardown must preserve terminal status")
        }
        let missingReason = controller()
        missingReason.downloadAndInstall()
        missingReason.showUpdateNotFoundWithError(NSError(domain: "Probe", code: 1)) {}
        try expect(missingReason.stage == .unavailable, "missing no-update reason is not proof of current version")
        let errorUpdate = controller()
        errorUpdate.downloadAndInstall()
        var errorAck = 0
        errorUpdate.showUpdaterError(NSError(domain: "Probe", code: 1,
                                             userInfo: [NSLocalizedDescriptionKey: "Synthetic failure"])) { errorAck += 1 }
        errorUpdate.dismissUpdateInstallation()
        try expect(errorUpdate.stage == .failed && errorUpdate.errorDetail == "Synthetic failure" && errorAck == 1,
                   "error status/detail and acknowledgement must survive teardown")
        let launchError = AppUpdateController(isProductionBuild: true, startUpdate: { _ in
            throw NSError(domain: "Probe", code: 2)
        })
        launchError.downloadAndInstall()
        try expect(launchError.stage == .failed, "launcher failure must release busy state")
        passed += 1

        let cancelledBlocker = try await acquire("cancel")
        let waiting = controller()
        waiting.downloadAndInstall()
        var waitingReplies: [SPUUserUpdateChoice] = []
        waiting.showReady { waitingReplies.append($0) }
        try await settle(300)
        try expect(waiting.stage == .waitingToInstall && waitingReplies.isEmpty,
                   "ready must wait while cleanup/uninstall holds a resource lease")
        waiting.cancel(); waiting.cancel()
        try expect(waiting.stage == .cancelled && waitingReplies == [.skip], "waiting cancellation must skip once")
        await ResourceMutationCoordinator.shared.release(cancelledBlocker)
        try await settle(300)
        try expect(waitingReplies == [.skip], "releasing cleanup after cancellation must not install")
        try await assertNoLeaseLeak("cancelled wait leaked global mutation lease")
        passed += 1

        let completedBlocker = try await acquire("install")
        let ready = controller()
        ready.downloadAndInstall()
        ready.showDownloadDidStartExtractingUpdate()
        var readyReplies: [SPUUserUpdateChoice] = []
        ready.showReady { readyReplies.append($0) }
        try await settle(300)
        try expect(ready.stage == .waitingToInstall && readyReplies.isEmpty, "second update must honor mutation lease")
        await ResourceMutationCoordinator.shared.release(completedBlocker)
        try await waitUntil("releasing cleanup must install once") { readyReplies == [.install] }
        try expect(ready.stage == .installing, "successful handoff must show installing")
        let blockedMutation = await ResourceMutationCoordinator.shared.acquire(paths: ["/private/tmp/update-probe-new-mutation"])
        try expect(blockedMutation == nil, "installation must prevent new cleanup/uninstall mutations")
        ready.cancel()
        try expect(readyReplies == [.install] && ready.stage == .installing, "installation itself is not cancellable")
        ready.dismissUpdateInstallation()
        try await assertNoLeaseLeak("installer dismissal did not release mutation lease")
        try expect(readyReplies == [.install], "teardown must not send a second install response")
        passed += 1

        // Release and cancel race on the actual shared actor. Either cancellation
        // wins (one .skip) or acquisition wins (one .install); never both/leak.
        for attempt in 0..<8 {
            let blocker = try await acquire("race-\(attempt)")
            let racing = controller()
            racing.downloadAndInstall()
            var replies: [SPUUserUpdateChoice] = []
            racing.showReady { replies.append($0) }
            await Task.yield()
            await ResourceMutationCoordinator.shared.release(blocker)
            racing.cancel()
            try await waitUntil("cancel/release race did not resolve") { !replies.isEmpty }
            try await settle(30)
            try expect(replies == [.skip] || replies == [.install], "race must resolve exactly once")
            racing.dismissUpdateInstallation()
            try await assertNoLeaseLeak("cancel/release race leaked mutation lease")
        }
        passed += 1

        print("AppUpdateControllerSmoke: PASS (\(passed) groups; real controller, Sparkle callbacks and shared mutation leases; no network/install/relaunch)")
    }
}
SWIFT
helper_objects=()
for name in UninstallHelperCore UninstallHelperIPC UninstallHelperClient; do
  if [[ -f "$debug_dir/$name.o" ]]; then helper_objects+=("$debug_dir/$name.o"); fi
done
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$update_controller_scratch/module-cache" \
  -I "$debug_dir" -F "$debug_dir" -framework Sparkle \
  -Xlinker -rpath -Xlinker "$debug_dir" \
  "$app_dir/MacDefier/AppUpdateState.swift" "$update_controller_scratch/AppUpdateController.swift" \
  "$update_controller_scratch/Probe.swift" "$debug_dir/CleanupKit.o" "${helper_objects[@]}" \
  -o "$update_controller_scratch/probe"
"$update_controller_scratch/probe"
