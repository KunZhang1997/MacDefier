#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd -- "$script_dir/.." && pwd)"
guide_scratch="$(mktemp -d "/private/tmp/macdefier-usage-guide.XXXXXX")"
trap 'rm -rf -- "$guide_scratch"' EXIT

ruby -e 'File.write(ARGV.fetch(0), STDIN.read)' "$guide_scratch/Probe.swift" <<'SWIFT'
import Foundation

@main
@MainActor
enum UsageGuideSmoke {
    enum Failure: Error { case assertion(String) }
    static let prefix = "macdefier.usageGuide.v1."
    static var passed = 0

    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure.assertion(message) }
    }

    static func test(_ name: String, _ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "MacDefier.UsageGuideSmoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let unrelated: [String: Any] = [
            "ai.enabled": false, "ai.mode": "local", "ai.localModel": "synthetic-model",
            "pet.drag.x": 29.5, "pet.drag.y": -88.0,
            "macdefier.appearance": "dark", "macdefier.menubar.enabled": false
        ]
        defaults.setPersistentDomain(unrelated, forName: suiteName)
        try body(defaults)
        let after = defaults.persistentDomain(forName: suiteName) ?? [:]
        let remaining = after.filter { !$0.key.hasPrefix(prefix) }
        try expect(NSDictionary(dictionary: remaining).isEqual(to: unrelated), "\(name): unrelated preferences changed")
        passed += 1
    }

    static func main() throws {
        try test("first launch") { defaults in
            let guide = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            try expect(guide.step == .welcome && guide.isPresented, "first launch must start at welcome")
            try expect(defaults.string(forKey: prefix + "installationIdentity") == "install-A", "installation identity must be stored")
        }
        try test("interrupted progress") { defaults in
            let guide = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            guide.next(); guide.next()
            let resumed = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            try expect(resumed.step == .review && resumed.isPresented, "interrupted guide must resume saved step")
        }
        try test("back bounds") { defaults in
            let guide = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            guide.back(); guide.back()
            try expect(guide.step == .welcome && guide.isPresented, "back must stop at welcome")
            guide.next(); guide.next(); guide.back()
            try expect(guide.step == .scan, "back must persist the previous step")
            try expect(UsageGuideState(defaults: defaults, installationIdentity: "install-A").step == .scan, "back progress must survive relaunch")
        }
        try test("skip and normal relaunch") { defaults in
            let guide = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            guide.next(); guide.dismiss()
            let relaunched = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            try expect(!relaunched.isPresented && relaunched.step == .scan, "skip must stay dismissed on ordinary relaunch")
            relaunched.next(); relaunched.back()
            try expect(!relaunched.isPresented && relaunched.step == .scan, "hidden guide must ignore navigation")
        }
        try test("finish and normal relaunch") { defaults in
            let guide = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            for _ in 0..<UsageGuideStep.allCases.count - 1 { guide.next() }
            try expect(guide.step == .ready && guide.isPresented, "final page must remain visible until committed")
            guide.next()
            let relaunched = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            try expect(!relaunched.isPresented && relaunched.step == .ready, "next on final step must dismiss and stay dismissed")
        }
        try test("replay") { defaults in
            let guide = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            guide.next(); guide.dismiss(); guide.replay()
            try expect(guide.isPresented && guide.step == .welcome, "replay must start a visible fresh guide")
            guide.next()
            let resumed = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            try expect(resumed.isPresented && resumed.step == .scan, "interrupted replay must resume")
        }
        try test("changed installation after dismissal") { defaults in
            let guide = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            guide.next(); guide.dismiss()
            let reinstalled = UsageGuideState(defaults: defaults, installationIdentity: "install-B")
            try expect(reinstalled.isPresented && reinstalled.step == .welcome, "new executable must reset seen and progress")
            try expect(defaults.string(forKey: prefix + "installationIdentity") == "install-B", "new executable identity must replace old identity")
        }
        try test("changed installation during guide") { defaults in
            let guide = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            guide.next(); guide.next()
            let reinstalled = UsageGuideState(defaults: defaults, installationIdentity: "install-B")
            try expect(reinstalled.isPresented && reinstalled.step == .welcome, "new executable must reset interrupted progress")
        }
        try test("missing identity preserves installation") { defaults in
            let guide = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            guide.next(); guide.dismiss()
            let unavailable = UsageGuideState(defaults: defaults, installationIdentity: nil)
            try expect(!unavailable.isPresented && unavailable.step == .scan, "missing identity must not reset completed guide")
            try expect(defaults.string(forKey: prefix + "installationIdentity") == "install-A", "missing identity must not erase known installation")
        }
        try test("nil identity progress") { defaults in
            let guide = UsageGuideState(defaults: defaults, installationIdentity: nil)
            guide.next()
            let resumed = UsageGuideState(defaults: defaults, installationIdentity: nil)
            try expect(resumed.isPresented && resumed.step == .scan, "unavailable executable identity must still preserve progress")
        }
        try test("corrupt negative step") { defaults in
            defaults.set("install-A", forKey: prefix + "installationIdentity")
            defaults.set(-999, forKey: prefix + "step")
            let guide = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            try expect(guide.step == .welcome && defaults.integer(forKey: prefix + "step") == 0, "negative step must clamp to welcome")
        }
        try test("corrupt high step") { defaults in
            defaults.set("install-A", forKey: prefix + "installationIdentity")
            defaults.set(Int.max, forKey: prefix + "step")
            let guide = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            try expect(guide.step == .ready && defaults.integer(forKey: prefix + "step") == UsageGuideStep.ready.rawValue, "high step must clamp to ready")
        }
        try test("corrupt step type") { defaults in
            defaults.set("install-A", forKey: prefix + "installationIdentity")
            defaults.set(["not": "a step"], forKey: prefix + "step")
            let guide = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            try expect(guide.step == .welcome && guide.isPresented, "invalid step type must fall back to welcome")
        }
        print("UsageGuideSmoke: PASS (\(passed) cases; isolated preference suites; unrelated preferences preserved)")
    }
}
SWIFT
swiftc -parse-as-library -module-cache-path "$guide_scratch/module-cache" \
  "$app_dir/MacDefier/UsageGuideState.swift" "$guide_scratch/Probe.swift" -o "$guide_scratch/probe"
"$guide_scratch/probe"
