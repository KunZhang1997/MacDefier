import Darwin
import XCTest
@testable import CleanupKit

final class InstallerPackageScannerTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var home: String { root.appendingPathComponent("Home", isDirectory: true).path }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent(
            "InstallerPackageScanner-\(UUID().uuidString)",
            isDirectory: true
        )
        for relative in ["Downloads", "Desktop", "Documents"] {
            try fm.createDirectory(
                atPath: home + "/" + relative,
                withIntermediateDirectories: true
            )
        }
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func write(_ relative: String, bytes: Int = 1) throws -> String {
        let path = home + "/" + relative
        try fm.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        XCTAssertTrue(fm.createFile(atPath: path, contents: Data(repeating: 7, count: bytes)))
        return path
    }

    func testFindsDMGPKGAndMPKGRegardlessOfSize() throws {
        let dmg = try write("Downloads/Tiny.dmg")
        let pkg = try write("Desktop/Builds/App-Test.PKG", bytes: 17)
        let mpkg = try write("Documents/Archive/Legacy.mpkg", bytes: 23)
        _ = try write("Downloads/source.zip", bytes: 31)

        let items = InstallerPackageScanner.scan(home: home, sharedRoot: nil)
        XCTAssertEqual(Set(items.map(\.path)), Set([dmg, pkg, mpkg].map(PathGate.normalize)))
        XCTAssertTrue(items.allSatisfy { $0.category == .installerPackages })
        XCTAssertTrue(items.allSatisfy { !$0.isSelected })
        XCTAssertTrue(items.allSatisfy { $0.risk == .caution })
        XCTAssertTrue(items.contains { $0.bytes < LargeFileScanner.minBytes })
    }

    func testPackageDirectoryIsIncludedButContentsAreNotDuplicated() throws {
        let package = home + "/Downloads/Offline.pkg"
        try fm.createDirectory(atPath: package + "/Contents", withIntermediateDirectories: true)
        _ = try write("Downloads/Offline.pkg/Contents/nested.dmg", bytes: 9)

        let items = InstallerPackageScanner.scan(home: home, sharedRoot: nil)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.path, PathGate.normalize(package))
        XCTAssertGreaterThan(items.first?.bytes ?? 0, 0)
    }

    func testDoesNotFollowInstallerSymlink() throws {
        let outside = root.appendingPathComponent("outside.dmg").path
        XCTAssertTrue(fm.createFile(atPath: outside, contents: Data([1])))
        let link = home + "/Downloads/link.dmg"
        try fm.createSymbolicLink(atPath: link, withDestinationPath: outside)

        XCTAssertTrue(InstallerPackageScanner.scan(home: home, sharedRoot: nil).isEmpty)
        XCTAssertFalse(PathGate.isSafeInstallerPackageTrashPath(link, home: home, sharedRoot: nil))
    }

    func testInstallerGateIsNarrowAndAllowsSmallPackages() throws {
        let dmg = try write("Downloads/small.dmg", bytes: 1)
        let zip = try write("Downloads/not-an-installer.zip", bytes: 1)
        let outside = root.appendingPathComponent("outside.pkg").path
        XCTAssertTrue(fm.createFile(atPath: outside, contents: Data([1])))

        XCTAssertTrue(PathGate.isSafeInstallerPackageTrashPath(dmg, home: home, sharedRoot: nil))
        XCTAssertTrue(PathGate.isSafeToTrash(dmg, home: home))
        XCTAssertFalse(PathGate.isSafeInstallerPackageTrashPath(zip, home: home, sharedRoot: nil))
        XCTAssertFalse(PathGate.isSafeInstallerPackageTrashPath(outside, home: home, sharedRoot: nil))
        XCTAssertFalse(PathGate.isSafeInstallerPackageTrashPath(home + "/Downloads", home: home, sharedRoot: nil))
    }

    func testNoFixedItemCountCap() throws {
        for index in 0..<501 {
            _ = try write("Downloads/Test-\(index).dmg")
        }
        XCTAssertEqual(
            InstallerPackageScanner.scan(home: home, sharedRoot: nil).count,
            501
        )
    }

    func testSmallEntryBudgetRetainsFoundInstallersAndMarksPartial() throws {
        for index in 0..<8 { _ = try write("Downloads/Bounded-\(index).dmg") }
        let report = InstallerPackageScanner.scanReport(
            home: home, sharedRoot: nil,
            budget: DiskScanBudget(maxEntries: 2)
        )
        XCTAssertTrue(report.isPartial)
        XCTAssertEqual(report.items.count, 2)
        XCTAssertTrue(report.items.allSatisfy { !$0.isSelected && !$0.sizeIsLowerBound })
    }

    func testEntryBudgetIsIndependentForEachExistingRoot() throws {
        for directory in ["Downloads", "Desktop", "Documents"] {
            for index in 0..<3 { _ = try write("\(directory)/Bounded-\(index).pkg") }
        }
        let report = InstallerPackageScanner.scanReport(
            home: home, sharedRoot: nil,
            budget: DiskScanBudget(maxEntries: 1)
        )
        XCTAssertTrue(report.isPartial)
        XCTAssertEqual(report.items.count, 3)
        XCTAssertEqual(Set(report.items.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().lastPathComponent }),
                       Set(["Downloads", "Desktop", "Documents"]))
    }

    func testPartialPackageIsOneItemWithLowerBoundSize() throws {
        let package = home + "/Downloads/Partial.mpkg"
        _ = try write("Downloads/Partial.mpkg/Contents/nested.pkg", bytes: 8192)
        let report = InstallerPackageScanner.scanReport(
            home: home, sharedRoot: nil,
            budget: DiskScanBudget(maxDepth: 0)
        )
        XCTAssertTrue(report.isPartial)
        XCTAssertEqual(report.items.count, 1)
        XCTAssertEqual(report.items.first?.path, PathGate.normalize(package))
        XCTAssertTrue(report.items.first?.sizeIsLowerBound == true)
        XCTAssertFalse(report.items.first?.isSelected ?? true)
    }

    func testZeroTimeAndCancellationCannotLookComplete() throws {
        _ = try write("Downloads/NotVisited.dmg")
        let timed = InstallerPackageScanner.scanReport(
            home: home, sharedRoot: nil,
            budget: DiskScanBudget(maxSeconds: 0)
        )
        XCTAssertTrue(timed.isPartial)
        XCTAssertTrue(timed.items.isEmpty)
        let cancelled = InstallerPackageScanner.scanReport(home: home, sharedRoot: nil, isCancelled: { true })
        XCTAssertTrue(cancelled.isPartial)
        XCTAssertTrue(cancelled.items.isEmpty)
    }

    func testHiddenAndApplicationPackageContentsRemainExcluded() throws {
        let visible = try write("Downloads/Visible.pkg")
        _ = try write("Downloads/.hidden.dmg")
        _ = try write("Downloads/.hidden-folder/Hidden.pkg")
        _ = try write("Downloads/Demo.app/Contents/Embedded.dmg")
        let report = InstallerPackageScanner.scanReport(home: home, sharedRoot: nil)
        XCTAssertFalse(report.isPartial)
        XCTAssertEqual(report.items.map(\.path), [PathGate.normalize(visible)])
    }

    func testDirectorySymlinkIsNotDescendedAndFIFOIsNotAnInstaller() throws {
        let outside = root.appendingPathComponent("Outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        XCTAssertTrue(fm.createFile(atPath: outside.appendingPathComponent("External.pkg").path, contents: Data([1])))
        try fm.createSymbolicLink(atPath: home + "/Downloads/Linked", withDestinationPath: outside.path)
        XCTAssertEqual(mkfifo(home + "/Downloads/not-a-file.dmg", 0o600), 0)
        let report = InstallerPackageScanner.scanReport(home: home, sharedRoot: nil)
        XCTAssertFalse(report.isPartial)
        XCTAssertTrue(report.items.isEmpty)
    }

    func testZeroByteInstallerIsStillDiscovered() throws {
        let empty = try write("Downloads/Empty.dmg", bytes: 0)
        let report = InstallerPackageScanner.scanReport(home: home, sharedRoot: nil)
        XCTAssertFalse(report.isPartial)
        XCTAssertEqual(report.items.map(\.path), [PathGate.normalize(empty)])
        XCTAssertEqual(report.items.first?.bytes, 0)
    }

    func testSymlinkScanRootIsSkippedAndReportedPartial() throws {
        let outside = root.appendingPathComponent("OutsideDownloads")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        XCTAssertTrue(fm.createFile(atPath: outside.appendingPathComponent("External.dmg").path, contents: Data([1])))
        try fm.removeItem(atPath: home + "/Downloads")
        try fm.createSymbolicLink(atPath: home + "/Downloads", withDestinationPath: outside.path)
        let report = InstallerPackageScanner.scanReport(home: home, sharedRoot: nil)
        XCTAssertTrue(report.isPartial)
        XCTAssertTrue(report.items.isEmpty)
    }
}
