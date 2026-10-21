import SwiftUI
import MonitorKit
import AppKit

@main
struct MacDefierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = MonitorService.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.chinese.rawValue

    private var isIconExport: Bool {
        ProcessInfo.processInfo.arguments.contains("--export-app-icon")
    }

    var body: some Scene {
        // 固定 ID 单主窗 Scene（M01-1 / M01-2）
        Window("MacDefier", id: AppDelegate.mainWindowID) {
            if isIconExport {
                Color.clear
                    .frame(width: 1, height: 1)
                    .onAppear {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 80_000_000)
                            _ = IconExport.exportIfRequested()
                            NSApp.terminate(nil)
                        }
                    }
            } else {
                ContentView()
                    .environmentObject(monitor)
                    .frame(minWidth: WindowChrome.minWidth, minHeight: WindowChrome.minContentHeight)
                    .preferredColorScheme(
                        (AppAppearance(rawValue: appearanceRaw) ?? .system).colorScheme
                    )
                    .onAppear {
                        // Retain the scene's OpenWindowAction outside the
                        // window hierarchy.  After the NSWindow is released,
                        // a Notification receiver inside ContentView no
                        // longer exists and cannot recreate the main scene.
                        MainWindowRouter.installOpenWindowHandler {
                            openWindow(id: AppDelegate.mainWindowID)
                        }
                        MenuBarController.shared.restoreFromDefaults()
                        MonitorAIAssist.shared.start(monitor: monitor)
                        // Tag the key window as main shell for reopen routing
                        DispatchQueue.main.async {
                            if let w = NSApp.keyWindow {
                                w.identifier = NSUserInterfaceItemIdentifier(AppDelegate.mainWindowID)
                            }
                        }
                    }
                    .onChange(of: appearanceRaw) { _, value in
                        AppAppearance.apply(rawValue: value)
                    }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(
            width: isIconExport ? 40 : WindowChrome.defaultWidth,
            height: isIconExport ? 40 : WindowChrome.contentHeight
        )
        .windowResizability(.contentMinSize)
        .commands {
            // 禁止 File → New Window 复制主壳
            CommandGroup(replacing: .newItem) {}
            // Commands must live in the app menu, not inside a collapsed Menu.
            // This keeps navigation shortcuts registered at every window width.
            CommandMenu(languageRaw == AppLanguage.english.rawValue ? "Navigate" : "导航") {
                ForEach(Array([AppRoute.diagnostic, .cleanup, .aiTools, .diskMap, .software, .monitor, .settings].enumerated()), id: \.element.id) { index, route in
                    Button(route.title) { AppNavigator.shared.route = route }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            }
        }
    }
}
