import Darwin
import Foundation

/// Whether the app has Full Disk Access, which decides if protected folders can be sized exactly.
public enum FullDiskAccess {
    /// Opens the Full Disk Access pane of System Settings.
    public static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    /// Whether access has not been refused: `false` only when listing `Library/Containers/com.apple.Safari` under
    /// `home` fails with a permission error (`EPERM` or `EACCES`), which is how macOS answers for a folder it
    /// protects. Any other outcome is `true`, including a missing folder (`ENOENT`) or any other error: those say
    /// nothing about access, and a banner that cannot be cleared would be wrong more often than right.
    public static func isGranted(home: URL) -> Bool {
        let probe = home.appending(path: "Library/Containers/com.apple.Safari", directoryHint: .isDirectory)
        guard let directory = opendir(probe.path) else { return !isPermissionError(errno) }
        defer { closedir(directory) }
        // Opening can work where reading the entries is what is refused.
        errno = 0
        _ = readdir(directory)
        return !isPermissionError(errno)
    }

    private static func isPermissionError(_ code: Int32) -> Bool {
        code == EPERM || code == EACCES
    }
}
