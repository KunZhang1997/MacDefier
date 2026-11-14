import Combine
import CryptoKit
import Foundation
import Network
import XCTest
@testable import MacDefier

private final class OllamaFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.macdefier.ollama-fixture-tests")
    private let handler: (String) -> String
    private var connections: [NWConnection] = []

    init(handler: @escaping (String) -> String) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> String {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, accumulated: Data())
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: self.listener.port!.rawValue)
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return "http://127.0.0.1:\(port)/v1"
    }

    func stop() {
        listener.cancel()
        queue.async { for connection in self.connections { connection.cancel() } }
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, complete, error in
            guard let self else { return }
            var bytes = accumulated
            if let chunk { bytes.append(chunk) }
            if let request = String(data: bytes, encoding: .utf8),
               let split = request.range(of: "\r\n\r\n") {
                let headers = request[..<split.lowerBound].components(separatedBy: "\r\n")
                let length = headers.first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if request[split.upperBound...].utf8.count >= length {
                    let response = self.handler(request)
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                        if !response.contains("X-Fixture-Hold: 1") { connection.cancel() }
                    })
                    return
                }
            }
            guard !complete, error == nil else { connection.cancel(); return }
            self.receive(connection, accumulated: bytes)
        }
    }
}

private final class OllamaFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String] = []

    func add(_ request: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return requests.filter { $0.hasPrefix("GET ") }.count
    }

    var pulls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter { $0.hasPrefix("POST ") }
    }
}

final class OllamaModelTests: XCTestCase {
    private static func httpResponse(_ body: String, status: Int = 200) -> String {
        "HTTP/1.1 \(status) Fixture\r\nContent-Type: application/x-ndjson\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }

    private static func tags(_ name: String?) -> String {
        guard let name else { return "{\"models\":[]}" }
        return "{\"models\":[{\"name\":\"\(name)\",\"size\":12345}]}"
    }

    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("async operation timed out")
    }

    @MainActor
    func testEndpointBindingSelectionStreamingAndCancellation() async throws {
        let pullURL = try OllamaEndpoint.apiURL("http://localhost:11434/v1/", path: "pull")
        let ipv6URL = try OllamaEndpoint.apiURL("http://[::1]:11434/v1", path: "tags")
        XCTAssertEqual(pullURL.path, "/api/pull")
        XCTAssertTrue(AIEndpointPolicy.isLoopbackHost(ipv6URL.host ?? ""))

        for endpoint in ["https://example.com/v1", "http://192.168.1.2:11434/v1", "http://user:secret@localhost:11434/v1"] {
            XCTAssertThrowsError(try OllamaEndpoint.apiURL(endpoint, path: "pull")) { error in
                XCTAssertTrue(error is OllamaModelFailure)
            }
        }
        XCTAssertTrue(OllamaEndpoint.matches("fixture", "fixture:latest"))
        XCTAssertFalse(OllamaEndpoint.matches("fixture:2b", "fixture:4b"))
        XCTAssertFalse(OllamaEndpoint.matches("fixture:2b", "fixture:2b-q8"))

        // Installed model selected without pull
        let state = OllamaFixtureState()
        let installed = try OllamaFixtureServer { request in
            _ = state.add(request)
            return Self.httpResponse(Self.tags("fixture:latest"))
        }
        let installedEndpoint = try await installed.start()
        defer { installed.stop() }

        let manager = OllamaModelManager(prepareRuntime: { _, _ in })
        var chosen: [String] = []
        manager.select("fixture", endpoint: installedEndpoint) { name, endpoint in
            chosen.append(name)
            XCTAssertEqual(endpoint, installedEndpoint)
        }
        try await wait { manager.activeModel == nil }
        XCTAssertEqual(chosen, ["fixture:latest"])
        XCTAssertTrue(state.pulls.isEmpty)

        // Streaming pull matrix + progress throttling verification
        let updates = "{\"status\":\"pulling layer\",\"total\":1000,\"completed\":400}\n{\"status\":\"pulling layer\",\"total\":1000,\"completed\":402}\n{\"status\":\"pulling layer\",\"total\":1000,\"completed\":405}\n{\"status\":\"success\"}\n"
        try await exercisePull(stream: updates, finalInstalled: true, succeeds: true)
        try await exercisePull(stream: "{\"status\":\"pulling layer\",\"total\":100,\"completed\":40}\n", finalInstalled: true, succeeds: false)
        try await exercisePull(stream: "{\"status\":\"success\"}\n", finalInstalled: false, succeeds: false)
        try await exercisePull(stream: "{\"error\":\"fixture failure\"}\n", finalInstalled: true, succeeds: false)
        try await exercisePull(stream: "malformed\n", finalInstalled: true, succeeds: false)
        try await exercisePull(stream: "{}\n", finalInstalled: true, succeeds: false, status: 500)

        // Cancel during preparation
        var preparations = 0
        let cancellable = OllamaModelManager(prepareRuntime: { _, _ in
            preparations += 1
            if preparations == 1 { try await Task.sleep(nanoseconds: 500_000_000) }
        })
        var activations = 0
        cancellable.select("fixture", endpoint: installedEndpoint) { _, _ in activations += 1 }
        try await wait { preparations == 1 }
        cancellable.cancel()
        cancellable.select("fixture", endpoint: installedEndpoint) { _, _ in activations += 1 }
        try await wait { cancellable.activeModel == nil }
        XCTAssertEqual(activations, 1)
        XCTAssertNil(cancellable.failure)

        // Cancel during live streaming response
        let holdServer = try OllamaFixtureServer { request in
            if request.hasPrefix("GET ") { return Self.httpResponse(Self.tags(nil)) }
            let body = "{\"status\":\"pulling layer\",\"completed\":10,\"total\":100}\n"
            return "HTTP/1.1 200 OK\r\nX-Fixture-Hold: 1\r\nContent-Type: application/x-ndjson\r\nContent-Length: 99999\r\n\r\n" + body
        }
        let holdEndpoint = try await holdServer.start()
        defer { holdServer.stop() }
        let streaming = OllamaModelManager(prepareRuntime: { _, _ in })
        streaming.select("fixture:1b", endpoint: holdEndpoint) { _, _ in activations += 100 }
        try await wait { streaming.progress != nil }
        streaming.cancel()
        streaming.select("fixture", endpoint: installedEndpoint) { _, _ in activations += 1 }
        try await wait { streaming.activeModel == nil }
        XCTAssertEqual(activations, 2)
        XCTAssertEqual(streaming.selectedModel, "fixture:latest")
    }

    @MainActor
    private func exercisePull(stream: String, finalInstalled: Bool, succeeds: Bool, status: Int = 200) async throws {
        let state = OllamaFixtureState()
        let server = try OllamaFixtureServer { request in
            let tagRead = state.add(request)
            if request.hasPrefix("GET ") {
                return Self.httpResponse(Self.tags(tagRead > 1 && finalInstalled ? "fixture:1b" : nil))
            }
            return Self.httpResponse(stream, status: status)
        }
        let endpoint = try await server.start()
        defer { server.stop() }

        let manager = OllamaModelManager(prepareRuntime: { _, _ in })
        var chosen: String?
        var publishedProgressValues: [Double] = []
        let subscription = manager.$progress.sink { value in
            if let value { publishedProgressValues.append(value) }
        }
        defer { subscription.cancel() }

        manager.select("fixture:1b", endpoint: endpoint) { name, _ in chosen = name }
        try await wait { manager.activeModel == nil }
        XCTAssertEqual(chosen != nil, succeeds)
        XCTAssertEqual(manager.failure == nil, succeeds)
        XCTAssertEqual(state.pulls.count, 1)
        let body = state.pulls[0].components(separatedBy: "\r\n\r\n").last!
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "fixture:1b")
        XCTAssertEqual(json["stream"] as? Bool, true)
        if succeeds {
            XCTAssertTrue(publishedProgressValues.contains(0.4))
            // Rapid sub-1% chunks (0.402, 0.405) must be throttled
            XCTAssertFalse(publishedProgressValues.contains(0.402))
            XCTAssertFalse(publishedProgressValues.contains(0.405))
        }
    }

    func testRuntimeArchiveSHA256VerificationAndAtomicInstall() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MacDefier-OllamaFixture-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }

        let content = root.appendingPathComponent("content")
        try fm.createDirectory(at: content, withIntermediateDirectories: false)
        for name in ["ollama", "llama-server"] {
            let file = content.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let archive = root.appendingPathComponent("fixture.tgz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", content.path, "."]
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)

        let digest = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
        let target = root.appendingPathComponent("runtime")
        XCTAssertThrowsError(try OllamaRuntime.installArchive(archive, root: root, target: target, expectedSHA256: "bad")) { error in
            if case OllamaModelFailure.runtimeChecksum = error {} else {
                XCTFail("Expected runtimeChecksum error, got \(error)")
            }
        }
        XCTAssertFalse(fm.fileExists(atPath: target.path))

        let installed = try OllamaRuntime.installArchive(archive, root: root, target: target, expectedSHA256: digest)
        XCTAssertTrue(fm.isExecutableFile(atPath: installed.path))
        _ = try OllamaRuntime.installArchive(archive, root: root, target: target, expectedSHA256: digest)
        XCTAssertTrue(fm.isExecutableFile(atPath: installed.path))
    }
}
