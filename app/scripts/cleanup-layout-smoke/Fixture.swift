// Diagnostic-only, in-memory fixture. No app service or cleanup executor exists.
struct CleanableItem: Identifiable {
    let id: String
    let path: String
    let category: CleanupCategory
    var isSelected = false
    var risk: CleanupRisk = .rebuild
    var isLowRiskBulkEligible: Bool { risk != .skip }
    var localizedDisplayTitle: String { "模拟应用缓存 · \(id)" }
    var localizedWhatIsIt: String { "仅测试布局，不对应真实文件，也没有删除能力。" }
    var ifCleaned: String { risk == .skip ? "cleanup_blocked:fixture" : "" }
    var localizedIfCleaned: String { "应用正在运行，建议保留；此处仅为模拟数据。" }
    var homeRelativePath: String { path }
    var formattedSize: String { "128.4 MB" }
}
struct CleanupCategoryGroup: Identifiable {
    let category: CleanupCategory
    var items: [CleanableItem]
    var id: CleanupCategory { category }
    var totalBytes: UInt64 { UInt64(items.count) * 134217728 }
}
extension CleanupCategory {
    var localizedTitle: String { title }
    var localizedWhatIsIt: String { whatIsIt }
    var localizedIfCleaned: String { ifCleaned }
}
extension CleanupRisk {
    var localizedLabel: String { label }
    var localizedTip: String { tip }
}
enum Format {
    static func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }
}
enum L10n {
    static func t(_ key: String, _ args: CVarArg...) -> String {
        switch key {
        case "cleanup.select_group": return "选择分类：\(args.first!)"
        case "cleanup.paths_count": return "\(args.first!) 个路径"
        case "cleanup.show_more_items": return "显示更多（还有 \(args.first!) 项）"
        default: return key
        }
    }
}
extension View {
    func mdCopyPathMenu(_ path: String) -> some View { self }
}

// Passive AppKit marker: records geometry but never participates in hit testing.
@MainActor final class ProbeMarkerView: NSView {
    var key = ""
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
@MainActor enum ProbeMarkers {
    static var views: [String: ProbeMarkerView] = [:]
    // Instrument only the controls directly exercised, keeping long-list cost
    // close to the production view rather than adding hundreds of AppKit views.
    static func records(_ key: String) -> Bool {
        ["checkbox:选择分类：应用缓存", "checkbox:模拟应用缓存 · userCache-0",
         "checkbox:模拟应用缓存 · userCache-1", "checkbox:模拟应用缓存 · systemLogs-1",
         "disclosure:userCache", "paths:userCache-1"].contains(key)
    }
    static func rect(_ key: String, in content: NSView) -> NSRect? {
        guard let view = views[key], view.window === content.window else { return nil }
        return view.convert(view.bounds, to: content)
    }
}
struct ProbeHitMarker: NSViewRepresentable {
    let key: String
    func makeNSView(context: Context) -> ProbeMarkerView {
        let view = ProbeMarkerView()
        view.key = key
        ProbeMarkers.views[key] = view
        return view
    }
    func updateNSView(_ view: ProbeMarkerView, context: Context) {
        view.key = key
        ProbeMarkers.views[key] = view
    }
    static func dismantleNSView(_ view: ProbeMarkerView, coordinator: ()) {
        if ProbeMarkers.views[view.key] === view { ProbeMarkers.views.removeValue(forKey: view.key) }
    }
}

@MainActor final class FixtureStore: ObservableObject {
    @Published var groups: [CleanupCategoryGroup]
    @Published var expandAll = false
    @Published var pageLimit = 40
    @Published var scrollTarget = ""
    @Published var openPaths = false
    @Published var collapseFirst = false
    // Match CleanupService's indexed selection lookup. A flattened 3,000-item
    // search per row would benchmark fixture overhead during lazy remeasurement.
    private var itemLocations: [String: (group: Int, item: Int)] = [:]
    var appeared = Set<String>()
    var expandedCategories = Set<CleanupCategory>()
    var expandedPaths = Set<String>()
    var selectedCount: Int { groups.flatMap(\.items).filter(\.isSelected).count }
    init(count: Int, groupCount: Int) {
        groups = CleanupCategory.allCases.prefix(groupCount).map { category in
            CleanupCategoryGroup(category: category, items: (0..<count).map {
                let id = "\(category.rawValue)-\($0)"
                return CleanableItem(id: id, path: "/NONEXISTENT_LAYOUT_FIXTURE/Library/Caches/\(id)", category: category,
                                     risk: $0 == 0 ? .skip : ($0 == 2 ? .caution : .rebuild))
            })
        }
        for g in groups.indices {
            for i in groups[g].items.indices { itemLocations[groups[g].items[i].id] = (g, i) }
        }
    }
    func previewPaths(for item: CleanableItem) -> [String] { [item.path, item.path + "/extra"] }
    func setAllSelected(_ selected: Bool, in category: CleanupCategory) {
        var next = groups
        for g in next.indices where next[g].category == category {
            for i in next[g].items.indices where next[g].items[i].risk != .skip { next[g].items[i].isSelected = selected }
        }
        groups = next
    }
    func isItemSelected(id: String) -> Bool {
        guard let location = itemLocations[id] else { return false }
        return groups[location.group].items[location.item].isSelected
    }
    func setSelected(itemID: String, selected: Bool) {
        guard let location = itemLocations[itemID], groups[location.group].items[location.item].risk != .skip else { return }
        var next = groups
        next[location.group].items[location.item].isSelected = selected
        groups = next
    }
    func revealInFinder(path: String) { }
    func selectAll() {
        var next = groups
        for g in next.indices {
            for i in next[g].items.indices where next[g].items[i].risk != .skip { next[g].items[i].isSelected = true }
        }
        groups = next
    }
}
