import Foundation

/// AI requests carry conversation and machine context. Only the configured
/// endpoint has passed privacy checks; redirects must not choose a new receiver.
enum AIRequestTransport {
    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request, delegate: RejectRedirects())
    }

    private final class RejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
