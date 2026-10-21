// AppDataConditions — per-app expand rules for large data inventory.

import Foundation

struct AppDataCondition: Sendable {
    let id: String
    let sourceApp: String
    let rootRelativeToHome: String
    let preferredChildren: [String]
    let minRootBytes: UInt64
    let minChildBytes: UInt64
    let expandModelFiles: Bool
    let modelExtensions: Set<String>
    let modelNameHints: [String]

    func absoluteRoot(home: String) -> String {
        if rootRelativeToHome.hasPrefix("/") {
            return rootRelativeToHome
        }
        return (home as NSString).appendingPathComponent(rootRelativeToHome)
    }
}

enum AppDataConditions {
    static let p0: [AppDataCondition] = [
        AppDataCondition(
            id: "mumu",
            sourceApp: "MuMu 模拟器",
            rootRelativeToHome: "Library/Application Support/com.netease.mumu.nemux",
            preferredChildren: ["bundles", "instances", "vms", "cache", "logs"],
            minRootBytes: 50 * 1024 * 1024,
            minChildBytes: 20 * 1024 * 1024,
            expandModelFiles: false,
            modelExtensions: [],
            modelNameHints: []
        ),
        AppDataCondition(
            id: "colima",
            sourceApp: "Colima",
            rootRelativeToHome: ".colima",
            preferredChildren: ["_lima", "default", "cache", "logs"],
            minRootBytes: 50 * 1024 * 1024,
            minChildBytes: 20 * 1024 * 1024,
            expandModelFiles: false,
            modelExtensions: [],
            modelNameHints: []
        ),
        AppDataCondition(
            id: "speaksend",
            sourceApp: "SpeakSend",
            rootRelativeToHome: "Library/Application Support/SpeakSend/ManagedModels",
            preferredChildren: [],
            minRootBytes: 50 * 1024 * 1024,
            minChildBytes: 50 * 1024 * 1024,
            expandModelFiles: true,
            modelExtensions: ["gguf", "bin"],
            modelNameHints: ["whisper", "ggml-", "gemma", "llama"]
        ),
        AppDataCondition(
            id: "music-library",
            sourceApp: "Music",
            rootRelativeToHome: "Music/Music Library.musiclibrary",
            preferredChildren: [],
            minRootBytes: 50 * 1024 * 1024,
            minChildBytes: 50 * 1024 * 1024,
            expandModelFiles: false,
            modelExtensions: [],
            modelNameHints: []
        ),
        AppDataCondition(
            id: "music-media",
            sourceApp: "Music",
            rootRelativeToHome: "Music/Music",
            preferredChildren: ["Media.localized", "Media"],
            minRootBytes: 50 * 1024 * 1024,
            minChildBytes: 50 * 1024 * 1024,
            expandModelFiles: false,
            modelExtensions: [],
            modelNameHints: []
        ),
        AppDataCondition(
            id: "lmstudio-models",
            sourceApp: "LM Studio",
            rootRelativeToHome: ".lmstudio/models",
            preferredChildren: [],
            minRootBytes: 100 * 1024 * 1024,
            minChildBytes: 100 * 1024 * 1024,
            expandModelFiles: true,
            modelExtensions: ["gguf", "bin"],
            modelNameHints: ["ggml-", "whisper"]
        ),
        AppDataCondition(
            id: "ollama",
            sourceApp: "Ollama",
            rootRelativeToHome: ".ollama/models",
            preferredChildren: ["blobs", "manifests"],
            minRootBytes: 100 * 1024 * 1024,
            minChildBytes: 50 * 1024 * 1024,
            expandModelFiles: false,
            modelExtensions: [],
            modelNameHints: []
        )
    ]
}
