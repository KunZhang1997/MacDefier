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

# Generated diagnostic input, not production changes. Only presentation code is
# copied. No CleanupService, scanners, filesystem executors or AI is linked.
parts = ["import SwiftUI\nimport AppKit\n"]
parts << between(models, 'public enum CleanupCategory:', 'public struct CleanableItem')
parts << between(theme, 'enum MDTheme {', '/// Per-app appearance preference.')
parts << between(theme, 'extension Color {', '// MARK: - Shared chrome')
parts << between(theme, 'struct MDGroupIcon:', '/// 胶囊标签')
parts << between(theme, 'struct MDRowMeta:', '/// 页内实体切换')
chrome = between(theme, 'struct MDRowSeparator:', '/// 列表行外壳')
parts << chrome
parts << File.read("#{__dir__}/Fixture.swift")
parts << "struct CleanupLayoutProbe: View {\n"
parts << <<~'SWIFT'
    @ObservedObject var cleanup: FixtureStore
    @State private var expanded: Set<CleanupCategory> = []
    @State private var expandedItemPaths: Set<String> = []
    @State private var itemDisplayLimits: [CleanupCategory: Int] = [:]
    private static let initialItemLimit = 40
    private static let itemPageSize = 40
    var body: some View {
        ScrollViewReader { proxy in
SWIFT
parts << between(view, '                ScrollView {', "\n            }\n        }\n    }\n")
parts << <<~'SWIFT'
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
        .onChange(of: cleanup.scrollTarget) { _, target in
            proxy.scrollTo(target, anchor: .bottom)
        }
        }
    }
SWIFT
section = between(view, '    private func categorySection(', '    private func cleaningState(')
abort 'item root changed; update appearance instrumentation' unless section.include?('.background(groupRowBackground(last: isLast))')
section = section.sub('.background(groupRowBackground(last: isLast))', '.onAppear { cleanup.appeared.insert(item.id) }.background(groupRowBackground(last: isLast))')
parts << section
parts << "}\n"
generated = parts.join("\n")
File.write("#{out}/GeneratedProbe.swift", generated)
puts "layout source SHA256=#{Digest::SHA256.hexdigest(view)}"
puts "theme source SHA256=#{Digest::SHA256.hexdigest(theme)}"
