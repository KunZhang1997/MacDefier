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
    @ObservedObject private var nav = AppNavigator.shared

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L10n.t("menu.about")) {
                NSApplication.shared.orderFrontStandardAboutPanel(nil)
            }
            .disabled(isIconExport)
        }
        CommandGroup(replacing: .appSettings) {
            Button(L10n.t("menu.settings")) {
                MainWindowRouter.openMainWindow()
                nav.route = .settings
            }
            .keyboardShortcut(",", modifiers: .command)
            .disabled(guide.isPresented || isIconExport)
        }
        CommandMenu(languageRaw == AppLanguage.english.rawValue ? "Navigate" : "导航") {
            Button(L10n.t("menu.command_palette")) {
                MainWindowRouter.openMainWindow()
                NotificationCenter.default.post(name: .macDefierOpenCommandPalette, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(guide.isPresented || isIconExport)

            Button(L10n.t("menu.refresh_page")) {
                MainWindowRouter.openMainWindow()
                NotificationCenter.default.post(name: .macDefierRefreshCurrentRoute, object: nil)
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(guide.isPresented || isIconExport)

            Button(L10n.t("menu.focus_search")) {
                MainWindowRouter.openMainWindow()
                if nav.route != .software {
                    nav.route = .software
                }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .macDefierFocusSearch, object: nil)
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(guide.isPresented || isIconExport)

            Button(L10n.t("menu.toggle_mister")) {
                MainWindowRouter.openMainWindow()
                nav.misterOpen.toggle()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(guide.isPresented || isIconExport)

            Divider()

            ForEach(Array([AppRoute.diagnostic, .cleanup, .aiTools, .diskMap, .software, .monitor, .settings].enumerated()), id: \.element.id) { index, route in
                Button(route.title) { nav.route = route }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .disabled(guide.isPresented)
            }

            Divider()

            Button(L10n.t("menu.monitor_prev")) {
                MainWindowRouter.openMainWindow()
                stepMonitorTab(delta: -1)
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(guide.isPresented || nav.route != .monitor)

            Button(L10n.t("menu.monitor_next")) {
                MainWindowRouter.openMainWindow()
                stepMonitorTab(delta: 1)
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(guide.isPresented || nav.route != .monitor)
        }
        CommandGroup(replacing: .help) {
            Button(L10n.t("guide.menu")) {
                MainWindowRouter.openMainWindow()
                guide.replay()
            }
            .disabled(isIconExport)

            Button(L10n.t("settings.website")) {
                NSWorkspace.shared.open(AppUpdateController.officialWebsiteURL)
            }
            .disabled(isIconExport)
        }
    }

    private func stepMonitorTab(delta: Int) {
        let tabs = MonitorTab.allCases
        guard let idx = tabs.firstIndex(of: nav.monitorTab) else { return }
        nav.monitorTab = tabs[(idx + delta + tabs.count) % tabs.count]
    }
}
