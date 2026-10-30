import Foundation

/// Converts package-manager diagnostics into display-safe reasons. Raw command
/// output can contain tokens, private paths or script text and is never returned.
enum UninstallCommandFailure {
    static func code(stderr: String, exitCode: Int32) -> String {
        let text = stderr.prefix(32_768).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch text {
        case "timeout", "cancelled", "output_limit": return text
        case "launch_failed": return "command_launch_failed"
        default: break
        }

        func contains(_ phrases: [String]) -> Bool { phrases.contains { text.contains($0) } }
        func token(_ value: String) -> Bool {
            text.range(of: "(^|[^a-z0-9_])" + value + "($|[^a-z0-9_])", options: .regularExpression) != nil
        }

        if token("erofs") || contains(["read-only file system", "read only file system"]) {
            return "command_read_only"
        }
        if token("enospc") || token("edquot") || contains(["no space left on device", "disk quota exceeded"]) {
            return "command_disk_full"
        }
        if token("ebusy") || token("etxtbsy") || contains(["resource busy", "text file busy", "file is locked"]) {
            return "command_locked"
        }
        if contains(["a terminal is required", "no tty present", "a password is required",
                     "must be run as root", "must be root", "requires root privileges", "requires administrator privileges"]) {
            return "command_authorization_required"
        }
        if token("eacces") || contains(["permission denied"]) {
            return "command_permission_denied"
        }
        if token("eperm") || contains(["operation not permitted"]) {
            return "command_operation_not_permitted"
        }
        if contains(["refusing to uninstall", "cannot uninstall", "can't uninstall"])
            && contains(["required by", "depends on", "dependency", "dependencies"]) {
            return "command_dependencies_blocked"
        }
        if exitCode == 127 || contains(["command not found"])
            || (text.contains("env:") && text.contains("no such file or directory")) {
            return "command_not_found"
        }
        if exitCode == 126 { return "command_not_executable" }
        return "command_failed"
    }
}
