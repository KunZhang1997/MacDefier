import Combine
import Foundation

enum UsageGuideStep: Int, CaseIterable {
    case welcome, scan, review, setup, ready
}

/// Owns guide progress only; presenting or leaving the guide never changes app work.
@MainActor
final class UsageGuideState: ObservableObject {
    static let shared = UsageGuideState(
        defaults: .standard,
        installationIdentity: currentInstallationIdentity()
    )

    private enum Keys {
        static let step = "macdefier.usageGuide.v1.step"
        static let seen = "macdefier.usageGuide.v1.seen"
        static let installationIdentity = "macdefier.usageGuide.v1.installationIdentity"
    }

    @Published private(set) var step: UsageGuideStep
    @Published private(set) var isPresented: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults, installationIdentity: String?) {
        self.defaults = defaults
        // A missing file identity must not make every launch look like a reinstall.
        if let installationIdentity,
           defaults.string(forKey: Keys.installationIdentity) != installationIdentity {
            defaults.removeObject(forKey: Keys.step)
            defaults.removeObject(forKey: Keys.seen)
            defaults.set(installationIdentity, forKey: Keys.installationIdentity)
        }
        let savedStep = defaults.object(forKey: Keys.step) as? Int ?? UsageGuideStep.welcome.rawValue
        let boundedStep = min(max(savedStep, UsageGuideStep.welcome.rawValue), UsageGuideStep.ready.rawValue)
        step = UsageGuideStep(rawValue: boundedStep) ?? .welcome
        isPresented = !defaults.bool(forKey: Keys.seen)
        defaults.set(step.rawValue, forKey: Keys.step)
    }

    func next() {
        guard isPresented else { return }
        guard let next = UsageGuideStep(rawValue: step.rawValue + 1) else {
            dismiss()
            return
        }
        setStep(next)
    }

    func back() {
        guard isPresented, let previous = UsageGuideStep(rawValue: step.rawValue - 1) else { return }
        setStep(previous)
    }

    func dismiss() {
        defaults.set(true, forKey: Keys.seen)
        isPresented = false
    }

    func replay() {
        setStep(.welcome)
        defaults.set(false, forKey: Keys.seen)
        isPresented = true
    }

    private func setStep(_ step: UsageGuideStep) {
        self.step = step
        defaults.set(step.rawValue, forKey: Keys.step)
    }

    /// Replacing the executable changes this identity; ordinary launches do not.
    private static func currentInstallationIdentity() -> String? {
        guard let executable = Bundle.main.executableURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return "\(device.stringValue):\(inode.stringValue):\(modified.timeIntervalSince1970.bitPattern)"
    }
}
