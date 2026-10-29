import Foundation

/// A throwaway home directory for tests. Tests must never touch the real home folder.
struct TempHome {
    /// The canonical path (`realpath(3)`), so no ancestor is a symlink, like the real `/Users/<name>`.
    /// The temp dir lives under `/var`, a symlink to `/private/var`, so this is `/private/var/...`.
    let url: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CleanoriTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let resolved = realpath(root.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(resolved) }
        url = URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
    }

    /// Creates a file of `bytes` non-zero bytes (so APFS allocates real blocks), making parent folders as needed.
    @discardableResult
    func file(_ rel: String, bytes: Int = 1 << 20, modified: Date? = nil) throws -> URL {
        let fileURL = url.appending(path: rel, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0xA5, count: bytes).write(to: fileURL)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: fileURL.path)
        }
        return fileURL
    }

    @discardableResult
    func dir(_ rel: String) throws -> URL {
        let dirURL = url.appending(path: rel, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        return dirURL
    }

    /// Creates a symbolic link at `rel` pointing to `to`, making parent folders as needed.
    @discardableResult
    func symlink(_ rel: String, to: URL) throws -> URL {
        let linkURL = url.appending(path: rel, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: to)
        return linkURL
    }

    /// Removes the whole tree, even folders a test made unreadable (e.g. `chmod 000`).
    func cleanup() {
        Self.restoreOwnerAccess(at: url)
        try? FileManager.default.removeItem(at: url)
    }

    /// Gives the owner `rwx` on every real directory below `dir` so it can be listed and emptied.
    /// Symlinks are never followed, so nothing outside the temp tree is touched.
    private static func restoreOwnerAccess(at dir: URL) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: dir.path),
              attrs[.type] as? FileAttributeType == .typeDirectory else { return }
        let mode = (attrs[.posixPermissions] as? Int ?? 0) | 0o700
        try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: dir.path)
        for child in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            restoreOwnerAccess(at: dir.appending(path: child, directoryHint: .notDirectory))
        }
    }
}
