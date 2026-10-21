// CliToolInventory — discover CLI tools (npm / brew / uv + data dirs + LaunchAgents).
// Product: MacDefier §7.3.1 C0. Uninstall adapters land in later slices.

import Darwin
import Foundation

// MARK: - Models

public enum CliToolChannel: String, Sendable, Codable, CaseIterable {
    case npm
    case brew
    case uv
    case manual
    case unknown

    /// Kit fallback (UI must prefer L10n).
    public var label: String {
        switch self {
        case .npm: return "npm"
        case .brew: return "brew"
        case .uv: return "uv"
        case .manual: return "manual"
        case .unknown: return "unknown"
        }
    }
}

public struct CliDataDir: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public let path: String
    public let bytes: UInt64
    public let riskNote: String

    public init(path: String, bytes: UInt64, riskNote: String = "") {
        self.path = path
        self.bytes = bytes
        self.riskNote = riskNote
    }
}

public struct CliLaunchAgentInfo: Identifiable, Sendable, Hashable {
    public var id: String { label }
    public let label: String
    public let plistPath: String
    public let running: Bool

    public init(label: String, plistPath: String, running: Bool) {
        self.label = label
        self.plistPath = plistPath
        self.running = running
    }
}

public struct CliTool: Identifiable, Sendable, Hashable {
    public let id: String
    public let displayName: String
    public let channel: CliToolChannel
    public let packageId: String
    public let programPaths: [String]
    public let programBytes: UInt64
    public let dataDirs: [CliDataDir]
    public let agents: [CliLaunchAgentInfo]
    public let bins: [String]
    public let protected: Bool
    public let detail: String
    // Not public caller authority: populated only by explicit manual-entry discovery.
    var manualEntryEvidence: [String: CliManualEntryEvidence] = [:]

    public init(
        id: String,
        displayName: String,
        channel: CliToolChannel,
        packageId: String,
        programPaths: [String],
        programBytes: UInt64,
        dataDirs: [CliDataDir],
        agents: [CliLaunchAgentInfo],
        bins: [String],
        protected: Bool,
        detail: String = ""
    ) {
        self.id = id
        self.displayName = displayName
        self.channel = channel
        self.packageId = packageId
        self.programPaths = programPaths
        self.programBytes = programBytes
        self.dataDirs = dataDirs
        self.agents = agents
        self.bins = bins
        self.protected = protected
        self.detail = detail
    }

    public var dataBytes: UInt64 {
        dataDirs.reduce(0) { $0 &+ $1.bytes }
    }

    public var totalBytes: UInt64 { programBytes &+ dataBytes }

    public var isRunning: Bool {
        agents.contains(where: \.running)
    }

    public var formattedProgramSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(programBytes), countStyle: .file)
    }

    public var formattedDataSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(dataBytes), countStyle: .file)
    }

    public var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
    }
}

// MARK: - Inventory

public enum CliToolInventory {
    /// Known home data directories (whitelist only — never scan all of ~).
    private static let dataDirFingerprints: [(keys: [String], relative: String, risk: String)] = [
        (["openclaw"], ".openclaw", "agent data"),
        (["@openai/codex", "codex"], ".codex", "sessions / auth"),
        (["@anthropic-ai/claude-code", "claude-code", "claude"], ".claude", "sessions / settings"),
        (["kimi-cli", "kimi"], ".kimi", "sessions"),
        (["kimi-cli", "kimi"], ".kimi-code", "sessions / settings"),
        (["opencode"], ".local/share/opencode", "sessions / settings"),
        (["opencode"], ".config/opencode", "config"),
        (["@google/gemini-cli", "gemini-cli", "gemini"], ".gemini", "config"),
        (["aider"], ".aider", "config"),
        (["grok", "grok-cli", "xai"], ".grok", "auth / sessions / downloads"),
        (["hermes"], ".hermes", "gateway / sessions"),
    ]

    /// Only MacDefier itself is hard-locked. Hermes is uninstallable (strong confirm in UI).
    private static let protectedPackageIds: Set<String> = [
        "macdefier",
    ]

    private static let protectedNameHints: [String] = [
        "macdefier",
    ]

    /// Background-safe discovery.
    public static func fetchAll(
        computeSize: Bool = true,
        onStage: @Sendable (String) -> Void = { _ in },
        onBatch: @Sendable ([CliTool]) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) -> [CliTool] {
        var byKey: [String: MutableTool] = [:]
        func publish() { onBatch(byKey.values.map(\.asCliTool).filter(isPresentOnDisk)) }

        if isCancelled() { return [] }
        onStage("scan.stage.npm")
        for t in scanNpmGlobals(computeSize: computeSize) {
            if isCancelled() { return [] }
            merge(t, into: &byKey)
        }
        publish()
        if isCancelled() { return [] }
        onStage("scan.stage.brew")
        for t in scanBrew(computeSize: computeSize) {
            if isCancelled() { return [] }
            merge(t, into: &byKey)
        }
        publish()
        if isCancelled() { return [] }
        onStage("scan.stage.uv")
        for t in scanUvTools(computeSize: computeSize) {
            if isCancelled() { return [] }
            merge(t, into: &byKey)
        }
        publish()
        if isCancelled() { return [] }
        onStage("scan.stage.manual")
        for t in scanVendorHomeCLIs(computeSize: computeSize) {
            if isCancelled() { return [] }
            merge(t, into: &byKey)
        }
        publish()
        if isCancelled() { return [] }
        onStage("scan.stage.verify")
        attachLaunchAgents(into: &byKey)
        if isCancelled() { return [] }
        attachDataDirs(into: &byKey, computeSize: computeSize)
        if isCancelled() { return [] }

        return byKey.values
            .map(\.asCliTool)
            .filter(isPresentOnDisk)
            .sorted { a, b in
                if a.protected != b.protected { return !a.protected && b.protected }
                if a.totalBytes != b.totalBytes { return a.totalBytes > b.totalBytes }
                return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            }
    }

    /// Drop ghosts after uninstall / broken links / infra packages.
    private static func isPresentOnDisk(_ tool: CliTool) -> Bool {
        let fm = FileManager.default
        let hidden: Set<String> = ["npm", "corepack"]
        if hidden.contains(tool.packageId.lowercased()) { return false }

        let programsExist = tool.programPaths.contains { fm.fileExists(atPath: $0) }
        let dataExist = tool.dataDirs.contains { fm.fileExists(atPath: $0.path) }
        let agentsExist = tool.agents.contains { fm.fileExists(atPath: $0.plistPath) }

        // Must have at least one real footprint
        guard programsExist || dataExist || agentsExist else { return false }

        // Channel-specific: package channels need program path unless agent/data-only row
        switch tool.channel {
        case .npm, .brew, .uv:
            // If claimed a package, program path must still exist (unless only leftover data/agent)
            if !tool.programPaths.isEmpty && !programsExist {
                // allow data/agent leftovers as manual-ish presence
                return dataExist || agentsExist
            }
            return true
        case .manual, .unknown:
            return programsExist || dataExist || agentsExist
        }
    }

    // MARK: npm

    private static func npmGlobalRoots() -> [String] {
        var roots = Set<String>()
        let fm = FileManager.default
        let home = NSHomeDirectory()

        let candidates = [
            "/opt/homebrew/lib/node_modules",
            "/usr/local/lib/node_modules",
            "\(home)/.local/lib/node_modules",
            "\(home)/.npm-global/lib/node_modules",
        ]
        for c in candidates where fm.fileExists(atPath: c) {
            roots.insert((c as NSString).standardizingPath)
        }

        // PATH npm root -g (may differ from Homebrew bulk installs)
        if let out = runCapture(["/bin/zsh", "-lc", "npm root -g 2>/dev/null"], timeout: 8) {
            let p = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty, fm.fileExists(atPath: p) {
                roots.insert((p as NSString).standardizingPath)
            }
        }
        return Array(roots)
    }

    private static func scanNpmGlobals(computeSize: Bool) -> [MutableTool] {
        let fm = FileManager.default
        var tools: [MutableTool] = []
        for root in npmGlobalRoots() {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for name in entries where !name.hasPrefix(".") {
                if name.hasPrefix("@") {
                    let scopePath = (root as NSString).appendingPathComponent(name)
                    guard let pkgs = try? fm.contentsOfDirectory(atPath: scopePath) else { continue }
                    for pkg in pkgs where !pkg.hasPrefix(".") {
                        let full = (scopePath as NSString).appendingPathComponent(pkg)
                        let packageId = "\(name)/\(pkg)"
                        if let t = makeNpmTool(packageId: packageId, path: full, computeSize: computeSize) {
                            tools.append(t)
                        }
                    }
                } else {
                    let full = (root as NSString).appendingPathComponent(name)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
                    if let t = makeNpmTool(packageId: name, path: full, computeSize: computeSize) {
                        tools.append(t)
                    }
                }
            }
        }
        return tools
    }

    private static func makeNpmTool(packageId: String, path: String, computeSize: Bool) -> MutableTool? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        // Skip empty / broken package dirs
        let display = friendlyName(for: packageId)
        let bytes = computeSize ? AppDataMatchers.directorySize(at: path) : 0
        let bins = binsFromPackage(path: path)
        let protected = isProtected(packageId: packageId, displayName: display)
        return MutableTool(
            id: "npm:\(packageId)",
            displayName: display,
            channel: .npm,
            packageId: packageId,
            programPaths: [path],
            programBytes: bytes,
            dataDirs: [],
            agents: [],
            bins: bins,
            protected: protected,
            detail: path
        )
    }

    private static func binsFromPackage(path: String) -> [String] {
        let pkgJSON = (path as NSString).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: pkgJSON)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        if let bin = obj["bin"] as? String {
            return [(path as NSString).lastPathComponent]
        }
        if let bin = obj["bin"] as? [String: Any] {
            return bin.keys.sorted()
        }
        return []
    }

    // MARK: brew

    private static func scanBrew(computeSize: Bool) -> [MutableTool] {
        guard let brew = which("brew") else { return [] }
        var tools: [MutableTool] = []
        if let formulae = runCapture([brew, "list", "--formula"], timeout: 20) {
            for name in formulae.split(whereSeparator: \.isNewline).map(String.init) where !name.isEmpty {
                // C0: only CLI-ish formulae (full Cellar walk is too slow / noisy).
                if isNoisyBrewFormula(name) || !isInterestingBrewFormula(name) { continue }
                let prefix = runCapture([brew, "--prefix", name], timeout: 5)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !prefix.isEmpty else { continue }
                let path = URL(fileURLWithPath: prefix).resolvingSymlinksInPath().path
                let bytes = computeSize ? AppDataMatchers.directorySize(at: path) : 0
                let display = friendlyName(for: name)
                tools.append(
                    MutableTool(
                        id: "brew:\(name)",
                        displayName: display,
                        channel: .brew,
                        packageId: name,
                        programPaths: [path],
                        programBytes: bytes,
                        dataDirs: [],
                        agents: [],
                        bins: [name],
                        protected: isProtected(packageId: name, displayName: display),
                        detail: path
                    )
                )
            }
        }
        // Casks are usually .app — App inventory already covers; skip bulk cask list for C0.
        return tools
    }

    private static func isNoisyBrewFormula(_ name: String) -> Bool {
        let n = name.lowercased()
        let skipPrefixes = ["lib", "python@", "node@", "openssl", "ca-certificates", "icu4c", "readline", "sqlite", "xz", "zlib", "gettext", "pcre", "glib", "gnutls"]
        if skipPrefixes.contains(where: { n.hasPrefix($0) }) { return true }
        let skipExact: Set<String> = [
            "pkgconf", "pkg-config", "m4", "autoconf", "automake", "cmake", "ninja",
            "git", "curl", "wget", "bash", "zsh", "coreutils", "findutils", "gawk",
            "gnu-sed", "grep", "make", "gcc", "llvm", "ruby", "perl", "pipx",
            "redis", "mysql", "mysql@8.4", "postgresql@15", "postgresql", "sqlite",
            "brotli", "c-ares", "libuv", "libnghttp2", "libnghttp3", "simdjson", "simdutf", "uvwasi",
        ]
        return skipExact.contains(n)
    }

    private static func isInterestingBrewFormula(_ name: String) -> Bool {
        let n = name.lowercased()
        // Never list generic libs (also kills false "gh" ∈ libnghttp2)
        if n.hasPrefix("lib") || n.hasPrefix("python@") || n.hasPrefix("node@") {
            return false
        }
        // Short names: exact only
        let exactOnly: Set<String> = ["gh", "fd", "jq", "aider", "ffmpeg", "ripgrep", "ollama"]
        if exactOnly.contains(n) { return true }
        // Longer product tokens
        let tokens = [
            "claude", "codex", "gemini", "whisper", "yt-dlp", "ytdlp",
            "imagemagick", "openclaw", "hermes", "kimi", "openai", "llm", "opencode", "cursor-agent", "copilot",
        ]
        for t in tokens {
            if n == t { return true }
            if n.hasPrefix(t + "-") || n.hasPrefix(t + "@") { return true }
            // allow whisper-cpp, claude-code; require token as path segment-ish
            if n.contains("-" + t) || n.contains(t + "-") { return true }
            if t.count >= 5, n.contains(t) { return true }
        }
        return false
    }

    // MARK: Vendor home CLIs (e.g. Grok: ~/.local/bin/grok → ~/.grok/bin/grok)

    /// Self-installed CLIs under `~/.local/bin` (or `~/bin`) that live in `~/.<name>/…`.
    /// Not npm/brew/uv — e.g. xAI Grok CLI.
    /// Isolated discovery seam: only the supplied home's manual entries are inspected.
    static func manualTools(home: String, computeSize: Bool = false, includeData: Bool = false) -> [CliTool] {
        var byKey: [String: MutableTool] = [:]
        for tool in scanVendorHomeCLIs(computeSize: computeSize, home: home) {
            merge(tool, into: &byKey)
        }
        if includeData { attachDataDirs(into: &byKey, computeSize: computeSize, home: home) }
        return byKey.values.map(\.asCliTool).sorted { $0.id < $1.id }
    }

    private static func scanVendorHomeCLIs(computeSize: Bool, home: String = NSHomeDirectory()) -> [MutableTool] {
        let fm = FileManager.default
        let binDirs = [
            "\(home)/.local/bin",
            "\(home)/bin",
        ]
        let sharedBinRoots = Set(binDirs.map { ($0 as NSString).standardizingPath })
        let knownStandaloneLeaves = [
            (home as NSString).appendingPathComponent(".local/share/opencode/bin/opencode"): "opencode"
        ]
        var tools: [MutableTool] = []
        var seenIds = Set<String>()

        for binDir in binDirs {
            guard let names = try? fm.contentsOfDirectory(atPath: binDir) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                let shim = (binDir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: shim, isDirectory: &isDir), !isDir.boolValue else { continue }

                let resolved = URL(fileURLWithPath: shim).resolvingSymlinksInPath().path
                guard fm.isExecutableFile(atPath: resolved) || fm.fileExists(atPath: resolved) else { continue }

                // Must resolve into home (not Homebrew / System)
                let homePrefix = (home as NSString).standardizingPath + "/"
                let resolvedStd = (resolved as NSString).standardizingPath
                guard resolvedStd.hasPrefix(homePrefix) else { continue }
                // Skip uv tool shims (live under .local/share/uv)
                if resolvedStd.contains("/.local/share/uv/") { continue }
                if resolvedStd.contains("/.local/pipx/") { continue }
                if resolvedStd.contains("/.cargo/bin/") { continue }

                // Native releases may place a regular file (or hard link) directly
                // in ~/.local/bin. Never mistake that shared directory for a vendor.
                let knownCommand = knownStandaloneLeaves[resolvedStd]
                if sharedBinRoots.contains(URL(fileURLWithPath: resolvedStd).deletingLastPathComponent().path)
                    || knownCommand != nil {
                    guard fm.isExecutableFile(atPath: resolvedStd),
                          !isProtected(packageId: name, displayName: name),
                          let targetEvidence = CliManualEntryEvidence.capture(resolvedStd),
                          targetEvidence.source.item.kind == mode_t(S_IFREG),
                          let entryEvidence = CliManualEntryEvidence.capture(shim) else { continue }
                    // A borrowed command is not evidence that its target belongs to
                    // this product. Only explicit platform aliases share a name.
                    let targetName = URL(fileURLWithPath: resolvedStd).lastPathComponent
                    let command = standaloneCommandName(name)
                    guard command == (knownCommand ?? standaloneCommandName(targetName)) else { continue }
                    let paths = Array(Set([shim, resolvedStd])).sorted()
                    var tool = MutableTool(
                        id: "manual:\(name)", displayName: friendlyName(for: command),
                        channel: .manual, packageId: command, programPaths: paths,
                        programBytes: computeSize ? AppDataMatchers.directorySize(at: resolvedStd) : 0,
                        dataDirs: [], agents: [], bins: [name], protected: false, detail: resolvedStd
                    )
                    tool.manualEntryEvidence[resolvedStd] = targetEvidence
                    tool.manualEntryEvidence[shim] = entryEvidence
                    // Distinct installations (even similarly named ones) are not a
                    // shared removal scope. Merge only names for the same binary.
                    let identity = targetEvidence.source.item
                    tool.standaloneKey = "standalone:\(command):\(identity.device):\(identity.inode)"
                    tools.append(tool)
                    continue
                }

                // Prefer ~/.<vendor>/… layout
                let rel = String(resolvedStd.dropFirst(homePrefix.count))
                guard rel.hasPrefix(".") else { continue }
                let vendorDot = rel.split(separator: "/").first.map(String.init) ?? ""
                guard vendorDot.count >= 2 else { continue } // ".grok"
                let vendorKey = String(vendorDot.dropFirst()) // "grok"
                if vendorKey.isEmpty { continue }
                if isProtected(packageId: vendorKey, displayName: vendorKey) { continue }

                let homeRoot = (home as NSString).appendingPathComponent(vendorDot)
                // Program: bin dir next to binary, or parent of binary
                let binURL = URL(fileURLWithPath: resolvedStd)
                var programRoot = binURL.deletingLastPathComponent().path
                let candidateBin = (homeRoot as NSString).appendingPathComponent("bin")
                if fm.fileExists(atPath: candidateBin) {
                    programRoot = candidateBin
                }
                guard !sharedBinRoots.contains((programRoot as NSString).standardizingPath) else { continue }

                let id = "vendor:\(vendorKey)"
                if seenIds.contains(id) { continue }
                seenIds.insert(id)

                var programBytes: UInt64 = 0
                if computeSize {
                    programBytes = AppDataMatchers.directorySize(at: programRoot)
                    // Include update downloads if present (still "program" footprint)
                    let downloads = (homeRoot as NSString).appendingPathComponent("downloads")
                    if fm.fileExists(atPath: downloads) {
                        programBytes += AppDataMatchers.directorySize(at: downloads)
                    }
                    let bundled = (homeRoot as NSString).appendingPathComponent("bundled")
                    if fm.fileExists(atPath: bundled) {
                        programBytes += AppDataMatchers.directorySize(at: bundled)
                    }
                }

                var paths = [programRoot]
                if shim != resolvedStd { paths.append(shim) }

                let display = friendlyName(for: vendorKey)
                tools.append(
                    MutableTool(
                        id: id,
                        displayName: display,
                        channel: .manual,
                        packageId: vendorKey,
                        programPaths: paths,
                        programBytes: programBytes,
                        dataDirs: [],
                        agents: [],
                        bins: [name],
                        protected: false,
                        detail: resolvedStd
                    )
                )
            }
        }

        // Also: known home roots with bin/ even if shim missing (broken PATH)
        for (_, rel, _) in dataDirFingerprints {
            // Nested data stores are not vendor-owned program roots.
            guard rel.hasPrefix("."), !rel.contains("/") else { continue }
            let root = (home as NSString).appendingPathComponent(rel)
            let bin = (root as NSString).appendingPathComponent("bin")
            guard fm.fileExists(atPath: bin) else { continue }
            let key = String(rel.dropFirst())
            if isProtected(packageId: key, displayName: key) { continue }
            let id = "vendor:\(key)"
            if seenIds.contains(id) { continue }
            // Must have at least one executable in bin
            guard let binNames = try? fm.contentsOfDirectory(atPath: bin),
                  binNames.contains(where: { fm.isExecutableFile(atPath: (bin as NSString).appendingPathComponent($0)) })
            else { continue }
            seenIds.insert(id)
            let display = friendlyName(for: key)
            let bytes = computeSize ? AppDataMatchers.directorySize(at: bin) : 0
            tools.append(
                MutableTool(
                    id: id,
                    displayName: display,
                    channel: .manual,
                    packageId: key,
                    programPaths: [bin],
                    programBytes: bytes,
                    dataDirs: [],
                    agents: [],
                    bins: [key],
                    protected: isProtected(packageId: key, displayName: display),
                    detail: bin
                )
            )
        }

        return tools
    }

    private static func standaloneCommandName(_ name: String) -> String {
        for suffix in ["-aarch64-apple-darwin", "-arm64-apple-darwin", "-x86_64-apple-darwin"] {
            if name.hasSuffix(suffix), name.count > suffix.count {
                return String(name.dropLast(suffix.count))
            }
        }
        return name
    }

    // MARK: uv

    private static func scanUvTools(computeSize: Bool) -> [MutableTool] {
        guard which("uv") != nil else { return [] }
        let listOut = runCapture(["/bin/zsh", "-lc", "uv tool list 2>/dev/null"], timeout: 15) ?? ""
        // Format:
        // kimi-cli v1.41.0
        // - kimi
        // - kimi-cli
        var tools: [MutableTool] = []
        var currentName: String?
        var currentBins: [String] = []

        func flush() {
            guard let name = currentName, !name.isEmpty else { return }
            let envPath = uvToolEnvPath(name: name)
            let bytes = computeSize && !envPath.isEmpty ? AppDataMatchers.directorySize(at: envPath) : 0
            let display = friendlyName(for: name)
            tools.append(
                MutableTool(
                    id: "uv:\(name)",
                    displayName: display,
                    channel: .uv,
                    packageId: name,
                    programPaths: envPath.isEmpty ? [] : [envPath],
                    programBytes: bytes,
                    dataDirs: [],
                    agents: [],
                    bins: currentBins.isEmpty ? [name] : currentBins,
                    protected: isProtected(packageId: name, displayName: display),
                    detail: envPath
                )
            )
            currentName = nil
            currentBins = []
        }

        for line in listOut.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") {
                let bin = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !bin.isEmpty { currentBins.append(bin) }
            } else if !trimmed.isEmpty {
                flush()
                // "kimi-cli v1.41.0"
                currentName = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
                currentBins = []
            }
        }
        flush()
        return tools
    }

    private static func uvToolEnvPath(name: String) -> String {
        let home = NSHomeDirectory()
        let p = "\(home)/.local/share/uv/tools/\(name)"
        if FileManager.default.fileExists(atPath: p) { return p }
        if let dir = runCapture(["/bin/zsh", "-lc", "uv tool dir 2>/dev/null"], timeout: 8) {
            let base = dir.trimmingCharacters(in: .whitespacesAndNewlines)
            let full = (base as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: full) { return full }
        }
        return ""
    }

    // MARK: LaunchAgents + data

    private static func attachLaunchAgents(into map: inout [String: MutableTool]) {
        let home = NSHomeDirectory()
        let dir = "\(home)/Library/LaunchAgents"
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return }
        let runningLabels = launchctlRunningLabels()

        for file in files where file.hasSuffix(".plist") {
            let path = (dir as NSString).appendingPathComponent(file)
            guard let plist = NSDictionary(contentsOfFile: path) as? [String: Any] else { continue }
            let label = (plist["Label"] as? String) ?? (file as NSString).deletingPathExtension
            let prog = firstProgram(from: plist)
            let running = runningLabels.contains(label)

            let hay = (label + " " + (prog ?? "") + " " + path).lowercased()
            var attached = false
            for (key, var tool) in map {
                let idHay = (tool.packageId + " " + tool.displayName + " " + tool.bins.joined(separator: " ")).lowercased()
                let agent = CliLaunchAgentInfo(label: label, plistPath: path, running: running)
                let matches = tool.standaloneKey != nil
                    ? (try? CliOwnershipBoundary.validateAgent(agent, tool: tool.asCliTool, home: home)) != nil
                    : matchesAgent(hay: hay, toolHay: idHay, packageId: tool.packageId)
                if matches {
                    tool.agents.append(agent)
                    map[key] = tool
                    attached = true
                    break
                }
            }
            // Standalone agent rows only for clearly third-party non-apple labels we care about
            if !attached, shouldSurfaceOrphanAgent(label: label, program: prog) {
                let display = shortAgentName(label)
                merge(
                    MutableTool(
                        id: "agent:\(label)",
                        displayName: display,
                        channel: .manual,
                        packageId: label,
                        programPaths: prog.map { [$0] } ?? [],
                        programBytes: 0,
                        dataDirs: [],
                        agents: [CliLaunchAgentInfo(label: label, plistPath: path, running: running)],
                        bins: [],
                        protected: isProtected(packageId: label, displayName: display),
                        detail: path
                    ),
                    into: &map
                )
            }
        }
    }

    private static func shouldSurfaceOrphanAgent(label: String, program: String?) -> Bool {
        let l = label.lowercased()
        if l.hasPrefix("com.apple.") { return false }
        if l.hasPrefix("homebrew.mxcl.") { return false }
        if l.contains("google.keystone") || l.contains("googleupdater") { return false }
        if l.contains("adobe") || l.contains("steam") { return false }
        // AI / local agent-ish
        if l.contains("openclaw") || l.contains("hermes") || l.contains("codex")
            || l.contains("claude") || l.contains("gateway") || l.contains("ollama")
        {
            return true
        }
        return false
    }

    private static func shortAgentName(_ label: String) -> String {
        if label.hasPrefix("ai.openclaw") { return "OpenClaw Gateway" }
        if label.hasPrefix("ai.hermes") { return "Hermes Gateway" }
        if label.contains("codex") { return "Codex helper" }
        return label
    }

    private static func matchesAgent(hay: String, toolHay: String, packageId: String) -> Bool {
        let pid = packageId.lowercased()
        let hayL = hay.lowercased()
        if !pid.isEmpty, hayL.contains(pid) { return true }

        // Brand tokens (safe)
        let brands = [
            "openclaw", "codex", "claude", "kimi", "hermes", "gemini",
            "notion-mcp", "notionhq", "ollama", "aider",
        ]
        for b in brands {
            if pid.contains(b), hayL.contains(b) { return true }
        }

        let stop: Set<String> = [
            "server", "cli", "code", "tool", "app", "node", "python", "main", "index",
            "helper", "proxy", "agent", "service", "gateway", "mcp", "bin", "lib",
        ]
        let token = pid.split(separator: "/").last.map(String.init)?.lowercased() ?? pid
        if token.count >= 8, !stop.contains(token), hayL.contains(token) { return true }

        for part in toolHay.lowercased().split(whereSeparator: {
            $0 == " " || $0 == "/" || $0 == "-" || $0 == "_" || $0 == "." || $0 == "@"
        }) {
            let t = String(part)
            if t.count >= 8, !stop.contains(t), hayL.contains(t) { return true }
        }
        return false
    }

    private static func firstProgram(from plist: [String: Any]) -> String? {
        if let p = plist["Program"] as? String { return p }
        if let args = plist["ProgramArguments"] as? [String], let first = args.first { return first }
        return nil
    }

    private static func launchctlRunningLabels() -> Set<String> {
        guard let out = runCapture(["/bin/launchctl", "list"], timeout: 8) else { return [] }
        var set = Set<String>()
        for line in out.split(whereSeparator: \.isNewline).dropFirst() {
            let cols = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            // PID Status Label — if PID is "-" not running; still include label for matching
            if let label = cols.last, !label.isEmpty {
                // Only mark running when PID is numeric
                if let pid = cols.first, Int(pid) != nil {
                    set.insert(label)
                }
            }
        }
        return set
    }

    private static func attachDataDirs(into map: inout [String: MutableTool], computeSize: Bool,
                                       home: String = NSHomeDirectory()) {
        let fm = FileManager.default
        for (keys, rel, risk) in dataDirFingerprints {
            let path = (home as NSString).appendingPathComponent(rel)
            guard fm.fileExists(atPath: path) else { continue }
            let bytes = computeSize ? AppDataMatchers.directorySize(at: path) : 0
            let dir = CliDataDir(path: path, bytes: bytes, riskNote: risk)
            var hit = false
            for (key, var tool) in map {
                let hay = (tool.packageId + " " + tool.displayName + " " + tool.bins.joined(separator: " ")).lowercased()
                let matches = tool.standaloneKey != nil
                    ? keys.contains { $0.lowercased() == tool.packageId.lowercased() }
                    : keys.contains { hay.contains($0.lowercased()) }
                if matches {
                    if !tool.dataDirs.contains(where: { $0.path == path }) {
                        tool.dataDirs.append(dir)
                    }
                    // no longer force-protect Hermes; user may uninstall
                    map[key] = tool
                    hit = true
                }
            }
            // Orphan data dir as row (e.g. leftover without package)
            if !hit {
                let id = "data:\(rel)"
                let base = (rel as NSString).lastPathComponent
                let display = friendlyName(for: base.hasPrefix(".") ? String(base.dropFirst()) : base)
                map[id] = MutableTool(
                    id: id,
                    displayName: display,
                    channel: .manual,
                    packageId: base,
                    programPaths: [],
                    programBytes: 0,
                    dataDirs: [dir],
                    agents: [],
                    bins: [],
                    protected: false,
                    detail: path
                )
            }
        }
    }

    // MARK: merge / helpers

    private static func merge(_ tool: MutableTool, into map: inout [String: MutableTool]) {
        let key = tool.standaloneKey ?? normalizeKey(channel: tool.channel, packageId: tool.packageId)
        if var existing = map[key] {
            existing.programPaths = Array(Set(existing.programPaths + tool.programPaths)).sorted()
            existing.manualEntryEvidence.merge(tool.manualEntryEvidence) { _, current in current }
            existing.programBytes = max(existing.programBytes, tool.programBytes)
            existing.bins = Array(Set(existing.bins + tool.bins)).sorted()
            existing.protected = existing.protected || tool.protected
            // Merge agents by label
            var agentByLabel: [String: CliLaunchAgentInfo] = [:]
            for a in existing.agents { agentByLabel[a.label] = a }
            for a in tool.agents { agentByLabel[a.label] = a }
            existing.agents = Array(agentByLabel.values).sorted { $0.label < $1.label }
            // Merge data dirs by path
            var dataByPath: [String: CliDataDir] = [:]
            for d in existing.dataDirs { dataByPath[d.path] = d }
            for d in tool.dataDirs { dataByPath[d.path] = d }
            existing.dataDirs = Array(dataByPath.values).sorted { $0.path < $1.path }
            if existing.detail.isEmpty { existing.detail = tool.detail }
            // Prefer non-manual channel when merging
            if existing.channel == .manual || existing.channel == .unknown,
               tool.channel != .manual, tool.channel != .unknown
            {
                existing.channel = tool.channel
                existing.packageId = tool.packageId
            }
            // Prefer gateway-ish display when agents present
            if !tool.agents.isEmpty, tool.displayName.localizedCaseInsensitiveContains("gateway")
                || tool.displayName.localizedCaseInsensitiveContains("Gateway")
            {
                existing.displayName = tool.displayName
            }
            existing.id = key
            map[key] = existing
        } else {
            var t = tool
            t.id = key
            map[key] = t
        }
    }

    /// Collapse known product aliases; unknown ids stay channel:package.
    private static func normalizeKey(channel: CliToolChannel, packageId: String) -> String {
        let p = packageId.lowercased()
        // Token collapse for multi-source rows (gateway label + ~/.dot + package name)
        let tokens = p.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let brands = ["openclaw", "hermes", "codex", "claude", "kimi", "gemini", "grok", "aider"]
        for b in brands {
            if p.contains(b) || tokens.contains(b) { return "product:\(b)" }
        }
        return "\(channel.rawValue):\(p)"
    }

    private static func isProtected(packageId: String, displayName: String) -> Bool {
        let p = packageId.lowercased()
        let d = displayName.lowercased()
        if protectedPackageIds.contains(p) { return true }
        if protectedNameHints.contains(where: { p.contains($0) || d.contains($0) }) { return true }
        // npm/corepack are hidden in isPresentOnDisk, not protected-lock
        if p == "npm" || p.hasSuffix("/npm") || p == "corepack" { return false }
        return false
    }

    /// Human title from package id / bin name — **no brand allowlist**.
    /// `@scope/foo-cli` → `Foo CLI`; `kimi-cli` → `Kimi CLI`; `grok` → `Grok`.
    private static func friendlyName(for packageId: String) -> String {
        // Take last path segment: @openai/codex → codex
        var raw = packageId.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = raw.split(separator: "/").last {
            raw = String(slash)
        }
        if raw.hasPrefix("@") {
            raw = String(raw.dropFirst())
        }
        // Split on - _ .
        let parts = raw
            .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return packageId }

        // Drop noise tokens that don't help a title
        let noise: Set<String> = [
            "ai", "app", "bin", "core", "js", "ts", "node", "npm", "pkg", "package",
        ]
        let kept = parts.filter { !noise.contains($0.lowercased()) }
        let use = kept.isEmpty ? parts : kept

        func titleCase(_ s: String) -> String {
            let lower = s.lowercased()
            // Keep short all-caps-ish tools as upper when fully acronym-like (gh, rg already short)
            if lower.count <= 2 { return lower }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }

        // If last token is "cli" / "code" / "mcp" / "server", treat as suffix phrase
        let suffixMap: [String: String] = [
            "cli": "CLI",
            "code": "Code",
            "mcp": "MCP",
            "server": "Server",
            "gateway": "Gateway",
        ]
        if use.count >= 2, let suf = suffixMap[use.last!.lowercased()] {
            let head = use.dropLast().map(titleCase).joined(separator: " ")
            return "\(head) \(suf)"
        }
        return use.map(titleCase).joined(separator: " ")
    }

    private static func which(_ cmd: String) -> String? {
        let out = runCapture(["/usr/bin/which", cmd], timeout: 3)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let out, !out.isEmpty, FileManager.default.isExecutableFile(atPath: out) else { return nil }
        return out
    }

    private static func runCapture(_ args: [String], timeout: TimeInterval) -> String? {
        guard let run = try? ProcessRunner.runSync(
            args,
            timeout: timeout,
            isCancelled: { Task.isCancelled }
        ), run.succeeded else { return nil }
        return run.stdoutString
    }

    private struct MutableTool {
        var id: String
        var displayName: String
        var channel: CliToolChannel
        var packageId: String
        var programPaths: [String]
        var programBytes: UInt64
        var dataDirs: [CliDataDir]
        var agents: [CliLaunchAgentInfo]
        var bins: [String]
        var protected: Bool
        var detail: String
        var manualEntryEvidence: [String: CliManualEntryEvidence] = [:]
        var standaloneKey: String? = nil

        var asCliTool: CliTool {
            var tool = CliTool(
                id: id,
                displayName: displayName,
                channel: channel,
                packageId: packageId,
                programPaths: programPaths,
                programBytes: programBytes,
                dataDirs: dataDirs,
                agents: agents,
                bins: bins,
                protected: protected,
                detail: detail
            )
            tool.manualEntryEvidence = manualEntryEvidence
            return tool
        }
    }
}
