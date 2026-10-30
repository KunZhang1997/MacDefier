#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd -- "$script_dir/.." && pwd)"
update_state_scratch="$(mktemp -d /private/tmp/MacDefier-update-state.XXXXXX)"
trap 'rm -rf -- "$update_state_scratch"' EXIT
ruby -e 'File.write(ARGV.fetch(0), STDIN.read)' "$update_state_scratch/Probe.swift" <<'SWIFT'
import Foundation

@main
enum AppUpdateStateSmoke {
    enum Failure: Error { case assertion(String) }
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure.assertion(message) }
    }

    static func main() throws {
        var state = AppUpdateState()
        try expect(state.stage == .idle && !state.stage.isBusy && !state.stage.isTerminal, "initial state")
        for hidden in [AppUpdateStage.idle, .probing, .current, .unavailable, .cancelled, .development] {
            try expect(!hidden.showsControl, "unknown, silent, current and unsupported states stay hidden")
        }
        for visible in [AppUpdateStage.available("0.18"), .checking, .downloading(nil), .preparing(nil), .waitingToInstall, .installing, .failed] {
            try expect(visible.showsControl, "available updates and explicit user action show controls")
        }
        state.setStage(.probing)
        try expect(state.stage.isBusy && !state.stage.isCancellable && !state.stage.showsControl, "silent probing stays hidden and blocks duplicate checks")
        state.setStage(.available("0.18"))
        try expect(!state.stage.isBusy && state.stage.showsControl, "available update offers download")
        state.begin()
        try expect(state.stage == .checking && state.stage.isBusy && state.stage.isCancellable, "checking state")

        state.beginDownload()
        try expect(state.stage == .downloading(nil), "download starts with unknown progress")
        state.expectBytes(1_000)
        state.receiveBytes(0)
        try expect(state.stage == .downloading(nil), "expected length alone must not invent 0%")
        state.receiveBytes(1)
        try expect(state.stage == .downloading(0), "0% becomes valid after actual bytes arrive")
        let before = state.stage
        state.receiveBytes(1)
        try expect(state.stage == before, "sub-percent chunks keep the same observable stage")

        state.beginDownload()
        state.receiveBytes(25)
        try expect(state.stage == .downloading(nil), "received bytes without length remain unknown")
        state.expectBytes(100)
        try expect(state.stage == .downloading(25), "late expected length uses already received bytes")
        state.expectBytes(200)
        try expect(state.stage == .downloading(12), "corrected length recomputes progress")
        state.expectBytes(0)
        try expect(state.stage == .downloading(nil), "zero length means unknown")
        state.expectBytes(50)
        try expect(state.stage == .downloading(50), "length correction preserves bytes")

        state.beginDownload()
        state.expectBytes(UInt64.max)
        state.receiveBytes(UInt64.max - 1)
        try expect(state.stage == .downloading(99), "large values must not round to premature 100%")
        state.receiveBytes(100)
        try expect(state.stage == .downloading(100), "received-byte overflow must saturate")
        state.beginDownload()
        state.expectBytes(50)
        state.receiveBytes(100)
        try expect(state.stage == .downloading(100), "bytes beyond expected clamp to 100%")
        state.beginDownload()
        state.receiveBytes(1)
        try expect(state.stage == .downloading(nil), "new download clears old expected length")
        state.expectBytes(10)
        try expect(state.stage == .downloading(10), "new download clears old received bytes")

        state.prepare()
        try expect(state.stage == .preparing(nil) && state.stage.isBusy && !state.stage.isCancellable, "preparing state")
        state.extractionProgress(0.256)
        try expect(state.stage == .preparing(25), "fractional extraction percentage")
        state.extractionProgress(-Double.greatestFiniteMagnitude)
        try expect(state.stage == .preparing(0), "negative extraction clamps before conversion")
        state.extractionProgress(Double.greatestFiniteMagnitude)
        try expect(state.stage == .preparing(100), "large extraction clamps before multiplication")
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            state.extractionProgress(invalid)
            try expect(state.stage == .preparing(nil), "non-finite extraction stays unknown")
        }

        state.setStage(.waitingToInstall)
        try expect(state.stage.isBusy && state.stage.isCancellable && !state.stage.isTerminal, "waiting installation is cancellable")
        state.setStage(.installing)
        try expect(state.stage.isBusy && !state.stage.isCancellable && !state.stage.isTerminal, "installation cannot be cancelled")
        for terminal in [AppUpdateStage.current, .unavailable, .failed, .cancelled, .development] {
            state.setStage(terminal)
            try expect(state.stage.isTerminal && !state.stage.isBusy && !state.stage.isCancellable, "terminal classification")
        }

        state.setStage(.cancelled)
        state.expectBytes(10)
        state.receiveBytes(UInt64.max)
        state.extractionProgress(0.5)
        try expect(state.stage == .cancelled, "late progress must not revive a cancelled transfer")
        state.begin()
        state.receiveBytes(10)
        try expect(state.stage == .checking, "download progress cannot replace checking")
        state.beginDownload()
        state.expectBytes(100)
        try expect(state.stage == .downloading(nil), "new attempt begins with no received bytes")

        state.setStage(.downloading(Int.max))
        try expect(state.stage == .downloading(100), "explicit download state clamps high values")
        state.setStage(.preparing(Int.min))
        try expect(state.stage == .preparing(0), "explicit preparing state clamps low values")
        print("AppUpdateStateSmoke: PASS (unknown/zero/corrected progress, UInt64 saturation, extraction bounds, phase guards, retry reset and stage capabilities)")
    }
}
SWIFT
swiftc -parse-as-library -module-cache-path "$update_state_scratch/module-cache" \
  "$app_dir/MacDefier/AppUpdateState.swift" "$update_state_scratch/Probe.swift" -o "$update_state_scratch/probe"
"$update_state_scratch/probe"
