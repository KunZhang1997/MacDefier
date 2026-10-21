import Foundation
import XCTest
@testable import CleanupKit

final class CLIOrphanExecutionTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var home: String { root.appendingPathComponent("Home").path }
    private var dataPath: String { home + "/.aider" }
    private var programPath: String { root.appendingPathComponent("bin/aider").path }
    private var unrelatedApp: InstalledApp {
        InstalledApp(name: "Unrelated", bundleIdentifier: "org.example.unrelated",
                     path: root.appendingPathComponent("Unrelated.app").path,
                     version: "1", bytes: 0, isSystemLocation: false, canTrashAppBundle: true)
    }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("CLIOrphanExecution-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        try fm.createDirectory(atPath: dataPath, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 128 * 1024).write(to: URL(fileURLWithPath: dataPath + "/history"))
        // Exercise CLI ownership independently of /tmp's broad PathGate allowance.
        XCTAssertTrue(PathGate.cliDataAllowPrefixes(home: home).contains(dataPath))
    }

    override func tearDownWithError() throws {
        if let root, root.lastPathComponent.hasPrefix("CLIOrphanExecution-") {
            try fm.removeItem(at: root)
        }
    }

    private func tool(programs: [String]? = nil, agents: [CliLaunchAgentInfo] = []) -> CliTool {
        CliTool(id: "manual:aider", displayName: "Aider", channel: .manual, packageId: "aider",
                programPaths: programs ?? [programPath], programBytes: 0,
                dataDirs: [CliDataDir(path: dataPath, bytes: 128 * 1024)], agents: agents,
                bins: ["aider"], protected: false)
    }

    private func isBlocked(_ inventory: [CliTool]?) -> Bool {
        TrashExecutor.shouldBlockOrphanPath(dataPath, installedApps: [unrelatedApp],
            containerOwnership: [], cliInventory: inventory, home: home)
    }

    func testReinstalledCLIBlocksPreviouslyScannedData() throws {
        let owner = tool()
        let preview = OrphanScanner.scanCLIDataOrphans(cliInventory: [owner], home: home)
        XCTAssertEqual(preview.map(\.path), [dataPath])
        XCTAssertFalse(isBlocked([owner]), "A known missing program is the uninstalled positive control")
        try Data([0x23]).write(to: URL(fileURLWithPath: programPath))
        XCTAssertTrue(OrphanScanner.scanCLIDataOrphans(cliInventory: [owner], home: home).isEmpty)
        XCTAssertTrue(isBlocked([owner]), "An existing preview must not authorize reinstalled CLI data")
        XCTAssertTrue(fm.fileExists(atPath: dataPath + "/history"))
    }

    func testRefreshedInventoryProtectsReinstallAtDifferentLocation() throws {
        let preview = OrphanScanner.scanCLIDataOrphans(cliInventory: [tool()], home: home)
        XCTAssertEqual(preview.map(\.path), [dataPath])
        let newPath = root.appendingPathComponent("bin/aider-new").path
        try Data([0x23]).write(to: URL(fileURLWithPath: newPath))
        XCTAssertTrue(isBlocked([tool(programs: [newPath])]))
    }

    func testUnavailableOrUnrelatedCLIInventoryFailsClosed() {
        XCTAssertTrue(isBlocked(nil))
        XCTAssertTrue(isBlocked([]))
        let other = CliTool(id: "manual:other", displayName: "Other", channel: .manual, packageId: "other",
                            programPaths: [programPath], programBytes: 0, dataDirs: [], agents: [],
                            bins: ["other"], protected: false)
        XCTAssertTrue(isBlocked([other]))
    }

    func testDataOnlyRowDoesNotProveThatItsProgramWasUninstalled() {
        XCTAssertTrue(isBlocked([tool(programs: [])]))
        XCTAssertTrue(OrphanScanner.scanCLIDataOrphans(cliInventory: [tool(programs: [])], home: home).isEmpty,
                      "Do not label data-only directories as verified uninstall remnants")
    }

    func testExistingLaunchAgentBlocksDataEvenWhenProgramIsMissing() throws {
        let path = root.appendingPathComponent("aider.plist").path
        try Data([0x41]).write(to: URL(fileURLWithPath: path))
        let agent = CliLaunchAgentInfo(label: "org.example.aider", plistPath: path, running: false)
        XCTAssertTrue(isBlocked([tool(agents: [agent])]))
    }

    func testUnknownProgramPathStateFailsClosed() throws {
        let notDirectory = root.appendingPathComponent("not-a-directory")
        try Data([0x41]).write(to: notDirectory)
        XCTAssertTrue(isBlocked([tool(programs: [notDirectory.path + "/aider"])]),
                      "ENOTDIR is not verified absence of an installed program")
    }

    func testKnownUninstalledCLIStillAllowsItsDataCandidate() {
        XCTAssertFalse(isBlocked([tool()]))
        XCTAssertEqual(OrphanScanner.scanCLIDataOrphans(cliInventory: [tool()], home: home).map(\.path), [dataPath])
    }

    func testAnyLiveOwnerProtectsSharedCLIData() throws {
        let otherProgram = root.appendingPathComponent("bin/other-aider").path
        try Data([0x23]).write(to: URL(fileURLWithPath: otherProgram))
        XCTAssertTrue(isBlocked([tool(), tool(programs: [otherProgram])]))
        XCTAssertTrue(OrphanScanner.scanCLIDataOrphans(
            cliInventory: [tool(), tool(programs: [otherProgram])], home: home).isEmpty)
    }

    func testUnknownSiblingOwnerCannotBorrowAnotherOwnersMissingProgramEvidence() {
        let unknownOwner = CliTool(id: "data:.aider", displayName: "Aider", channel: .manual, packageId: ".aider",
                                   programPaths: [], programBytes: 0,
                                   dataDirs: [CliDataDir(path: dataPath, bytes: 128 * 1024)], agents: [],
                                   bins: [], protected: false)
        let owners = [tool(), unknownOwner]
        XCTAssertTrue(isBlocked(owners), "Every possible owner must have its own verifiable program locations")
        XCTAssertTrue(OrphanScanner.scanCLIDataOrphans(cliInventory: owners, home: home).isEmpty)
    }

    func testRunningAgentProtectsDataEvenIfItsPlistWasRemoved() {
        let agent = CliLaunchAgentInfo(label: "org.example.aider", plistPath: root.appendingPathComponent("gone.plist").path,
                                      running: true)
        XCTAssertTrue(isBlocked([tool(agents: [agent])]))
    }

    func testUnrelatedDirectoryAndSymlinkNeverBecomeCLIOrphanEvidence() throws {
        XCTAssertFalse(OrphanScanner.isVerifiedCLIDataOrphan(root.path, cliInventory: [tool()], home: home))
        let aliasHome = root.appendingPathComponent("AliasHome")
        try fm.createDirectory(at: aliasHome, withIntermediateDirectories: true)
        let alias = aliasHome.appendingPathComponent(".aider")
        try fm.createSymbolicLink(at: alias, withDestinationURL: URL(fileURLWithPath: dataPath))
        XCTAssertFalse(OrphanScanner.isVerifiedCLIDataOrphan(alias.path, cliInventory: [tool()], home: aliasHome.path))
    }
}
