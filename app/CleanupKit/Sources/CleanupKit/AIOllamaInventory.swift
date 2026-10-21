import CryptoKit
import Darwin
import Foundation

/// Metadata-only inventory of the standard local Ollama store. Never invokes Ollama or reads model content.
public enum AIOllamaInventory {
    struct Budget {
        var entries = 24_000
        var manifests = 4_096
        var manifestBytes = 1_048_576
        var totalManifestBytes = 16 * 1_048_576
        var references = 65_536
        var seconds: TimeInterval = 5
    }

    public static func scan(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                            now: Date = Date(), isCancelled: @Sendable () -> Bool = { false }) -> AICleanupInventory {
        scan(home: home, now: now, budget: Budget(), isCancelled: isCancelled)
    }

    static func scan(home: String, now: Date, budget: Budget,
                     isCancelled: @Sendable () -> Bool) -> AICleanupInventory {
        let graph = readGraph(home: home, budget: budget, excluding: [], isCancelled: isCancelled)
        guard graph.exists else {
            return .init(issues: configuredElsewhere(than: graph.root) ? ["modelRootUnverified"] : [], scannedAt: now)
        }
        let graphHash = graph.hash
        let originalProof = OriginalProof(graph: graph)
        let originalJSON = originalProof.json
        let candidates = graph.manifests.sorted { $0.path < $1.path }.map { manifest -> AICleanupCandidate in
            let paths = exclusivePaths(for: manifest, in: graph)
            let available = graph.complete && originalJSON != nil
            let resources = available ? paths.compactMap { graph.proofs[$0]?.resource } : []
            let fullBytes = AIResourceTotals.bytes(([manifest.path] + manifest.references.map { blobPath($0, root: graph.root) })
                .compactMap { graph.proofs[$0]?.resource })
            let activity = ([manifest.path] + manifest.references.map { blobPath($0, root: graph.root) })
                .compactMap { graph.proofs[$0]?.modifiedAt }.max()
            return AICleanupCandidate(tool: .ollama, kind: .model, title: manifest.name,
                resources: resources, state: available ? .ready : .unknown,
                reason: available ? "modelExclusive" : "modelGraphIncomplete", lastActivity: activity,
                metadata: ["modelName": manifest.name, "manifestSHA256": manifest.hash,
                           "graphSHA256": graphHash, "storeScope": "standard", "activityEvidence": "filesystemModification",
                           "originalGraphProof": originalJSON ?? "",
                           "fullModelBytes": String(fullBytes),
                           "sharedBlobCount": String(manifest.references.count - (paths.count - 1)),
                           "resourceProofs": proofJSON(paths: paths, graph: graph)], contextPath: manifest.path)
        }
        var issues = graph.issues.sorted()
        if originalJSON == nil { issues.append("modelGraphIncomplete") }
        issues.append("modelStandardRootOnly")
        if configuredElsewhere(than: graph.root) { issues.append("modelRootUnverified") }
        return .init(candidates: candidates, issues: Array(Set(issues)).sorted(), scannedAt: now)
    }

    /// Executor moves blobs first and the manifest last. Exclusions are resources of completed models
    /// plus blobs already moved for this model. Every remaining reference must match the original graph.
    public static func validateModel(_ candidate: AICleanupCandidate,
                                     home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                                     excludingMovedPaths: Set<String> = []) -> Bool {
        guard candidate.tool == .ollama, candidate.kind == .model,
              !excludingMovedPaths.contains(candidate.path),
              excludingMovedPaths.allSatisfy({ UninstallFileBoundary.isMissing($0) }),
              let originalText = candidate.metadata["originalGraphProof"], originalText.utf8.count <= 32 * 1_048_576,
              let originalData = originalText.data(using: .utf8),
              let original = try? JSONDecoder().decode(OriginalProof.self, from: originalData),
              let proofsText = candidate.metadata["resourceProofs"],
              proofsText.utf8.count <= 1_048_576,
              let proofsData = proofsText.data(using: .utf8),
              let expectedProofs = try? JSONDecoder().decode([String: String].self, from: proofsData) else { return false }
        let completed = Set(excludingMovedPaths.filter { original.manifests[$0] != nil })
        let graph = readGraph(home: home, budget: Budget(), excluding: excludingMovedPaths,
                              excludedProofs: original.blobs.filter { excludingMovedPaths.contains($0.key) }, isCancelled: { false })
        guard graph.complete, let manifest = graph.manifests.first(where: { $0.path == candidate.path }),
              original.isBounded(root: graph.root), original.hash(excluding: []) == candidate.metadata["graphSHA256"],
              candidate.id == "ollama:model:\(manifest.path)",
              candidate.metadata["manifestSHA256"] == manifest.hash,
              original.hash(excluding: completed) == graph.hash else { return false }
        let paths = original.exclusivePaths(for: manifest.path, root: graph.root)
        guard Set(paths) == Set(candidate.resources.map(\.path)), Set(expectedProofs.keys) == Set(paths),
              expectedProofs.allSatisfy({ original.signature(for: $0.key) == $0.value }) else { return false }
        let allowed = Set(paths).union(completed.flatMap { original.exclusivePaths(for: $0, root: graph.root) })
        guard excludingMovedPaths.isSubset(of: allowed), completed.allSatisfy({ path in
            Set(original.exclusivePaths(for: path, root: graph.root)).isSubset(of: excludingMovedPaths)
        }) else { return false }
        for resource in candidate.resources where !excludingMovedPaths.contains(resource.path) {
            guard resource.stillMatches(), let fresh = graph.proofs[resource.path],
                  expectedProofs[resource.path] == fresh.signature,
                  resource.identity == fresh.resource?.identity,
                  resource.modifiedAt == fresh.resource?.modifiedAt,
                  resource.bytes == fresh.bytes else { return false }
        }
        return true
    }

    private struct OriginalProof: Codable {
        struct Entry: Codable {
            var hash: String
            var signature: String
            var references: Set<String>
        }
        var manifests: [String: Entry]
        var blobs: [String: String]
        var root: String
        init(graph: Graph) {
            root = graph.root
            manifests = Dictionary(uniqueKeysWithValues: graph.manifests.map {
                ($0.path, Entry(hash: $0.hash, signature: graph.proofs[$0.path]?.signature ?? "?", references: $0.references))
            })
            blobs = Dictionary(uniqueKeysWithValues: graph.references.keys.compactMap { digest in
                let path = blobPath(digest, root: graph.root)
                return graph.proofs[path].map { (path, $0.signature) }
            })
        }
        var json: String? {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(self), data.count <= 32 * 1_048_576 else { return nil }
            return String(data: data, encoding: .utf8)
        }
        func signature(for path: String) -> String? { manifests[path]?.signature ?? blobs[path] }
        func exclusivePaths(for manifest: String, root: String) -> [String] {
            guard let entry = manifests[manifest] else { return [] }
            let sole = entry.references.filter { digest in
                let path = blobPath(digest, root: root)
                let parts = blobs[path]?.split(separator: ":") ?? []
                return parts.count == 11 && parts[4] == "1"
                    && manifests.values.filter { $0.references.contains(digest) }.count == 1
            }.map { blobPath($0, root: root) }.sorted()
            return sole + [manifest]
        }
        func hash(excluding removed: Set<String>) -> String {
            let remaining = manifests.filter { !removed.contains($0.key) }
            let lines = remaining.keys.sorted().map { path in
                "\(path)\u{0}\(remaining[path]!.hash)\u{0}\(remaining[path]!.signature)"
            }
            // The retained reference union intentionally excludes orphaned blobs after completed models.
            let references = Set(remaining.values.flatMap { $0.references })
            let blobLines = references.sorted().map { digest in
                let path = blobPath(digest, root: root)
                return "\(path)\u{0}\(blobs[path] ?? "?")"
            }
            return sha256(Data((lines + blobLines).joined(separator: "\n").utf8))
        }
        func isBounded(root: String) -> Bool {
            guard self.root == root, manifests.count <= 4096, blobs.count <= 65_536,
                  manifests.values.reduce(0, { $0 + $1.references.count }) <= 65_536 else { return false }
            for (path, entry) in manifests {
                guard path.hasPrefix(root + "/manifests/"), path.utf8.count <= 1024,
                      displayName(Array(path.dropFirst((root + "/manifests/").count).split(separator: "/").map(String.init))) != nil,
                      entry.hash.utf8.count == 64, entry.signature.utf8.count <= 1024,
                      entry.references.count <= 513, entry.references.allSatisfy(validDigest) else { return false }
            }
            let expected = Set(manifests.values.flatMap { $0.references }.map { blobPath($0, root: root) })
            return Set(blobs.keys) == expected && blobs.values.allSatisfy { $0.utf8.count <= 1024 }
        }
    }

    private struct Manifest {
        let path: String
        let name: String
        let hash: String
        let references: Set<String>
    }

    private struct Proof {
        let signature: String
        let bytes: UInt64
        let logicalBytes: UInt64
        let links: UInt16
        let modifiedAt: Date
        let resource: AIResource?
    }

    private struct Graph {
        var root: String
        var exists = false
        var complete = true
        var manifests: [Manifest] = []
        var proofs: [String: Proof] = [:]
        var references: [String: Set<String>] = [:]
        var sizes: [String: UInt64] = [:]
        var excludedProofs: [String: String] = [:]
        var issues = Set<String>()
        var hash: String {
            let manifestLines = manifests.sorted { $0.path < $1.path }.map {
                "\($0.path)\u{0}\($0.hash)\u{0}\(proofs[$0.path]?.signature ?? "?")"
            }
            let blobLines = references.keys.sorted().map { digest -> String in
                let path = blobPath(digest, root: root)
                return "\(path)\u{0}\(proofs[path]?.signature ?? excludedProofs[path] ?? "?")"
            }
            return sha256(Data((manifestLines + blobLines).joined(separator: "\n").utf8))
        }
        mutating func fail(_ issue: String = "modelGraphIncomplete") { complete = false; issues.insert(issue) }
    }

    private static func readGraph(home: String, budget: Budget, excluding: Set<String>, excludedProofs: [String: String] = [:],
                                  isCancelled: @Sendable () -> Bool) -> Graph {
        let canonicalHome = physical(home) ?? home
        let root = (canonicalHome as NSString).appendingPathComponent(".ollama/models")
        var graph = Graph(root: root)
        graph.excludedProofs = excludedProofs
        guard !UninstallFileBoundary.isMissing(root) else { graph.complete = false; return graph }
        graph.exists = true
        guard physical(root) == root, let rootProof = directoryProof(root),
              let manifestsProof = directoryProof(root + "/manifests"),
              let blobsProof = directoryProof(root + "/blobs") else { graph.fail("modelPathUnsafe"); return graph }
        let started = ContinuousClock.now
        var entries = 0, manifestBytes = 0, references = 0
        var directories: [String: String] = [root: rootProof, root + "/manifests": manifestsProof,
                                              root + "/blobs": blobsProof]
        func overBudget() -> Bool {
            isCancelled() || entries > budget.entries || manifestBytes > budget.totalManifestBytes
                || graph.manifests.count > budget.manifests || references > budget.references
                || started.duration(to: .now) > .seconds(budget.seconds)
        }
        func walk(_ path: String, parts: [String]) {
            guard !overBudget(), let stamp = directoryProof(path) else { graph.fail(); return }
            directories[path] = stamp
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { graph.fail(); return }
            guard let directory = fdopendir(fd) else { close(fd); graph.fail(); return }
            defer { closedir(directory) }
            while true {
                errno = 0
                guard let item = readdir(directory) else { if errno != 0 { graph.fail() }; break }
                let name = withUnsafePointer(to: &item.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                entries += 1
                guard !overBudget() else { graph.fail(); break }
                let child = path + "/" + name
                var info = stat()
                guard fstatat(dirfd(directory), name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { graph.fail(); continue }
                let kind = info.st_mode & mode_t(S_IFMT)
                if kind == mode_t(S_IFDIR), parts.count < 3 {
                    walk(child, parts: parts + [name])
                } else if kind == mode_t(S_IFREG), parts.count == 3 {
                    guard graph.manifests.count < budget.manifests,
                          let modelName = displayName(parts + [name]),
                          let proof = fileProof(child), proof.links == 1,
                          let data = readManifest(child, expected: proof.signature,
                                                  limit: min(budget.manifestBytes, budget.totalManifestBytes - manifestBytes)),
                          let refs = parseManifest(data) else { graph.fail(); continue }
                    manifestBytes += data.count
                    references += refs.count
                    graph.proofs[child] = proof
                    graph.manifests.append(.init(path: child, name: modelName, hash: sha256(data), references: Set(refs.keys)))
                    for (digest, size) in refs {
                        graph.references[digest, default: []].insert(child)
                        if let previous = graph.sizes[digest], previous != size { graph.fail() }
                        graph.sizes[digest] = size
                    }
                } else {
                    // Unknown nesting, symlinks and special files could conceal references.
                    graph.fail("modelPathUnsafe")
                }
            }
        }
        walk(root + "/manifests", parts: [])
        for digest in graph.references.keys.sorted() {
            guard !overBudget() else { graph.fail(); break }
            let path = blobPath(digest, root: root)
            if excluding.contains(path), UninstallFileBoundary.isMissing(path) { continue }
            guard let proof = fileProof(path), proof.logicalBytes == graph.sizes[digest] else { graph.fail(); continue }
            graph.proofs[path] = proof
        }
        if overBudget() { graph.fail() }
        for (path, stamp) in directories {
            guard !overBudget() else { graph.fail(); break }
            if directoryProof(path) != stamp { graph.fail() }
        }
        for (path, proof) in graph.proofs {
            guard !overBudget() else { graph.fail(); break }
            if fileProof(path)?.signature != proof.signature { graph.fail() }
        }
        return graph
    }

    private static func exclusivePaths(for manifest: Manifest, in graph: Graph) -> [String] {
        // Unknown/moved blobs retain their original exclusivity by graph; real hard links are retained.
        let blobs = manifest.references.filter { digest in
            graph.references[digest]?.count == 1 && (graph.proofs[blobPath(digest, root: graph.root)]?.links ?? 1) == 1
        }.map { blobPath($0, root: graph.root) }.sorted()
        return blobs + [manifest.path]
    }

    private static func parseManifest(_ data: Data) -> [String: UInt64]? {
        struct Descriptor: Decodable { let digest: String; let size: UInt64; let mediaType: String }
        struct Document: Decodable { let schemaVersion: Int; let mediaType: String; let config: Descriptor; let layers: [Descriptor] }
        guard let document = try? JSONDecoder().decode(Document.self, from: data), document.schemaVersion == 2,
              document.mediaType == "application/vnd.docker.distribution.manifest.v2+json",
              document.layers.count <= 512 else { return nil }
        let descriptors = [document.config] + document.layers
        guard descriptors.allSatisfy({ !$0.mediaType.isEmpty && validDigest($0.digest) }) else { return nil }
        var sizes: [String: UInt64] = [:]
        for descriptor in descriptors {
            if let old = sizes[descriptor.digest], old != descriptor.size { return nil }
            sizes[descriptor.digest] = descriptor.size
        }
        return sizes
    }

    private static func displayName(_ parts: [String]) -> String? {
        guard parts.count == 4 else { return nil }
        for (index, part) in parts.enumerated() {
            let bytes = Array(part.utf8)
            let alnum: (UInt8) -> Bool = { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
            guard let first = bytes.first, alnum(first), bytes.count <= (index == 0 ? 350 : 80),
                  bytes.dropFirst().allSatisfy({ alnum($0) || $0 == 45 || ($0 == 46 && index != 1) || ($0 == 58 && index == 0) }) else { return nil }
        }
        let suffix = parts[2] + ":" + parts[3]
        if parts[0].lowercased() != "registry.ollama.ai" { return parts[0] + "/" + parts[1] + "/" + suffix }
        return parts[1].lowercased() == "library" ? suffix : parts[1] + "/" + suffix
    }

    private static func validDigest(_ digest: String) -> Bool {
        digest.hasPrefix("sha256:") && digest.utf8.count == 71 && digest.dropFirst(7).utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func blobPath(_ digest: String, root: String) -> String {
        root + "/blobs/sha256-" + digest.dropFirst(7)
    }

    private static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func physical(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        // Match AIResource/UninstallFileBoundary's Foundation spelling of fixed macOS /var and /tmp aliases.
        return URL(fileURLWithPath: String(cString: pointer)).standardizedFileURL.path
    }

    private static func signature(_ value: stat) -> String {
        "\(value.st_dev):\(value.st_ino):\(value.st_mode):\(value.st_uid):\(value.st_nlink):\(value.st_size):\(value.st_blocks):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
    }

    private static func directoryProof(_ path: String) -> String? {
        var info = stat()
        guard physical(path) == path, lstat(path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == getuid(),
              info.st_mode & 0o022 == 0 else { return nil }
        return signature(info)
    }

    private static func fileProof(_ path: String) -> Proof? {
        var info = stat()
        guard physical(path) == path, lstat(path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid(),
              info.st_mode & 0o022 == 0, info.st_size >= 0,
              let resource = try? AIResource.capture(path: path, bytes: UInt64(max(0, info.st_blocks)) * 512),
              resource.boundary.item == UninstallFileBoundary.Identity(info), resource.stillMatches() else { return nil }
        return Proof(signature: signature(info), bytes: resource.bytes, logicalBytes: UInt64(info.st_size),
                     links: info.st_nlink, modifiedAt: resource.modifiedAt, resource: resource)
    }

    private static func readManifest(_ path: String, expected: String, limit: Int) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, signature(before) == expected, before.st_size <= limit else { return nil }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; return nil }
            if count == 0 { break }
            guard data.count + count <= limit else { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard fstat(fd, &after) == 0, signature(after) == expected, fileProof(path)?.signature == expected else { return nil }
        return data
    }

    private static func proofJSON(paths: [String], graph: Graph) -> String {
        let values = Dictionary(uniqueKeysWithValues: paths.compactMap { path in graph.proofs[path].map { (path, $0.signature) } })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(values)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func configuredElsewhere(than root: String) -> Bool {
        guard let configured = ProcessInfo.processInfo.environment["OLLAMA_MODELS"], !configured.isEmpty else { return false }
        return (physical(configured) ?? configured) != root
    }
}
