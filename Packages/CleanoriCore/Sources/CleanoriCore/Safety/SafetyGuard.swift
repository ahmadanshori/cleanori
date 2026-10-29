import Foundation

/// The outcome of a `SafetyGuard` check. A denial carries the user-visible reason.
public enum SafetyVerdict: Equatable, Sendable {
    case allowed
    case denied(String)
}

/// The last safety gate before any file is deleted or trashed (spec §5.8).
///
/// Rules run in a fixed order and the first denial wins. The guard judges a path by its text and by
/// `lstat` on the item itself; it never resolves symlinks and does not check that the item exists
/// (`Cleaner` does that before asking).
///
/// Callers must act on the path the guard approved, i.e. the same `URL` they passed to `check`.
public struct SafetyGuard: Sendable {
    /// Normalized components of the home folder; `nil` when `home` is unusable, which denies everything.
    private let homeComponents: [String]?

    public init(home: URL) {
        let parts = Self.normalizedComponents(of: home)
        homeComponents = (parts?.isEmpty ?? true) ? nil : parts
    }

    public func check(_ url: URL, method: CleanMethod, isCatalogItem: Bool) -> SafetyVerdict {
        // 1. Inside home, judged after removing `.` and `..`, without resolving symlinks.
        guard let home = homeComponents,
              let parts = Self.normalizedComponents(of: url),
              parts.count >= home.count,
              parts.starts(with: home)
        else { return .denied("Outside home folder") }
        let relative = Array(parts.dropFirst(home.count))
        let path = "/" + parts.joined(separator: "/")
        let kind = Self.fileKind(atPath: path)

        // 2. Never home itself, nor a folder directly inside it (`~/Library`, a whole `~/Developer`).
        //    A plain file at the root of home (`~/big.dmg`) is fine.
        if relative.isEmpty || (relative.count == 1 && kind == .directory) {
            return .denied("Top-level home folder")
        }

        // 3. The item itself must not be a symbolic link.
        if kind == .symlink { return .denied("Is a symbolic link") }

        // 4. Protected locations. Moving a regular file in Documents or Desktop to the Trash is allowed
        //    because it is reversible; everything else protected is denied for every method.
        if let protected = Self.protectedLocations.first(where: { Self.isEqualOrInside(relative, $0.components) }) {
            let reversibleTrash = method == .trash
                && kind == .regular
                && protected.allowsTrashingFiles
                && relative.count > protected.components.count
            if !reversibleTrash { return .denied("Protected location") }
        }

        // 5. Permanent deletion only: the item must come from a cleanup rule and must not be source code.
        if method == .delete {
            guard isCatalogItem else { return .denied("Not found by a cleanup rule") }
            let name = parts[parts.count - 1]
            if name.lowercased() == ".git" || (kind == .directory && Self.hasEntry(".git", inDirectory: path)) {
                return .denied("Contains a git repository")
            }
            // Build-artifact folders legitimately carry project markers (`.next/package.json`,
            // `Pods/Pods.xcodeproj`), so they skip this one check (Ruling R1); the rest still applies.
            if kind == .directory, !Self.artifactFolderNames.contains(name), Self.isProjectFolder(atPath: path) {
                return .denied("Is a project folder")
            }
        }

        return .allowed
    }

    // MARK: - Policy data

    private struct ProtectedLocation: Sendable {
        let components: [String]
        /// Files (not folders) inside may be moved to the Trash.
        var allowsTrashingFiles = false
    }

    /// Relative to home (spec §5.8).
    private static let protectedLocations: [ProtectedLocation] = [
        ProtectedLocation(components: ["Documents"], allowsTrashingFiles: true),
        ProtectedLocation(components: ["Desktop"], allowsTrashingFiles: true),
        ProtectedLocation(components: ["Pictures"]),
        ProtectedLocation(components: ["Library", "Mobile Documents"]),
        ProtectedLocation(components: ["Library", "Mail"]),
        ProtectedLocation(components: ["Library", "Messages"]),
        ProtectedLocation(components: ["Library", "Keychains"]),
        ProtectedLocation(components: ["Library", "Application Support", "MobileSync"]),
        ProtectedLocation(components: [".ssh"]),
        ProtectedLocation(components: [".gnupg"]),
    ]

    /// Folders cleanup rules produce that may contain project marker files (Ruling R1).
    private static let artifactFolderNames: Set<String> = [
        "node_modules", ".next", ".expo", "build", "Pods", ".gradle",
    ]

    private static let projectMarkerFiles = [
        "package.json", "Package.swift", "settings.gradle", "settings.gradle.kts",
    ]

    // MARK: - Path helpers

    /// Splits a file URL's path into components, dropping `.` and resolving `..` lexically.
    ///
    /// This is deliberately not `standardizedFileURL`: that also strips a leading `/private`, but only
    /// when the path exists, so home and a not-yet-existing item could disagree. Nothing here consults
    /// the filesystem, and symlinks are never resolved. Returns `nil` for non-file URLs.
    private static func normalizedComponents(of url: URL) -> [String]? {
        guard url.isFileURL else { return nil }
        var stack: [String] = []
        for part in url.path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !stack.isEmpty { stack.removeLast() }
            default: stack.append(String(part))
            }
        }
        return stack
    }

    /// Component-wise prefix test, so `Documents2` is not inside `Documents`. Case-insensitive because
    /// the default macOS volume is, and `~/documents` is `~/Documents` there.
    private static func isEqualOrInside(_ path: [String], _ prefix: [String]) -> Bool {
        path.count >= prefix.count
            && zip(prefix, path).allSatisfy { $0.caseInsensitiveCompare($1) == .orderedSame }
    }

    // MARK: - Filesystem helpers (never follow symlinks)

    private enum FileKind { case missing, symlink, directory, regular, other }

    private static func fileKind(atPath path: String) -> FileKind {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .missing }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return .symlink
        case S_IFDIR: return .directory
        case S_IFREG: return .regular
        default: return .other
        }
    }

    private static func hasEntry(_ name: String, inDirectory path: String) -> Bool {
        fileKind(atPath: path + "/" + name) != .missing
    }

    /// A folder holding a project marker at its own level.
    private static func isProjectFolder(atPath path: String) -> Bool {
        if projectMarkerFiles.contains(where: { hasEntry($0, inDirectory: path) }) { return true }
        let children = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return children.contains { $0.lowercased().hasSuffix(".xcodeproj") }
    }
}
