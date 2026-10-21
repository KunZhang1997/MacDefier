// SensorsSampler — bounded read-only SMC temperatures and fan RPM (no control).

import Foundation

public final class SensorsSampler: Sampler<[SensorReading]> {
    private let availabilityLock = NSLock()
    private var available = false

    /// AppleSMC transport availability, not a promise that every metric exists.
    /// Empty readings remain unavailable to consumers even with an open transport.
    public var isAvailable: Bool {
        availabilityLock.lock()
        defer { availabilityLock.unlock() }
        return available
    }

    public override func read() {
        // Hardware IO runs on the sampling queue, never in the initializer's setup.
        let sample = MinimalSMC.sample()
        availabilityLock.lock()
        available = sample.isAvailable
        availabilityLock.unlock()
        publish(sample.readings)
    }
}
