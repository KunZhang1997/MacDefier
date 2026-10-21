import CryptoKit
import Foundation

/// Reuses the existing daemon/CLI, then falls back to an app-managed runtime.
/// Version and SHA-256 use SpeakSend's pinned official macOS archive.
@MainActor
enum OllamaRuntime {
    static let version = "v0.33.1"
    static let archiveURL = URL(string: "https://github.com/ollama/ollama/releases/download/v0.33.1/ollama-darwin.tgz")!
    static let archiveSHA256 = "6c4ff73ee47b1d8971cf80df3b7db4fc4284cfcdffdfe09c014e12cd72bacf83"
    private static var daemons: [String: Process] = [:]

    static func ensureReady(endpoint: String,
                            onStage: @escaping @MainActor (OllamaModelManager.Stage) -> Void) async throws {
        let probe = try OllamaEndpoint.apiURL(endpoint, path: "tags")
        if await reachable(probe) { return }
        try Task.checkCancellation()
        // A custom endpoint belongs to its configured server; never start a
        // different default daemon and pretend it fulfilled that configuration.
        guard probe.scheme == "http", probe.port == 11_434,
              probe.path == "/api/tags" else { throw OllamaModelFailure.unavailable }
        let paths = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama",
                     "/Applications/Ollama.app/Contents/Resources/ollama"]
        let executable: URL
        if let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            executable = URL(fileURLWithPath: path)
        } else {
            onStage(.runtimeDownload)
            executable = try await installRuntime()
        }
        try Task.checkCancellation()
        onStage(.starting)
        let host = probe.host ?? "127.0.0.1"
        let address = "\(host.contains(":") ? "[\(host)]" : host):11434"
        if daemons[address]?.isRunning != true {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["serve"]
            var env = ProcessInfo.processInfo.environment
            env["OLLAMA_HOST"] = address
            env.removeValue(forKey: "OLLAMA_MODELS") // reuse the user's existing library
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() }
            catch { throw OllamaModelFailure.runtimeStart }
            daemons[address] = process
        }
        for _ in 0..<40 {
            try Task.checkCancellation()
            if await reachable(probe) { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw OllamaModelFailure.runtimeStart
    }

    static func shutdown() {
        // Only processes started by this MacDefier instance are owned here.
        for process in daemons.values where process.isRunning { process.terminate() }
        daemons.removeAll()
    }

    private static func reachable(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        // A redirect is not proof that the intended local daemon is running.
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.url == url else { return false }
        return http.statusCode == 200
    }

    private static func installRuntime() async throws -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.macdefier.app", isDirectory: true)
            .appendingPathComponent("runtime/ollama", isDirectory: true)
        let target = root.appendingPathComponent(version, isDirectory: true)
        if let existing = locateExecutable(in: target) { return existing }
        var request = URLRequest(url: archiveURL)
        request.timeoutInterval = 120
        let downloaded: URL
        do {
            let (file, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                try? FileManager.default.removeItem(at: file)
                throw OllamaModelFailure.runtimeDownload
            }
            downloaded = file
        } catch is CancellationError { throw CancellationError() }
        catch { throw OllamaModelFailure.runtimeDownload }
        defer { try? FileManager.default.removeItem(at: downloaded) }
        let expectedDigest = archiveSHA256
        let worker = Task.detached(priority: .utility) {
            try installArchive(downloaded, root: root, target: target, expectedSHA256: expectedDigest)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    nonisolated static func installArchive(_ archive: URL, root: URL, target: URL,
                                           expectedSHA256: String) throws -> URL {
        let fm = FileManager.default
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expectedSHA256.lowercased() else { throw OllamaModelFailure.runtimeChecksum }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let stage = root.appendingPathComponent(".install-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", stage.path]
        tar.standardOutput = FileHandle.nullDevice
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        let deadline = Date().addingTimeInterval(120)
        while tar.isRunning {
            if Task.isCancelled || Date() > deadline {
                tar.terminate()
                tar.waitUntilExit()
                try Task.checkCancellation()
                throw OllamaModelFailure.runtimeInstall
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard tar.terminationStatus == 0, locateExecutable(in: stage) != nil else {
            throw OllamaModelFailure.runtimeInstall
        }
        try Task.checkCancellation()
        if let existing = locateExecutable(in: target) { return existing }
        // An incomplete previous install is retained until the verified one is in place.
        let previous = root.appendingPathComponent(".previous-" + UUID().uuidString)
        let hadPrevious = fm.fileExists(atPath: target.path)
        if hadPrevious { try fm.moveItem(at: target, to: previous) }
        do { try fm.moveItem(at: stage, to: target) }
        catch {
            if hadPrevious { try? fm.moveItem(at: previous, to: target) }
            throw OllamaModelFailure.runtimeInstall
        }
        if hadPrevious { try? fm.removeItem(at: previous) }
        guard let installed = locateExecutable(in: target) else { throw OllamaModelFailure.runtimeInstall }
        return installed
    }

    nonisolated private static func locateExecutable(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let entries = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                                          options: [.skipsHiddenFiles]) else { return nil }
        let files = entries.compactMap { $0 as? URL }
        // Current archive needs its companion runner, not just a CLI binary.
        guard files.contains(where: { $0.lastPathComponent == "llama-server" && fm.isExecutableFile(atPath: $0.path) }) else { return nil }
        return files.first { $0.lastPathComponent == "ollama" && fm.isExecutableFile(atPath: $0.path) }
    }
}
