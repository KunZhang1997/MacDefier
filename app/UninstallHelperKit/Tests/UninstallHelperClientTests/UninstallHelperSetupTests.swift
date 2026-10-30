import Foundation
import ServiceManagement
import XCTest
import UninstallHelperIPC
@testable import UninstallHelperClient

@MainActor final class UninstallHelperSetupTests: XCTestCase {
    /// This fake supplies every effect. No test constructs SMAppService or calls
    /// the public setup entry point, which would display UI or register a daemon.
    private final class SetupFixture {
        var status: SMAppService.Status
        var configurationAvailable = true
        var enableConfirmed = true
        var approvalConfirmed = true
        var statusAfterRegister: SMAppService.Status = .enabled
        var statusAfterApproval: SMAppService.Status?
        var registrationError: Error?
        var events: [String] = []

        init(_ status: SMAppService.Status) { self.status = status }

        @MainActor func prepare() async throws {
            try await UninstallHelperSetup.prepareRegistration(
                status: { self.status },
                register: {
                    self.events.append("register")
                    self.status = self.statusAfterRegister
                    if let error = self.registrationError { throw error }
                },
                configurationAvailable: configurationAvailable,
                confirmEnable: {
                    self.events.append("confirmEnable")
                    return self.enableConfirmed
                },
                confirmApproval: {
                    self.events.append("confirmApproval")
                    if let status = self.statusAfterApproval { self.status = status }
                    return self.approvalConfirmed
                })
        }
    }

    private func failureCode(_ fixture: SetupFixture) async -> String? {
        do {
            try await fixture.prepare()
            XCTFail("Expected setup to stop")
            return nil
        } catch {
            guard let failure = error as? UninstallHelperFailure else {
                XCTFail("Unexpected failure type: \(type(of: error))")
                return nil
            }
            return failure.code
        }
    }

    func testValidConfigurationNotFoundRegistersAfterConfirmation() async throws {
        let fixture = SetupFixture(.notFound)
        XCTAssertEqual(UninstallHelperSetup.presentationState(status: .notFound, configurationAvailable: true), .notRegistered)
        try await fixture.prepare()
        XCTAssertEqual(fixture.status, .enabled)
        XCTAssertEqual(fixture.events, ["confirmEnable", "register"])
    }

    func testNotRegisteredUsesSameConfirmedRegistrationFlow() async throws {
        let fixture = SetupFixture(.notRegistered)
        try await fixture.prepare()
        XCTAssertEqual(fixture.status, .enabled)
        XCTAssertEqual(fixture.events, ["confirmEnable", "register"])
    }

    func testEnableCancellationNeverRegisters() async {
        for status in [SMAppService.Status.notFound, .notRegistered] {
            let fixture = SetupFixture(status)
            fixture.enableConfirmed = false
            let code = await failureCode(fixture)
            XCTAssertEqual(code, "uninstall_authorization_cancelled")
            XCTAssertEqual(fixture.status, status)
            XCTAssertEqual(fixture.events, ["confirmEnable"])
        }
    }

    func testMissingConfigurationRejectsEveryStatusWithoutPromptOrRegistration() async {
        for status in [SMAppService.Status.notFound, .notRegistered, .requiresApproval, .enabled] {
            let fixture = SetupFixture(status)
            fixture.configurationAvailable = false
            XCTAssertEqual(UninstallHelperSetup.presentationState(status: status, configurationAvailable: false), .unavailable)
            let code = await failureCode(fixture)
            XCTAssertEqual(code, "uninstall_helper_configuration_missing")
            XCTAssertTrue(fixture.events.isEmpty)
        }
    }

    func testApprovalCancellationNeverRegistersOrContinues() async {
        let fixture = SetupFixture(.requiresApproval)
        fixture.approvalConfirmed = false
        let code = await failureCode(fixture)
        XCTAssertEqual(code, "uninstall_authorization_cancelled")
        XCTAssertEqual(fixture.events, ["confirmApproval"])
    }

    func testApprovalConfirmationWithoutEnabledStatusStillStops() async {
        let fixture = SetupFixture(.requiresApproval)
        let code = await failureCode(fixture)
        XCTAssertEqual(code, "uninstall_helper_approval_required")
        XCTAssertEqual(fixture.events, ["confirmApproval"])
    }

    func testApprovalCanEnableExistingRegistrationWithoutRegisteringAgain() async throws {
        let fixture = SetupFixture(.requiresApproval)
        fixture.statusAfterApproval = .enabled
        try await fixture.prepare()
        XCTAssertEqual(fixture.events, ["confirmApproval"])
        XCTAssertEqual(fixture.status, .enabled)
    }

    func testNewRegistrationRequiringApprovalWaitsForEnabledStatus() async throws {
        let fixture = SetupFixture(.notFound)
        fixture.statusAfterRegister = .requiresApproval
        fixture.statusAfterApproval = .enabled
        try await fixture.prepare()
        XCTAssertEqual(fixture.events, ["confirmEnable", "register", "confirmApproval"])
    }

    func testRegistrationErrorWithEnabledStatusDoesNotReportGenericFailure() async throws {
        let fixture = SetupFixture(.notFound)
        fixture.registrationError = NSError(domain: "fixture.registration", code: 1)
        try await fixture.prepare()
        XCTAssertEqual(fixture.events, ["confirmEnable", "register"])
    }

    func testRegistrationErrorWithApprovalStatusUsesApprovalFlow() async throws {
        let fixture = SetupFixture(.notRegistered)
        fixture.registrationError = NSError(domain: "fixture.registration", code: 1)
        fixture.statusAfterRegister = .requiresApproval
        fixture.statusAfterApproval = .enabled
        try await fixture.prepare()
        XCTAssertEqual(fixture.events, ["confirmEnable", "register", "confirmApproval"])
    }

    func testRegistrationErrorWithUnapprovedStatusDoesNotContinue() async {
        let fixture = SetupFixture(.notFound)
        fixture.registrationError = NSError(domain: "fixture.registration", code: 1)
        fixture.statusAfterRegister = .requiresApproval
        let code = await failureCode(fixture)
        XCTAssertEqual(code, "uninstall_helper_approval_required")
        XCTAssertEqual(fixture.events, ["confirmEnable", "register", "confirmApproval"])
    }

    func testRegistrationErrorWithNotFoundStatusFailsWithoutApprovalPrompt() async {
        let fixture = SetupFixture(.notFound)
        fixture.registrationError = NSError(domain: "fixture.registration", code: 1)
        fixture.statusAfterRegister = .notFound
        let code = await failureCode(fixture)
        XCTAssertEqual(code, "uninstall_helper_registration_failed")
        XCTAssertEqual(fixture.events, ["confirmEnable", "register"])
    }

    func testRegistrationMustActuallyReachEnabledOrApprovalState() async {
        let fixture = SetupFixture(.notRegistered)
        fixture.statusAfterRegister = .notRegistered
        let code = await failureCode(fixture)
        XCTAssertEqual(code, "uninstall_helper_registration_failed")
        XCTAssertEqual(fixture.events, ["confirmEnable", "register"])
    }

    func testEnabledStateDoesNotPromptOrRegisterAgain() async throws {
        let fixture = SetupFixture(.enabled)
        try await fixture.prepare()
        XCTAssertTrue(fixture.events.isEmpty)
        XCTAssertEqual(UninstallHelperSetup.presentationState(status: .enabled, configurationAvailable: true), .enabled)
        XCTAssertEqual(UninstallHelperSetup.presentationState(status: .requiresApproval, configurationAvailable: true), .requiresApproval)
        XCTAssertEqual(UninstallHelperSetup.presentationState(status: .notRegistered, configurationAvailable: true), .notRegistered)
    }

    private struct BundleFixture {
        let serviceName = "com.macdefier.app.uninstall-helper"
        let root: URL
        let bundle: URL
        let definition: URL
        let executable: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("UninstallHelperSetup-\(UUID().uuidString)")
            bundle = root.appendingPathComponent("Fixture.app")
            definition = bundle.appendingPathComponent("Contents/Library/LaunchDaemons/\(serviceName).plist")
            executable = bundle.appendingPathComponent("Contents/MacOS/MacDefier-UninstallHelper")
            try FileManager.default.createDirectory(at: definition.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Inert data with an executable bit: configuration checks never run it.
            try Data("fixture-only; never execute\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            try writeDefinition()
        }

        func writeDefinition(_ mutate: (inout [String: Any]) -> Void = { _ in }) throws {
            var plist: [String: Any] = [
                "Label": serviceName,
                "BundleProgram": "Contents/MacOS/MacDefier-UninstallHelper",
                "MachServices": [serviceName: true]
            ]
            mutate(&plist)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: definition)
        }

        @MainActor var isAvailable: Bool {
            UninstallHelperSetup.configurationAvailable(serviceName: serviceName, bundleURL: bundle)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    func testSyntheticBundledConfigurationIsAvailable() throws {
        let fixture = try BundleFixture()
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.isAvailable)
    }

    func testMissingPlistIsUnavailable() throws {
        let fixture = try BundleFixture()
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.isAvailable)
        try FileManager.default.removeItem(at: fixture.definition)
        XCTAssertFalse(fixture.isAvailable)
    }

    func testMissingExecutableIsUnavailable() throws {
        let fixture = try BundleFixture()
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.isAvailable)
        try FileManager.default.removeItem(at: fixture.executable)
        XCTAssertFalse(fixture.isAvailable)
    }

    func testExecutableWithoutExecutePermissionIsUnavailable() throws {
        let fixture = try BundleFixture()
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.isAvailable)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.executable.path)
        XCTAssertFalse(fixture.isAvailable)
    }

    func testWrongLabelMachServiceOrBundleProgramIsUnavailable() throws {
        let fixture = try BundleFixture()
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.isAvailable)
        let invalid: [[String: Any]] = [
            ["Label": "com.example.foreign"],
            ["MachServices": ["com.example.foreign": true]],
            ["MachServices": [fixture.serviceName: false]],
            ["MachServices": [fixture.serviceName: true, "com.example.extra": true]],
            ["BundleProgram": "Contents/MacOS/OtherHelper"]
        ]
        for replacements in invalid {
            try fixture.writeDefinition { $0.merge(replacements) { _, new in new } }
            XCTAssertFalse(fixture.isAvailable, "Accepted invalid fields: \(replacements.keys.sorted())")
        }
    }

    func testProgramAndProgramArgumentsOverridesAreUnavailable() throws {
        let fixture = try BundleFixture()
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.isAvailable)
        try fixture.writeDefinition { $0["Program"] = "/bin/true" }
        XCTAssertFalse(fixture.isAvailable)
        try fixture.writeDefinition { $0["ProgramArguments"] = ["/bin/true"] }
        XCTAssertFalse(fixture.isAvailable)
    }

    func testMalformedPlistIsUnavailable() throws {
        let fixture = try BundleFixture()
        defer { fixture.cleanUp() }
        try Data("not a property list".utf8).write(to: fixture.definition)
        XCTAssertFalse(fixture.isAvailable)
    }

    func testSymlinkedDefinitionOrExecutableIsUnavailable() throws {
        for isDefinition in [true, false] {
            let fixture = try BundleFixture()
            defer { fixture.cleanUp() }
            XCTAssertTrue(fixture.isAvailable)
            let original = isDefinition ? fixture.definition : fixture.executable
            let moved = fixture.root.appendingPathComponent("original-file")
            try FileManager.default.moveItem(at: original, to: moved)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: moved)
            XCTAssertFalse(fixture.isAvailable)
        }
    }

    func testSymlinkedConfigurationParentIsUnavailable() throws {
        let fixture = try BundleFixture()
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.isAvailable)
        let original = fixture.definition.deletingLastPathComponent()
        let moved = fixture.root.appendingPathComponent("MovedLaunchDaemons")
        try FileManager.default.moveItem(at: original, to: moved)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: moved)
        XCTAssertFalse(fixture.isAvailable)
    }
}
