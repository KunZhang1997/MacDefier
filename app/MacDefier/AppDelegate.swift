// AppDelegate — single main window reopen (Dock / menu bar).

import AppKit
import MonitorKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let mainWindowID = "main"

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowRouter.openMainWindow()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--monitor-history") {
            AppNavigator.shared.route = .monitor
            AppNavigator.shared.monitorTab = .history
        }
        #endif
        AppAppearance.apply(
            rawValue: UserDefaults.standard.string(forKey: AppAppearance.storageKey)
                ?? AppAppearance.system.rawValue
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await MonitorService.shared.history.finishRecording()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        OllamaModelManager.shared.cancel()
        OllamaRuntime.shutdown()
    }
}

@MainActor
enum MainWindowRouter {
    private static var openWindowHandler: (() -> Void)?

    static func installOpenWindowHandler(_ handler: @escaping () -> Void) {
        openWindowHandler = handler
    }

    /// 优先激活已有主窗；否则发通知让 SwiftUI 按固定 ID 打开。禁止 newWindowForTab。
    static func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)

        if let existing = NSApp.windows.first(where: isMainShellWindow) {
            if existing.isMiniaturized { existing.deminiaturize(nil) }
            existing.makeKeyAndOrderFront(nil)
            return
        }

        openWindowHandler?()
    }

    private static func isMainShellWindow(_ w: NSWindow) -> Bool {
        if w.identifier?.rawValue == AppDelegate.mainWindowID { return true }
        if w.level != .normal { return false }
        if w.styleMask.contains(.nonactivatingPanel) { return false }
        guard w.canBecomeMain else { return false }
        return w.frame.width >= 400 && w.frame.height >= 300
    }
}
