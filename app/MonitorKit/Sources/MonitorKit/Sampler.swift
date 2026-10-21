// Thin Reader replacement for Stats Kit/module/reader.swift.
// No Store / DB / SystemStats / ModuleType — only interval + callback.

import Foundation

public protocol Sampling: AnyObject {
    func setup()
    func read()
    func start()
    func pause()
    func stop()
    func setInterval(_ seconds: Int)
}

open class Sampler<T>: Sampling {
    public private(set) var value: T?
    public var interval: Int
    public var callback: (T?) -> Void
    /// Consumers that enqueue delivery must recheck this generation before applying it.
    public var publicationCallback: ((T?, UInt64, Date) -> Void)?

    private var repeater: Repeater?
    private var running = false
    private var generation: UInt64 = 0
    private var readInFlight = false
    private var readPending = false
    private var validPublishGeneration: UInt64?
    /// Accessed only by the serial sampling queue.
    private var lastReadGeneration: UInt64?
    /// start/pause/stop 并发保护（public API，未来可能非主线程调用）
    private let stateLock = NSLock()
    /// 采样串行队列；子类可用它把外部调用（如 clearIPHistory）编组到采样上下文
    let queue: DispatchQueue

    public init(
        interval: Int = 1,
        queueLabel: String = "com.macdefier.MonitorKit.Sampler",
        callback: @escaping (T?) -> Void = { _ in }
    ) {
        self.interval = max(1, interval)
        self.callback = callback
        self.queue = DispatchQueue(label: queueLabel, qos: .utility)
        setup()
    }

    open func setup() {}
    open func read() {}
    /// Called on the sampling queue before the first read of every start/resume generation.
    open func samplingDidStart() {}

    /// Subclasses with a blocking read (for example `Process`) should interrupt it here.
    open func cancelCurrentRead() {}

    public func publish(_ newValue: T?) {
        stateLock.lock()
        // Explicit queue operations may publish without an active sample. A sample result is
        // accepted only while its generation is still current, so stop/restart cannot leak a tail result.
        let shouldPublish = running && (validPublishGeneration.map { $0 == generation } ?? true)
        let publicationGeneration = generation
        let sampledAt = Date()
        stateLock.unlock()
        guard shouldPublish else { return }
        value = newValue
        callback(newValue)
        publicationCallback?(newValue, publicationGeneration, sampledAt)
    }

    public final func isPublicationCurrent(_ publicationGeneration: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running && generation == publicationGeneration
    }

    public func start() {
        stateLock.lock()
        guard !running else {
            stateLock.unlock()
            return
        }
        running = true
        generation &+= 1
        let currentRepeater: Repeater
        if let repeater {
            currentRepeater = repeater
        } else {
            let created = Repeater(seconds: interval) { [weak self] in
                self?.requestRead()
            }
            repeater = created
            currentRepeater = created
        }
        stateLock.unlock()

        requestRead()
        currentRepeater.start()
    }

    public func pause() {
        stateLock.lock()
        guard running else {
            stateLock.unlock()
            return
        }
        running = false
        generation &+= 1
        readPending = false
        let currentRepeater = repeater
        stateLock.unlock()

        currentRepeater?.pause()
        cancelCurrentRead()
    }

    public func stop() {
        stateLock.lock()
        running = false
        generation &+= 1
        readPending = false
        let currentRepeater = repeater
        repeater = nil
        stateLock.unlock()

        currentRepeater?.pause()
        cancelCurrentRead()
    }

    public func setInterval(_ seconds: Int) {
        stateLock.lock()
        let nextInterval = max(1, seconds)
        guard interval != nextInterval else {
            stateLock.unlock()
            return
        }
        interval = nextInterval
        let shouldRestart = running
        let oldRepeater = repeater
        let replacement = Repeater(seconds: nextInterval) { [weak self] in
            self?.requestRead()
        }
        repeater = replacement
        stateLock.unlock()

        oldRepeater?.pause()
        if shouldRestart {
            replacement.start()
        }
    }

    /// Internal so MonitorKit tests can exercise coalescing without waiting for a real timer tick.
    func requestRead() {
        stateLock.lock()
        guard running else {
            stateLock.unlock()
            return
        }
        if readInFlight {
            readPending = true
            stateLock.unlock()
            return
        }
        readInFlight = true
        let readGeneration = generation
        stateLock.unlock()

        enqueueRead(generation: readGeneration)
    }

    /// Blocking subclasses can poll this immediately before and after launching external work.
    public final var shouldContinueCurrentRead: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let validPublishGeneration else { return running }
        return running && validPublishGeneration == generation
    }

    private func enqueueRead(generation readGeneration: UInt64) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let shouldRead = self.running && self.generation == readGeneration
            self.validPublishGeneration = shouldRead ? readGeneration : nil
            self.stateLock.unlock()

            if shouldRead {
                if self.lastReadGeneration != readGeneration {
                    self.samplingDidStart()
                    self.lastReadGeneration = readGeneration
                }
                self.read()
            }

            self.stateLock.lock()
            self.validPublishGeneration = nil
            self.readInFlight = false
            let runPending = self.running && self.readPending
            self.readPending = false
            if runPending {
                self.readInFlight = true
            }
            let nextGeneration = self.generation
            self.stateLock.unlock()

            if runPending {
                self.enqueueRead(generation: nextGeneration)
            }
        }
    }
}
