import SwiftUI
import AppKit
import Darwin

@main struct ProbeMain {
    @MainActor static func main() {
        setbuf(stdout, nil)
        let groupCount = 15
        let count = 200
        let start = ProcessInfo.processInfo.systemUptime
        func mark(_ text: String) {
            print(String(format: "%.3f %@", ProcessInfo.processInfo.systemUptime - start, text))
        }
        // Independent watchdog: never leave a wedged diagnostic UI running.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
            print("WATCHDOG timeout: layout probe stopped")
            _exit(124)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let fixture = FixtureStore(count: count, groupCount: groupCount)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.hasShadow = false
        window.contentView = NSHostingView(rootView: CleanupLayoutProbe(cleanup: fixture))
        window.orderBack(nil)
        mark("created groups=\(groupCount) items_each=\(count)")
        var lastHeartbeat = ProcessInfo.processInfo.systemUptime
        var largestGap: TimeInterval = 0
        let heartbeat = DispatchSource.makeTimerSource(queue: .main)
        heartbeat.schedule(deadline: .now(), repeating: .milliseconds(100))
        heartbeat.setEventHandler {
            let now = ProcessInfo.processInfo.systemUptime
            largestGap = max(largestGap, now - lastHeartbeat)
            lastHeartbeat = now
        }
        heartbeat.resume()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            mark("expand begin")
            fixture.expandAll = true
            DispatchQueue.main.async { mark("expand main queue advanced") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            mark("selection begin")
            fixture.selectAll()
            DispatchQueue.main.async { mark("selection main queue advanced") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            mark("scroll to last group row 39")
            fixture.scrollTarget = "\(fixture.groups.last!.category.rawValue)-39"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            mark("page 80")
            fixture.pageLimit = 80
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
            fixture.scrollTarget = "\(fixture.groups.last!.category.rawValue)-79"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            mark("page 200")
            fixture.pageLimit = 200
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
            fixture.scrollTarget = "\(fixture.groups.last!.category.rawValue)-199"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            mark("resize begin")
            window.setContentSize(NSSize(width: 650, height: 500))
            DispatchQueue.main.async { mark("resize main queue advanced") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) {
            fixture.openPaths = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
            mark("collapse first category above viewport")
            fixture.collapseFirst = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.5) {
            fixture.scrollTarget = "\(fixture.groups[1].category.rawValue)-0"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.5) {
            let last = "\(fixture.groups.last!.category.rawValue)-199"
            let returned = "\(fixture.groups[1].category.rawValue)-0"
            let passed = fixture.appeared.contains(last) && fixture.appeared.contains(returned)
                && fixture.isItemSelected(id: returned) && fixture.isItemSelected(id: last)
                && largestGap < 2.0
            mark("CHECK reachable_last=\(fixture.appeared.contains(last)) returned=\(fixture.appeared.contains(returned)) selected=\(fixture.isItemSelected(id: returned)) rows_appeared=\(fixture.appeared.count) max_heartbeat_gap=\(largestGap)")
            if let view = window.contentView,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[0] + ".png"))
                }
            }
            mark("COMPLETE")
            heartbeat.cancel()
            window.orderOut(nil)
            _exit(passed ? 0 : 1)
        }
        app.run()
    }
}
