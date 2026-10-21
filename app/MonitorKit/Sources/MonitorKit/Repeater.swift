// Adapted from Stats Kit/plugins/Repeater.swift (MIT) — Copyright (c) 2022 Serhiy Mytrovtsiy.
// Queue label uses com.macdefier (not eu.exelban).

import Foundation

public final class Repeater {
    private enum State {
        case paused
        case running
    }

    private var callback: () -> Void
    private var state: State = .paused
    private var timer: DispatchSourceTimer
    /// start/pause/reset 并发时保护 state，防 dispatch_resume/suspend 失衡 abort
    private let stateLock = NSLock()

    public init(seconds: Int, queueLabel: String = "com.macdefier.MonitorKit.Repeater", callback: @escaping () -> Void) {
        self.callback = callback
        self.timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: queueLabel, qos: .utility))
        setupTimer(seconds)
    }

    deinit {
        timer.setEventHandler {}
        timer.cancel()
        stateLock.lock()
        let wasPaused = state == .paused
        stateLock.unlock()
        if wasPaused {
            timer.resume()
        }
    }

    private func setupTimer(_ interval: Int) {
        let seconds = max(1, interval)
        timer.schedule(
            deadline: .now() + Double(seconds),
            repeating: .seconds(seconds),
            leeway: .milliseconds(200)
        )
        timer.setEventHandler { [weak self] in
            self?.callback()
        }
    }

    public func start() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard state == .paused else { return }
        state = .running
        timer.resume()
    }

    public func pause() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard state == .running else { return }
        state = .paused
        timer.suspend()
    }

    public func reset(seconds: Int, restart: Bool = false) {
        if state == .running {
            pause()
        }
        setupTimer(seconds)
        if restart {
            callback()
            start()
        }
    }
}
