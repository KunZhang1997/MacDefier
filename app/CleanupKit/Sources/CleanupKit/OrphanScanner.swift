// OrphanScanner — residual folders left by uninstalled apps.
// + CLI tool data dirs left after package uninstall (§7.3.1).
// Safety spirit adapted from PureMac OrphanSafetyPolicy (MIT).

import Foundation
import Darwin

public enum OrphanScanner {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    private static let fm = FileManager.default
    private static let minBytes: UInt64 = 64 * 1024
    /// 自身 bundle id：本应用还在跑，自己的目录不是「卸后残留」
    private static let selfBundleID = (Bundle.main.bundleIdentifier ?? "com.macdefier.app").lowercased()

    private static func allowedRoots(home: String) -> [String] {
        [
            "\(home)/Library/Caches",
            "\(home)/Library/Logs",
            "\(home)/Library/Saved Application State",
            "\(home)/Library/HTTPStorages",
            "\(home)/Library/WebKit",
            "\(home)/Library/Application Support/CrashReporter",
            "\(home)/Library/Application Support",
            "\(home)/Library/Preferences"
        ]
    }

    /// Known CLI data folders (sync with CliToolInventory / PathGate.cliDataAllow).
    /// Never includes `.hermes` (protected).
    private static let cliDataFingerprints: [(brands: [String], relative: String, title: String)] = [
        (["openclaw"], ".openclaw", "OpenClaw"),
        (["codex"], ".codex", "Codex"),
        (["claude"], ".claude", "Claude Code"),
        (["kimi"], ".kimi", "Kimi CLI"),
        (["gemini"], ".gemini", "Gemini CLI"),
        (["aider"], ".aider", "Aider"),
        (["grok"], ".grok", "Grok CLI"),
    ]

    /// Scan volatile roots + leftover CLI data dirs not owned by a still-installed CLI package.
    public static func scan(
        installed: [InstalledApp],
        cliInventory: [CliTool]? = nil,
        onProgress: (String) -> Void = { _ in }
    ) -> [CleanableItem] {
        let tools = cliInventory ?? CliToolInventory.fetchAll(
            computeSize: false,
            isCancelled: { Task.isCancelled }
        )
        let containers = ContainerOwnershipScanner.scan(home: home, installed: installed)
        var items: [CleanableItem] = []
        items.append(contentsOf: scanLibraryOrphans(installed: installed, cliInventory: tools, containerOwnership: containers, onProgress: onProgress))
        items.append(contentsOf: scanContainerOrphans(installed: installed, containerOwnership: containers, onProgress: onProgress))
        items.append(contentsOf: scanCLIDataOrphans(cliInventory: tools))
        var seen = Set<String>()
        var unique: [CleanableItem] = []
        for it in items.sorted(by: { $0.bytes > $1.bytes }) {
            let key = PathGate.normalize(it.path)
            if seen.insert(key).inserted {
                unique.append(it)
            }
        }
        return unique
    }

    // MARK: - Sandbox containers

    /// Containers are intentionally outside the generic PathGate scan.  This dedicated
    /// inventory makes their space visible after an app has gone away, while only
    /// metadata-consistent, non-system direct children become manual candidates.
    static func scanContainerOrphans(
        installed: [InstalledApp],
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        containerOwnership: [ContainerOwnership]? = nil,
        onProgress: (String) -> Void = { _ in },
        measureSize: (String) -> UInt64 = { AppDataMatchers.directorySize(at: $0) }
    ) -> [CleanableItem] {
        var items: [CleanableItem] = []
        for ownership in containerOwnership ?? ContainerOwnershipScanner.scan(home: home, installed: installed) {
            if Task.isCancelled { return items }
            // These containers never enter the result: do not recursively size them.
            guard ownership.confidence == .verifiedOrphan else { continue }
            onProgress(URL(fileURLWithPath: ownership.path).lastPathComponent)
            let size = measureSize(ownership.path)
            guard size >= minBytes else { continue }
            let bundle = ownership.bundleID ?? URL(fileURLWithPath: ownership.path).lastPathComponent
            let evidence = ownership.evidence.joined(separator: "；")
            switch ownership.confidence {
            case .verifiedOrphan:
                items.append(CleanableItem(
                    name: bundle,
                    path: ownership.path,
                    bytes: size,
                    category: .orphans,
                    isSelected: false,
                    appName: bundle,
                    displayTitle: "卸后保留数据 · \(bundle)",
                    whatIsIt: evidence,
                    ifCleaned: "可能含游戏资源、存档、设置或账号状态。默认不勾；进入安全预览后由用户逐项确认，移入废纸篓可还原。",
                    risk: .caution
                ))
            case .installedOwner, .protected, .ambiguous, .unreadable:
                // Installed and system owners do not belong in the orphan result.
                continue
            }
        }
        return items
    }

    // MARK: - Library orphans

    static func scanLibraryOrphans(
        installed: [InstalledApp],
        cliInventory: [CliTool],
        containerOwnership: [ContainerOwnership],
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        onProgress: (String) -> Void = { _ in },
        measureSize: (String) -> UInt64 = { AppDataMatchers.directorySize(at: $0) }
    ) -> [CleanableItem] {
        let activeCLITokens = activeCLIOwnershipTokens(from: cliInventory)
        var items: [CleanableItem] = []

        for root in allowedRoots(home: home) {
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for name in names {
                if Task.isCancelled { return items }
                if name.hasPrefix(".") { continue }
                if name.hasPrefix("com.apple.") { continue }
                let lowerName = name.lowercased()
                if lowerName == selfBundleID || lowerName.hasPrefix(selfBundleID + ".") { continue }
                let path = (root as NSString).appendingPathComponent(name)
                onProgress(name)
                guard isStrictlyUnderAllowedRoot(path, home: home) else { continue }
                if CleanupRiskPolicy.shouldNeverListAsOrphan(name: name, path: path) { continue }
                // Plain folder names (including localized apps and shared runtimes)
                // do not establish an owner. Only exact IDs corroborated by container
                // metadata with a missing original app location become candidates.
                guard let owner = libraryOrphanOwner(name: name, path: path, installed: installed,
                                                    containerOwnership: containerOwnership) else { continue }
                if isOwnedByActiveCLI(name: name, path: path, tokens: activeCLITokens) { continue }
                let size = measureSize(path)
                guard size >= minBytes else { continue }
                items.append(CleanableItem(
                    name: name,
                    path: path,
                    bytes: size,
                    category: .orphans,
                    isSelected: false,
                    appName: friendlyName(name),
                    displayTitle: "卸后残留 · \(friendlyName(name) ?? name)",
                    whatIsIt: "目录标识与原应用归属记录一致。" + owner.evidence.joined(separator: "；"),
                    ifCleaned: "进废纸篓可还原。从不进「勾选低风险」。游戏/大软件本体请去「软件」页。",
                    risk: .caution
                ))
            }
        }
        return items
    }

    /// Positive identity evidence is required; absence from AppInventory alone never
    /// authorizes a Library folder. Keep this separate from uninstall ownership grants.
    static func libraryOrphanOwner(
        name: String, path: String, installed: [InstalledApp],
        containerOwnership: [ContainerOwnership]
    ) -> ContainerOwnership? {
        var identifier = name.lowercased()
        for suffix in [".plist", ".savedstate"] where identifier.hasSuffix(suffix) {
            identifier = String(identifier.dropLast(suffix.count))
        }
        // Reject unidentified entries before doing app-name/path matching. A Library
        // can contain thousands of plists; matching each against every app is costly.
        guard let owner = containerOwnership.first(where: {
            $0.confidence == .verifiedOrphan && $0.bundleID?.lowercased() == identifier
        }), AppOwnership.looksLikeReverseDNS(identifier),
              !CleanupRiskPolicy.shouldNeverListAsOrphan(name: name, path: path),
              !AppOwnership.isOwnedByInstalled(name: name, path: path, apps: installed) else { return nil }
        return owner
    }

    // MARK: - CLI data orphans

    /// §7.3.1 G2: L2 data left after CLI program is gone. Dynamic from inventory + fingerprint fallback.
    static func scanCLIDataOrphans(
        cliInventory tools: [CliTool],
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        measureSize: (String) -> UInt64 = { AppDataMatchers.directorySize(at: $0) }
    ) -> [CleanableItem] {
        var items: [CleanableItem] = []
        var seenPaths = Set<String>()

        func appendCLIData(
            path: String,
            title: String,
            relativeName: String
        ) {
            let key = PathGate.normalize(path)
            guard seenPaths.insert(key).inserted else { return }
            guard fm.fileExists(atPath: path) else { return }
            guard isVerifiedCLIDataOrphan(path, cliInventory: tools, home: home) else { return }
            guard PathGate.isSafeToTrash(path, home: home) else { return }
            let size = measureSize(path)
            guard size >= minBytes else { return }
            items.append(CleanableItem(
                name: relativeName,
                path: path,
                bytes: size,
                category: .orphans,
                isSelected: false,
                appName: title,
                displayTitle: "CLI 卸后数据 · \(title)",
                whatIsIt: "「软件 → CLI 工具」里卸程序时未勾选的数据/会话目录（如 \(relativeName)）。可能含登录与历史。",
                ifCleaned: "进废纸篓可还原。默认不勾；确认不再需要再清。",
                risk: .caution
            ))
        }

        for t in tools {
            if t.protected { continue }
            let hasProgram = t.programPaths.contains { fm.fileExists(atPath: $0) }
            if hasProgram { continue }
            for d in t.dataDirs {
                let rel = (d.path as NSString).lastPathComponent
                appendCLIData(path: d.path, title: t.displayName, relativeName: rel)
            }
        }

        let activeTokens = activeCLIOwnershipTokens(from: tools, home: home)
        for entry in cliDataFingerprints {
            let path = (home as NSString).appendingPathComponent(entry.relative)
            guard fm.fileExists(atPath: path) else { continue }
            if entry.brands.contains(where: { brand in
                tokenMatchesBrand(activeTokens, brand: brand)
            }) {
                continue
            }
            let claimedByLive = tools.contains { t in
                let live = t.programPaths.contains { fm.fileExists(atPath: $0) }
                guard live else { return false }
                return t.dataDirs.contains { PathGate.normalize($0.path) == PathGate.normalize(path) }
                    || ownershipTokens(from: t).contains(where: { entry.brands.contains($0) })
            }
            if claimedByLive { continue }
            appendCLIData(path: path, title: entry.title, relativeName: entry.relative)
        }

        return items
    }

    /// The CLI allow-list grants a location, not proof that its owner was removed.
    static func isCLIDataRoot(
        _ path: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> Bool {
        let candidate = PathGate.standardizeOnly(path)
        return PathGate.cliDataAllowPrefixes(home: home).contains {
            PathGate.standardizeOnly($0) == candidate
        }
    }

    /// Shared scan/execution evidence. A data-only inventory row is not an uninstall
    /// record: unreadable package discovery can produce the same row. Require at
    /// least one recorded program location and verify that every possible owner is
    /// absent. The executor supplies a fresh inventory immediately before use.
    static func isVerifiedCLIDataOrphan(
        _ path: String,
        cliInventory: [CliTool]?,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> Bool {
        guard let tools = cliInventory, !tools.isEmpty,
              isCLIDataRoot(path, home: home),
              PathGate.normalize(path) == PathGate.standardizeOnly(path) else { return false }
        let candidate = PathGate.standardizeOnly(path)
        let directOwners = tools.filter { tool in
            tool.dataDirs.contains { PathGate.standardizeOnly($0.path) == candidate }
        }
        guard !directOwners.isEmpty else { return false }
        let brand = String(URL(fileURLWithPath: candidate).lastPathComponent.dropFirst())
        let possibleOwners = tools.filter { tool in
            directOwners.contains(tool) || tokenMatchesBrand(ownershipTokens(from: tool), brand: brand)
        }
        guard !possibleOwners.contains(where: { $0.protected || $0.isRunning }) else { return false }
        // One absent installation cannot prove that an unknown sibling was removed.
        guard possibleOwners.allSatisfy({ !$0.programPaths.isEmpty }) else { return false }
        let programs = Set(possibleOwners.flatMap(\.programPaths))
        guard !programs.isEmpty, programs.allSatisfy(isConfirmedMissingCLIPath) else { return false }
        guard possibleOwners.flatMap(\.agents).allSatisfy({ isConfirmedMissingCLIPath($0.plistPath) }) else {
            return false
        }
        if brand == "kimi" {
            // The desktop product shares this data even without a CLI package.
            return [home + "/Library/Application Support/kimi-desktop", home + "/Library/Application Support/kimi"]
                .allSatisfy(isConfirmedMissingCLIPath)
        }
        return true
    }

    private static func isConfirmedMissingCLIPath(_ path: String) -> Bool {
        // fileExists conflates ENOENT with EACCES/ENOTDIR and follows broken links.
        // Detached volumes and unresolved aliases cannot prove an uninstall either.
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              !PathGate.isUnderComponentPrefixes(path, ["/Volumes", "/Network"]),
              PathGate.standardizeOnly(path) == path,
              PathGate.normalize(path) == path else { return false }
        var info = stat()
        return lstat(path, &info) != 0 && errno == ENOENT
    }

    private static func tokenMatchesBrand(_ tokens: Set<String>, brand: String) -> Bool {
        let b = brand.lowercased()
        if tokens.contains(b) { return true }
        return tokens.contains { t in
            t == b || t.hasPrefix(b + "-") || t.hasSuffix("-" + b) || t.contains(b)
        }
    }

    /// Tokens from still-installed CLI programs (dynamic — package/display/bin names).
    private static func activeCLIOwnershipTokens(
        from tools: [CliTool]? = nil,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> Set<String> {
        let list = tools ?? CliToolInventory.fetchAll(computeSize: false)
        var tokens = Set<String>()
        for t in list {
            let hasProgram = t.programPaths.contains { fm.fileExists(atPath: $0) }
            guard hasProgram else { continue }
            tokens.formUnion(ownershipTokens(from: t))
        }
        // Desktop app support folders still present
        if fm.fileExists(atPath: "\(home)/Library/Application Support/kimi-desktop")
            || fm.fileExists(atPath: "\(home)/Library/Application Support/kimi")
        {
            tokens.insert("kimi")
        }
        return tokens
    }

    private static func ownershipTokens(from tool: CliTool) -> Set<String> {
        var tokens = Set<String>()
        func add(_ raw: String) {
            let s = raw.lowercased()
            guard s.count >= 3 else { return }
            let last = s.split(separator: "/").last.map(String.init) ?? s
            if last.count >= 3 { tokens.insert(last) }
            for part in last.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." }) {
                let p = String(part)
                if p.count >= 4 { tokens.insert(p) }
            }
            for part in s.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }) {
                let p = String(part)
                if p.count >= 4 { tokens.insert(p) }
            }
        }
        add(tool.packageId)
        add(tool.displayName)
        for b in tool.bins { add(b) }
        return tokens
    }

    /// Library cache/log folders that belong to a still-installed CLI (not true orphans).
    private static func isOwnedByActiveCLI(name: String, path: String, tokens: Set<String>) -> Bool {
        guard !tokens.isEmpty else { return false }
        let hay = (name + " " + URL(fileURLWithPath: path).lastPathComponent).lowercased()
        for t in tokens.sorted(by: { $0.count > $1.count }) {
            if t.count < 4 { continue }
            if hay == t || hay.hasPrefix(t + "-") || hay.hasPrefix(t + "_")
                || hay.contains(t + "-") || hay.contains("-" + t) || hay.contains(t)
            {
                return true
            }
        }
        return false
    }

    // MARK: - Ownership roots

    private static func isStrictlyUnderAllowedRoot(_ path: String, home: String) -> Bool {
        let lower = path.lowercased()
        return allowedRoots(home: home).contains { root in
            let r = root.lowercased() + "/"
            return lower.hasPrefix(r)
        }
    }

    private static func friendlyName(_ name: String) -> String? {
        if name.hasPrefix("com.") || name.hasPrefix("org.") || name.hasPrefix("net.") {
            return name.split(separator: ".").last.map(String.init)
        }
        if name.hasSuffix(".savedState") {
            return String(name.dropLast(".savedState".count))
        }
        return name
    }

    private static func directorySize(_ path: String) -> UInt64 {
        AppDataMatchers.directorySize(at: path)
    }
}
