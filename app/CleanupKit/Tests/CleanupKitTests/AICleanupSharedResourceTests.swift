import Foundation
import XCTest
@testable import CleanupKit

final class AICleanupSharedResourceTests: XCTestCase {
    private let fm = FileManager.default
    private var fixture: URL!
    private var home: String { fixture.appendingPathComponent("Home").path }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        fixture = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("AICleanupSharedFixture-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: fixture) }

    @discardableResult
    private func write(_ relative: String, bytes: Int = 1) throws -> String {
        let path = home + "/" + relative
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func capture(_ path: String, bytes: UInt64) throws -> AIResource {
        try AIResource.capture(path: path, bytes: bytes)
    }

    private func candidate(_ id: String, kind: AIDataKind = .cache, state: AICandidateState = .ready,
                           tool: AITool = .cursor, resources: [AIResource] = [], date: Date? = nil) -> AICleanupCandidate {
        AICleanupCandidate(id: id, tool: tool, kind: kind, title: id, resources: resources,
                           state: state, reason: "fixture", lastActivity: date)
    }

    func testParentAndChildMutationsExcludeEachOtherInBothOrders() async throws {
        let child = try write("cache/item")
        let parent = (child as NSString).deletingLastPathComponent
        let coordinator = ResourceMutationCoordinator()
        let first = await coordinator.acquire(paths: [parent])
        let parentLease = try XCTUnwrap(first)
        let blockedChild = await coordinator.acquire(paths: [child])
        XCTAssertNil(blockedChild, "A generic parent cleanup must exclude an AI child cleanup")
        await coordinator.release(parentLease)
        let next = await coordinator.acquire(paths: [child])
        let childLease = try XCTUnwrap(next)
        let blockedParent = await coordinator.acquire(paths: [parent])
        XCTAssertNil(blockedParent, "A child cleanup must also exclude its parent")
        await coordinator.release(childLease)
        let released = await coordinator.acquire(paths: [parent])
        XCTAssertNotNil(released)
        if let released { await coordinator.release(released) }
    }

    func testHardlinkNamesShareOneMutationLease() async throws {
        let first = try write("one/model.bin", bytes: 19)
        let alias = home + "/two/same-model.bin"
        try fm.createDirectory(atPath: (alias as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.linkItem(atPath: first, toPath: alias)
        let coordinator = ResourceMutationCoordinator()
        let acquired = await coordinator.acquire(paths: [first])
        let lease = try XCTUnwrap(acquired)
        let blocked = await coordinator.acquire(paths: [alias])
        XCTAssertNil(blocked, "Separate names for one inode cannot be mutated concurrently")
        await coordinator.release(lease)
        let released = await coordinator.acquire(paths: [alias])
        XCTAssertNotNil(released)
        if let released { await coordinator.release(released) }
    }

    func testSiblingPathsCanProceedAndReleasingOneDoesNotReleaseAnother() async throws {
        let first = try write("cache/item")
        let sibling = try write("cache-old/item")
        let coordinator = ResourceMutationCoordinator()
        let firstResult = await coordinator.acquire(paths: [first])
        let siblingResult = await coordinator.acquire(paths: [sibling])
        let firstLease = try XCTUnwrap(firstResult)
        let siblingLease = try XCTUnwrap(siblingResult)
        await coordinator.release(firstLease)
        let blocked = await coordinator.acquire(paths: [home])
        XCTAssertNil(blocked, "The sibling's lease must remain active")
        await coordinator.release(siblingLease)
        let allReleased = await coordinator.acquire(paths: [home])
        XCTAssertNotNil(allReleased)
        if let allReleased { await coordinator.release(allReleased) }
    }

    func testConcurrentOverlappingRequestsHaveExactlyOneWinner() async throws {
        let child = try write("tree/child")
        let parent = (child as NSString).deletingLastPathComponent
        let coordinator = ResourceMutationCoordinator()
        async let parentResult = coordinator.acquire(paths: [parent])
        async let childResult = coordinator.acquire(paths: [child])
        let results = await [parentResult, childResult]
        XCTAssertEqual(results.compactMap { $0 }.count, 1)
        for token in results.compactMap({ $0 }) { await coordinator.release(token) }
    }

    func testEmptyAndRelativeRequestsCannotCreateMutationLeases() async {
        let coordinator = ResourceMutationCoordinator()
        let empty = await coordinator.acquire(paths: [])
        let relative = await coordinator.acquire(paths: ["relative/path", ""])
        XCTAssertNil(empty)
        XCTAssertNil(relative)
    }

    func testParentResourcesCoverDescendantsButKeepPathPrefixSiblings() throws {
        let child = try write("tree/cache/a.bin", bytes: 20)
        let grandchild = try write("tree/cache/sub/b.bin", bytes: 30)
        let sibling = try write("tree/cache-old/keep.bin", bytes: 7)
        let parentResource = try capture(home + "/tree/cache", bytes: 50)
        let childResource = try capture(child, bytes: 20)
        let subdirectoryResource = try capture(home + "/tree/cache/sub", bytes: 30)
        let grandchildResource = try capture(grandchild, bytes: 30)
        let siblingResource = try capture(sibling, bytes: 7)
        let input = [grandchildResource, siblingResource, childResource, parentResource, subdirectoryResource]
        for order in [input, Array(input.reversed()), [parentResource, grandchildResource, siblingResource, subdirectoryResource, childResource]] {
            let unique = AIResourceTotals.unique(order)
            XCTAssertEqual(Set(unique.map(\.path)), Set([parentResource.path, siblingResource.path]))
            XCTAssertEqual(AIResourceTotals.bytes(order), 57)
        }
    }

    func testSamePathAndHardlinkedResourcesAreCountedOnce() throws {
        let path = try write("a/file", bytes: 19)
        let alias = home + "/b/file"
        try fm.createDirectory(atPath: (alias as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.linkItem(atPath: path, toPath: alias)
        let first = try capture(path, bytes: 19)
        let duplicate = try capture(path, bytes: 19)
        let secondName = try capture(alias, bytes: 19)
        XCTAssertEqual(first.identity, secondName.identity)
        XCTAssertNotEqual(first.path, secondName.path)
        XCTAssertEqual(AIResourceTotals.unique([secondName, first, duplicate]).count, 1)
        XCTAssertEqual(AIResourceTotals.bytes([secondName, first, duplicate]), 19)
    }

    func testIndependentResourceTotalsSaturateRatherThanWrap() throws {
        let first = try capture(write("first"), bytes: UInt64.max - 5)
        let second = try capture(write("second"), bytes: 10)
        XCTAssertEqual(AIResourceTotals.unique([first, second]).count, 2)
        XCTAssertEqual(AIResourceTotals.bytes([first, second]), UInt64.max)
    }

    func testDontListHidesAllDatesAndAllCanShowUnknownDates() {
        let dates: [Date?] = [nil, .distantPast, now, now.addingTimeInterval(1), now.addingTimeInterval(-400 * 86_400)]
        for date in dates {
            XCTAssertFalse(AIConversationAge.dontList.includes(date, now: now))
            XCTAssertTrue(AIConversationAge.all.includes(date, now: now))
        }
    }

    func testAgeThresholdsExcludeUnknownFutureAndExactBoundary() {
        for age in [AIConversationAge.days30, .days90, .days180, .days365] {
            let days = age.days!
            let boundary = now.addingTimeInterval(-Double(days) * 86_400)
            XCTAssertFalse(age.includes(nil, now: now))
            XCTAssertFalse(age.includes(.distantPast, now: now))
            XCTAssertFalse(age.includes(now.addingTimeInterval(1), now: now))
            XCTAssertFalse(age.includes(boundary, now: now), "The boundary must be strictly older than \(days) days")
            XCTAssertFalse(age.includes(boundary.addingTimeInterval(0.001), now: now))
            XCTAssertTrue(age.includes(boundary.addingTimeInterval(-0.001), now: now))
        }
    }

    func testConversationVisibilityDefaultsToHiddenAndUsesEachOwnersAge() {
        let old = now.addingTimeInterval(-100 * 86_400)
        let rows = [candidate("cache"),
                    candidate("cursor-old", kind: .conversation, state: .reviewOnly, date: old),
                    candidate("cursor-recent", kind: .conversation, state: .reviewOnly, date: now),
                    candidate("cursor-unknown", kind: .conversation, state: .reviewOnly),
                    candidate("codex-old", kind: .conversation, state: .reviewOnly, tool: .codex, date: old),
                    candidate("claude-unknown", kind: .conversation, state: .reviewOnly, tool: .claude)]
        XCTAssertEqual(AICleanupSelection.visible(rows, ages: [:], now: now).map(\.id), ["cache"])
        let visible = AICleanupSelection.visible(rows, ages: [.cursor: .days90, .claude: .all], now: now)
        XCTAssertEqual(visible.map(\.id), ["cache", "cursor-old", "claude-unknown"])
        XCTAssertTrue(visible.filter { $0.kind == .conversation }.allSatisfy { $0.state == .reviewOnly },
                      "Showing metadata does not authorize its deletion")
    }

    func testApprovedSelectionExcludesUnrequestedBlockedEmptyAndInspectionKinds() throws {
        let resource = try capture(write("cache/item", bytes: 11), bytes: 11)
        let rows = [candidate("approved", resources: [resource]),
                    candidate("unrequested", resources: [resource]),
                    candidate("review", state: .reviewOnly, resources: [resource]),
                    candidate("in-use", state: .inUse, resources: [resource]),
                    candidate("unknown", state: .unknown, resources: [resource]),
                    candidate("retained", state: .retained, resources: [resource]),
                    candidate("empty"),
                    candidate("tool", kind: .tool, resources: [resource]),
                    candidate("worktree", kind: .worktree, resources: [resource]),
                    candidate("database", kind: .database, resources: [resource])]
        let requested = Set(rows.map(\.id)).subtracting(["unrequested"])
        let approved = AICleanupSelection.approved(requested, candidates: rows)
        XCTAssertEqual(approved.map(\.id), ["approved"])
        XCTAssertTrue(AICleanupSelection.approved([], candidates: rows).isEmpty, "Initial selection is empty")
        XCTAssertEqual(AICleanupSelection.resources(approved).map(\.path), [resource.path])
    }

    func testSelectionResourcesDeduplicateOverlapsAcrossApprovedProductRows() throws {
        let child = try write("cache/child", bytes: 13)
        let model = try write("models/model", bytes: 17)
        let alias = home + "/model-alias"
        try fm.linkItem(atPath: model, toPath: alias)
        let parentResource = try capture(home + "/cache", bytes: 13)
        let childResource = try capture(child, bytes: 13)
        let modelResource = try capture(model, bytes: 17)
        let aliasResource = try capture(alias, bytes: 17)
        let rows = [candidate("parent", resources: [parentResource]),
                    candidate("child", resources: [childResource]),
                    candidate("model", kind: .model, resources: [modelResource]),
                    candidate("alias", resources: [aliasResource])]
        let selected = AICleanupSelection.approved(Set(rows.map(\.id)), candidates: rows)
        let resources = AICleanupSelection.resources(selected)
        XCTAssertEqual(resources.count, 2)
        XCTAssertEqual(Set(resources.map(\.identity)), Set([parentResource.identity, modelResource.identity]))
        XCTAssertFalse(resources.contains { $0.path == childResource.path })
        XCTAssertEqual(AIResourceTotals.bytes(resources), 30)
    }
}
