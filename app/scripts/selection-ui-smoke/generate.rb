require 'digest'

root = File.expand_path('../..', __dir__)
theme = File.read("#{root}/MacDefier/Theme.swift")
first = theme.index('// MARK: - Selection checkbox') or abort 'checkbox source missing'
last = theme.index('// A copy action keeps paths available', first) or abort 'checkbox source boundary missing'
out = ARGV.fetch(0)
abort 'output directory must exist' unless File.directory?(out)
File.write("#{out}/Checkbox.swift", "import SwiftUI\nimport AppKit\n" + theme[first...last])
puts "Theme SHA256=#{Digest::SHA256.hexdigest(theme)}"
