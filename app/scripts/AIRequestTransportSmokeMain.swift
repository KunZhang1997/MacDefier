// Real URLSession transport regression, with synthetic data and loopback only.
// Compile with the shipped MacDefier/AI/AIRequestTransport.swift.
import Foundation
import Network

private final class LoopbackHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.macdefier.AITransportSmoke")
    private let handler: (String) -> String
    private let lock = NSLock()
    private var requests: [String] = []

    init(handler: @escaping (String) -> String) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.receive(connection, accumulated: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: self.listener.port!.rawValue)
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, complete, error in
            guard let self else { connection.cancel(); return }
            var data = accumulated
            if let chunk { data.append(chunk) }
            if let request = String(data: data, encoding: .utf8),
               let separator = request.range(of: "\r\n\r\n") {
                let header = String(request[..<separator.lowerBound])
                let lengthHeader = header.components(separatedBy: "\r\n").first {
                    $0.lowercased().hasPrefix("content-length:")
                }
                let expectedLength = lengthHeader.flatMap {
                    Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces))
                } ?? 0
                if request[separator.upperBound...].utf8.count >= expectedLength {
                    self.lock.lock()
                    self.requests.append(request)
                    self.lock.unlock()
                    let response = self.handler(request)
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    return
                }
            }
            guard !complete, error == nil, data.count < 65_536 else { connection.cancel(); return }
            self.receive(connection, accumulated: data)
        }
    }
}

@main
enum AIRequestTransportSmoke {
    enum Failure: Error { case assertion(String) }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.assertion(message) }
    }

    static func response(_ status: Int, body: String = "", location: String? = nil) -> String {
        let locationHeader = location.map { "Location: \($0)\r\n" } ?? ""
        return "HTTP/1.1 \(status) Test\r\n\(locationHeader)Content-Type: application/json\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }

    static func request(_ port: UInt16, path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = Data("SYNTHETIC_PRIVATE_SUMMARY".utf8)
        request.setValue("Bearer SYNTHETIC_KEY", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        return request
    }

    static func main() async {
        do {
            try await run()
            print("AIRequestTransportSmoke: PASS (200; 301/302/303/307/308 blocked; 400 then 307; no redirect-target requests)")
        } catch {
            fputs("AIRequestTransportSmoke: FAIL \(error)\n", stderr)
            exit(1)
        }
    }

    static func run() async throws {
        let destination = try LoopbackHTTPServer { _ in response(200, body: "{\"leaked\":true}") }
        let destinationPort = try await destination.start()
        defer { destination.stop() }
        let target = "http://localhost:\(destinationPort)/unconfigured-receiver"

        let source = try LoopbackHTTPServer { incoming in
            let path = incoming.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            if path == "/success" {
                let valid = incoming.hasPrefix("POST ")
                    && incoming.contains("SYNTHETIC_PRIVATE_SUMMARY")
                    && incoming.contains("Bearer SYNTHETIC_KEY")
                return response(valid ? 200 : 422, body: "{\"ok\":true}")
            }
            if path == "/unsupported-options" { return response(400, body: "{\"error\":\"unsupported options\"}") }
            let code = Int(path.dropFirst()) ?? 500
            return response(code, body: "{\"redirect\":true}", location: target)
        }
        let sourcePort = try await source.start()
        defer { source.stop() }

        let (data, success) = try await AIRequestTransport.data(for: request(sourcePort, path: "success"))
        try expect((success as? HTTPURLResponse)?.statusCode == 200, "normal POST must preserve body and authorization")
        try expect(String(data: data, encoding: .utf8) == "{\"ok\":true}", "normal response is preserved")

        for code in [301, 302, 303, 307, 308] {
            let (_, blocked) = try await AIRequestTransport.data(for: request(sourcePort, path: "\(code)"))
            try expect((blocked as? HTTPURLResponse)?.statusCode == code, "HTTP \(code) must remain at configured endpoint")
            try expect(blocked.url?.port == Int(sourcePort), "redirect response URL must stay at source")
            try expect(destination.requestCount == 0, "redirect target must receive no request or synthetic body")
        }

        let (_, unsupported) = try await AIRequestTransport.data(for: request(sourcePort, path: "unsupported-options"))
        try expect((unsupported as? HTTPURLResponse)?.statusCode == 400, "400 must reach client retry logic unchanged")
        let (_, retryRedirect) = try await AIRequestTransport.data(for: request(sourcePort, path: "307"))
        try expect((retryRedirect as? HTTPURLResponse)?.statusCode == 307, "retry transport must reject redirect too")
        try expect(source.requestCount == 8, "expected exactly eight requests at the configured endpoint")
        try expect(destination.requestCount == 0, "no request may reach the unconfigured receiver")
    }
}
