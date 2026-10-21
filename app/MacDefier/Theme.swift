import SwiftUI
import AppKit
import Collaboration

/// Design tokens from workspace/DESIGN.md (macOS HIG / MacDefier).
///
/// These colors intentionally resolve through `NSAppearance`: the application
/// follows macOS Light/Dark Mode without each page having to manage its own
/// color scheme.
enum MDTheme {
    // Backgrounds
    static let window = Color.adaptive(light: 0xECECEC, dark: 0x1E1E1E)
    static let sidebar = Color.adaptive(light: 0xE5E5EA, dark: 0x252527)
    static let content = Color.adaptive(light: 0xF7F8FB, dark: 0x202023)
    static let surface = Color.adaptive(light: 0xFFFFFF, dark: 0x2C2C2E)
    static let surfaceInset = Color.adaptive(light: 0xF0F2F6, dark: 0x363639)
    static let surfaceSelected = Color.adaptive(
        light: 0x007AFF, dark: 0x0A84FF,
        lightAlpha: 0.12, darkAlpha: 0.26
    )

    // Labels
    static let label = Color.adaptive(
        light: 0x000000, dark: 0xFFFFFF,
        lightAlpha: 0.88, darkAlpha: 0.92
    )
    static let secondary = Color.adaptive(
        light: 0x3C3C43, dark: 0xFFFFFF,
        lightAlpha: 0.60, darkAlpha: 0.72
    )
    static let tertiary = Color.adaptive(
        light: 0x3C3C43, dark: 0xFFFFFF,
        lightAlpha: 0.74, darkAlpha: 0.64
    )

    // Borders / accents
    static let border = Color.adaptive(light: 0xD1D1D6, dark: 0x48484A)
    static let separator = Color.adaptive(
        light: 0x3C3C43, dark: 0x545458,
        lightAlpha: 0.18, darkAlpha: 0.65
    )
    /// Fine card and avatar outlines. Unlike a black overlay, this remains
    /// visible against dark material and control backgrounds.
    static let subtleBorder = Color.adaptive(
        light: 0x000000, dark: 0xFFFFFF,
        lightAlpha: 0.08, darkAlpha: 0.16
    )
    static let accent = Color.adaptive(light: 0x007AFF, dark: 0x0A84FF)
    static let success = Color.adaptive(light: 0x34C759, dark: 0x30D158)
    static let warning = Color.adaptive(light: 0xFF9500, dark: 0xFF9F0A)
    static let danger = Color.adaptive(light: 0xFF3B30, dark: 0xFF453A)
    static let chart1 = Color.adaptive(light: 0x007AFF, dark: 0x0A84FF)
    static let chart2 = Color.adaptive(light: 0x34C759, dark: 0x30D158)
    static let chart3 = Color.adaptive(light: 0xFF9500, dark: 0xFF9F0A)
    static let chart4 = Color.adaptive(light: 0xAF52DE, dark: 0xBF5AF2)
    static let chart6 = Color.adaptive(light: 0x8E8E93, dark: 0x98989D)

    static let radiusCard: CGFloat = 12
    static let radiusButton: CGFloat = 6
    static let resultCardRadius: CGFloat = 12
    static let resultCardGap: CGFloat = 12
    static let resultHeaderHeight: CGFloat = 56
    static let resultInset: CGFloat = 14
    /// 内容区左右边距；铺满主栏，不人为限窄列
    static let pagePadding: CGFloat = 24
    static let contentMaxWidth: CGFloat = 10_000
    static let sidebarWidth: CGFloat = 168
    /// 列表行默认垂直内边距（密排）
    static let rowVerticalPadding: CGFloat = 6
    static let rowSeparatorLeading: CGFloat = 14
    /// 区块纵向间距
    static let sectionSpacing: CGFloat = 10
    /// 页标题 20 bold；顶栏底 padding
    static let pageTitleSize: CGFloat = 22
    static let pageHeaderBottom: CGFloat = 8
    /// E 实体行身份槽 / 组头符号槽
    static let entityIconSize: CGFloat = 28
    static let groupIconSize: CGFloat = 20
    static let entityIconSpacing: CGFloat = 10
    /// 分隔线缩进 = 行左右 padding + 28 + 间距
    static var entitySeparatorLeading: CGFloat { 14 + entityIconSize + entityIconSpacing }
    static let metaSizeWidth: CGFloat = 72
    static let metaVersionWidth: CGFloat = 48
}

/// Per-app appearance preference. `system` is the default and changes only
/// MacDefier's appearance; it never changes the user's macOS setting.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "app.appearance"

    var id: String { rawValue }

    var settingsTitle: String {
        switch self {
        case .system: return L10n.t("settings.appearance_system")
        case .light: return L10n.t("settings.appearance_light")
        case .dark: return L10n.t("settings.appearance_dark")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    private var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    static func apply(rawValue: String) {
        let selection = AppAppearance(rawValue: rawValue) ?? .system
        NSApp.appearance = selection.nsAppearance
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    /// A custom token whose value follows the containing window's AppKit
    /// appearance. Keep source-of-truth tokens here instead of scattering
    /// `colorScheme` branches through individual views.
    static func adaptive(
        light: UInt32,
        dark: UInt32,
        lightAlpha: Double = 1,
        darkAlpha: Double = 1
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            let alpha = isDark ? darkAlpha : lightAlpha
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha
            )
        })
    }
}

// MARK: - Shared chrome

/// Presentation only: each page retains its own eligibility, confirmation and executor.
struct MDSelectionActionBar<Status: View>: View {
    let selectedCount: Int
    let selectedBytes: String
    let canClean: Bool
    var progress: Double? = nil
    let buttonIdentifier: String
    var actionHelp: String = L10n.t("cleanup.review_selected")
    let action: () -> Void
    @ViewBuilder var status: () -> Status

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedCount == 0 ? L10n.t("cleanup.none_selected")
                     : L10n.t("cleanup.selected_line", selectedCount, selectedBytes))
                    .font(.callout.weight(.medium)).foregroundStyle(MDTheme.label)
                    .fixedSize(horizontal: false, vertical: true)
                status()
            }
            Spacer(minLength: 8)
            if let progress {
                ProgressView(value: progress).frame(width: 72)
                    .accessibilityLabel(L10n.t("aitools.moving"))
            }
            Button(action: action) {
                Label(L10n.t("cleanup.clean_selected"), systemImage: "trash")
                    .font(.callout.weight(.semibold))
                    .frame(minWidth: 128, minHeight: 34)
                    .padding(.horizontal, 12)
                    .foregroundStyle(canClean ? Color.white : MDTheme.secondary)
                    .background(canClean ? MDTheme.accent : MDTheme.surfaceInset,
                                in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain).disabled(!canClean)
            .accessibilityIdentifier(buttonIdentifier).help(actionHelp)
        }
        .padding(.horizontal, MDTheme.pagePadding).padding(.vertical, 10)
        .frame(maxWidth: .infinity).background(MDTheme.surface)
        .overlay(alignment: .top) { Divider() }
    }
}

extension View {
    func mdResultHeader() -> some View {
        padding(.horizontal, MDTheme.resultInset).padding(.vertical, 10)
            .frame(minHeight: MDTheme.resultHeaderHeight)
    }
}

/// Neutral navigation surface; selected state must not compete with page actions.
struct MDGlassTabs<Tab: Hashable>: View {
    let tabs: [(id: Tab, title: String)]
    @Binding var selection: Tab

    var body: some View {
        buttons
            .background(MDTheme.surfaceInset, in: Capsule())
            .overlay { Capsule().strokeBorder(MDTheme.subtleBorder, lineWidth: 0.5) }
    }

    private var buttons: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.id) { tab in
                Button { selection = tab.id } label: {
                    Text(tab.title)
                        .font(.system(size: 13, weight: selection == tab.id ? .semibold : .regular))
                        .foregroundStyle(selection == tab.id ? MDTheme.label : MDTheme.secondary)
                        .padding(.horizontal, 13).frame(minHeight: 32)
                        .background(selection == tab.id ? MDTheme.surface : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab.id ? [.isSelected] : [])
            }
        }.padding(4)
        .accessibilityElement(children: .contain)
    }
}

struct MDCard<Content: View>: View {
    var padding: CGFloat = 12
    /// 在双列等高容器内为 true 时，背景铺满行高
    var fillHeight: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(
                maxWidth: .infinity,
                maxHeight: fillHeight ? .infinity : nil,
                alignment: .topLeading
            )
            .background(
                RoundedRectangle(cornerRadius: MDTheme.radiusCard, style: .continuous)
                    .fill(MDTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MDTheme.radiusCard, style: .continuous)
                    .stroke(MDTheme.border.opacity(0.5), lineWidth: 0.5)
            )
    }
}

/// 页头：单行标题 + 可选 meta + trailing；无副标题堆砌
struct MDPageHeader<Trailing: View>: View {
    let title: String
    var meta: String? = nil
    var titleHelp: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    init(
        title: String,
        meta: String? = nil,
        titleHelp: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.meta = meta
        self.titleHelp = titleHelp
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.system(size: MDTheme.pageTitleSize, weight: .bold))
                .foregroundStyle(MDTheme.label)
                .lineLimit(1)
                .modifier(OptionalHelp(titleHelp))
            if let meta, !meta.isEmpty {
                Text(meta)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(MDTheme.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension MDPageHeader where Trailing == EmptyView {
    init(title: String, meta: String? = nil, titleHelp: String? = nil) {
        self.init(title: title, meta: meta, titleHelp: titleHelp) { EmptyView() }
    }
}

private struct OptionalHelp: ViewModifier {
    let text: String?
    init(_ text: String?) { self.text = text }
    func body(content: Content) -> some View {
        if let text, !text.isEmpty {
            content.help(text)
        } else {
            content
        }
    }
}

/// 顶栏统一左右/顶/底 padding（hiddenTitleBar）
struct MDPageBar<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, MDTheme.pagePadding)
            .padding(.top, 8)
            .padding(.bottom, 8)
    }
}

/// E 实体行：28 身份槽（App 真图或 SF+浅底）
struct MDEntityLeading: View {
    enum Kind {
        case appIcon(NSImage)
        case symbol(String, tint: Color = MDTheme.accent)
    }

    let kind: Kind
    var size: CGFloat = MDTheme.entityIconSize

    var body: some View {
        switch kind {
        case .appIcon(let image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .symbol(let name, let tint):
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(MDTheme.surfaceInset)
                    .frame(width: size, height: size)
                Image(systemName: name)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: size, height: size)
        }
    }
}

/// 组头 20 槽 SF（清理分类等）
struct MDGroupIcon: View {
    let systemName: String
    var tint: Color = MDTheme.accent
    var size: CGFloat = MDTheme.groupIconSize

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(MDTheme.surfaceInset)
                .frame(width: size, height: size)
            Image(systemName: systemName)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

/// 胶囊标签（channel / 风险 / 系统）
struct MDTag: View {
    let text: String
    var tone: Tone = .neutral

    enum Tone {
        case neutral, accent, warning, success
        var fg: Color {
            switch self {
            case .neutral: return MDTheme.secondary
            case .accent: return MDTheme.accent
            case .warning: return MDTheme.warning
            case .success: return MDTheme.success
            }
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tone.fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(MDTheme.surfaceInset, in: Capsule())
            .lineLimit(1)
    }
}

/// 右列体积/版本（等宽对齐）
struct MDRowMeta: View {
    let text: String
    var width: CGFloat = MDTheme.metaSizeWidth
    var emphasis: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: emphasis ? 12 : 11, weight: emphasis ? .medium : .regular).monospacedDigit())
            .foregroundStyle(emphasis ? MDTheme.secondary : MDTheme.tertiary)
            .lineLimit(1)
            .frame(minWidth: width, alignment: .trailing)
    }
}

/// 页内实体切换：下划线 Tab（软件 App|CLI、监控七页）
struct MDUnderlineTabBar<Tab: Hashable>: View {
    let tabs: [(id: Tab, title: String, badge: String?)]
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.id) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { selection = tab.id }
                } label: {
                    VStack(spacing: 0) {
                        HStack(spacing: 5) {
                            Text(tab.title)
                                .font(.system(size: 12, weight: selection == tab.id ? .semibold : .medium))
                                .lineLimit(1)
                            if let badge = tab.badge, !badge.isEmpty {
                                Text(badge)
                                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                                    .foregroundStyle(selection == tab.id ? MDTheme.accent : MDTheme.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .foregroundStyle(selection == tab.id ? MDTheme.accent : MDTheme.secondary)
                        .fixedSize(horizontal: true, vertical: false)

                        Rectangle()
                            .fill(selection == tab.id ? MDTheme.accent : Color.clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}

struct MDProgressBar: View {
    var progress: Double
    var tint: Color = MDTheme.accent
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(MDTheme.surfaceInset)
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, progress)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}

struct MDRing: View {
    var progress: Double
    var lineWidth: CGFloat = 8
    var size: CGFloat = 96
    var tint: Color = MDTheme.chart1
    var center: String
    var caption: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(MDTheme.surfaceInset, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text(center)
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(MDTheme.label)
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(MDTheme.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

struct MDPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title).fontWeight(.semibold)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(MDTheme.accent, in: RoundedRectangle(cornerRadius: MDTheme.radiusButton, style: .continuous))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}

struct MDSecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(MDTheme.surfaceInset, in: RoundedRectangle(cornerRadius: MDTheme.radiusButton, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MDTheme.radiusButton, style: .continuous)
                    .stroke(MDTheme.border, lineWidth: 0.5)
            )
            .foregroundStyle(MDTheme.label)
        }
        .buttonStyle(.plain)
    }
}

struct MDKPICard: View {
    let title: String
    let value: String
    var unit: String = ""
    var footer: String = ""
    var progress: Double
    var tint: Color = MDTheme.accent

    var body: some View {
        MDCard(padding: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MDTheme.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value)
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                        .foregroundStyle(MDTheme.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if !unit.isEmpty {
                        Text(unit)
                            .font(.system(size: 12))
                            .foregroundStyle(MDTheme.secondary)
                    }
                }
                MDProgressBar(progress: progress, tint: tint, height: 3)
                if !footer.isEmpty {
                    Text(footer)
                        .font(.system(size: 10))
                        .foregroundStyle(MDTheme.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }
}

struct MDProcessRow: View {
    let name: String
    let detail: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(MDTheme.label)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(MDTheme.tertiary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .foregroundStyle(MDTheme.secondary)
                .lineLimit(1)
                .frame(minWidth: 56, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }
}

struct MDSectionTitle: View {
    let title: String
    var meta: String? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MDTheme.label)
            Spacer()
            if let meta {
                Text(meta)
                    .font(.system(size: 11))
                    .foregroundStyle(MDTheme.tertiary)
            }
        }
    }
}

// MARK: - Native-ish grouped list chrome（全页统一横线 / 分组卡片）

/// 系统设置感细分割线；默认左缩进与设置行对齐
struct MDRowSeparator: View {
    var leading: CGFloat = 14

    var body: some View {
        Rectangle()
            .fill(MDTheme.separator)
            .frame(height: 0.5)
            .padding(.leading, leading)
    }
}

/// 白底 inset 分组容器（System Settings / Stats 感）
struct MDGroupedList<Content: View>: View {
    var cornerRadius: CGFloat = MDTheme.radiusCard
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(MDTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(MDTheme.border.opacity(0.5), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// 列表行外壳：统一 padding + 可选底部分割线
struct MDListRowChrome<Content: View>: View {
    var showSeparator: Bool = true
    var separatorLeading: CGFloat = MDTheme.rowSeparatorLeading
    var horizontalPadding: CGFloat = 14
    var verticalPadding: CGFloat = MDTheme.rowVerticalPadding
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
            if showSeparator {
                MDRowSeparator(leading: separatorLeading)
            }
        }
    }
}

/// 双列同宽 **且同高**（评分|提示、综合|硬件、网络总览|流量 等）
struct MDEqualSplit<Left: View, Right: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var left: () -> Left
    @ViewBuilder var right: () -> Right

    var body: some View {
        // 1) 先按内容量出较高一侧 → 2) 两侧 maxHeight∞ 拉齐 → 3) fixedSize 锁住行高
        HStack(alignment: .top, spacing: spacing) {
            left()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            right()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    func mdContentCanvas() -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(MDTheme.content)
    }

    /// 主内容：铺满主栏（不再缩成窄列居中）
    func mdContentColumn(maxWidth: CGFloat = MDTheme.contentMaxWidth) -> some View {
        self
            .frame(maxWidth: maxWidth == MDTheme.contentMaxWidth ? .infinity : maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 页面统一水平内边距
    func mdPagePadding() -> some View {
        self.padding(.horizontal, MDTheme.pagePadding)
    }

    /// Scroll 内容区顶距（整页进 Scroll 时用，与 MDPageBar 顶距一致）
    func mdScrollPageTop() -> some View {
        self
            .padding(.horizontal, MDTheme.pagePadding)
            .padding(.top, 16)
            .padding(.bottom, 16)
    }
}

enum LocalIdentity {
    static var displayName: String {
        let full = NSFullUserName()
        if full.isEmpty { return NSUserName() }
        return full
    }

    static var shortName: String {
        let n = displayName
        if let first = n.split(separator: " ").first { return String(first) }
        return n
    }

    static var monogram: String {
        let n = displayName.trimmingCharacters(in: .whitespaces)
        guard let c = n.first else { return "?" }
        return String(c).uppercased()
    }

    /// 本机登录用户真实头像（系统设置同款来源）。
    /// **禁止** `NSImage.userName`——那是通用剪影，不是用户照片。
    static var accountImage: NSImage? {
        if let cached = _accountImageCache { return cached }
        let img = resolveAccountImage()
        _accountImageCache = img
        return img
    }

    /// 进程内缓存（头像不会在会话中变）
    private static var _accountImageCache: NSImage??

    private static func resolveAccountImage() -> NSImage? {
        let names = [NSUserName(), NSFullUserName()]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let authorities: [CBIdentityAuthority] = [
            CBIdentityAuthority.default(),
            CBIdentityAuthority.local(),
            CBIdentityAuthority.managed()
        ].compactMap { $0 }

        for name in names {
            for auth in authorities {
                if let identity = CBIdentity(name: name, authority: auth),
                   let image = identity.image,
                   isUsableAvatar(image) {
                    return image
                }
            }
        }

        // POSIX uid via name is enough on personal Macs；图片目录作兜底
        if let fromFile = userPicturesDirectoryImage() {
            return fromFile
        }

        return nil
    }

    private static func isUsableAvatar(_ image: NSImage) -> Bool {
        guard image.isValid else { return false }
        let s = image.size
        // 过小 / 空图不要
        guard s.width >= 16, s.height >= 16 else { return false }
        return true
    }

    private static func userPicturesDirectoryImage() -> NSImage? {
        let home = NSHomeDirectory()
        let candidates = [
            (home as NSString).appendingPathComponent("Library/User Pictures"),
            "/Library/User Pictures"
        ]
        let short = NSUserName().lowercased()
        let full = NSFullUserName().lowercased()
        for dir in candidates {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            // 优先文件名含用户名
            let ranked = files.sorted { a, b in
                let al = a.lowercased(), bl = b.lowercased()
                let ascore = (al.contains(short) ? 2 : 0) + (full.contains(al) || al.contains(full.prefix(4).description) ? 1 : 0)
                let bscore = (bl.contains(short) ? 2 : 0) + (full.contains(bl) || bl.contains(full.prefix(4).description) ? 1 : 0)
                return ascore > bscore
            }
            for name in ranked {
                let ext = (name as NSString).pathExtension.lowercased()
                guard ["png", "jpg", "jpeg", "tif", "tiff", "heic"].contains(ext) else { continue }
                let path = (dir as NSString).appendingPathComponent(name)
                if let img = NSImage(contentsOfFile: path), isUsableAvatar(img) {
                    return img
                }
            }
        }
        return nil
    }
}

// MARK: - Selection checkbox

/// Native checkbox appearance with a generous pointer target. Only selection is
/// interactive here; Finder, disclosure and management buttons stay outside it.
struct MDCheckbox<Label: View>: View {
    private let title: String
    @Binding private var isOn: Bool
    private let label: Label
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {
        self.title = title
        self._isOn = isOn
        self.label = label()
    }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Toggle("", isOn: .constant(isOn))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .frame(width: 28, height: 28)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                label
            }
            .frame(minWidth: 28, minHeight: 28, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.checkbox)
                .disabled(!isEnabled)
        }
    }
}

extension MDCheckbox where Label == EmptyView {
    init(_ title: String, isOn: Binding<Bool>) {
        self.init(title, isOn: isOn) { EmptyView() }
    }
}

// A copy action keeps paths available without embedding native selectable-text
// overlays in frequently updated cleanup rows (a macOS layout-recursion path).
extension View {
    func mdCopyPathMenu(_ path: String) -> some View {
        contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            } label: {
                Label(L10n.t("common.copy_path"), systemImage: "doc.on.doc")
            }
        }
    }
}
