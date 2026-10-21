// AppDataLocations — roots for large app-data inventory (not junk-cache tables).

import Foundation

public enum AppDataLocations {
    private static var home: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Roots allowed for **inventory scan only** (exact path or under prefix).
    /// 删除闸见 `ProtectedMediaRoots`：媒体库根可盘点，但清理/卸载一律拒绝。
    public static var allowedRoots: [String] {
        [
            "\(home)/Library/Application Support/com.apple.wallpaper/aerials",
            "\(home)/Library/Application Support/com.netease.mumu.nemux",
            "\(home)/Library/Application Support/SpeakSend",
            "\(home)/.colima",
            "\(home)/.ollama",
            "\(home)/.lmstudio",
            "\(home)/.cache/llama.cpp",
            "\(home)/.cache/whisper",
            "\(home)/Music/Music Library.musiclibrary",
            "\(home)/Music/Music",
            "\(home)/Movies/TV",
            "\(home)/Movies/Videos",
            "\(home)/Pictures/Photos Library.photoslibrary"
        ]
    }

    public static func isUnderAllowedRoot(_ path: String) -> Bool {
        let resolved = normalize(path)
        return allowedRoots.contains { root in
            let r = normalize(root)
            return resolved == r || resolved.hasPrefix(r + "/")
        }
    }

    public static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
