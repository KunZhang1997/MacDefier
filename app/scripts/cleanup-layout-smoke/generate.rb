require 'digest'

root = File.expand_path('../..', __dir__)
out = ARGV.fetch(0)
abort 'output directory must already exist' unless File.directory?(out)
view = File.read("#{root}/MacDefier/Views/CleanupView.swift")
theme = File.read("#{root}/MacDefier/Theme.swift")
models = File.read("#{root}/CleanupKit/Sources/CleanupKit/Models.swift")

def between(text, first, last)
  start = text.index(first) or abort "missing #{first}"
  finish = text.index(last, start) or abort "missing #{last}"
  text[start...finish]
end

def instrument(text, source, replacement)
  abort "instrumentation anchor changed: #{source}" unless text.scan(source).length == 1
  text.sub(source, replacement)
end

# Mechanically extract production presentation and controls; diagnostics add only
# passive geometry markers and appearance callbacks. No service, scanner, AI,
# filesystem executor or deletion implementation is compiled into this probe.
parts = ["import SwiftUI\nimport AppKit\n"]
parts << between(models, 'public enum CleanupCategory:', 'public struct CleanableItem')
parts << between(theme, 'enum MDTheme {', '/// Per-app appearance preference.')
parts << between(theme, 'extension Color {', '// MARK: - Shared chrome')
parts << between(theme, "extension View {\n    func mdResultHeader()", '/// Neutral navigation surface;')
parts << between(theme, 'struct MDGroupIcon:', '/// 胶囊标签')
parts << between(theme, 'struct MDRowMeta:', '/// 页内实体切换')
parts << between(theme, 'struct MDRowSeparator:', '/// 列表行外壳')
checkbox = between(theme, 'struct MDCheckbox<', '// A copy action keeps paths')
checkbox = instrument(checkbox, '.allowsHitTesting(false)', '.background { if ProbeMarkers.records("checkbox:" + title) { ProbeHitMarker(key: "checkbox:" + title) } }.allowsHitTesting(false)')
parts << checkbox
parts << File.read("#{__dir__}/Fixture.swift")
parts << <<~'SWIFT'
  struct CleanupLayoutProbe: View {
      @ObservedObject var cleanup: FixtureStore
      @State private var expanded: Set<CleanupCategory> = []
      @State private var expandedItemPaths: Set<String> = []
      @State private var itemDisplayLimits: [CleanupCategory: Int] = [:]
      @Environment(\.accessibilityReduceMotion) private var reduceMotion
      private static let initialItemLimit = 40
      private static let itemPageSize = 40
      // Fixture results remain selectable; lifecycle policy belongs to service tests.
      private var canSelectPreview: Bool { true }
SWIFT
parts << between(view, '    private enum PreviewRow:', '    private var aiConfigured:')
parts << <<~'SWIFT'
      var body: some View {
          ScrollViewReader { proxy in
SWIFT
parts << between(view, '                    ScrollView {', "\n                    .onAppear { focusPendingCategory(using: proxy) }")
parts << <<~'SWIFT'
              .background(MDTheme.content)
              .onReceive(cleanup.$expandAll) { open in
                  expanded = open ? Set(cleanup.groups.map(\.category)) : []
              }
              .onReceive(cleanup.$pageLimit) { limit in
                  if let category = cleanup.groups.last?.category { itemDisplayLimits[category] = limit }
              }
              .onReceive(cleanup.$openPaths) { open in
                  if open, let id = cleanup.groups.last?.items.last?.id { expandedItemPaths.insert(id) }
              }
              .onReceive(cleanup.$collapseFirst) { collapse in
                  if collapse, let category = cleanup.groups.first?.category { expanded.remove(category) }
              }
              .onChange(of: expanded) { _, value in cleanup.expandedCategories = value }
              .onChange(of: expandedItemPaths) { _, value in cleanup.expandedPaths = value }
              .onChange(of: cleanup.scrollTarget) { _, target in proxy.scrollTo(target, anchor: .top) }
          }
      }
SWIFT
section = between(view, "    @ViewBuilder\n    private func previewRow(", '    private func cleaningState(')
section = instrument(section, '.background(groupRowBackground(last: isLast))', '.onAppear { cleanup.appeared.insert(item.id) }.background(groupRowBackground(last: isLast))')
section = instrument(section, '.help(group.category.localizedWhatIsIt)', '.help(group.category.localizedWhatIsIt).background { if ProbeMarkers.records("disclosure:" + group.category.rawValue) { ProbeHitMarker(key: "disclosure:" + group.category.rawValue) } }')
section = instrument(section, '.help(L10n.t("cleanup.paths_expand_help"))', '.help(L10n.t("cleanup.paths_expand_help")).background { if ProbeMarkers.records("paths:" + item.id) { ProbeHitMarker(key: "paths:" + item.id) } }')
parts << section
parts << "}\n"
File.write("#{out}/GeneratedProbe.swift", parts.join("\n"))
puts "layout source SHA256=#{Digest::SHA256.hexdigest(view)}"
puts "theme source SHA256=#{Digest::SHA256.hexdigest(theme)}"
puts 'layout extraction=PreviewRow/previewRows/previewRow/categoryHeader/itemRow; control=production MDCheckbox'
