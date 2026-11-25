import SwiftUI
import AppKit
import CleanupKit

/// Pure shortcut-invoked (`⌘K`) command palette. Adds zero permanent UI chrome to the window.
struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    @ObservedObject private var nav = AppNavigator.shared
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var searchFocused: Bool

    @State private var query = ""
    @State private var selectedID: String?
    @State private var hoveredID: String?

    private struct CommandItem: Identifiable {
        enum Group: String, CaseIterable {
            case navigate
            case monitor
            case actions

            var title: String {
                switch self {
                case .navigate: return L10n.t("palette.group.navigate")
                case .monitor: return L10n.t("palette.group.monitor")
                case .actions: return L10n.t("palette.group.actions")
                }
            }
        }

        let id: String
        let group: Group
        let title: String
        let subtitle: String?
        let systemImage: String
        let shortcut: String?
        let keywords: [String]
        let perform: () -> Void
    }

    private var allItems: [CommandItem] {
        let routeOrder: [AppRoute] = [.diagnostic, .cleanup, .aiTools, .diskMap, .software, .monitor, .settings]
        let navItems = routeOrder.enumerated().map { index, route in
            CommandItem(
                id: "route.\(route.rawValue)",
                group: .navigate,
                title: route.title,
                subtitle: nil,
                systemImage: route.systemImage,
                shortcut: route == .settings ? "⌘," : "⌘\(index + 1)",
                keywords: [route.rawValue, route.title],
                perform: {
                    if route == .aiTools {
                        nav.openAIToolsStorage()
                    } else {
                        nav.route = route
                    }
                }
            )
        }

        let subrouteItems: [CommandItem] = [
            CommandItem(
                id: "subroute.services",
                group: .navigate,
                title: "\(AppRoute.aiTools.title) · \(L10n.t("software.tab.services"))",
                subtitle: nil,
                systemImage: "gearshape.2",
                shortcut: nil,
                keywords: ["services", "launchagents", "daemon", "后台服务", "自启", "守护"],
                perform: {
                    nav.openSoftwareServices()
                }
            ),
            CommandItem(
                id: "subroute.cli",
                group: .navigate,
                title: "\(AppRoute.software.title) · \(L10n.t("software.tab.cli"))",
                subtitle: nil,
                systemImage: "terminal",
                shortcut: nil,
                keywords: ["cli", "npm", "brew", "uv", "命令行"],
                perform: {
                    SoftwareService.shared.listKind = .cli
                    nav.route = .software
                }
            ),
        ]

        let monitorItems = MonitorTab.allCases.map { tab in
            CommandItem(
                id: "monitor.\(tab.rawValue)",
                group: .monitor,
                title: "\(AppRoute.monitor.title) · \(tab.title)",
                subtitle: nil,
                systemImage: tab.systemImage,
                shortcut: nil,
                keywords: ["monitor", "监控", tab.rawValue, tab.title],
                perform: {
                    nav.monitorTab = tab
                    nav.route = .monitor
                }
            )
        }

        let actionItems: [CommandItem] = [
            CommandItem(
                id: "action.refresh",
                group: .actions,
                title: L10n.t("menu.refresh_page"),
                subtitle: nil,
                systemImage: "arrow.clockwise",
                shortcut: "⌘R",
                keywords: ["refresh", "rescan", "scan", "刷新", "重扫", "扫描"],
                perform: {
                    NotificationCenter.default.post(name: .macDefierRefreshCurrentRoute, object: nil)
                }
            ),
            CommandItem(
                id: "action.mister",
                group: .actions,
                title: L10n.t("menu.toggle_mister"),
                subtitle: nil,
                systemImage: "sparkles",
                shortcut: "⌘⇧M",
                keywords: ["ai", "mister", "defier", "chat", "助手", "对话"],
                perform: {
                    nav.misterOpen.toggle()
                }
            ),
            CommandItem(
                id: "action.guide",
                group: .actions,
                title: L10n.t("guide.menu"),
                subtitle: nil,
                systemImage: "questionmark.circle",
                shortcut: nil,
                keywords: ["guide", "help", "tutorial", "引导", "帮助"],
                perform: {
                    UsageGuideState.shared.replay()
                }
            ),
            CommandItem(
                id: "action.website",
                group: .actions,
                title: L10n.t("settings.website"),
                subtitle: AppUpdateController.officialWebsiteDisplay,
                systemImage: "globe",
                shortcut: nil,
                keywords: ["website", "official", "macdefier", "官网", "官方网站", "介绍"],
                perform: {
                    NSWorkspace.shared.open(AppUpdateController.officialWebsiteURL)
                }
            ),
            CommandItem(
                id: "action.appearance",
                group: .actions,
                title: L10n.t("palette.action.appearance"),
                subtitle: (AppAppearance(rawValue: appearanceRaw) ?? .system).settingsTitle,
                systemImage: "circle.lefthalf.filled",
                shortcut: nil,
                keywords: ["theme", "appearance", "dark", "light", "外观", "深色", "浅色"],
                perform: {
                    let all = AppAppearance.allCases
                    let current = AppAppearance(rawValue: appearanceRaw) ?? .system
                    let next = all[((all.firstIndex(of: current) ?? 0) + 1) % all.count]
                    appearanceRaw = next.rawValue
                    AppAppearance.apply(rawValue: next.rawValue)
                }
            )
        ]

        return navItems + subrouteItems + monitorItems + actionItems
    }

    private var filteredItems: [CommandItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return allItems }
        let q = trimmed.lowercased()
        return allItems.filter { item in
            item.title.lowercased().contains(q)
                || (item.subtitle?.lowercased().contains(q) ?? false)
                || item.keywords.contains(where: { $0.lowercased().contains(q) })
        }
    }

    private var groupedSections: [(group: CommandItem.Group, items: [CommandItem])] {
        let items = filteredItems
        return CommandItem.Group.allCases.compactMap { group in
            let matching = items.filter { $0.group == group }
            return matching.isEmpty ? nil : (group, matching)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider()
            resultsList
            Divider()
            footerHints
        }
        .frame(width: 580, height: 400)
        .background {
            if reduceTransparency {
                MDTheme.surface
            } else {
                Rectangle().fill(.thickMaterial)
            }
        }
        .onAppear {
            searchFocused = true
            selectedID = filteredItems.first?.id
        }
        .onChange(of: query) { _, _ in
            if let current = selectedID, filteredItems.contains(where: { $0.id == current }) {
                return
            }
            selectedID = filteredItems.first?.id
        }
        .onKeyPress(.upArrow) {
            moveSelection(delta: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(delta: 1)
            return .handled
        }
        .onKeyPress(.return) {
            executeSelected()
            return .handled
        }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.callout.weight(.medium))
                .foregroundStyle(MDTheme.secondary)
                .accessibilityHidden(true)

            TextField(L10n.t("palette.placeholder"), text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onSubmit { executeSelected() }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(MDTheme.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("common.clear"))
            }

            Button {
                isPresented = false
            } label: {
                Text("esc")
                    .font(.caption2.monospaced())
                    .foregroundStyle(MDTheme.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(MDTheme.surfaceInset, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("palette.hint.close"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if groupedSections.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.title2)
                                .foregroundStyle(MDTheme.tertiary)
                            Text(L10n.t("palette.empty"))
                                .font(.callout)
                                .foregroundStyle(MDTheme.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                    } else {
                        ForEach(groupedSections, id: \.group.rawValue) { section in
                            Text(section.group.title)
                                .font(.caption2.weight(.semibold))
                                .tracking(0.8)
                                .foregroundStyle(MDTheme.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                                .padding(.bottom, 2)

                            ForEach(section.items) { item in
                                row(for: item)
                                    .id(item.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .onChange(of: selectedID) { _, newValue in
                guard let newValue else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private func row(for item: CommandItem) -> some View {
        let isSelected = selectedID == item.id
        let isHovered = hoveredID == item.id

        return Button {
            run(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.systemImage)
                    .font(.callout.weight(.medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isSelected ? .white : MDTheme.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .white : MDTheme.label)
                        .lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(isSelected ? Color.white.opacity(0.82) : MDTheme.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if let shortcut = item.shortcut {
                    Text(shortcut)
                        .font(.caption2.monospaced())
                        .foregroundStyle(isSelected ? Color.white.opacity(0.92) : MDTheme.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            isSelected ? Color.white.opacity(0.18) : MDTheme.surfaceInset,
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(MDTheme.accent)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(MDTheme.rowHover)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredID = hovering ? item.id : (hoveredID == item.id ? nil : hoveredID)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: hoveredID)
    }

    private var footerHints: some View {
        HStack(spacing: 16) {
            hint("↑↓", L10n.t("palette.hint.navigate"))
            hint("↵", L10n.t("palette.hint.run"))
            hint("esc", L10n.t("palette.hint.close"))
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(MDTheme.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption2.monospaced())
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(MDTheme.surfaceInset, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(label)
        }
    }

    private func moveSelection(delta: Int) {
        let items = filteredItems
        guard !items.isEmpty else {
            selectedID = nil
            return
        }
        guard let current = selectedID,
              let idx = items.firstIndex(where: { $0.id == current }) else {
            selectedID = items.first?.id
            return
        }
        let next = (idx + delta + items.count) % items.count
        selectedID = items[next].id
    }

    private func executeSelected() {
        let items = filteredItems
        if let current = selectedID, let match = items.first(where: { $0.id == current }) {
            run(match)
        } else if let first = items.first {
            run(first)
        }
    }

    private func run(_ item: CommandItem) {
        isPresented = false
        item.perform()
    }
}
