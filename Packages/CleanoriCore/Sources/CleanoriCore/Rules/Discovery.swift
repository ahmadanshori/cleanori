import Foundation

/// Building blocks for `CleanupRule.discover`.
///
/// Discovery never follows symbolic links: a link is not an item, and a folder that is itself a link is
/// not listed. Only items that exist are returned. Paths are built with `appending(path:)` so names with
/// spaces, commas and parentheses (`iPhone14,5 27.0.1 (24A446)`) stay literal.
///
/// The helpers that list a folder's children (`children`, `allButHighestVersion`, `bundles`) return real
/// directories only. Finder drops `.DS_Store` into any folder the user opens, and such stray files must
/// never become items or count as "the newest version".
enum Discovery {
    typealias Function = @Sendable (CoreEnvironment) async throws -> [DiscoveredItem]

    /// Each of `relPaths` (relative to home) that exists, as one item named by that relative path
    /// (`.npm/_cacache`): a bare last component such as `store` or `cache` would be ambiguous in the UI.
    static func fixed(_ relPaths: [String]) -> Function {
        { env in
            relPaths.compactMap { relPath in
                entry(in: env.home, named: relPath)?.item(named: relPath)
            }
        }
    }

    /// Every child folder of `relPath` that `isIncluded` accepts, sorted by name and named after its last
    /// path component. Plain files are skipped.
    static func children(
        of relPath: String,
        where isIncluded: @escaping @Sendable (URL) -> Bool = { _ in true }
    ) -> Function {
        { env in
            listSubdirectories(of: env.home.appending(path: relPath, directoryHint: .isDirectory))
                .filter { isIncluded($0.url) }
                .map(\.item)
        }
    }

    /// Every child folder of `relPath` whose name `isVersion` accepts, except the one with the highest version,
    /// comparing names numerically (so `9.10.0` ranks above `9.4.1`). Other child folders are neither versions nor
    /// items. Returns nothing when there is at most one version.
    static func allButHighestVersion(
        in relPath: String,
        isVersion isVersionName: @escaping @Sendable (String) -> Bool = { _ in true }
    ) -> Function {
        { env in
            let all = listSubdirectories(of: env.home.appending(path: relPath, directoryHint: .isDirectory))
                .filter { isVersionName($0.name) }
            guard let newest = all.max(by: { isVersion($0.name, below: $1.name) }) else { return [] }
            return all.filter { $0.name != newest.name }.map(\.item)
        }
    }

    /// Every `*.<fileExtension>` bundle (a folder) at most `levels` folders below `relPath`, without entering bundles.
    static func bundles(withExtension fileExtension: String, under relPath: String, levels: Int) -> Function {
        { env in
            var found: [DiscoveredItem] = []
            collectBundles(
                in: env.home.appending(path: relPath, directoryHint: .isDirectory),
                withExtension: fileExtension.lowercased(),
                levelsLeft: levels,
                into: &found
            )
            return found
        }
    }

    // MARK: - Internals

    /// A real (non-link) file or folder found on disk.
    private struct Entry {
        let url: URL
        let isDirectory: Bool
        let modified: Date?

        var name: String { url.lastPathComponent }

        var item: DiscoveredItem { item(named: name) }

        func item(named displayName: String) -> DiscoveredItem {
            DiscoveredItem(url: url, displayName: displayName, lastActivity: modified)
        }
    }

    private static func isVersion(_ lhs: String, below rhs: String) -> Bool {
        switch lhs.compare(rhs, options: .numeric) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: lhs < rhs
        }
    }

    private static func collectBundles(
        in dir: URL, withExtension fileExtension: String, levelsLeft: Int, into found: inout [DiscoveredItem]
    ) {
        for child in listSubdirectories(of: dir) {
            if child.url.pathExtension.lowercased() == fileExtension {
                found.append(child.item)
            } else if levelsLeft > 1 {
                collectBundles(in: child.url, withExtension: fileExtension, levelsLeft: levelsLeft - 1, into: &found)
            }
        }
    }

    /// The child folders of `dir` (no files, no links), sorted by name.
    private static func listSubdirectories(of dir: URL) -> [Entry] {
        listChildren(of: dir).filter(\.isDirectory)
    }

    /// The non-link children of `dir`, sorted by name. Empty when `dir` is missing, unreadable, or a link.
    private static func listChildren(of dir: URL) -> [Entry] {
        guard let info = inspect(dir), info.isDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return [] }
        return names.sorted().compactMap { entry(in: dir, named: $0) }
    }

    /// The item at `base/relPath`, or `nil` when it does not exist or is a symbolic link.
    private static func entry(in base: URL, named relPath: String) -> Entry? {
        let probe = base.appending(path: relPath, directoryHint: .notDirectory)
        guard let info = inspect(probe) else { return nil }
        let url = info.isDirectory ? base.appending(path: relPath, directoryHint: .isDirectory) : probe
        return Entry(url: url, isDirectory: info.isDirectory, modified: info.modified)
    }

    /// Describes the item itself, never a link's target. `nil` when it does not exist or is a symbolic link.
    private static func inspect(_ url: URL) -> (isDirectory: Bool, modified: Date?)? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { return nil }
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return (info.st_mode & S_IFMT == S_IFDIR, modified)
    }
}
