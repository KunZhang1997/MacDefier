// Smoke test for shipped AIEndpointPolicy (M08-1).
// Run via: app/scripts/test-ai-endpoint-policy.sh

import Foundation

@main
enum AIEndpointPolicySmoke {
    enum Fail: Error { case assert(String) }

    static func expect(_ cond: @autoclosure () -> Bool, _ msg: String) throws {
        if !cond() { throw Fail.assert(msg) }
    }

    static func main() {
        do {
            try run()
            print("AIEndpointPolicySmoke: PASS")
        } catch {
            fputs("AIEndpointPolicySmoke: FAIL \(error)\n", stderr)
            exit(1)
        }
    }

    static func run() throws {
        // loopback
        try expect(AIEndpointPolicy.classify("http://127.0.0.1:11434/v1").kind == .loopback, "127 loopback")
        try expect(AIEndpointPolicy.classify("http://localhost:11434/v1").kind == .loopback, "localhost loopback")
        try expect(AIEndpointPolicy.isTrueLocalEndpoint("http://127.0.0.1:11434/v1"), "true local")
        try expect(AIEndpointPolicy.isAllowedAsLocalModeEndpoint("http://127.0.0.1:11434/v1"), "local allows loopback")
        try expect(AIEndpointPolicy.mayRequestAsLocalMode("http://127.0.0.1:11434/v1", privacyAcknowledged: false), "loopback no ack")

        // private LAN / link-local
        try expect(AIEndpointPolicy.classify("http://192.168.1.10:11434/v1").kind == .privateLAN, "RFC1918")
        try expect(AIEndpointPolicy.classify("http://10.0.0.5:11434/v1").kind == .privateLAN, "10/8")
        try expect(AIEndpointPolicy.classify("http://172.16.0.2:11434/v1").kind == .privateLAN, "172.16")
        try expect(AIEndpointPolicy.classify("http://169.254.1.1:11434/v1").kind == .privateLAN, "link-local")
        try expect(AIEndpointPolicy.isAllowedAsLocalModeEndpoint("http://192.168.1.10:11434/v1"), "local allows LAN")
        try expect(!AIEndpointPolicy.mayRequestAsLocalMode("http://192.168.1.10:11434/v1", privacyAcknowledged: false), "LAN needs ack")
        try expect(AIEndpointPolicy.mayRequestAsLocalMode("http://192.168.1.10:11434/v1", privacyAcknowledged: true), "LAN with ack")

        // public remote — must NOT be "local mode"
        let publicHTTPS = "https://api.openai.com/v1"
        try expect(AIEndpointPolicy.classify(publicHTTPS).kind == .remote, "public remote")
        try expect(!AIEndpointPolicy.isAllowedAsLocalModeEndpoint(publicHTTPS), "local rejects public")
        try expect(!AIEndpointPolicy.mayRequestAsLocalMode(publicHTTPS, privacyAcknowledged: false), "public no local w/o ack")
        try expect(!AIEndpointPolicy.mayRequestAsLocalMode(publicHTTPS, privacyAcknowledged: true), "public no local even with ack")

        // public HTTP forbidden
        let publicHTTP = "http://api.openai.com/v1"
        try expect(AIEndpointPolicy.classify(publicHTTP).kind == .invalid, "public HTTP invalid")
        try expect(!AIEndpointPolicy.classify(publicHTTP).isRequestAllowed, "public HTTP blocked")
        try expect(!AIEndpointPolicy.isAllowedAsLocalModeEndpoint(publicHTTP), "local rejects public HTTP")

        // scheme-less defaults
        try expect(AIEndpointPolicy.classify("127.0.0.1:11434/v1").kind == .loopback, "scheme-less loopback")
        try expect(AIEndpointPolicy.classify("api.openai.com/v1").kind == .remote, "scheme-less public → https remote")
        try expect(!AIEndpointPolicy.isAllowedAsLocalModeEndpoint("api.openai.com/v1"), "scheme-less public not local")
    }
}
