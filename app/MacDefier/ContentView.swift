import SwiftUI
import AppKit
import MonitorKit
import CleanupKit

/// Horizontal workbench: keep existing page services, sheets and navigation state.
struct ContentView: View {
    @ObservedObject private var nav = AppNavigator.shared
    @ObservedObject private var guide = UsageGuideState.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.chinese.rawValue
    @State private var commandPalettePresented = false
    private let routes: [AppRoute] = [.diagnostic, .cleanup, .aiTools, .diskMap, .software, .monitor, .settings]

    var body: some View {
        ZStack {
            ZStack {
                VStack(spacing: 0) {
                    unifiedNavigationBar
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(MDTheme.content)
                .background(WindowChromeInstaller())
                .ignoresSafeArea()
                // Keep one route-independent default dock above persistent page actions.
                // This is an initial/reset position, not a restriction on user dragging.
                MisterDefenderOverlay(isOpen: $nav.misterOpen, dockInset: 76)
                    .environmentObject(MonitorService.shared)
                    .padding(.top, WindowChrome.trafficLightsTop)
                    .ignoresSafeArea()
            }
            .disabled(guide.isPresented)
            .allowsHitTesting(!guide.isPresented)
            .accessibilityHidden(guide.isPresented)
            if guide.isPresented {
                UsageGuideOverlay(guide: guide) {
                    guide.dismiss()
                    nav.route = .settings
                }
            }
        }
        .sheet(isPresented: $commandPalettePresented) {
            CommandPaletteView(isPresented: $commandPalettePresented)
        }
        .onReceive(NotificationCenter.default.publisher(for: .macDefierOpenCommandPalette)) { _ in
            guard !guide.isPresented else { return }
            commandPalettePresented = true
        }
        .environment(\.layoutDirection, .leftToRight)
        .environment(\.locale, L10n.locale)
        .tint(MDTheme.accent)
        .animation(nil, value: appLanguageRaw)
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
        .background {
            MainWindowVisibilityObserver { visible in
                MonitorService.shared.setMainWindowVisible(visible)
            }
        }
        .onAppear { MonitorService.shared.setMonitorPageVisible(nav.route == .monitor) }
        .onChange(of: nav.route) { _, route in
            MonitorService.shared.setMonitorPageVisible(route == .monitor)
        }
        .onDisappear {
            MonitorService.shared.setMainWindowVisible(false)
            MonitorService.shared.setMonitorPageVisible(false)
        }
    }

    private var unifiedNavigationBar: some View {
        let sideReserve = WindowChrome.trafficLightsLeading
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                Color.clear
                    .frame(minWidth: sideReserve, maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)

                navigationTabsPill

                HStack(spacing: 0) {
                    UpdateDownloadControl()
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.leading, 8)
                    Spacer(minLength: 14)
                }
                .frame(minWidth: 14, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(height: WindowChrome.trafficLightsTop)

            HStack(spacing: 8) {
                scrollableNavigationTabsPill
                UpdateDownloadControl()
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.leading, sideReserve)
            .padding(.trailing, 14)
            .frame(height: WindowChrome.trafficLightsTop)
        }
        .frame(maxWidth: .infinity)
        .frame(height: WindowChrome.trafficLightsTop)
        .background(MDTheme.content)
    }

    private var scrollableNavigationTabsPill: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                navigationTabsPill
                    .padding(.horizontal, 4)
                    .frame(height: WindowChrome.trafficLightsTop)
            }
            .onChange(of: nav.route) { _, route in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                    reader.scrollTo(route, anchor: .center)
                }
            }
            .onAppear { reader.scrollTo(nav.route, anchor: .center) }
        }
        .frame(maxWidth: .infinity, maxHeight: WindowChrome.trafficLightsTop)
    }

    private var navigationTabsPill: some View {
        MDGlassTabs(tabs: routes.map { (id: $0, title: $0.title) }, selection: $nav.route)
            .id(appLanguageRaw)
            .accessibilityIdentifier("workbench.navigation")
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            Group {
                switch nav.route {
                case .diagnostic:
                    DiagnosticView(
                        onOpenMonitor: { finding in
                            nav.openMonitor(focus: finding)
                        },
                        onOpenCleanupAndScan: { finding in
                            // Home is a diagnosis entry. Scanning is explicit on the destination page.
                            nav.openCleanup(focus: finding)
                        },
                        onOpenSoftware: { finding in
                            nav.focusSoftware(path: finding?.appPath,
                                              bundleID: finding?.appBundleID,
                                              name: finding?.processName)
                        },
                        onOpenMister: { nav.misterOpen = true }
                    )
                case .cleanup:
                    CleanupView()
                case .aiTools:
                    AIToolCleanupView()
                case .diskMap:
                    DiskMapView()
                case .software:
                    SoftwareView()
                case .monitor:
                    MonitorCenterView(selectedTab: $nav.monitorTab)
                case .settings:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MDTheme.content)
    }

}

/// High-frequency sampling is isolated from navigation and page state.
struct WorkbenchLiveReadings: View {
    @EnvironmentObject private var monitor: MonitorService
    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.chinese.rawValue
    var body: some View {
        // Expiry must update even when samplers pause while the window is inactive.
        GeometryReader { geometry in
            TimelineView(.periodic(from: .now, by: 2)) { timeline in
                content(at: timeline.date, compact: geometry.size.width < 760)
            }
            .id(appLanguageRaw)
        }
        .frame(height: 64)
    }
    private var unavailable: String { L10n.t("workbench.metric_unavailable") }

    private func content(at now: Date, compact: Bool) -> some View {
        let snapshot = monitor.snapshot
        return HStack(spacing: 0) {
            metric("CPU", symbol: "cpu", value: snapshot.cpuIsFresh(at: now)
                   ? String(format: "%.0f%%", (snapshot.cpu?.totalUsage ?? 0) * 100) : unavailable, compact: compact)
            Divider().frame(height: 28)
            metric(L10n.t("diag.kpi.memory"), symbol: "memorychip", value: memoryValue(at: now), compact: compact)
            Divider().frame(height: 28)
            metric(L10n.t("workbench.disk_free"), symbol: "internaldrive", value: diskValue(at: now), compact: compact)
            Divider().frame(height: 28)
            metric(L10n.t("diag.kpi.network"), symbol: "wifi", value: snapshot.networkIsFresh(at: now)
                   ? snapshot.network.first.map { Format.rate($0.bytesInPerSec) } ?? unavailable : unavailable, compact: compact)
        }
        .frame(height: 64)
        .background(MDTheme.surfaceInset)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private func memoryValue(at now: Date) -> String {
        guard monitor.snapshot.ramIsFresh(at: now), let ram = monitor.snapshot.ram else { return unavailable }
        return String(format: "%.1f / %.0f GB", Double(ram.used) / 1_073_741_824,
                      Double(ram.total) / 1_073_741_824)
    }
    private func diskValue(at now: Date) -> String {
        guard monitor.snapshot.systemDiskIsFresh(at: now),
              let disk = monitor.snapshot.disks.first(where: DiagnosticScore.isSystemVolume) else { return unavailable }
        return Format.bytes(disk.free)
    }
    private func metric(_ title: String, symbol: String, value: String, compact: Bool) -> some View {
            HStack(spacing: 10) {
                if !compact {
                    Image(systemName: symbol).font(.system(size: 22))
                        .foregroundStyle(MDTheme.secondary).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 11)).foregroundStyle(MDTheme.secondary)
                    Text(value).font(.system(size: compact ? 16 : 20, weight: .semibold).monospacedDigit())
                        .foregroundStyle(MDTheme.label).lineLimit(1).minimumScaleFactor(0.7)
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, compact ? 10 : 14).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(value)")
            .accessibilityAddTraits(.isStaticText)
    }
}

