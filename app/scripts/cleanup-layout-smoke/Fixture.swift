// Diagnostic-only, in-memory fixture. No app service or cleanup executor exists.
struct CleanableItem: Identifiable {
    let id: String
    let path: String
    let category: CleanupCategory
    var isSelected = false
    let risk: CleanupRisk = .rebuild
    var isLowRiskBulkEligible: Bool { true }
    var localizedDisplayTitle: String { "模拟应用缓存 · \(id)" }
    var localizedWhatIsIt: String { "仅测试布局，不对应真实文件，也没有删除能力。" }
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
    static func bytes(_ value: Double) -> String { "128.4 MB" }
}
enum L10n {
    static func t(_ key: String, _ args: CVarArg...) -> String { key }
}
extension View {
    func mdCopyPathMenu(_ path: String) -> some View { self }
}
@MainActor final class FixtureStore: ObservableObject {
    @Published var groups: [CleanupCategoryGroup]
    @Published var expandAll = false
    @Published var pageLimit = 40
    @Published var scrollTarget = ""
    @Published var openPaths = false
    @Published var collapseFirst = false
    var appeared = Set<String>()
    init(count: Int, groupCount: Int) {
        groups = CleanupCategory.allCases.prefix(groupCount).map { category in
            CleanupCategoryGroup(category: category, items: (0..<count).map {
                let id = "\(category.rawValue)-\($0)"
                return CleanableItem(id: id, path: "/NONEXISTENT_LAYOUT_FIXTURE/Library/Caches/\(id)", category: category)
            })
        }
    }
    func previewPaths(for item: CleanableItem) -> [String] { [item.path, item.path + "/extra"] }
    func setCategorySelected(_ category: CleanupCategory, selected: Bool) {
        for g in groups.indices where groups[g].category == category {
            for i in groups[g].items.indices { groups[g].items[i].isSelected = selected }
        }
    }
    func isItemSelected(id: String) -> Bool { groups.flatMap(\.items).first { $0.id == id }?.isSelected ?? false }
    func setSelected(itemID: String, selected: Bool) {
        for g in groups.indices {
            for i in groups[g].items.indices where groups[g].items[i].id == itemID {
                groups[g].items[i].isSelected = selected
            }
        }
    }
    func revealInFinder(path: String) { }
    func selectAll() {
        var next = groups
        for g in next.indices {
            for i in next[g].items.indices { next[g].items[i].isSelected = true }
        }
        groups = next
    }
}
