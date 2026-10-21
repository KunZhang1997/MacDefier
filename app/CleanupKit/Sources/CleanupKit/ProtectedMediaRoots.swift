// ProtectedMediaRoots — media library roots: readable for inventory, never deletable.
// TrashExecutor and UninstallExecutor share this list; do not maintain separate copies.

import Foundation

/// 媒体库禁清根：扫描可读，但任何删除路径（清理/卸载）一律拒绝。
public enum ProtectedMediaRoots {
    public static let list: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            home + "/Music/Music",
            home + "/Music/Music Library.musiclibrary",
            home + "/Movies/TV",
            home + "/Movies/Videos",
            home + "/Pictures/Photos Library.photoslibrary",
            home + "/Pictures/照片图库.photoslibrary",
        ]
    }()

    public static func contains(_ path: String) -> Bool {
        let p = AppDataLocations.normalize(path)
        return list.contains { root in
            let r = AppDataLocations.normalize(root)
            return p == r || p.hasPrefix(r + "/")
        }
    }
}
