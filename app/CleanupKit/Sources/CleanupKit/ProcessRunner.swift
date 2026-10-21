import Darwin
import Foundation

public struct ProcessRunResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public let timedOut: Bool
    public let wasCancelled: Bool

    /// Truncated output must never be treated as a complete inventory.
    public let outputLimitExceeded: Bool

    public var succeeded: Bool {
        exitCode == 0 && !timedOut && !wasCancelled && !outputLimitExceeded
    }

    public var stdoutString: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    public var stderrString: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }
}

public enum ProcessRunnerError: LocalizedError, Equatable {
    case emptyCommand
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyCommand:
            return "没有可执行命令"
        case .launchFailed(let message):
            return "无法启动子进程：\(message)"
        }
    }
}

/// Uses a private process group when possible and a libproc descendant walk otherwise.
public struct ProcessOutputLimits: Sendable {
    public let stdoutBytes: Int
    public let stderrBytes: Int

    public init(stdoutBytes: Int = 8 * 1024 * 1024, stderrBytes: Int = 1024 * 1024) {
        self.stdoutBytes = max(0, stdoutBytes)
        self.stderrBytes = max(0, stderrBytes)
    }
}

public enum ProcessRunner {
    private static let pollNanoseconds: UInt64 = 20_000_000
    private static let terminateGraceNanoseconds: UInt64 = 500_000_000

    public static func run(
        _ command: [String],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        timeout: TimeInterval,
        outputLimits: ProcessOutputLimits = ProcessOutputLimits()
    ) async throws -> ProcessRunResult {
        guard let executable = command.first, !executable.isEmpty else {
            throw ProcessRunnerError.emptyCommand
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let stderrFD = stderrPipe.fileHandleForReading.fileDescriptor
        guard makeNonBlocking(stdoutFD), makeNonBlocking(stderrFD) else {
            throw ProcessRunnerError.launchFailed("无法配置输出管道")
        }

        do {
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }
        // The child owns duplicated write descriptors. Closing the parent's copies
        // lets EOF reflect the whole child process tree rather than this Process object.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        // Moving the child after launch can race exec; detect failure and fall back to
        // an explicit libproc descendant walk instead of assuming group ownership.
        let pid = process.processIdentifier
        let ownsProcessGroup = setpgid(pid, pid) == 0 || getpgid(pid) == pid
        let startedAt = ContinuousClock.now
        let limit = Duration.nanoseconds(Int64(max(timeout, 0) * 1_000_000_000))
        var timedOut = false
        var wasCancelled = false
        var stdout = Data()
        var stderr = Data()
        var outputLimitExceeded = false
        var stdoutEOF = false
        var stderrEOF = false

        while true {
            if !stdoutEOF { stdoutEOF = drainAvailable(stdoutFD, into: &stdout, limit: outputLimits.stdoutBytes, exceeded: &outputLimitExceeded) }
            if !stderrEOF { stderrEOF = drainAvailable(stderrFD, into: &stderr, limit: outputLimits.stderrBytes, exceeded: &outputLimitExceeded) }
            if !process.isRunning, stdoutEOF, stderrEOF { break }
            if Task.isCancelled {
                wasCancelled = true
                await stopProcessTree(process, pid: pid, ownsProcessGroup: ownsProcessGroup)
                break
            }
            if startedAt.duration(to: .now) >= limit {
                timedOut = true
                await stopProcessTree(process, pid: pid, ownsProcessGroup: ownsProcessGroup)
                break
            }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }

        if timedOut || wasCancelled {
            let drainDeadline = ContinuousClock.now.advanced(by: .nanoseconds(Int64(terminateGraceNanoseconds)))
            while ContinuousClock.now < drainDeadline, !stdoutEOF || !stderrEOF {
                if !stdoutEOF { stdoutEOF = drainAvailable(stdoutFD, into: &stdout, limit: outputLimits.stdoutBytes, exceeded: &outputLimitExceeded) }
                if !stderrEOF { stderrEOF = drainAvailable(stderrFD, into: &stderr, limit: outputLimits.stderrBytes, exceeded: &outputLimitExceeded) }
                if stdoutEOF, stderrEOF { break }
                try? await Task.sleep(nanoseconds: pollNanoseconds)
            }
        }
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        // isRunning is already false after Foundation observes termination.
        // waitUntilExit spins a thread-bound run loop and can hang after this
        // async task resumes on another worker, outside our timeout/cancel loop.
        return ProcessRunResult(
            exitCode: process.isRunning ? -1 : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut,
            wasCancelled: wasCancelled,
            outputLimitExceeded: outputLimitExceeded
        )
    }

    /// Synchronous adapter for legacy inventory code. Output is still drained concurrently
    /// and timeout kills the whole command group, so callers cannot deadlock on full pipes.
    public static func runSync(
        _ command: [String],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        timeout: TimeInterval,
        outputLimits: ProcessOutputLimits = ProcessOutputLimits(),
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> ProcessRunResult {
        guard let executable = command.first, !executable.isEmpty else {
            throw ProcessRunnerError.emptyCommand
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let stderrFD = stderrPipe.fileHandleForReading.fileDescriptor
        guard makeNonBlocking(stdoutFD), makeNonBlocking(stderrFD) else {
            throw ProcessRunnerError.launchFailed("无法配置输出管道")
        }
        var stdout = Data()
        var stderr = Data()

        do {
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        let pid = process.processIdentifier
        let ownsProcessGroup = setpgid(pid, pid) == 0 || getpgid(pid) == pid
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        var timedOut = false
        var wasCancelled = false
        var outputLimitExceeded = false
        var stdoutEOF = false
        var stderrEOF = false
        while true {
            if !stdoutEOF { stdoutEOF = drainAvailable(stdoutFD, into: &stdout, limit: outputLimits.stdoutBytes, exceeded: &outputLimitExceeded) }
            if !stderrEOF { stderrEOF = drainAvailable(stderrFD, into: &stderr, limit: outputLimits.stderrBytes, exceeded: &outputLimitExceeded) }
            if !process.isRunning, stdoutEOF, stderrEOF { break }
            if isCancelled() {
                wasCancelled = true
                stopProcessTreeSync(process, pid: pid, ownsProcessGroup: ownsProcessGroup)
                break
            }
            if Date() >= deadline {
                timedOut = true
                stopProcessTreeSync(process, pid: pid, ownsProcessGroup: ownsProcessGroup)
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        if timedOut || wasCancelled {
            let drainDeadline = Date().addingTimeInterval(0.5)
            while Date() < drainDeadline, !stdoutEOF || !stderrEOF {
                if !stdoutEOF { stdoutEOF = drainAvailable(stdoutFD, into: &stdout, limit: outputLimits.stdoutBytes, exceeded: &outputLimitExceeded) }
                if !stderrEOF { stderrEOF = drainAvailable(stderrFD, into: &stderr, limit: outputLimits.stderrBytes, exceeded: &outputLimitExceeded) }
                if stdoutEOF, stderrEOF { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        // Do not add an unbounded wait after the bounded polling/draining loop.
        return ProcessRunResult(
            exitCode: process.isRunning ? -1 : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut,
            wasCancelled: wasCancelled,
            outputLimitExceeded: outputLimitExceeded
        )
    }

    private static func stopProcessTree(
        _ process: Process,
        pid: pid_t,
        ownsProcessGroup: Bool
    ) async {
        if ownsProcessGroup {
            _ = kill(-pid, SIGTERM)
        } else if process.isRunning {
            signalDescendants(of: pid, signal: SIGTERM)
        }
        if process.isRunning { process.terminate() }

        let deadline = ContinuousClock.now.advanced(by: .nanoseconds(Int64(terminateGraceNanoseconds)))
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
        if ownsProcessGroup {
            _ = kill(-pid, SIGKILL)
        } else if process.isRunning {
                signalDescendants(of: pid, signal: SIGKILL)
            _ = kill(pid, SIGKILL)
        }
    }

    private static func stopProcessTreeSync(
        _ process: Process,
        pid: pid_t,
        ownsProcessGroup: Bool
    ) {
        if ownsProcessGroup {
            _ = kill(-pid, SIGTERM)
        } else if process.isRunning {
            signalDescendants(of: pid, signal: SIGTERM)
        }
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if ownsProcessGroup {
            _ = kill(-pid, SIGKILL)
        } else if process.isRunning {
                signalDescendants(of: pid, signal: SIGKILL)
            _ = kill(pid, SIGKILL)
        }
    }

    private static func makeNonBlocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0 else { return false }
        return fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    /// Drain a non-blocking descriptor on the calling task. Returns true on EOF
    /// or a terminal read error. No other thread owns or closes this descriptor.
    private static func drainAvailable(_ descriptor: Int32, into output: inout Data, limit: Int, exceeded: inout Bool) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        // Bound each pass so a command that writes continuously cannot starve
        // the timeout/cancellation checks in the outer loop.
        for _ in 0..<16 {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, raw.count)
            }
            if count > 0 {
                let retained = min(Int(count), max(0, limit - output.count))
                output.append(contentsOf: buffer.prefix(retained))
                if retained < count { exceeded = true }
                // Continue draining discarded bytes so a noisy child cannot fill
                // the pipe and prevent its own exit or our cancellation checks.
                continue
            }
            if count == 0 { return true }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return false }
            return true
        }
        return false
    }

    private static func signalDescendants(of parent: pid_t, signal: Int32) {
        var capacity = max(proc_listchildpids(parent, nil, 0), 0)
        guard capacity > 0 else { return }
        var children = [pid_t](repeating: 0, count: Int(capacity) / MemoryLayout<pid_t>.stride + 1)
        capacity = children.withUnsafeMutableBytes { buffer in
            proc_listchildpids(parent, buffer.baseAddress, Int32(buffer.count))
        }
        let count = max(0, Int(capacity) / MemoryLayout<pid_t>.stride)
        for child in children.prefix(count) where child > 0 {
            signalDescendants(of: child, signal: signal)
            _ = kill(child, signal)
        }
    }
}
