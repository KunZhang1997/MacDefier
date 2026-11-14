import Foundation
import XCTest
@testable import MacDefier

@MainActor
final class UsageGuideStateTests: XCTestCase {
    private let prefix = "macdefier.usageGuide.v1."

    private func runIsolated(_ name: String, _ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "MacDefier.UsageGuideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let unrelated: [String: Any] = [
            "ai.enabled": false,
            "ai.mode": "local",
            "ai.localModel": "synthetic-model",
            "pet.drag.x": 29.5,
            "pet.drag.y": -88.0,
            "macdefier.appearance": "dark",
            "macdefier.menubar.enabled": false
        ]
        defaults.setPersistentDomain(unrelated, forName: suiteName)
        try body(defaults)
        let after = defaults.persistentDomain(forName: suiteName) ?? [:]
        let remaining = after.filter { !$0.key.hasPrefix(prefix) }
        XCTAssertTrue(NSDictionary(dictionary: remaining).isEqual(to: unrelated), "\(name): unrelated preferences changed")
    }

    func testNavigationPersistenceReplayAndCorruptedPreferences() throws {
        try runIsolated("first launch") { defaults in
            let guide = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            XCTAssertEqual(guide.step, .welcome)
            XCTAssertTrue(guide.isPresented)
            XCTAssertEqual(defaults.string(forKey: prefix + "installationIdentity"), "install-A")
        }

        try runIsolated("interrupted progress") { defaults in
            let guide = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            guide.next()
            guide.next()
            let resumed = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            XCTAssertEqual(resumed.step, .review)
            XCTAssertTrue(resumed.isPresented)
        }

        try runIsolated("back bounds") { defaults in
            let guide = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            guide.back()
            guide.back()
            XCTAssertEqual(guide.step, .welcome)
            XCTAssertTrue(guide.isPresented)
            guide.next()
            guide.next()
            guide.back()
            XCTAssertEqual(guide.step, .scan)
            XCTAssertEqual(UsageGuideState(defaults: defaults, installationIdentity: "install-A").step, .scan)
        }

        try runIsolated("skip and normal relaunch") { defaults in
            let guide = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            guide.next()
            guide.dismiss()
            let relaunched = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            XCTAssertFalse(relaunched.isPresented)
            XCTAssertEqual(relaunched.step, .scan)
            relaunched.next()
            relaunched.back()
            XCTAssertFalse(relaunched.isPresented)
            XCTAssertEqual(relaunched.step, .scan)
        }

        try runIsolated("finish and normal relaunch") { defaults in
            let guide = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            for _ in 0..<(UsageGuideStep.allCases.count - 1) { guide.next() }
            XCTAssertEqual(guide.step, .ready)
            XCTAssertTrue(guide.isPresented)
            guide.next()
            let relaunched = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            XCTAssertFalse(relaunched.isPresented)
            XCTAssertEqual(relaunched.step, .ready)
        }

        try runIsolated("replay") { defaults in
            let guide = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            guide.next()
            guide.dismiss()
            guide.replay()
            XCTAssertTrue(guide.isPresented)
            XCTAssertEqual(guide.step, .welcome)
            guide.next()
            let resumed = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            XCTAssertTrue(resumed.isPresented)
            XCTAssertEqual(resumed.step, .scan)
        }

        try runIsolated("changed installation after dismissal") { defaults in
            let guide = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            guide.next()
            guide.dismiss()
            let reinstalled = UsageGuideState(defaults: defaults, installationIdentity: "install-B")
            XCTAssertTrue(reinstalled.isPresented)
            XCTAssertEqual(reinstalled.step, .welcome)
            XCTAssertEqual(defaults.string(forKey: prefix + "installationIdentity"), "install-B")
        }

        try runIsolated("changed installation during guide") { defaults in
            let guide = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            guide.next()
            guide.next()
            let reinstalled = UsageGuideState(defaults: defaults, installationIdentity: "install-B")
            XCTAssertTrue(reinstalled.isPresented)
            XCTAssertEqual(reinstalled.step, .welcome)
        }

        try runIsolated("missing identity preserves installation") { defaults in
            let guide = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            guide.next()
            guide.dismiss()
            let unavailable = UsageGuideState(defaults: defaults, installationIdentity: nil)
            XCTAssertFalse(unavailable.isPresented)
            XCTAssertEqual(unavailable.step, .scan)
            XCTAssertEqual(defaults.string(forKey: prefix + "installationIdentity"), "install-A")
        }

        try runIsolated("nil identity progress") { defaults in
            let guide = UsageGuideState(defaults: defaults, installationIdentity: nil)
            guide.next()
            let resumed = UsageGuideState(defaults: defaults, installationIdentity: nil)
            XCTAssertTrue(resumed.isPresented)
            XCTAssertEqual(resumed.step, .scan)
        }

        try runIsolated("corrupt negative step") { defaults in
            defaults.set("install-A", forKey: prefix + "installationIdentity")
            defaults.set(-999, forKey: prefix + "step")
            let guide = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            XCTAssertEqual(guide.step, .welcome)
            XCTAssertEqual(defaults.integer(forKey: prefix + "step"), 0)
        }

        try runIsolated("corrupt high step") { defaults in
            defaults.set("install-A", forKey: prefix + "installationIdentity")
            defaults.set(Int.max, forKey: prefix + "step")
            let guide = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            XCTAssertEqual(guide.step, .ready)
            XCTAssertEqual(defaults.integer(forKey: prefix + "step"), UsageGuideStep.ready.rawValue)
        }

        try runIsolated("corrupt step type") { defaults in
            defaults.set("install-A", forKey: prefix + "installationIdentity")
            defaults.set(["not": "a step"], forKey: prefix + "step")
            let guide = UsageGuideState(defaults: defaults, installationIdentity: "install-A")
            XCTAssertEqual(guide.step, .welcome)
            XCTAssertTrue(guide.isPresented)
        }
    }
}
