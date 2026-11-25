import XCTest
@testable import MonitorKit

final class ProcessFamilyInspectorTests: XCTestCase {
    func testParseProcArgs2BufferValidAndTruncatedSafety() {
        // Construct synthetic KERN_PROCARGS2 buffer:
        // int32 argc = 4, exec_path\0, padding \0\0, argv[0]\0argv[1]\0argv[2]\0argv[3]\0
        var buf: [UInt8] = []
        var argc: Int32 = 4
        withUnsafeBytes(of: &argc) { buf.append(contentsOf: $0) }
        buf.append(contentsOf: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome".utf8)
        buf.append(contentsOf: [0, 0, 0])
        for arg in [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "--no-startup-window",
            "--remote-debugging-port=9333",
            "--user-data-dir=/Users/demo/.maitian-data/chrome-profile"
        ] {
            buf.append(contentsOf: arg.utf8)
            buf.append(0)
        }
        buf.append(contentsOf: "HOME=/Users/demo".utf8)
        buf.append(0)

        let parsed = BrowserAutomationClassifier.parseProcArgs2Buffer(buf)
        XCTAssertEqual(parsed, [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "--no-startup-window",
            "--remote-debugging-port=9333",
            "--user-data-dir=/Users/demo/.maitian-data/chrome-profile"
        ])

        // Truncated / malformed buffers must never crash
        XCTAssertNil(BrowserAutomationClassifier.parseProcArgs2Buffer([]))
        XCTAssertNil(BrowserAutomationClassifier.parseProcArgs2Buffer([1, 0, 0]))
        XCTAssertNil(BrowserAutomationClassifier.parseProcArgs2Buffer([0, 0, 0, 0, 65, 0]))
        var hugeArgc: [UInt8] = []
        var bad: Int32 = 99999
        withUnsafeBytes(of: &bad) { hugeArgc.append(contentsOf: $0) }
        hugeArgc.append(contentsOf: "/bin/ls\0ls\0".utf8)
        XCTAssertNil(BrowserAutomationClassifier.parseProcArgs2Buffer(hugeArgc))
    }

    func testBrowserAutomationClassifierDistinguishesMainVsAutomatedBrowsers() {
        let chromeExec = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let chromeApp = "/Applications/Google Chrome.app"
        let home = "/Users/demo"

        // 1. User's normal primary Chrome -> nil
        XCTAssertNil(BrowserAutomationClassifier.classify(
            executablePath: chromeExec,
            appPath: chromeApp,
            arguments: [chromeExec],
            homeDirectory: home
        ))

        // 2. Developer running --remote-debugging-port OR --enable-automation on their DEFAULT profile (or omitted user-data-dir) -> nil (protect main browser!)
        XCTAssertNil(BrowserAutomationClassifier.classify(
            executablePath: chromeExec,
            appPath: chromeApp,
            arguments: [
                chromeExec,
                "--enable-automation",
                "--no-startup-window",
                "--remote-debugging-port=9222"
            ],
            homeDirectory: home
        ))
        XCTAssertNil(BrowserAutomationClassifier.classify(
            executablePath: chromeExec,
            appPath: chromeApp,
            arguments: [
                chromeExec,
                "--enable-automation",
                "--user-data-dir=/System/Volumes/Data/Users/demo/Library/Application Support/Google/Chrome"
            ],
            homeDirectory: home
        ))

        // 3. Renderer helper child process -> nil
        XCTAssertNil(BrowserAutomationClassifier.classify(
            executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
            appPath: chromeApp,
            arguments: ["Helper", "--type=renderer", "--enable-automation"],
            homeDirectory: home
        ))

        // 4. Background debug Chrome with custom data dir (like maitian) -> detected with sanitized hint!
        let info = BrowserAutomationClassifier.classify(
            executablePath: chromeExec,
            appPath: chromeApp,
            arguments: [
                chromeExec,
                "--no-startup-window",
                "--remote-debugging-port=9333",
                "--user-data-dir=/Users/demo/.maitian-data/chrome-profile"
            ],
            homeDirectory: home
        )
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.debugPort, 9333)
        XCTAssertEqual(info?.profileHint, ".maitian-data")
        XCTAssertFalse(info?.displayHint.contains("demo") ?? true)

        // 5. Headless Chrome -> detected
        let headless = BrowserAutomationClassifier.classify(
            executablePath: chromeExec,
            appPath: chromeApp,
            arguments: [chromeExec, "--headless=new"],
            homeDirectory: home
        )
        XCTAssertEqual(headless?.isHeadless, true)
    }

    func testSimctlBootedJSONParserAndShutdownValidation() {
        let sample = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-6": [
              {
                "udid": "EF96C0C8-FDF7-478E-947E-987810995207",
                "name": "iPhone 16 Pro",
                "state": "Booted"
              },
              {
                "udid": "11111111-2222-3333-4444-555555555555",
                "name": "iPhone 15",
                "state": "Shutdown"
              }
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-27-1": [
              {
                "udid": "not-a-valid-uuid; rm -rf /",
                "name": "Malicious",
                "state": "Booted"
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let parsed = SimulatorControl.parseSimctlBootedJSON(sample)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.name, "iPhone 16 Pro")
        XCTAssertEqual(parsed.first?.runtime, "iOS 18.6")

        // Reject non-UUID strings before ever touching xcrun
        XCTAssertEqual(SimulatorControl.shutdownBooted(udids: ["../bad"]), .invalidIdentifier)
    }

    func testLiveCaptureProducesPositiveFamiliesAndRejectsSelfTermination() {
        let families = ProcessFamilyInspector.capture(querySimulators: false, limit: 12)
        XCTAssertFalse(families.isEmpty)
        XCTAssertTrue(families.allSatisfy { $0.processCount >= 1 && $0.footprintBytes >= 0 })

        // Terminating our own PID or a non-automated process must be refused.
        if let selfIdentity = MonitoredProcessIdentity.read(pid: getpid()) {
            XCTAssertEqual(AutomatedBrowserExit.terminate(selfIdentity), .unavailable)
        }
    }
}
