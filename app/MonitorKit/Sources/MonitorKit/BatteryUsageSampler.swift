import Foundation
import IOKit.ps

/// Read-only access to the public IOPowerSources snapshot API.
public final class BatteryUsageSampler: Sampler<BatteryInfo> {
    public override func read() {
        guard var value = Self.readBattery() else {
            publish(nil)
            return
        }
        value.freshnessLimit = max(15, Double(interval) * 2)
        publish(value)
    }

    typealias SourceReader = () -> [[String: Any]]?

    /// A nil snapshot is a read failure; a successful snapshot without an internal
    /// battery is an explicitly absent battery. Missing fields remain unknown.
    static func readBattery(
        using read: SourceReader = readPowerSources,
        sampledAt: Date = Date()
    ) -> BatteryInfo? {
        parsePowerSources(read(), sampledAt: sampledAt)
    }

    private static func readPowerSources() -> [[String: Any]]? {
        // Copy results are owned; Get results are borrowed from `info`.
        guard let copiedInfo = IOPSCopyPowerSourcesInfo() else { return nil }
        let info = copiedInfo.takeRetainedValue()
        guard let copiedSources = IOPSCopyPowerSourcesList(info) else { return nil }
        let sources = copiedSources.takeRetainedValue()
        var descriptions: [[String: Any]] = []
        for index in 0..<CFArrayGetCount(sources) {
            guard let rawSource = CFArrayGetValueAtIndex(sources, index) else { return nil }
            let source = Unmanaged<AnyObject>.fromOpaque(rawSource).takeUnretainedValue()
            guard let borrowedDescription = IOPSGetPowerSourceDescription(info, source),
                  let description = borrowedDescription.takeUnretainedValue() as? [String: Any] else {
                return nil
            }
            descriptions.append(description)
        }
        return descriptions
    }

    /// Pure dictionary parsing seam. Tests never need an actual battery or IOKit read.
    static func parsePowerSources(
        _ descriptions: [[String: Any]]?,
        sampledAt: Date = Date()
    ) -> BatteryInfo? {
        guard let descriptions else { return nil }
        var presentBatteries: [[String: Any]] = []
        for description in descriptions {
            // Only the two source types documented in IOPSKeys.h establish whether
            // an internal battery exists. An untyped/unknown source is not absence.
            guard let type = description[kIOPSTypeKey] as? String else { return nil }
            switch type {
            case kIOPSInternalBatteryType:
                guard let isPresent = boolean(description[kIOPSIsPresentKey]) else { return nil }
                if isPresent { presentBatteries.append(description) }
            case kIOPSUPSType:
                continue
            default:
                return nil
            }
        }
        guard !presentBatteries.isEmpty else {
            return BatteryInfo(isPresent: false, sampledAt: sampledAt)
        }
        // The model describes a single internal battery. Do not silently select one
        // pack or average capacities that may be expressed in different units.
        guard presentBatteries.count == 1, let battery = presentBatteries.first else { return nil }

        let current = nonnegativeInteger(battery[kIOPSCurrentCapacityKey])
        let maximum = nonnegativeInteger(battery[kIOPSMaxCapacityKey])
        let charge: Double?
        if let current, let maximum, maximum > 0, current <= maximum {
            charge = Double(current) / Double(maximum)
        } else {
            charge = nil
        }
        let isCharging = boolean(battery[kIOPSIsChargingKey])
        let isOnACPower: Bool?
        switch battery[kIOPSPowerSourceStateKey] as? String {
        case kIOPSACPowerValue: isOnACPower = true
        case kIOPSBatteryPowerValue: isOnACPower = false
        default: isOnACPower = nil
        }

        // IOPSKeys.h defines validity as well as minute units. In particular,
        // calculating (-1), unavailable, and an irrelevant estimate are not zero.
        let timeToEmpty = isOnACPower == false && isCharging == false
            ? nonnegativeInteger(battery[kIOPSTimeToEmptyKey]) : nil
        let timeToFull = isCharging == true
            ? nonnegativeInteger(battery[kIOPSTimeToFullChargeKey]) : nil
        return BatteryInfo(
            isPresent: true,
            charge: charge,
            isCharging: isCharging,
            isOnACPower: isOnACPower,
            timeToEmptyMinutes: timeToEmpty,
            timeToFullMinutes: timeToFull,
            sampledAt: sampledAt
        )
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func nonnegativeInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID(),
              let integer = Int(exactly: number.doubleValue), integer >= 0 else { return nil }
        return integer
    }
}
