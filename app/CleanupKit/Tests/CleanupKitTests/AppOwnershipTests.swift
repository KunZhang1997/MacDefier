// AppOwnership — residual / orphan / deep-link attribution tests.
// Run: cd app/CleanupKit && swift test --filter AppOwnershipTests

import XCTest
@testable import CleanupKit

final class AppOwnershipTests: XCTestCase {

    private func app(
        name: String,
        bid: String,
        path: String = "/Applications/X.app"
    ) -> InstalledApp {
        InstalledApp(
            name: name,
            bundleIdentifier: bid,
            path: path,
            version: "1",
            bytes: 1,
            relatedBytes: 0,
            isSystemLocation: false,
            canTrashAppBundle: true
        )
    }

    // MARK: - Hermes must not claim com.hermes.p6game

    func testReusedNameIndexPreservesOwnershipDecisions() {
        let apps = [
            app(name: "Cursor", bid: "com.todesktop.cursor", path: "/Applications/Cursor.app"),
            app(name: "Hermes", bid: "ai.nousresearch.hermes", path: "/Applications/Hermes.app"),
            app(name: "Duplicate", bid: "com.example.first", path: "/Applications/First.app"),
            app(name: "Duplicate", bid: "com.example.second", path: "/Applications/Second.app")
        ]
        let index = AppOwnership.uniqueNormalizedNameSet(from: apps)
        for name in ["Cursor", "Duplicate", "com.hermes.p6game", "ai.nousresearch.hermes", "Unknown"] {
            let path = "/Users/test/Library/Application Support/" + name
            XCTAssertEqual(
                AppOwnership.isOwnedByInstalled(name: name, path: path, apps: apps),
                AppOwnership.isOwnedByInstalled(name: name, path: path, apps: apps, uniqueNormalizedNames: index),
                name
            )
        }
    }

    func testHermesDoesNotClaimP6GameBundleFolder() {
        let hermes = app(name: "Hermes", bid: "ai.nousresearch.hermes", path: "/Applications/Hermes.app")
        let folder = "com.hermes.p6game"
        let path = "/Users/x/Library/Caches/\(folder)"
        XCTAssertFalse(
            AppOwnership.folderBelongs(to: hermes, folderName: folder, path: path),
            "name token hermes must not claim unrelated reverse-DNS folder"
        )
        XCTAssertFalse(
            AppOwnership.isOwnedByInstalled(name: folder, path: path, apps: [hermes])
        )
    }

    func testExactBundleIDStillOwnsOwnFolder() {
        let hermes = app(name: "Hermes", bid: "ai.nousresearch.hermes")
        XCTAssertTrue(
            AppOwnership.folderBelongs(
                to: hermes,
                folderName: "ai.nousresearch.hermes",
                path: "/Users/x/Library/Caches/ai.nousresearch.hermes"
            )
        )
        XCTAssertTrue(
            AppOwnership.bundleIDMatches(
                folderName: "ai.nousresearch.hermes.helper",
                bundleID: "ai.nousresearch.hermes"
            )
        )
    }

    func testBundleIDComponentBoundaryNoPartialComponent() {
        // com.foo.app must not match com.foobar.app
        XCTAssertFalse(
            AppOwnership.bundleIDMatches(folderName: "com.foobar.app", bundleID: "com.foo.app")
        )
        XCTAssertTrue(
            AppOwnership.bundleIDMatches(folderName: "com.foo.app", bundleID: "com.foo.app")
        )
        XCTAssertTrue(
            AppOwnership.bundleIDMatches(folderName: "com.foo.app.plist", bundleID: "com.foo.app")
        )
        XCTAssertTrue(
            AppOwnership.bundleIDMatches(folderName: "com.foo.app.helper", bundleID: "com.foo.app")
        )
    }

    // MARK: - Chrome / Drive channel isolation

    func testChromeChannelsDoNotCrossClaim() {
        let home = "/Users/test"
        let stable = AppOwnership.channelRelatedPaths(
            bundleID: "com.google.Chrome",
            appPath: "/Applications/Google Chrome.app",
            home: home
        )
        let beta = AppOwnership.channelRelatedPaths(
            bundleID: "com.google.Chrome.beta",
            appPath: "/Applications/Google Chrome Beta.app",
            home: home
        )
        let drive = AppOwnership.channelRelatedPaths(
            bundleID: "com.google.drivefs",
            appPath: "/Applications/Google Drive.app",
            home: home
        )

        XCTAssertTrue(stable.contains { $0.hasSuffix("/Google/Chrome") })
        XCTAssertFalse(stable.contains { $0.contains("Chrome Beta") })
        XCTAssertFalse(stable.contains { $0.contains("DriveFS") })

        XCTAssertTrue(beta.contains { $0.hasSuffix("/Google/Chrome Beta") })
        XCTAssertFalse(beta.contains { $0.hasSuffix("/Google/Chrome") && !$0.contains("Beta") })

        XCTAssertTrue(drive.contains { $0.hasSuffix("/Google/DriveFS") })
        XCTAssertFalse(drive.contains { $0.contains("Chrome") })
    }

    func testResidualMatcherDoesNotCrossClaimChromeViaName() {
        let chrome = app(
            name: "Google Chrome",
            bid: "com.google.Chrome",
            path: "/Applications/Google Chrome.app"
        )
        // "Chrome Beta" folder must not belong to stable Chrome via name segment
        XCTAssertFalse(
            AppOwnership.folderBelongs(
                to: chrome,
                folderName: "Chrome Beta",
                path: "/Users/x/Library/Application Support/Google/Chrome Beta"
            )
        )
        // Exact channel paths still returned by channel table for beta only
        let betaPaths = AppOwnership.channelRelatedPaths(
            bundleID: "com.google.Chrome.beta",
            appPath: "/Applications/Google Chrome Beta.app",
            home: "/Users/x"
        )
        XCTAssertTrue(betaPaths.contains { $0.hasSuffix("Chrome Beta") })
    }

    // MARK: - Deep link

    func testDeepLinkPrefersExactBundleID() {
        let a = app(name: "Foo", bid: "com.foo.app", path: "/Applications/Foo.app")
        let b = app(name: "Foo Helper", bid: "com.foo.helper", path: "/Applications/Foo Helper.app")
        let r = AppOwnership.resolveDeepLink(
            path: nil,
            bundleID: "com.foo.app",
            name: "Foo",
            in: [a, b]
        )
        if case .exact(let hit) = r {
            XCTAssertEqual(hit.bundleIdentifier, "com.foo.app")
        } else {
            XCTFail("expected exact bid match")
        }
    }

    func testDeepLinkAmbiguousSameNameDoesNotAutoPickFirst() {
        let a = app(name: "Notes", bid: "com.a.notes", path: "/Applications/NotesA.app")
        let b = app(name: "Notes", bid: "com.b.notes", path: "/Applications/NotesB.app")
        let r = AppOwnership.resolveDeepLink(path: nil, bundleID: nil, name: "Notes", in: [a, b])
        if case .ambiguous(let hits) = r {
            XCTAssertEqual(hits.count, 2)
        } else {
            XCTFail("two same-name apps must be ambiguous, not auto-open first")
        }
    }

    func testDeepLinkPartialNameIsNoneNotFirst() {
        let a = app(name: "Microsoft Word", bid: "com.microsoft.Word", path: "/Applications/Microsoft Word.app")
        let b = app(name: "Word Processor", bid: "com.other.wp", path: "/Applications/Word Processor.app")
        // contains-style "Word" must NOT auto-open either app (no exact name/base match)
        let r = AppOwnership.resolveDeepLink(path: nil, bundleID: nil, name: "Word", in: [a, b])
        if case .none = r {
            // ok
        } else if case .exact(let hit) = r {
            XCTFail("must not auto-pick \(hit.name) from partial name")
        } else if case .ambiguous = r {
            XCTFail("partial name must not open picker either — only exact name")
        }
    }

    /// M05-3: short substring / single-char-ish names must never first-match open sheet.
    func testDeepLinkShortSubstringNeverExact() {
        let notes = app(name: "Notes", bid: "com.apple.Notes", path: "/Applications/Notes.app")
        let wechat = app(name: "WeChat", bid: "com.tencent.xinWeChat", path: "/Applications/WeChat.app")
        let tencentVideo = app(name: "腾讯视频", bid: "com.tencent.tenvideo", path: "/Applications/TencentVideo.app")
        let apps = [notes, wechat, tencentVideo]

        for partial in ["Note", "We", "腾讯", "Chat"] {
            let r = AppOwnership.resolveDeepLink(path: nil, bundleID: nil, name: partial, in: apps)
            if case .none = r {
                // required: no auto sheet
            } else {
                XCTFail("partial \"\(partial)\" must be .none, got \(r)")
            }
        }

        // Exact unique still works
        if case .exact(let hit) = AppOwnership.resolveDeepLink(
            path: nil, bundleID: nil, name: "WeChat", in: apps
        ) {
            XCTAssertEqual(hit.bundleIdentifier, "com.tencent.xinWeChat")
        } else {
            XCTFail("exact WeChat must resolve")
        }

        // Bundle ID wins over fuzzy name
        if case .exact(let hit) = AppOwnership.resolveDeepLink(
            path: nil,
            bundleID: "com.apple.Notes",
            name: "We",
            in: apps
        ) {
            XCTAssertEqual(hit.bundleIdentifier, "com.apple.Notes")
        } else {
            XCTFail("exact bid must win")
        }

        // Path wins over everything
        if case .exact(let hit) = AppOwnership.resolveDeepLink(
            path: "/Applications/WeChat.app",
            bundleID: "com.apple.Notes",
            name: "Notes",
            in: apps
        ) {
            XCTAssertEqual(hit.path, "/Applications/WeChat.app")
        } else {
            XCTFail("exact path must win")
        }
    }

    func testDeepLinkExactBaseNameFromBundlePath() {
        let a = app(name: "Google Chrome", bid: "com.google.Chrome", path: "/Applications/Google Chrome.app")
        let r = AppOwnership.resolveDeepLink(
            path: nil, bundleID: nil, name: "Google Chrome", in: [a]
        )
        if case .exact(let hit) = r {
            XCTAssertEqual(hit.bundleIdentifier, "com.google.Chrome")
        } else {
            XCTFail("exact display name must resolve")
        }
    }

    func testGenericTokensDoNotOwn() {
        let appX = app(name: "Helper", bid: "com.example.mytool")
        XCTAssertFalse(
            AppOwnership.folderBelongs(
                to: appX,
                folderName: "helper",
                path: "/Users/x/Library/Caches/helper"
            )
        )
    }

    func testCursorDisplayNameAndBundleBasenameCountAsOneInstalledOwner() {
        let cursor = app(
            name: "Cursor",
            bid: "com.todesktop.230313mzl4w4u92",
            path: "/Applications/Cursor.app"
        )
        let names = AppOwnership.uniqueNormalizedNameSet(from: [cursor])

        XCTAssertEqual(names, Set(["cursor"]))
        XCTAssertTrue(
            AppOwnership.isOwnedByInstalled(
                name: "Cursor",
                path: "/Users/test/Library/Application Support/Cursor",
                apps: [cursor]
            ),
            "a reinstalled Cursor must own its live Application Support directory"
        )
    }

    func testSameNormalizedNameAcrossDifferentAppsRemainsAmbiguous() {
        let first = app(
            name: "Cursor",
            bid: "com.example.cursor.one",
            path: "/Applications/Cursor.app"
        )
        let second = app(
            name: "Cursor",
            bid: "com.example.cursor.two",
            path: "/Applications/Cursor Beta.app"
        )

        XCTAssertFalse(AppOwnership.uniqueNormalizedNameSet(from: [first, second]).contains("cursor"))
    }

    // MARK: - M05-1 ResidualMatcher shipped path (enhanced)

    func testResidualMatcherHermesDoesNotClaimP6Game() {
        let hermes = app(
            name: "Hermes",
            bid: "ai.nousresearch.hermes",
            path: "/Applications/Hermes.app"
        )
        // Application Scripts / Containers — bid-only roots + reverse-DNS guard
        XCTAssertFalse(
            ResidualMatcher.matches(
                folderName: "com.hermes.p6game",
                path: "/Users/x/Library/Application Scripts/com.hermes.p6game",
                app: hermes,
                sensitivity: .enhanced
            )
        )
        XCTAssertFalse(
            ResidualMatcher.matches(
                folderName: "com.hermes.p6game",
                path: "/Users/x/Library/Containers/com.hermes.p6game",
                app: hermes,
                sensitivity: .enhanced
            )
        )
        XCTAssertFalse(
            ResidualMatcher.matches(
                folderName: "ai.hermes.gateway.plist",
                path: "/Users/x/Library/LaunchAgents/ai.hermes.gateway.plist",
                app: hermes,
                sensitivity: .enhanced
            )
        )
        // Own bid still matches
        XCTAssertTrue(
            ResidualMatcher.matches(
                folderName: "ai.nousresearch.hermes",
                path: "/Users/x/Library/Caches/ai.nousresearch.hermes",
                app: hermes,
                sensitivity: .enhanced
            )
        )
        // Exact display-name folder under Caches still allowed
        XCTAssertTrue(
            ResidualMatcher.matches(
                folderName: "Hermes",
                path: "/Users/x/Library/Caches/Hermes",
                app: hermes,
                sensitivity: .enhanced
            )
        )
    }

    func testResidualMatcherDeveloperDoesNotClaimSTMExtension() {
        let developer = app(
            name: "Developer",
            bid: "com.apple.dt.Developer",
            path: "/Applications/Developer.app"
        )
        XCTAssertFalse(
            ResidualMatcher.matches(
                folderName: "com.apple.STMExtension.Developer",
                path: "/Users/x/Library/Containers/com.apple.STMExtension.Developer",
                app: developer,
                sensitivity: .enhanced
            )
        )
        XCTAssertTrue(
            ResidualMatcher.matches(
                folderName: "com.apple.dt.Developer",
                path: "/Users/x/Library/Containers/com.apple.dt.Developer",
                app: developer,
                sensitivity: .enhanced
            )
        )
    }

    func testResidualMatcherNoStudioTokenCrossClaim() {
        // Old enhanced used nameSegments.contains("studio") → obs-studio / maestro-studio
        let studio = app(name: "Studio", bid: "com.example.studio", path: "/Applications/Studio.app")
        XCTAssertFalse(
            ResidualMatcher.matches(
                folderName: "obs-studio",
                path: "/Users/x/Library/Application Support/obs-studio",
                app: studio,
                sensitivity: .enhanced
            )
        )
        XCTAssertFalse(
            ResidualMatcher.matches(
                folderName: "maestro-studio",
                path: "/Users/x/Library/Application Support/maestro-studio",
                app: studio,
                sensitivity: .enhanced
            )
        )
        // Exact name folder still OK when non-generic; "studio" is generic → blocked
        XCTAssertFalse(
            ResidualMatcher.matches(
                folderName: "Studio",
                path: "/Users/x/Library/Application Support/Studio",
                app: studio,
                sensitivity: .enhanced
            ),
            "generic token 'studio' must not name-claim"
        )
        // Bid still owns own support
        XCTAssertTrue(
            ResidualMatcher.matches(
                folderName: "com.example.studio",
                path: "/Users/x/Library/Application Support/com.example.studio",
                app: studio,
                sensitivity: .enhanced
            )
        )
    }

    func testResidualMatcherVendorMegaFolderNotNameClaimed() {
        let chrome = app(
            name: "Google Chrome",
            bid: "com.google.Chrome",
            path: "/Applications/Google Chrome.app"
        )
        XCTAssertFalse(
            ResidualMatcher.matches(
                folderName: "Google",
                path: "/Users/x/Library/Application Support/Google",
                app: chrome,
                sensitivity: .enhanced
            ),
            "must not claim whole vendor mega-folder via name"
        )
    }

    func testLooksLikeReverseDNS() {
        XCTAssertTrue(AppOwnership.looksLikeReverseDNS("com.hermes.p6game"))
        XCTAssertTrue(AppOwnership.looksLikeReverseDNS("ai.hermes.gateway.plist"))
        XCTAssertTrue(AppOwnership.looksLikeReverseDNS("com.apple.STMExtension.Developer"))
        XCTAssertFalse(AppOwnership.looksLikeReverseDNS("Hermes"))
        XCTAssertFalse(AppOwnership.looksLikeReverseDNS("Google Chrome"))
    }
}
