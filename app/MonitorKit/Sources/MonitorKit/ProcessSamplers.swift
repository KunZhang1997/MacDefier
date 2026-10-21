// Adapted from Stats Modules/CPU/readers.swift ProcessReader (MIT)
// Copyright (c) 2019 Serhiy Mytrovtsiy.
// Store process count → constructor param.

import AppKit
import Darwin
import Foundation

private final class ProcessOutputBox: @unchecked Sendable {
    let lock = NSLock()
    var data: Data?
}

public final class CPUProcessSampler: Sampler<[TopProcess]> {
    public var limit: Int
    private let processLock = NSLock()
    private var currentProcess: Process?

    public init(limit: Int = 8, interval: Int = 2, callback: @escaping ([TopProcess]?) -> Void = { _ in }) {
        self.limit = limit
        super.init(interval: interval, queueLabel: "com.macdefier.MonitorKit.CPUProcess", callback: callback)
    }

    public override func read() {
        guard limit > 0 else {
            publish([])
            return
        }

        let startedAt = Date().timeIntervalSince1970
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Aceo", "pid,pcpu,comm", "-r"]

        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        // stderr 不读：直接丢弃，防双向管道写满死锁
        task.standardError = FileHandle.nullDevice

        do {
            guard shouldContinueCurrentRead else { return }
            setCurrentProcess(task)
            try task.run()
        } catch {
            clearCurrentProcess(task)
            publish(nil)
            return
        }

        let outputData = readProcessOutput(
            from: outputPipe.fileHandleForReading,
            process: task,
            timeout: 3
        )
        clearCurrentProcess(task)
        guard shouldContinueCurrentRead else { return }
        guard let outputData else { publish(nil); return }
        guard let output = String(data: outputData, encoding: .utf8), !output.isEmpty else {
            publish(nil)
            return
        }

        var index = 0
        var processes: [TopProcess] = []
        output.enumerateLines { line, stop in
            if index != 0 {
                let str = line.trimmingCharacters(in: .whitespaces)
                let parts = str.split(whereSeparator: { $0.isWhitespace })
                guard parts.count >= 3,
                      let pid = Int(parts[0]),
                      let usage = Double(parts[1].replacingOccurrences(of: ",", with: "."))
                else {
                    index += 1
                    return
                }
                let command = parts.dropFirst(2).joined(separator: " ")
                var name = command
                if let app = NSRunningApplication(processIdentifier: pid_t(pid)), let n = app.localizedName {
                    name = n
                }
                if command.contains("com.apple.Virtua"), name.contains("Docker") {
                    name = "Docker"
                }
                let identity = pid_t(exactly: pid).flatMap { MonitoredProcessIdentity.read(pid: $0) }
                // A process born after ps/top began cannot own this earlier row.
                guard identity.map({ Double($0.startSeconds) + Double($0.startMicroseconds) / 1_000_000 <= startedAt }) ?? true else { return }
                processes.append(TopProcess(pid: pid, name: name, usage: usage, identity: identity))
                if processes.count >= self.limit {
                    stop = true
                }
            }
            index += 1
        }
        publish(processes)
    }

    public override func cancelCurrentRead() {
        processLock.lock()
        let process = currentProcess
        processLock.unlock()
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    private func setCurrentProcess(_ process: Process) {
        processLock.lock()
        currentProcess = process
        processLock.unlock()
    }

    private func clearCurrentProcess(_ process: Process) {
        processLock.lock()
        if currentProcess === process { currentProcess = nil }
        processLock.unlock()
    }
}

public final class RAMProcessSampler: Sampler<[TopProcess]> {
    public var limit: Int
    private let processLock = NSLock()
    private var currentProcess: Process?

    public init(limit: Int = 8, interval: Int = 3, callback: @escaping ([TopProcess]?) -> Void = { _ in }) {
        self.limit = limit
        super.init(interval: interval, queueLabel: "com.macdefier.MonitorKit.RAMProcess", callback: callback)
    }

    public override func read() {
        guard limit > 0 else {
            publish([])
            return
        }

        let startedAt = Date().timeIntervalSince1970
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        task.arguments = ["-l", "1", "-o", "mem", "-n", "\(limit)", "-stats", "pid,command,mem"]

        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        // stderr 不读：直接丢弃，防双向管道写满死锁
        task.standardError = FileHandle.nullDevice

        do {
            guard shouldContinueCurrentRead else { return }
            setCurrentProcess(task)
            try task.run()
        } catch {
            clearCurrentProcess(task)
            publish(nil)
            return
        }

        let outputData = readProcessOutput(
            from: outputPipe.fileHandleForReading,
            process: task,
            timeout: 4
        )
        clearCurrentProcess(task)
        guard shouldContinueCurrentRead else { return }
        guard let outputData else { publish(nil); return }
        guard let output = String(data: outputData, encoding: .utf8), !output.isEmpty else {
            publish(nil)
            return
        }

        var processes: [TopProcess] = []
        output.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.split(whereSeparator: { $0.isWhitespace }).first,
                  let pid = Int(first), pid > 0
            else { return }

            // top mem column like "123M" or "1G+"
            let tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard tokens.count >= 3 else { return }
            let memToken = tokens.last ?? "0"
            let usage = Self.parseMemory(memToken)
            let command = tokens.dropFirst().dropLast().joined(separator: " ")
            var name = command
            if let app = NSRunningApplication(processIdentifier: pid_t(pid)), let n = app.localizedName {
                name = n
            }
            let identity = pid_t(exactly: pid).flatMap { MonitoredProcessIdentity.read(pid: $0) }
                // A process born after ps/top began cannot own this earlier row.
                guard identity.map({ Double($0.startSeconds) + Double($0.startMicroseconds) / 1_000_000 <= startedAt }) ?? true else { return }
                processes.append(TopProcess(pid: pid, name: name, usage: usage, identity: identity))
        }
        publish(Array(processes.prefix(limit)))
    }

    public override func cancelCurrentRead() {
        processLock.lock()
        let process = currentProcess
        processLock.unlock()
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    private func setCurrentProcess(_ process: Process) {
        processLock.lock()
        currentProcess = process
        processLock.unlock()
    }

    private func clearCurrentProcess(_ process: Process) {
        processLock.lock()
        if currentProcess === process { currentProcess = nil }
        processLock.unlock()
    }

    private static func parseMemory(_ raw: String) -> Double {
        var s = raw.replacingOccurrences(of: "+", with: "").replacingOccurrences(of: "-", with: "")
        guard let last = s.last else { return 0 }
        let mult: Double
        switch last {
        case "K", "k": mult = 1024
        case "M", "m": mult = 1024 * 1024
        case "G", "g": mult = 1024 * 1024 * 1024
        default:
            return Double(s) ?? 0
        }
        s.removeLast()
        return (Double(s) ?? 0) * mult
    }
}

/// Draining concurrently prevents an unexpected amount of output from filling the pipe before exit.
func readProcessOutput(
    from handle: FileHandle,
    process: Process,
    timeout: TimeInterval
) -> Data? {
    let output = ProcessOutputBox()
    let drain = DispatchGroup()
    drain.enter()
    DispatchQueue.global(qos: .utility).async {
        defer { drain.leave() }
        // Use the throwing API and keep ownership of the handle in this closure.
        // The caller may time out and return while this read is still draining;
        // closing the handle from the caller used to raise an Objective-C
        // NSFileHandle exception here and abort the whole app.
        do {
            let data = try handle.readToEnd() ?? Data()
            output.lock.lock()
            output.data = data
            output.lock.unlock()
        } catch {
            output.lock.lock()
            output.data = nil
            output.lock.unlock()
        }
    }

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    guard !process.isRunning else {
        process.terminate()
        // EOF is independent of process exit: a child can close stdout and
        // continue running, including after ignoring SIGTERM. Always bound its
        // termination grace period and escalate based on process liveness.
        let terminationDeadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while process.isRunning, ContinuousClock.now < terminationDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        _ = drain.wait(timeout: .now() + 0.5)
        return nil
    }

    guard drain.wait(timeout: .now() + 0.5) == .success else { return nil }
    output.lock.lock()
    let result = output.data
    output.lock.unlock()
    return process.terminationStatus == 0 ? result : nil
}
