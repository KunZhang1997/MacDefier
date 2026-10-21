import Foundation
import Darwin

// Data-only stubs provide inputs to mechanically extracted production methods.
// These models deliberately have no inventory, resource capture, Trash or executor.
struct AppStub { let canTrashAppBundle: Bool }
enum ResidualKind { case appBundle, preferences, containers, support, mediaLibrary, cache, logs, savedState, other }
struct ResidualItem {
    let path: String
    let kind: ResidualKind
    var isSelected = false
}
struct CliDataStub { let path: String }
struct CliToolStub {
    let agents: [String]
    let dataDirs: [CliDataStub]
    let protected: Bool
}
enum AIPhaseStub { case idle, scanning, preview, cleaning }
struct AICandidateStub {
    let id: String
    let canSelect: Bool
}

@main struct BulkSelectionSmokeMain {
    static func main() {
        var checks = 0
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        func residuals() -> [ResidualItem] {
            [ResidualItem(path: "/FAKE/Applications/Example.app", kind: .appBundle),
             ResidualItem(path: "/FAKE/Library/Preferences/example", kind: .preferences),
             ResidualItem(path: "/FAKE/Library/Containers/example", kind: .containers),
             ResidualItem(path: "/FAKE/Library/Application Support/example", kind: .support),
             ResidualItem(path: "/FAKE/Library/Caches/example", kind: .cache),
             ResidualItem(path: "/FAKE/Library/Logs/example", kind: .logs),
             ResidualItem(path: "/FAKE/Library/Saved Application State/example", kind: .savedState),
             ResidualItem(path: "/FAKE/Other/example", kind: .other),
             ResidualItem(path: "/FAKE/Pictures/Example.photoslibrary", kind: .mediaLibrary),
             ResidualItem(path: "/FAKE/Library/Group Containers/shared", kind: .containers)]
        }

        let app = AppBulkProbe(app: AppStub(canTrashAppBundle: true), items: residuals())
        app.applyKeepUserData()
        check(app.items.filter(\.isSelected).map(\.kind) == [.appBundle], "app initial keep-data preset selects only main app")
        app.selectAllItems()
        check(app.items.prefix(8).allSatisfy(\.isSelected), "app bulk includes main app and associated data, cache, logs and saved state")
        check(!app.keepUserData, "app bulk updates keep-data state to match selected associated data")
        check(!app.items[8].isSelected && !app.items[9].isSelected, "app bulk does not add media library or shared group container")
        app.items[8].isSelected = true
        app.items[9].isSelected = true
        app.selectAllItems()
        check(app.items[8].isSelected && app.items[9].isSelected, "app bulk preserves explicitly selected media and shared entries")
        app.clearItemSelection()
        check(app.items.allSatisfy { !$0.isSelected }, "app clear removes every selection including main app")
        check(!app.keepUserData, "app clear does not invoke preset or silently reselect main app")
        app.clearItemSelection()
        check(app.items.allSatisfy { !$0.isSelected }, "app repeated clear remains empty")

        let preset = AppBulkProbe(app: AppStub(canTrashAppBundle: true), items: residuals(), keepUserData: false)
        preset.applyKeepUserData()
        check(preset.items.prefix(4).allSatisfy(\.isSelected), "app explicit data preset selects main app, preferences, private container and support")
        check(!preset.items[8].isSelected && !preset.items[9].isSelected, "app explicit data preset still excludes media and shared container")
        let system = AppBulkProbe(app: AppStub(canTrashAppBundle: false), items: residuals())
        system.applyKeepUserData()
        check(!system.items[0].isSelected, "system app preset does not select protected bundle")
        system.selectAllItems()
        check(!system.items[0].isSelected && system.items[1...7].allSatisfy(\.isSelected), "system app bulk selects associated items but not bundle")
        check(!system.items[8].isSelected && !system.items[9].isSelected, "system app bulk retains media and shared-container exclusions")

        let cli = CLIBulkProbe(tool: CliToolStub(agents: ["fake-agent"],
            dataDirs: [CliDataStub(path: "/FAKE/cli/data-a"), CliDataStub(path: "/FAKE/cli/data-b")],
            protected: false), hasProgram: true)
        check(cli.hasOptions && !cli.allOptionsSelected, "CLI exposes unselected agent, program and data options")
        cli.selectAllOptions()
        check(cli.stopAgents && cli.uninstallProgram, "CLI bulk selects existing agent and program")
        check(cli.selectedData == Set(["/FAKE/cli/data-a", "/FAKE/cli/data-b"]) && cli.allOptionsSelected,
              "CLI bulk selects every data option and reports all selected")
        cli.clearAllOptions()
        check(!cli.stopAgents && !cli.uninstallProgram && cli.selectedData.isEmpty && !cli.allOptionsSelected,
              "CLI clear resets agent, program and data to zero")
        let protectedCLI = CLIBulkProbe(tool: CliToolStub(agents: ["fake-agent"],
            dataDirs: [CliDataStub(path: "/FAKE/protected/data")], protected: true), hasProgram: true)
        protectedCLI.selectAllOptions()
        check(!protectedCLI.stopAgents && !protectedCLI.uninstallProgram && protectedCLI.selectedData.isEmpty,
              "protected CLI cannot gain any selection through select all")
        let dataOnlyCLI = CLIBulkProbe(tool: CliToolStub(agents: [],
            dataDirs: [CliDataStub(path: "/FAKE/data-only")], protected: false), hasProgram: false)
        dataOnlyCLI.selectAllOptions()
        check(!dataOnlyCLI.stopAgents && !dataOnlyCLI.uninstallProgram && dataOnlyCLI.allOptionsSelected,
              "data-only CLI does not invent program or agent actions")
        let emptyCLI = CLIBulkProbe(tool: CliToolStub(agents: [], dataDirs: [], protected: false), hasProgram: false)
        check(!emptyCLI.hasOptions, "empty CLI has no bulk-select options")

        let eligibleIDs = Set((0..<73).map { "eligible-\($0)" })
        let rows = eligibleIDs.sorted().map { AICandidateStub(id: $0, canSelect: true) }
            + (0..<7).map { AICandidateStub(id: "skip-\($0)", canSelect: false) }
        let ai = AIBulkProbe(visibleCandidates: rows)
        ai.selectAllEligible()
        check(ai.selectedIDs == eligibleIDs, "AI bulk selects all 73 eligible rows, beyond the 40-row render limit")
        check(ai.selectedIDs.isDisjoint(with: Set((0..<7).map { "skip-\($0)" })), "AI bulk excludes every nonselectable candidate")
        check(ai.refreshCalls == 1, "AI successful bulk action refreshes selection once")
        let expiredAI = AIBulkProbe(visibleCandidates: rows)
        expiredAI.requiresRescan = true // Actual expiry callback sets this flag; no timer is simulated.
        expiredAI.selectAllEligible()
        check(expiredAI.selectedIDs.isEmpty && expiredAI.refreshCalls == 0, "AI preview marked expired cannot bulk-select")
        for phase in [AIPhaseStub.idle, .scanning, .cleaning] {
            let busyAI = AIBulkProbe(visibleCandidates: rows)
            busyAI.phase = phase
            busyAI.selectAllEligible()
            check(busyAI.selectedIDs.isEmpty && busyAI.refreshCalls == 0, "AI phase \(phase) cannot bulk-select")
        }

        print("BULK_SELECTION_PROBE checks=\(checks) failures=\(failures)")
        print("BOUNDARY extracted method bodies + fake memory state; no SwiftUI events, live inventory, timer scheduling or executor validation")
        exit(failures == 0 ? 0 : 1)
    }
}
