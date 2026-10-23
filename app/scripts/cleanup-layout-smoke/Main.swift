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
        mark("created groups=\(groupCount) items_each=\(count); in_memory_fixture_only=true")
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ passed: Bool) {
            checks[name] = passed
            mark("CHECK \(name)=\(passed)")
        }
        func screenshot(_ name: String) {
            guard let view = window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                let url = URL(fileURLWithPath: CommandLine.arguments[0] + "-\(name).png")
                do { try data.write(to: url); mark("SCREENSHOT \(url.path)") }
                catch { mark("SCREENSHOT failed \(error)") }
            }
        }
        func click(_ key: String) -> Bool {
            guard let content = window.contentView, let rect = ProbeMarkers.rect(key, in: content),
                  rect.width > 0, rect.height > 0, content.bounds.intersects(rect) else {
                mark("CLICK missing/offscreen marker=\(key)"); return false
            }
            let point = NSPoint(x: rect.midX, y: rect.midY)
            let location = content.convert(point, to: nil)
            let now = ProcessInfo.processInfo.systemUptime
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: now,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: now + 0.01,
                windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else { return false }
            // Queue release first so native button tracking cannot wait for input.
            app.postEvent(up, atStart: true)
            window.sendEvent(down)
            mark("CLICK marker=\(key) x=\(point.x) y=\(point.y)")
            return true
        }
        let first = fixture.groups[0]
        let firstItem = first.items[1]
        let groupKey = "checkbox:选择分类：" + first.category.localizedTitle
        let itemKey = "checkbox:" + firstItem.localizedDisplayTitle
        let disclosureKey = "disclosure:" + first.category.rawValue
        func geometry(_ size: String) {
            guard let content = window.contentView,
                  let group = ProbeMarkers.rect(groupKey, in: content),
                  let item = ProbeMarkers.rect(itemKey, in: content),
                  let disclosure = ProbeMarkers.rect(disclosureKey, in: content) else {
                check("geometry_\(size)", false); return
            }
            let aligned = abs(group.minX - item.minX) <= 0.5
            let separate = group.maxX <= disclosure.minX
            mark("GEOMETRY \(size) container=\(content.bounds.size) group_checkbox=\(group) item_checkbox=\(item) disclosure=\(disclosure) delta_x=\(abs(group.minX - item.minX))")
            check("checkbox_leading_aligned_\(size)", aligned)
            check("disclosure_separate_\(size)", separate)
        }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            screenshot("collapsed-800")
            check("group_click_dispatched", click(groupKey))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            check("group_checkbox_selects", fixture.selectedCount == count - 1)
            check("group_checkbox_opens", fixture.expandedCategories.contains(first.category))
            check("protected_item_unselected", !fixture.isItemSelected(id: first.items[0].id))
            geometry("800")
            screenshot("expanded-800")
            check("disclosure_close_dispatched", click(disclosureKey))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            check("disclosure_closes_without_selection_change", !fixture.expandedCategories.contains(first.category) && fixture.selectedCount == count - 1)
            check("disclosure_open_dispatched", click(disclosureKey))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) {
            check("disclosure_reopens_without_selection_change", fixture.expandedCategories.contains(first.category) && fixture.selectedCount == count - 1)
            check("item_click_dispatched", click(itemKey))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            check("item_checkbox_independent", !fixture.isItemSelected(id: firstItem.id) && fixture.selectedCount == count - 2 && fixture.expandedCategories.contains(first.category))
            check("paths_click_dispatched", click("paths:" + firstItem.id))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.55) {
            check("paths_expand_without_selection_change", fixture.expandedPaths.contains(firstItem.id) && fixture.selectedCount == count - 2)
            screenshot("paths-800")
            mark("resize begin")
            window.setContentSize(NSSize(width: 650, height: 500))
            DispatchQueue.main.async { mark("resize main queue advanced") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.95) {
            screenshot("expanded-650")
            geometry("650")
            check("protected_checkbox_click_dispatched", click("checkbox:" + first.items[0].localizedDisplayTitle))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            check("protected_checkbox_stays_unselected", !fixture.isItemSelected(id: first.items[0].id))
            fixture.expandAll = true
            mark("expand all begin")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.7) {
            mark("selection all begin")
            fixture.selectAll()
            DispatchQueue.main.async { mark("selection main queue advanced") }
        }
        let lastCategory = fixture.groups.last!.category
        func itemTarget(_ category: CleanupCategory, _ row: Int) -> String { "item:\(category.rawValue):\(category.rawValue)-\(row)" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            mark("scroll to last group row 39")
            fixture.scrollTarget = itemTarget(lastCategory, 39)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) {
            mark("page 80")
            fixture.pageLimit = 80
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.7) { fixture.scrollTarget = itemTarget(lastCategory, 79) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) {
            mark("page 200")
            fixture.pageLimit = 200
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.7) { fixture.scrollTarget = itemTarget(lastCategory, 199) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.3) {
            screenshot("long-list-last-650")
            check("reachable_last", fixture.appeared.contains("\(lastCategory.rawValue)-199"))
            fixture.openPaths = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
            mark("collapse first category above viewport")
            fixture.collapseFirst = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.5) {
            mark("return to second category")
            fixture.scrollTarget = itemTarget(fixture.groups[1].category, 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 11) {
            screenshot("returned-650")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 11.4) {
            let last = "\(lastCategory.rawValue)-199"
            let returnedItem = fixture.groups[1].items[1]
            let returned = returnedItem.id
            check("returned_after_collapse", fixture.appeared.contains(returned))
            if let content = window.contentView, let rect = ProbeMarkers.rect("checkbox:" + returnedItem.localizedDisplayTitle, in: content) {
                check("returned_checkbox_visible", content.bounds.intersects(rect))
            } else { check("returned_checkbox_visible", false) }
            check("selection_persists", fixture.isItemSelected(id: returned) && fixture.isItemSelected(id: last))
            check("paths_open_persists", fixture.expandedPaths.contains(last))
            check("heartbeat_under_2_seconds", largestGap < 2.0)
            mark("PERFORMANCE rows_appeared=\(fixture.appeared.count) max_heartbeat_gap=\(largestGap)")
            let failures = checks.filter { !$0.value }.map(\.key).sorted()
            mark("COMPLETE checks=\(checks.count) failed=\(failures)")
            heartbeat.cancel()
            window.orderOut(nil)
            _exit(failures.isEmpty ? 0 : 1)
        }
        app.run()
    }
}
