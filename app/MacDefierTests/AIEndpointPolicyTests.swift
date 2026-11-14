import XCTest
@testable import MacDefier

final class AIEndpointPolicyTests: XCTestCase {
    func testLoopbackClassificationAndLocalMode() {
        XCTAssertEqual(AIEndpointPolicy.classify("http://127.0.0.1:11434/v1").kind, .loopback)
        XCTAssertEqual(AIEndpointPolicy.classify("http://localhost:11434/v1").kind, .loopback)
        XCTAssertTrue(AIEndpointPolicy.isTrueLocalEndpoint("http://127.0.0.1:11434/v1"))
        XCTAssertTrue(AIEndpointPolicy.isAllowedAsLocalModeEndpoint("http://127.0.0.1:11434/v1"))
        XCTAssertTrue(AIEndpointPolicy.mayRequestAsLocalMode("http://127.0.0.1:11434/v1", privacyAcknowledged: false))
    }

    func testPrivateLANAndLinkLocalRequirePrivacyAcknowledgement() {
        XCTAssertEqual(AIEndpointPolicy.classify("http://192.168.1.10:11434/v1").kind, .privateLAN)
        XCTAssertEqual(AIEndpointPolicy.classify("http://10.0.0.5:11434/v1").kind, .privateLAN)
        XCTAssertEqual(AIEndpointPolicy.classify("http://172.16.0.2:11434/v1").kind, .privateLAN)
        XCTAssertEqual(AIEndpointPolicy.classify("http://169.254.1.1:11434/v1").kind, .privateLAN)
        XCTAssertTrue(AIEndpointPolicy.isAllowedAsLocalModeEndpoint("http://192.168.1.10:11434/v1"))
        XCTAssertFalse(AIEndpointPolicy.mayRequestAsLocalMode("http://192.168.1.10:11434/v1", privacyAcknowledged: false))
        XCTAssertTrue(AIEndpointPolicy.mayRequestAsLocalMode("http://192.168.1.10:11434/v1", privacyAcknowledged: true))
    }

    func testPublicRemoteAndPlainHTTPPolicy() {
        let publicHTTPS = "https://api.openai.com/v1"
        XCTAssertEqual(AIEndpointPolicy.classify(publicHTTPS).kind, .remote)
        XCTAssertFalse(AIEndpointPolicy.isAllowedAsLocalModeEndpoint(publicHTTPS))
        XCTAssertFalse(AIEndpointPolicy.mayRequestAsLocalMode(publicHTTPS, privacyAcknowledged: false))
        XCTAssertFalse(AIEndpointPolicy.mayRequestAsLocalMode(publicHTTPS, privacyAcknowledged: true))

        let publicHTTP = "http://api.openai.com/v1"
        XCTAssertEqual(AIEndpointPolicy.classify(publicHTTP).kind, .invalid)
        XCTAssertFalse(AIEndpointPolicy.classify(publicHTTP).isRequestAllowed)
        XCTAssertFalse(AIEndpointPolicy.isAllowedAsLocalModeEndpoint(publicHTTP))
    }

    func testF4SchemeLessBaseURLNormalizationAndChatURL() throws {
        // Loopback with port must normalize to http:// (not https:// or scheme "localhost:")
        XCTAssertEqual(AIEndpointPolicy.normalizedBaseURLString("127.0.0.1:11434/v1"), "http://127.0.0.1:11434/v1")
        XCTAssertEqual(AIEndpointPolicy.normalizedBaseURLString("localhost:11434/v1/"), "http://localhost:11434/v1")
        XCTAssertEqual(AIEndpointPolicy.normalizedBaseURLString("[::1]:11434/v1"), "http://[::1]:11434/v1")

        let loopbackCls = AIEndpointPolicy.classify("127.0.0.1:11434/v1")
        XCTAssertEqual(loopbackCls.kind, .loopback)
        XCTAssertFalse(loopbackCls.usesTLS)

        let localhostURL = try AIClient.chatURL(from: "localhost:11434/v1")
        XCTAssertEqual(localhostURL.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertEqual(localhostURL.scheme, "http")
        XCTAssertEqual(localhostURL.host, "localhost")
        XCTAssertEqual(localhostURL.port, 11434)

        let ipv4URL = try AIClient.chatURL(from: "127.0.0.1:11434")
        XCTAssertEqual(ipv4URL.absoluteString, "http://127.0.0.1:11434/v1/chat/completions")

        // Remote without scheme must normalize to https://
        XCTAssertEqual(AIEndpointPolicy.normalizedBaseURLString("example.invalid/v1/"), "https://example.invalid/v1")
        let remoteCls = AIEndpointPolicy.classify("api.openai.com/v1")
        XCTAssertEqual(remoteCls.kind, .remote)
        XCTAssertTrue(remoteCls.usesTLS)
        XCTAssertFalse(AIEndpointPolicy.isAllowedAsLocalModeEndpoint("api.openai.com/v1"))

        let remoteURL = try AIClient.chatURL(from: "example.invalid/v1")
        XCTAssertEqual(remoteURL.absoluteString, "https://example.invalid/v1/chat/completions")

        // Plain HTTP remote must be rejected by chatURL as well
        XCTAssertThrowsError(try AIClient.chatURL(from: "http://example.invalid/v1"))

        // OllamaEndpoint also accepts scheme-less loopback
        let ollamaTags = try OllamaEndpoint.apiURL("localhost:11434/v1", path: "tags")
        XCTAssertEqual(ollamaTags.absoluteString, "http://localhost:11434/api/tags")
    }
}
