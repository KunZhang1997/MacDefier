import SwiftUI
import MonitorKit
import AppKit

@main
struct MacDefierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.chinese.rawValue

    private var isIconExport: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--export-app-icon")
        #else
        false
        #endif
    }

    var body: some Scene {
        // 固定 ID 单主窗 Scene（M01-1 / M01-2）
        Window("MacDefier", id: AppDelegate.mainWindowID) {
            if AppDelegate.isRunningTests {
                Color.clear.frame(width: 1, height: 1)
            } else {
                #if DEBUG
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
                    MainShellRootView()
                }
                #else
                MainShellRootView()
                #endif
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(
            width: (AppDelegate.isRunningTests || isIconExport) ? 40 : WindowChrome.defaultWidth,
            height: (AppDelegate.isRunningTests || isIconExport) ? 40 : WindowChrome.contentHeight
        )
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            if !AppDelegate.isRunningTests {
                MainShellCommands(languageRaw: languageRaw, isIconExport: isIconExport)
            }
        }
    }
}

private struct MainShellRootView: View {
    @StateObject private var monitor = MonitorService.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue

    var body: some View {
        ContentView()
            .environmentObject(monitor)
            .frame(minWidth: WindowChrome.minWidth, minHeight: WindowChrome.minContentHeight)
            .preferredColorScheme(
                (AppAppearance(rawValue: appearanceRaw) ?? .system).colorScheme
            )
            .onAppear {
                MainWindowRouter.installOpenWindowHandler {
                    openWindow(id: AppDelegate.mainWindowID)
                }
                MenuBarController.shared.restoreFromDefaults()
                MonitorAIAssist.shared.start(monitor: monitor)
                AppUpdateController.shared.checkForUpdateIfNeeded()
                DispatchQueue.main.async {
                    if let w = NSApp.keyWindow {
                        w.identifier = NSUserInterfaceItemIdentifier(AppDelegate.mainWindowID)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                AppUpdateController.shared.checkForUpdateIfNeeded()
            }
            .onChange(of: appearanceRaw) { _, value in
                AppAppearance.apply(rawValue: value)
            }
    }
}

private struct MainShellCommands: Commands {
    let languageRaw: String
    let isIconExport: Bool
    @ObservedObject private var guide = UsageGuideState.shared

    var body: some Commands {
        CommandMenu(languageRaw == AppLanguage.english.rawValue ? "Navigate" : "导航") {
            ForEach(Array([AppRoute.diagnostic, .cleanup, .aiTools, .diskMap, .software, .monitor, .settings].enumerated()), id: \.element.id) { index, route in
                Button(route.title) { AppNavigator.shared.route = route }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .disabled(guide.isPresented)
            }
        }
        CommandGroup(replacing: .help) {
            Button(L10n.t("guide.menu")) {
                MainWindowRouter.openMainWindow()
                guide.replay()
            }
            .disabled(isIconExport)
        }
    }
}
