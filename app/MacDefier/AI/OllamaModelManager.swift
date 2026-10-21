import Combine
import Foundation

/// Model management uses Ollama's native API; chat continues using /v1.
/// Adapted from SpeakSend's catalog: explicit success + a fresh catalog are
/// required before a downloaded model can become the active selection.
enum OllamaModelFailure: Error {
    case endpoint, unavailable, http(Int), invalidResponse, interrupted, modelMissing
    case runtimeDownload, runtimeChecksum, runtimeInstall, runtimeStart
}

struct OllamaInstalledModel: Decodable, Identifiable, Equatable {
    var name: String
    var size: Int64?
    var id: String { name }
}

enum OllamaEndpoint {
    static func apiURL(_ endpoint: String, path: String) throws -> URL {
        let raw = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: raw),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, AIEndpointPolicy.isLoopbackHost(host),
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { throw OllamaModelFailure.endpoint }
        var basePath = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if basePath == "v1" { basePath = "" }
        else if basePath.hasSuffix("/v1") { basePath = String(basePath.dropLast(3)) }
        parts.path = "/" + ([basePath, "api", path].filter { !$0.isEmpty }.joined(separator: "/"))
        guard let url = parts.url else { throw OllamaModelFailure.endpoint }
        return url
    }

    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        func canonical(_ name: String) -> String {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.contains(":") ? trimmed : trimmed + ":latest"
        }
        return canonical(lhs) == canonical(rhs)
    }

    static func validModelName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 200, !name.hasPrefix("/"),
              !name.contains("..") else { return false }
        return name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_.:/".unicodeScalars.contains($0)
        }
    }
}

/// A loopback endpoint must not redirect model management to another device.
private final class OllamaLocalRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let host = request.url?.host, AIEndpointPolicy.isLoopbackHost(host) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

@MainActor
final class OllamaModelManager: ObservableObject {
    static let shared = OllamaModelManager()

    enum Stage { case preparing, runtimeDownload, starting, downloading, verifying }
    @Published private(set) var models: [OllamaInstalledModel] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var catalogUnavailable = false
    @Published private(set) var activeModel: String?
    @Published private(set) var stage: Stage = .preparing
    @Published private(set) var progress: Double?
    @Published private(set) var failure: OllamaModelFailure?
    @Published private(set) var failedModel: String?
    @Published private(set) var selectedModel: String?
    private(set) var catalogEndpoint = ""
    private var refreshID = UUID()
    private var operationID: UUID?
    private var downloadTask: Task<Void, Never>?
    private let session: URLSession
    private let prepareRuntime: (String, @escaping @MainActor (Stage) -> Void) async throws -> Void

    init(session: URLSession? = nil,
         prepareRuntime: @escaping (String, @escaping @MainActor (Stage) -> Void) async throws -> Void = {
             try await OllamaRuntime.ensureReady(endpoint: $0, onStage: $1)
         }) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 120
            config.timeoutIntervalForResource = 86_400
            self.session = URLSession(configuration: config, delegate: OllamaLocalRedirectPolicy(), delegateQueue: nil)
        }
        self.prepareRuntime = prepareRuntime
    }

    func installedName(_ name: String) -> String? {
        models.first { OllamaEndpoint.matches($0.name, name) }?.name
    }

    func refresh(endpoint: String) async {
        let id = UUID()
        refreshID = id
        if catalogEndpoint != endpoint {
            models = []
            catalogEndpoint = endpoint
            selectedModel = nil
            failure = nil
        }
        isRefreshing = true
        defer { if refreshID == id { isRefreshing = false } }
        do {
            let fetched = try await fetchModels(endpoint: endpoint)
            guard refreshID == id else { return }
            models = fetched
            catalogUnavailable = false
        } catch {
            guard refreshID == id else { return }
            // A failed refresh is not proof that previously listed models vanished.
            catalogUnavailable = true
        }
    }

    func select(_ name: String, endpoint: String,
                onReady: @escaping @MainActor (String, String) -> Void) {
        let model = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard activeModel == nil else { return }
        guard OllamaEndpoint.validModelName(model) else {
            failure = .invalidResponse
            failedModel = model
            return
        }
        let id = UUID()
        operationID = id
        activeModel = model
        failure = nil
        failedModel = nil
        progress = nil
        stage = .preparing
        downloadTask = Task { [self] in
            defer {
                if operationID == id {
                    activeModel = nil
                    downloadTask = nil
                    operationID = nil
                    progress = nil
                }
            }
            do {
                _ = try OllamaEndpoint.apiURL(endpoint, path: "tags")
                try await prepareRuntime(endpoint) { [weak self] stage in
                    guard self?.operationID == id else { return }
                    self?.stage = stage
                }
                try Task.checkCancellation()
                var fetched = try await fetchModels(endpoint: endpoint)
                guard operationID == id else { return }
                if !fetched.contains(where: { OllamaEndpoint.matches($0.name, model) }) {
                    stage = .downloading
                    try await pull(model: model, endpoint: endpoint, operation: id)
                    try Task.checkCancellation()
                    stage = .verifying
                    fetched = try await fetchModels(endpoint: endpoint)
                }
                try Task.checkCancellation()
                guard operationID == id else { return }
                guard let installed = fetched.first(where: { OllamaEndpoint.matches($0.name, model) }) else {
                    throw OllamaModelFailure.modelMissing
                }
                // Invalidate a concurrent refresh so stale tags cannot undo this catalog.
                refreshID = UUID()
                isRefreshing = false
                models = fetched
                catalogEndpoint = endpoint
                catalogUnavailable = false
                selectedModel = installed.name
                onReady(installed.name, endpoint)
            } catch {
                guard operationID == id else { return }
                if !(error is CancellationError) {
                    failure = (error as? OllamaModelFailure) ?? .unavailable
                    failedModel = model
                }
            }
        }
    }

    func cancel() {
        operationID = nil
        downloadTask?.cancel()
        downloadTask = nil
        activeModel = nil
        progress = nil
        failure = nil
        failedModel = nil
    }

    private struct Tags: Decodable { var models: [OllamaInstalledModel] }
    private struct Update: Decodable {
        var status: String?
        var total: Int64?
        var completed: Int64?
        var error: String?
    }

    private func fetchModels(endpoint: String) async throws -> [OllamaInstalledModel] {
        var request = URLRequest(url: try OllamaEndpoint.apiURL(endpoint, path: "tags"))
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        try Self.requireSuccess(response)
        return try JSONDecoder().decode(Tags.self, from: data).models.filter { !$0.name.isEmpty }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func pull(model: String, endpoint: String, operation: UUID) async throws {
        var request = URLRequest(url: try OllamaEndpoint.apiURL(endpoint, path: "pull"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let (bytes, response) = try await session.bytes(for: request)
        try Self.requireSuccess(response)
        var succeeded = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard operationID == operation else { throw CancellationError() }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard let data = line.data(using: .utf8),
                  let update = try? JSONDecoder().decode(Update.self, from: data) else {
                throw OllamaModelFailure.invalidResponse
            }
            if let error = update.error, !error.isEmpty { throw OllamaModelFailure.interrupted }
            succeeded = succeeded || update.status == "success"
            if update.status?.contains("verif") == true || update.status?.contains("manifest") == true {
                stage = .verifying
                progress = nil
            } else if let total = update.total, total > 0, let done = update.completed {
                stage = .downloading
                progress = min(1, max(0, Double(done) / Double(total)))
            }
        }
        try Task.checkCancellation()
        guard succeeded else { throw OllamaModelFailure.interrupted }
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw OllamaModelFailure.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw OllamaModelFailure.http(http.statusCode) }
    }
}
