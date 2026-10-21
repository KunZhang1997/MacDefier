// CleanupKitTests — PathGate + AppQueryMatcher automated safety nets.
// Run: cd app/CleanupKit && swift test

import XCTest
@testable import CleanupKit

final class PathGateTests: XCTestCase {
    private var home: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    // MARK: - Sensitive hard block (scan + trash)

    func testHardBlockSSH() {
        let p = home + "/.ssh/id_rsa"
        XCTAssertTrue(PathGate.isSensitiveHardBlocked(p))
        XCTAssertFalse(PathGate.isPathAllowedForScan(p))
        XCTAssertFalse(PathGate.isSafeToTrash(p))
    }

    func testHardBlockAWSGnupgKeychains() {
        for p in [
            home + "/.aws/credentials",
            home + "/.gnupg/pubring.kbx",
            home + "/Library/Keychains/login.keychain-db",
            home + "/Documents/secret.txt",
            home + "/Desktop/note.md",
            home + "/Downloads/file.zip"
        ] {
            XCTAssertTrue(PathGate.isSensitiveHardBlocked(p), p)
            XCTAssertFalse(PathGate.isSafeToTrash(p), p)
            XCTAssertFalse(PathGate.isPathAllowedForScan(p), p)
        }
    }

    // MARK: - Junk allow / deny

    func testBrowserCredentialPathsHardBlockedFromTrash() {
        let chromeLogin = home + "/Library/Application Support/Google/Chrome/Default/Login Data"
        let webData = home + "/Library/Application Support/Google/Chrome/Default/Web Data"
        XCTAssertTrue(PathGate.isBrowserCredentialPath(chromeLogin))
        XCTAssertTrue(PathGate.isBrowserCredentialPath(webData))
        XCTAssertFalse(PathGate.isSafeToTrash(chromeLogin), chromeLogin)
        XCTAssertFalse(PathGate.isSafeToTrash(webData), webData)
    }

    /// M03-1: allow 根若被符号链接到密钥目录，解析后必须硬拒（不改真实 HOME）
    func testAllowPrefixSymlinkIntoSecretsIsBlocked() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("PathGateSymlink-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let fakeHome = base.appendingPathComponent("Home", isDirectory: true).path
        try fm.createDirectory(atPath: fakeHome + "/.ssh", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: fakeHome + "/.aws", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: fakeHome + "/Library/Keychains", withIntermediateDirectories: true)
        try "secret".write(toFile: fakeHome + "/.ssh/id_rsa", atomically: true, encoding: .utf8)
        try "k".write(toFile: fakeHome + "/.aws/credentials", atomically: true, encoding: .utf8)
        try "kc".write(toFile: fakeHome + "/Library/Keychains/login.keychain-db", atomically: true, encoding: .utf8)

        // ~/.ollama → ~/.ssh
        try fm.createSymbolicLink(
            atPath: fakeHome + "/.ollama",
            withDestinationPath: fakeHome + "/.ssh"
        )
        // ~/.openclaw → ~/.aws
        try fm.createSymbolicLink(
            atPath: fakeHome + "/.openclaw",
            withDestinationPath: fakeHome + "/.aws"
        )
        // ~/.claude → Keychains（leaf 不存在的路径也必须拦）
        try fm.createSymbolicLink(
            atPath: fakeHome + "/.claude",
            withDestinationPath: fakeHome + "/Library/Keychains"
        )
        // Docker allow 子树伪造：Data/cache → Keychains
        let dockerCacheParent = fakeHome + "/Library/Containers/com.docker.docker/Data"
        try fm.createDirectory(atPath: dockerCacheParent, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            atPath: dockerCacheParent + "/cache",
            withDestinationPath: fakeHome + "/Library/Keychains"
        )

        XCTAssertFalse(
            PathGate.isSafeToTrash(fakeHome + "/.ollama/id_rsa", home: fakeHome),
            "ollama→ssh must block"
        )
        XCTAssertFalse(
            PathGate.isSafeToTrash(fakeHome + "/.openclaw/credentials", home: fakeHome),
            "openclaw→aws must block"
        )
        XCTAssertFalse(
            PathGate.isSafeToTrash(fakeHome + "/.claude/login.keychain-db", home: fakeHome),
            "cli data→keychains must block"
        )
        // leaf 不存在时仍须拒绝（中间 symlink 解析）
        XCTAssertFalse(
            PathGate.isSafeToTrash(fakeHome + "/.claude/missing.keychain-db", home: fakeHome),
            "cli→keychains missing leaf must block"
        )
        XCTAssertFalse(
            PathGate.isSafeToTrash(dockerCacheParent + "/cache/login.keychain-db", home: fakeHome),
            "docker cache→keychains must block"
        )
        XCTAssertFalse(PathGate.isPathAllowedForScan(fakeHome + "/.ollama/id_rsa", home: fakeHome))

        // allow 根 → 个人数据（Documents/Preferences）：须敏感硬闸，不得 trash
        try fm.createDirectory(atPath: fakeHome + "/Documents", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: fakeHome + "/Library/Preferences", withIntermediateDirectories: true)
        try "tax".write(toFile: fakeHome + "/Documents/tax.pdf", atomically: true, encoding: .utf8)
        try "p".write(toFile: fakeHome + "/Library/Preferences/com.x.plist", atomically: true, encoding: .utf8)
        try fm.removeItem(atPath: fakeHome + "/.openclaw")
        try fm.createSymbolicLink(
            atPath: fakeHome + "/.openclaw",
            withDestinationPath: fakeHome + "/Documents"
        )
        try fm.createSymbolicLink(
            atPath: fakeHome + "/.codex",
            withDestinationPath: fakeHome + "/Library/Preferences"
        )
        XCTAssertFalse(
            PathGate.isSafeToTrash(fakeHome + "/.openclaw/tax.pdf", home: fakeHome),
            "openclaw→Documents must block"
        )
        XCTAssertFalse(
            PathGate.isSafeToTrash(fakeHome + "/.codex/com.x.plist", home: fakeHome),
            "codex→Preferences must block"
        )

        // 真 allow 目录 + 中途/叶子 symlink 逃逸到敏感区
        try fm.removeItem(atPath: fakeHome + "/.ollama")
        try fm.createDirectory(atPath: fakeHome + "/.ollama", withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            atPath: fakeHome + "/.ollama/escape",
            withDestinationPath: fakeHome + "/Documents/tax.pdf"
        )
        try fm.createSymbolicLink(
            atPath: fakeHome + "/.ollama/models",
            withDestinationPath: fakeHome + "/.ssh"
        )
        XCTAssertFalse(
            PathGate.isSafeToTrash(fakeHome + "/.ollama/escape", home: fakeHome),
            "ollama leaf→Documents must block"
        )
        XCTAssertFalse(
            PathGate.isSafeToTrash(fakeHome + "/.ollama/models/id_rsa", home: fakeHome),
            "ollama mid→ssh must block"
        )

        // 正常 AI 目录（真目录非链接）仍可通过
        try fm.createDirectory(atPath: fakeHome + "/.lmstudio/models", withIntermediateDirectories: true)
        try "w".write(toFile: fakeHome + "/.lmstudio/models/x.bin", atomically: true, encoding: .utf8)
        XCTAssertTrue(PathGate.isSafeToTrash(fakeHome + "/.lmstudio/models/x.bin", home: fakeHome))

        // 正常 ollama 真目录 models 可通过
        try fm.removeItem(atPath: fakeHome + "/.ollama")
        try fm.createDirectory(atPath: fakeHome + "/.ollama/models", withIntermediateDirectories: true)
        try "m".write(toFile: fakeHome + "/.ollama/models/blob", atomically: true, encoding: .utf8)
        XCTAssertTrue(PathGate.isSafeToTrash(fakeHome + "/.ollama/models/blob", home: fakeHome))
    }

    func testAllowPrefixDoesNotMatchPartialComponent() {
        // /foo 不匹配 /foobar — 组件边界
        let p = home + "/Library/Caches/com.example.foobar/cache"
        // 只要在 Caches 下即可 trash；这里只验证前缀 helper 边界
        XCTAssertTrue(PathGate.isUnderComponentPrefixes(
            "/Users/x/Library/Caches/com.example.app",
            ["/Users/x/Library/Caches"]
        ))
        XCTAssertFalse(PathGate.isUnderComponentPrefixes(
            "/Users/x/Library/CachesExtra/foo",
            ["/Users/x/Library/Caches"]
        ))
        _ = p
    }

    func testScanAllowsUserCaches() {
        let p = home + "/Library/Caches/com.example.foo"
        XCTAssertTrue(PathGate.isPathAllowedForScan(p))
        XCTAssertTrue(PathGate.isSafeToTrash(p))
    }

    func testScanBlocksApplications() {
        XCTAssertFalse(PathGate.isPathAllowedForScan("/Applications/Safari.app"))
        XCTAssertFalse(PathGate.isSafeToTrash("/Applications/Safari.app"))
    }

    func testScanBlocksContainersExceptDockerCarveOut() {
        let container = home + "/Library/Containers/com.apple.Safari/Data"
        XCTAssertFalse(PathGate.isPathAllowedForScan(container))

        let dockerCache = home + "/Library/Containers/com.docker.docker/Data/cache/x"
        XCTAssertTrue(PathGate.isPathAllowedForScan(dockerCache))
        XCTAssertTrue(PathGate.isSafeToTrash(dockerCache))
    }

    // MARK: - AppData inventory ≠ trash

    func testAppDataLocationsNotEarlyTrueForTrash() {
        // Inventory roots must not become deletable solely via AppDataLocations
        let speakSend = home + "/Library/Application Support/SpeakSend/models/x.bin"
        let mumu = home + "/Library/Application Support/com.netease.mumu.nemux/vms/disk"
        let colima = home + "/.colima/default/rootfs"
        for p in [speakSend, mumu, colima] {
            XCTAssertTrue(AppDataLocations.isUnderAllowedRoot(p), "inventory should still know root: \(p)")
            XCTAssertFalse(PathGate.isSafeToTrash(p), "trash must block inventory-only: \(p)")
        }
    }

    func testAINarrowCarveOutStillTrashable() {
        // PureMac AI narrow paths remain cleanable
        let ollama = home + "/.ollama/models/blobs/sha256-abc"
        XCTAssertTrue(PathGate.isSafeToTrash(ollama))
        XCTAssertTrue(PathGate.isPathAllowedForScan(ollama))
    }

    func testProtectedMediaNeverTrash() {
        let photos = home + "/Pictures/Photos Library.photoslibrary"
        XCTAssertTrue(ProtectedMediaRoots.contains(photos))
        XCTAssertFalse(PathGate.isSafeToTrash(photos))
        XCTAssertFalse(PathGate.isSafeForUninstall(photos, allowAppBundle: "/Applications/Photos.app"))
    }

    // MARK: - Uninstall: only target .app

    func testUninstallOnlyAllowAppBundle() {
        let target = "/Applications/Target.app"
        let victim = "/Applications/Victim.app"
        XCTAssertTrue(PathGate.isSafeForUninstall(target, allowAppBundle: target))
        XCTAssertFalse(PathGate.isSafeForUninstall(victim, allowAppBundle: target))
        XCTAssertFalse(PathGate.isSafeForUninstall(
            "/Applications/Other.app/Contents/MacOS/Other",
            allowAppBundle: target
        ))
    }

    func testUninstallAllowsResidualCacheNotWholeRoot() {
        let target = "/Applications/Foo.app"
        // 缓存目录用 bid 风格名，勿用 *.app 后缀（那是包扩展名）
        let cache = home + "/Library/Caches/com.foo.bar"
        XCTAssertTrue(PathGate.isSafeForUninstall(cache, allowAppBundle: target))
        XCTAssertFalse(PathGate.isSafeForUninstall(home + "/Library/Caches", allowAppBundle: target))
        XCTAssertFalse(PathGate.isSafeForUninstall("/Applications", allowAppBundle: target))
    }

    func testUninstallPreferencesOnlyPlist() {
        let target = "/Applications/Foo.app"
        let plist = home + "/Library/Preferences/com.foo.app.plist"
        let folder = home + "/Library/Preferences/com.foo.app"
        XCTAssertTrue(PathGate.isSafeForUninstall(plist, allowAppBundle: target))
        XCTAssertFalse(PathGate.isSafeForUninstall(folder, allowAppBundle: target))
    }

    /// P0: whole LaunchAgents root must not pass uninstall gate; single plist still may.
    func testUninstallBlocksLaunchAgentsRootButAllowsPlist() {
        let target = "/Applications/Foo.app"
        let root = home + "/Library/LaunchAgents"
        let plist = home + "/Library/LaunchAgents/com.foo.agent.plist"
        let nonPlist = home + "/Library/LaunchAgents/com.foo.folder"
        XCTAssertFalse(PathGate.isSafeForUninstall(root, allowAppBundle: target), "LaunchAgents root must be forbiddenExact")
        XCTAssertTrue(PathGate.isSafeForUninstall(plist, allowAppBundle: target), "single plist still allowed")
        XCTAssertFalse(PathGate.isSafeForUninstall(nonPlist, allowAppBundle: target), "non-plist child still blocked")
    }

    /// §8.8: Intel Homebrew cache must pass scan/trash; /usr/bin still hard-denied.
    func testHomebrewCachesAllowedButUsrBinDenied() {
        let brewCache = "/usr/local/Homebrew/Library/Caches/Homebrew"
        let brewCacheRoot = "/usr/local/Homebrew/Library/Caches"
        let optBrewCache = "/opt/homebrew/Library/Caches/Homebrew"
        XCTAssertTrue(PathGate.isPathAllowedForScan(brewCache), brewCache)
        XCTAssertTrue(PathGate.isSafeToTrash(brewCache), brewCache)
        XCTAssertTrue(PathGate.isPathAllowedForScan(brewCacheRoot), brewCacheRoot)
        XCTAssertTrue(PathGate.isSafeToTrash(brewCacheRoot), brewCacheRoot)
        XCTAssertTrue(PathGate.isPathAllowedForScan(optBrewCache), optBrewCache)
        XCTAssertTrue(PathGate.isSafeToTrash(optBrewCache), optBrewCache)

        XCTAssertTrue(PathGate.isSecretHardBlocked("/usr/bin/yes"))
        XCTAssertFalse(PathGate.isPathAllowedForScan("/usr/bin/yes"))
        XCTAssertFalse(PathGate.isSafeToTrash("/usr/bin/yes"))
        XCTAssertTrue(PathGate.isSecretHardBlocked("/usr/sbin/systemsetup"))
        XCTAssertFalse(PathGate.isPathAllowedForScan("/usr/sbin/systemsetup"))
        XCTAssertFalse(PathGate.isSafeToTrash("/System/Library/CoreServices/Finder.app"))
        // Bare /usr is not on allow tables → still denied for scan/trash
        XCTAssertFalse(PathGate.isPathAllowedForScan("/usr"))
        XCTAssertFalse(PathGate.isSafeToTrash("/usr"))
        XCTAssertFalse(PathGate.isPathAllowedForScan("/usr/lib"))
        XCTAssertFalse(PathGate.isSafeToTrash("/usr/lib"))
    }

    func testUninstallBlocksSSHEvenIfForged() {
        let target = "/Applications/Foo.app"
        XCTAssertFalse(PathGate.isSafeForUninstall(home + "/.ssh/id_rsa", allowAppBundle: target))
        XCTAssertFalse(PathGate.isSafeForUninstall(home + "/Documents/a", allowAppBundle: target))
    }

    // MARK: - User trash

    func testUnderUserTrash() {
        XCTAssertTrue(PathGate.isUnderUserTrash(home + "/.Trash/old.pdf"))
        XCTAssertFalse(PathGate.isUnderUserTrash(home + "/Documents/old.pdf"))
    }

    // MARK: - Symlink resolve (Caches → .ssh)

    func testSymlinkIntoSSHBlockedWhenResolved() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PathGateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let link = tmp.appendingPathComponent("evil-link")
        let ssh = home + "/.ssh"
        // If ~/.ssh missing, still point at Documents as hard-blocked target
        let target = FileManager.default.fileExists(atPath: ssh) ? ssh : (home + "/Documents")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)

        let resolved = PathGate.normalize(link.path)
        XCTAssertTrue(PathGate.isSensitiveHardBlocked(resolved))
        XCTAssertFalse(PathGate.isSafeToTrash(resolved))
        XCTAssertFalse(PathGate.isPathAllowedForScan(resolved))
    }

    // MARK: - Browser prefixes

    func testBrowserChromeASAllowedForTrash() {
        let p = home + "/Library/Application Support/Google/Chrome/Default/Cache"
        XCTAssertTrue(PathGate.isSafeToTrash(p))
        XCTAssertTrue(PathGate.isPathAllowedForScan(p))
    }

    func testSystemCookiesBinaryNotInBrowserAllowAsLoosePath() {
        // Shared cookie jar must stay blocked for generic trash (not under catalog prefixes)
        let p = home + "/Library/Cookies/Cookies.binarycookies"
        XCTAssertFalse(PathGate.isSafeToTrash(p))
    }

    func testDeepApplicationSupportNotBlankedByLargeGate() {
        // Nested AS path must NOT be trashable solely via large-file helper
        let deep = home + "/Library/Application Support/SomeRandomApp/secret.db"
        XCTAssertFalse(PathGate.isSafeToTrash(deep), deep)
    }

    func testContainersNotAllowedViaLargeGate() {
        let p = home + "/Library/Containers/com.apple.Safari/Data/Library/foo"
        XCTAssertFalse(PathGate.isSafeToTrash(p), p)
    }

    func testLargeDownloadFileTrashableWhenBigEnough() throws {
        // 不写真实 ~/Downloads：临时 fakeHome + 注入 home（CI/沙箱安全）
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("PathGateLarge-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let fakeHome = base.appendingPathComponent("Home", isDirectory: true).path
        let downloads = fakeHome + "/Downloads"
        try fm.createDirectory(atPath: downloads, withIntermediateDirectories: true)

        let marker = downloads + "/.macdefier-pathgate-large-\(UUID().uuidString).bin"
        let size = Int(LargeFileScanner.minBytes + 1)
        fm.createFile(atPath: marker, contents: nil)
        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: marker))
        try fh.truncate(atOffset: UInt64(size))
        try fh.close()

        XCTAssertTrue(
            PathGate.isSafeToTrash(marker, home: fakeHome),
            "large Downloads file should be trashable under injected home"
        )
        let small = downloads + "/.macdefier-pathgate-small-\(UUID().uuidString).txt"
        try "hi".write(toFile: small, atomically: true, encoding: .utf8)
        XCTAssertFalse(
            PathGate.isSafeToTrash(small, home: fakeHome),
            "small Downloads file must stay blocked"
        )
    }

    func testUninstallBlocksContainersNotOwnedByTargetApp() {
        let target = "/Applications/Foo.app"
        let otherContainer = home + "/Library/Containers/com.other.app"
        let otherAS = home + "/Library/Application Support/OtherVendor"
        XCTAssertFalse(PathGate.isSafeForUninstall(otherContainer, allowAppBundle: target))
        XCTAssertFalse(PathGate.isSafeForUninstall(otherAS, allowAppBundle: target))
    }
}

final class AppQueryMatcherTests: XCTestCase {
    private func app(name: String, bid: String, path: String) -> InstalledApp {
        InstalledApp(
            name: name,
            bundleIdentifier: bid,
            path: path,
            version: "1.0",
            bytes: 1_000_000,
            relatedBytes: 0,
            isSystemLocation: false,
            canTrashAppBundle: true
        )
    }

    func testExtractQueryStripsUninstallVerbs() {
        XCTAssertEqual(AppQueryMatcher.extractQuery(from: "卸载腾讯视频"), "腾讯视频")
        XCTAssertEqual(AppQueryMatcher.extractQuery(from: "帮我删掉 WeChat"), "WeChat")
        XCTAssertNotNil(AppQueryMatcher.extractQuery(from: "uninstall Docker"))
    }

    func testLooksLikeTargetedUninstall() {
        XCTAssertTrue(AppQueryMatcher.looksLikeTargetedUninstall("卸载钉钉"))
        XCTAssertFalse(AppQueryMatcher.looksLikeTargetedUninstall("电脑好卡"))
    }

    func testFindMatchesByAlias() {
        let apps = [
            app(name: "Tencent Video", bid: "com.tencent.tenvideo", path: "/Applications/TencentVideo.app"),
            app(name: "Safari", bid: "com.apple.Safari", path: "/Applications/Safari.app")
        ]
        let hits = AppQueryMatcher.findMatches(query: "腾讯视频", in: apps)
        XCTAssertEqual(hits.first?.bundleIdentifier, "com.tencent.tenvideo")
    }
}

final class MatchingStringTests: XCTestCase {
    func testNormalizedForMatching() {
        XCTAssertEqual("Foo Bar-1".mdNormalizedForMatching(), "foobar1")
    }

    func testMatchingSegmentsStopsGenericContains() {
        // craft 不得与 minecraft 在「整词段」上命中（防 substring 误关联）
        let craft = MatchingSegments.of("Craft")
        let mine = MatchingSegments.of("Minecraft")
        XCTAssertTrue(craft.contains("craft"))
        XCTAssertTrue(mine.contains("minecraft"))
        XCTAssertFalse(mine.contains("craft"))
        XCTAssertTrue(MatchingSegments.stopwords.contains("craft"))
    }
}
