import AppKit
import SwiftUI

private enum L10n {
    static func t(_ key: String) -> String { key == "scan.stop" ? "停止扫描" : key }
}

@main struct ScanCardLayoutProbe {
    @MainActor static func main() {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.prohibited)
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { _exit(124) }
        var waiting = ScanJourney()
        waiting.begin(["first", "second"])
        var reading = waiting
        reading.start("first")
        var results = reading
        results.complete("first", count: 120)
        results.start("second")
        var stopped = waiting
        stopped.stop()
        var resumed = stopped
        resumed.begin(["first", "second"], resuming: true)
        var complete = results
        complete.complete("second", count: 3)
        complete.finish()
        var partial = reading
        partial.finish(partial: true)
        // Page-owned `compact` means results are present below this card.
        // An empty, inactive restart entry must remain large, regardless of history.
        let cases = [("idle", ScanJourney(), false, false), ("waiting", waiting, false, true),
                     ("reading-empty", reading, false, true), ("first-results", results, true, true),
                     ("stopped-empty", stopped, false, true), ("resumed", resumed, false, true),
                     ("rescan-empty", complete, false, false), ("rescan-with-results", complete, true, true),
                     ("discarded-empty", ScanJourney(), false, false), ("partial-empty", partial, false, false)]
        var checks = 0
        var failures = 0
        for width in [CGFloat(320), 592, 695] {
            for kind in [MDScanArtworkKind.cleanup, .aiTools, .disk, .software] {
                for (name, journey, compact, shouldBeCompact) in cases {
                    let clock = MDScanAnimationClock()
                    let card = MDScanActivityCard(kind: kind, journey: journey, clock: clock,
                        title: "应用缓存 · com.tencent.workbuddy.mac / a-long-file-name-that-must-wrap",
                        detail: "扫描结果已保留", compact: compact,
                        action: journey.status == .idle || journey.status == .stopped ? {} : nil,
                        stop: journey.status == .running ? {} : nil, identifier: "probe.scan")
                        .frame(width: width).fixedSize(horizontal: false, vertical: true)
                    let host = NSHostingView(rootView: card)
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.alphaValue = 0
                    window.contentView = host
                    window.orderBack(nil)
                    host.layoutSubtreeIfNeeded()
                    let height = host.fittingSize.height
                    let passed = shouldBeCompact ? abs(height - 94) < 0.5 : height >= 220
                    checks += 1
                    if !passed { failures += 1 }
                    print("\(passed ? "PASS" : "FAIL") kind=\(kind) state=\(name) width=\(width) height=\(height)")
                    window.close()
                }
            }
        }
        print("checks=\(checks) failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
