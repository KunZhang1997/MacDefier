import AppKit
import SwiftUI
import Darwin
import ApplicationServices

// This executable links only the actual shared checkbox and an in-memory model.
// It has no scanner, uninstall executor, package manager, AI or user data store.
@MainActor final class SelectionFixture: ObservableObject {
    @Published var original = false
    @Published var compact = false
    @Published var labeled = false
    @Published var disabled = false
    @Published var besideFinder = false
    @Published var changes = 0
    @Published var finderActions = 0
    func binding(_ key: ReferenceWritableKeyPath<SelectionFixture, Bool>) -> Binding<Bool> {
        Binding(get: { self[keyPath: key] }, set: { self[keyPath: key] = $0; self.changes += 1 })
    }
}

private final class MarkerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct HitMarker: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView {
        let view = MarkerView()
        view.identifier = NSUserInterfaceItemIdentifier(name)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { }
}

private struct FixtureView: View {
    @ObservedObject var state: SelectionFixture
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Selection QA — fake data only").font(.headline)
            HStack {
                Toggle("Original hidden label", isOn: $state.original)
                    .toggleStyle(.checkbox).labelsHidden()
                    .background(HitMarker(name: "original"))
                Text("Original small checkbox")
            }
            HStack {
                MDCheckbox("Compact selection", isOn: state.binding(\.compact))
                    .background(HitMarker(name: "compact"))
                Text("28 pt pointer target")
            }
            MDCheckbox("Named selection", isOn: state.binding(\.labeled)) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Click the name or the blank area")
                    Text("/FAKE/Cache/sample").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            .background(HitMarker(name: "labeled"))
            MDCheckbox("Protected selection", isOn: state.binding(\.disabled)) {
                Text("Protected item stays disabled").frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(true)
            .background(HitMarker(name: "disabled"))
            HStack(spacing: 10) {
                MDCheckbox("Selection beside Finder", isOn: state.binding(\.besideFinder)) {
                    Text("Independent Finder action").frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(HitMarker(name: "besideFinder"))
                Button("Finder") { state.finderActions += 1 }
                    .background(HitMarker(name: "finder"))
            }
            Text(verbatim: "Selected: \(state.compact), \(state.labeled) · changes \(state.changes)")
                .font(.caption.monospaced())
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// Keep AX verification independent from pointer markers and posted mouse events.
// The native Toggle is a positive control for an available accessibility tree.
private struct AccessibilityFixtureView: View {
    @ObservedObject var state: SelectionFixture
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Native AX baseline", isOn: $state.original).toggleStyle(.checkbox)
            MDCheckbox("Compact selection", isOn: state.binding(\.compact))
            MDCheckbox("Named selection", isOn: state.binding(\.labeled)) {
                Text("Named selection label").frame(maxWidth: .infinity, alignment: .leading)
            }
            MDCheckbox("Protected selection", isOn: state.binding(\.disabled)) {
                Text("Disabled selection").frame(maxWidth: .infinity, alignment: .leading)
            }.disabled(true)
        }.padding(20).frame(width: 420, height: 220)
    }
}

@MainActor private enum AccessibilityFixtureRunner {
    // SwiftUI's synthetic nodes do not conform to the full NSAccessibilityProtocol.
    // These selectors are public NSAccessibility getters, not private SwiftUI APIs.
    static func attribute(_ object: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    static func nodes(_ object: NSObject, depth: Int = 0) -> [NSObject] {
        guard depth < 30 else { return [] }
        let children = attribute(object, "accessibilityChildren") as? [NSObject] ?? []
        return [object] + children.flatMap { nodes($0, depth: depth + 1) }
    }

    static func boolMethod(_ object: NSObject, _ name: String) -> Bool? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let implementation = object.method(for: selector) else { return nil }
        // NSObject.perform returns an object and must not be used for BOOL methods.
        typealias Method = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(implementation, to: Method.self)(object, selector)
    }

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let state = SelectionFixture()
        state.labeled = true
        let host = NSHostingView(rootView: AccessibilityFixtureView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 420, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "MacDefier AX QA — fake data"
        window.contentView = host
        window.orderBack(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            host.layoutSubtreeIfNeeded()
            // Preserve the generic NSHostingView getter. Legacy AXChildren can
            // return an empty array even when this typed getter returns nodes.
            let all = (host.accessibilityChildren() as? [NSObject] ?? []).flatMap { nodes($0) }
            print("AX fixture trusted=\(AXIsProcessTrusted()) nodes=\(all.count)")
            for node in all {
                print("AX role=\(attribute(node, "accessibilityRole") ?? "nil") label=\(attribute(node, "accessibilityLabel") ?? "nil") value=\(attribute(node, "accessibilityValue") ?? "nil")")
            }
            @MainActor func named(_ title: String) -> NSObject? {
                all.first { attribute($0, "accessibilityLabel") as? String == title }
            }
            guard let baseline = named("Native AX baseline") else {
                print("UNVERIFIED AX environment: native Toggle positive control is unavailable")
                print("RESULT AX unavailable (exit 77), not a product failure or a pass")
                window.orderOut(nil)
                _exit(77)
            }
            var failures = 0
            func check(_ condition: Bool, _ name: String) {
                print("\(condition ? "PASS" : "FAIL") \(name)")
                if !condition { failures += 1 }
            }
            @MainActor func value(_ node: NSObject?) -> Bool? {
                node.flatMap { attribute($0, "accessibilityValue") as? NSNumber }?.boolValue
            }
            let namedSelection = named("Named selection")
            let compact = named("Compact selection")
            let disabled = named("Protected selection")
            let checkboxes = all.filter { attribute($0, "accessibilityRole") as? String == "AXCheckBox" }
            check(attribute(baseline, "accessibilityRole") as? String == "AXCheckBox" && value(baseline) == false,
                  "AX native Toggle positive control")
            let titles = ["Native AX baseline", "Compact selection", "Named selection", "Protected selection"]
            check(checkboxes.count == titles.count && titles.allSatisfy { title in
                checkboxes.filter { attribute($0, "accessibilityLabel") as? String == title }.count == 1
            }, "AX checkbox roles and unique labels are preserved")
            check(value(namedSelection) == true, "AX named checkbox exposes its selected state")
            check(value(compact) == false, "AX compact checkbox exposes its name and value")
            check(namedSelection.flatMap { boolMethod($0, "isAccessibilityEnabled") } == true
                  && disabled.flatMap { boolMethod($0, "isAccessibilityEnabled") } == false,
                  "AX enabled and disabled states are preserved")
            check(namedSelection.flatMap { boolMethod($0, "accessibilityPerformPress") } == true
                  && !state.labeled && state.changes == 1,
                  "AX press changes the bound value exactly once")
            check(value(namedSelection) == false, "AX selected value updates after press")
            check(disabled.flatMap { boolMethod($0, "accessibilityPerformPress") } == false
                  && !state.disabled && state.changes == 1,
                  "AX press cannot change a disabled checkbox")
            print("RESULT AX failures=\(failures)")
            window.orderOut(nil)
            _exit(failures == 0 ? 0 : 1)
        }
        app.run()
    }
}

@main struct SelectionSmokeMain {
    @MainActor static func main() {
        setbuf(stdout, nil)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
            print("FAIL watchdog stopped selection fixture")
            _exit(124)
        }
        if CommandLine.arguments.contains("--accessibility-only") {
            AccessibilityFixtureRunner.run()
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        print("AX trusted=\(AXIsProcessTrusted())")
        let state = SelectionFixture()
        let host = NSHostingView(rootView: FixtureView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "MacDefier selection QA — fake data"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        app.activate()
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures += 1 }
        }
        func marker(_ name: String) -> NSView? {
            func walk(_ view: NSView) -> NSView? {
                if view.identifier?.rawValue == name { return view }
                for child in view.subviews { if let hit = walk(child) { return hit } }
                return nil
            }
            return walk(host)
        }
        func click(_ name: String, x: CGFloat? = nil, y: CGFloat? = nil) {
            host.layoutSubtreeIfNeeded()
            guard let view = marker(name) else { check(false, "marker \(name)"); return }
            let local = NSPoint(x: x ?? view.bounds.midX, y: y ?? view.bounds.midY)
            let point = view.convert(local, to: nil)
            let stamp = ProcessInfo.processInfo.systemUptime
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: stamp, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                timestamp: stamp + 0.01, windowNumber: window.windowNumber, context: nil,
                eventNumber: 2, clickCount: 1, pressure: 0)!
            app.postEvent(down, atStart: false)
            app.postEvent(up, atStart: false)
            let deadline = Date().addingTimeInterval(0.05)
            while let event = app.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
                app.sendEvent(event)
                if Date() >= deadline { break }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        func screenshot(_ name: String) {
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
            let folder = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            try? data.write(to: folder.appendingPathComponent(name + ".png"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            host.layoutSubtreeIfNeeded()
            for name in ["original", "compact", "labeled"] {
                if let view = marker(name) { print("FRAME \(name) \(view.bounds.size)") }
            }
            if let original = marker("original") { click("original", x: original.bounds.maxX + 4) }
            check(!state.original, "baseline nearby click misses the old checkbox")
            check((marker("compact")?.bounds.width ?? 0) >= 28 && (marker("compact")?.bounds.height ?? 0) >= 28,
                  "compact pointer target is at least 28x28")
            click("compact", x: 1, y: 1)
            check(state.compact && state.changes == 1, "checkbox edge click toggles exactly once")
            if let label = marker("labeled") { click("labeled", x: label.bounds.maxX - 3) }
            check(state.labeled && state.changes == 2, "blank label area toggles exactly once")
            click("disabled")
            check(!state.disabled && state.changes == 2, "disabled item cannot be selected")
            click("finder")
            check(state.finderActions == 1 && !state.besideFinder && state.changes == 2,
                  "Finder action does not change selection")
            for _ in 0..<10 { click("compact", x: 1, y: 1) }
            check(state.compact && state.changes == 12, "ten repeated clicks each toggle once")
            screenshot("light-640")
            window.appearance = NSAppearance(named: .darkAqua)
            screenshot("dark-640")
            window.setContentSize(NSSize(width: 850, height: 500))
            host.rootView = FixtureView(state: state)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            screenshot("dark-850")
            print("RESULT pointer failures=\(failures)")
            window.orderOut(nil)
            // Use a fresh process so hit markers and synthetic mouse events cannot
            // affect the AX positive control. The existing shell runner runs both.
            let pointerFailures = failures
            let ax = Process()
            ax.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            ax.arguments = ["--accessibility-only"]
            ax.standardOutput = FileHandle.standardOutput
            ax.standardError = FileHandle.standardError
            do { try ax.run() }
            catch {
                print("UNVERIFIED AX fixture could not start: \(error)")
                _exit(pointerFailures == 0 ? 77 : 1)
            }
            DispatchQueue.global(qos: .utility).async {
                // SwiftUI builds its AX tree on demand. Make a public, read-only
                // AX request only to the fake fixture this process just started.
                let fixture = AXUIElementCreateApplication(ax.processIdentifier)
                AXUIElementSetMessagingTimeout(fixture, 1)
                Thread.sleep(forTimeInterval: 0.15)
                var windows: CFTypeRef?
                let activation = AXUIElementCopyAttributeValue(fixture, kAXWindowsAttribute as CFString, &windows)
                print("AX fixture window request status=\(activation.rawValue)")
                ax.waitUntilExit()
                let status = ax.terminationStatus
                print("RESULT pointerFailures=\(pointerFailures) axExit=\(status)")
                _exit(pointerFailures == 0 ? status : 1)
            }
        }
        app.run()
    }
}
