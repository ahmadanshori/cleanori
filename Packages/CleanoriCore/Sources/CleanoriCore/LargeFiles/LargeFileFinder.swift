import CoreServices
import Foundation
import Synchronization

/// One row of the Large Files screen.
public struct LargeFile: Sendable, Identifiable {
    /// The path, which is unique within one result.
    public let id: String
    public let url: URL
    public let kind: FileKind
    /// When the file was last opened (Spotlight's last used date, else the file system's access date).
    /// `nil` when neither is known.
    public let lastOpened: Date?
    /// Space used on disk. For a package (such as a `.photoslibrary`) that is the whole folder.
    public let bytes: Int64
    /// Set when the item cannot be selected: it lies in a folder Developer Junk manages, or `SafetyGuard`
    /// would refuse to move it to the Trash. It is still listed.
    public let lock: LockReason?

    public init(url: URL, kind: FileKind, lastOpened: Date?, bytes: Int64, lock: LockReason?) {
        id = url.path
        self.url = url
        self.kind = kind
        self.lastOpened = lastOpened
        self.bytes = bytes
        self.lock = lock
    }
}

/// Finds the large files in the home folder (spec §5.6).
///
/// - `Library` and `.Trash` directly in the home folder are not entered, and neither is any `node_modules`
///   or `.git`. Another folder that happens to be named `Library` is walked like any other.
/// - A package (`.photoslibrary`, `.app`...) is measured whole with `DirectorySizer` and reported as one item.
///   Its content is never listed.
/// - Symbolic links are neither listed nor followed.
/// - A file in a folder that Developer Junk manages is listed, locked: one of `Catalog.managedRoots`, or a
///   project's build folder (`Catalog.managedProjectFolders`, such as `android/app/build` or `.next`) anywhere
///   below a project root.
/// - So is anything `SafetyGuard` would refuse to move to the Trash (a package in `~/Pictures`, a folder in
///   `~/Documents`), so the user sees why up front rather than a failure when cleaning. A plain file in
///   `~/Documents` or `~/Desktop` is allowed, and listed unlocked.
/// - Unreadable folders are skipped; they never stop the walk.
/// - Cancelling the task running `find` ends it with `CancellationError`.
public struct LargeFileFinder: Sendable {
    private let env: CoreEnvironment
    private let lastUsedDate: @Sendable (URL) -> Date?
    private let safety: SafetyGuard

    /// `lastUsedDate` tells when the file at a URL was last opened, or `nil` when it does not know. The default
    /// asks Spotlight. Tests pass their own, so they never depend on the Spotlight index.
    public init(
        env: CoreEnvironment,
        lastUsedDate: @escaping @Sendable (URL) -> Date? = LargeFileFinder.spotlightLastUsed
    ) {
        self.env = env
        self.lastUsedDate = lastUsedDate
        safety = SafetyGuard(home: env.home)
    }

    /// Spotlight's `kMDItemLastUsedDate` for a file, or `nil` when it is not indexed or has none.
    public static let spotlightLastUsed: @Sendable (URL) -> Date? = { url in
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// The files and packages of at least `minBytes` (on disk), sorted by `lastOpened` with the oldest first
    /// and files without a date before all others, then by size, largest first.
    ///
    /// With `notOpenedInDays`, only what was last opened more than that many days before `env.now()` is returned.
    /// An item without any date counts as old. One dated in the future counts as recent.
    ///
    /// `progress` is told how many entries have been visited, every 2,000 entries. Packages are measured after the
    /// walk, and their entries count too.
    public func find(
        minBytes: Int64 = 100_000_000,
        notOpenedInDays: Int? = nil,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> [LargeFile] {
        try Task.checkCancellation()
        let relay = progress.map(ProgressRelay.init)
        let walk = try walkHome(minBytes: minBytes, notOpenedInDays: notOpenedInDays, relay: relay)
        var found = walk.files
        var entries = walk.entries

        for package in walk.packages {
            try Task.checkCancellation()
            let base = entries
            let size: SizeResult
            do {
                // A fresh sizer (and so a fresh ledger) for each package, so every item reports the space it uses by itself.
                size = try await DirectorySizer().size(of: package) { update in
                    relay?.report(base + update.itemsScanned, path: update.currentPath)
                }
            } catch let cancellation as CancellationError {
                throw cancellation
            } catch {
                continue // gone, or unreadable as a whole
            }
            entries = max(entries, relay?.highest ?? 0)
            guard size.bytes >= minBytes else { continue }
            if let file = autoreleasepool(invoking: { makeFile(at: package, bytes: size.bytes, notOpenedInDays: notOpenedInDays) }) {
                found.append(file)
            }
        }
        try Task.checkCancellation()

        found.sort(by: Self.isListedBefore)
        return found
    }

    // MARK: - Walking

    /// Folders directly in the home folder that are not entered.
    private static let skippedInHome: Set<String> = ["Library", ".Trash"]
    /// Folders that are not entered wherever they are.
    private static let skippedAnywhere: Set<String> = ["node_modules", ".git"]

    /// Prefetched by the enumerator in bulk, so none of them costs a separate system call per entry.
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .isPackageKey, .totalFileAllocatedSizeKey,
    ]
    private static let keySet = Set(keys)

    private struct Walk {
        var files: [LargeFile] = []
        /// Packages found, measured by the caller after the walk.
        var packages: [URL] = []
        var entries = 0
    }

    /// Walks the home folder, returning the large regular files and the packages found.
    private func walkHome(minBytes: Int64, notOpenedInDays: Int?, relay: ProgressRelay?) throws -> Walk {
        guard let enumerator = FileManager.default.enumerator(
            at: env.home,
            includingPropertiesForKeys: Self.keys,
            options: [],
            errorHandler: { _, _ in true } // an unreadable folder is simply left out
        ) else {
            throw POSIXError(.EIO)
        }

        var walk = Walk()

        /// Visits one entry; returns `false` when the walk is finished.
        func visitNext() throws -> Bool {
            guard let reported = enumerator.nextObject() as? URL else { return false }
            try Task.checkCancellation()
            walk.entries += 1
            if walk.entries % DirectorySizer.progressInterval == 0 {
                relay?.report(walk.entries, path: reported.path)
            }

            guard let values = try? reported.resourceValues(forKeys: Self.keySet) else { return true }
            // A link is neither listed nor entered. The enumerator never follows one, so it needs no
            // `skipDescendants()`; called on anything but a folder, that call makes Foundation skip the next folder
            // it would have entered, silently dropping a whole subtree. It is only called on folders, below.
            if values.isSymbolicLink == true { return true }

            if values.isDirectory == true {
                let name = reported.lastPathComponent
                if Self.skippedAnywhere.contains(name) || (enumerator.level == 1 && Self.skippedInHome.contains(name)) {
                    enumerator.skipDescendants()
                } else if values.isPackage == true {
                    enumerator.skipDescendants()
                    walk.packages.append(underHome(reported, level: enumerator.level, isDirectory: true))
                }
                return true
            }

            guard values.isRegularFile == true, let allocated = values.totalFileAllocatedSize,
                  Int64(allocated) >= minBytes else { return true }
            let url = underHome(reported, level: enumerator.level, isDirectory: false)
            if let file = makeFile(at: url, bytes: Int64(allocated), notOpenedInDays: notOpenedInDays) {
                walk.files.append(file)
            }
            return true
        }

        // Each step creates autoreleased URLs and resource-value dictionaries; without draining them per entry,
        // memory would grow with the number of entries in the home folder (see `DirectorySizer`).
        while try autoreleasepool(invoking: visitNext) {}
        return walk
    }

    /// `reported` (a URL the enumerator gave, `level` folders below the home folder) spelled below `env.home`
    /// as given. Foundation resolves symlinks in the ancestors of the folder it walks, so the reported URL cannot
    /// be trusted to start with the caller's own path, and `SafetyGuard` compares paths lexically.
    private func underHome(_ reported: URL, level: Int, isDirectory: Bool) -> URL {
        let relative = Self.components(of: reported).suffix(level).joined(separator: "/")
        return env.home.appending(path: relative, directoryHint: isDirectory ? .isDirectory : .notDirectory)
    }

    // MARK: - Items

    /// The row for the file or package at `url`, or `nil` when it was opened too recently for `notOpenedInDays`.
    private func makeFile(at url: URL, bytes: Int64, notOpenedInDays: Int?) -> LargeFile? {
        let lastOpened = lastUsedDate(url) ?? Self.accessDate(of: url)
        if let days = notOpenedInDays, let lastOpened {
            let cutoff = env.now().addingTimeInterval(-Double(days) * 86_400)
            if lastOpened >= cutoff { return nil } // opened within the last `days` days (exactly that many still counts)
        }
        return LargeFile(url: url, kind: FileKind.of(url), lastOpened: lastOpened, bytes: bytes, lock: lock(for: url))
    }

    /// Why the item at `url` cannot be selected, if it cannot. The folder being managed by Developer Junk is
    /// the more specific reason, so it is checked first.
    private func lock(for url: URL) -> LockReason? {
        let components = Self.components(of: url)
        if managedRoots.contains(where: { components.starts(with: $0) }) { return .managedByDeveloperJunk }
        if isInProjectBuildFolder(components) { return .managedByDeveloperJunk }
        // The same question `Cleaner` asks right before it trashes the item.
        if case .denied = safety.check(url, method: .trash, isCatalogItem: false) { return .protectedLocation }
        return nil
    }

    /// The path of each folder Developer Junk manages, as components, so a folder that only shares a name prefix
    /// (`.android-notes`) does not match.
    private var managedRoots: [[String]] {
        Catalog.managedRoots(home: env.home).map(Self.components(of:))
    }

    /// Whether the item with these path components lies inside one of `Catalog.managedProjectFolders` below a project
    /// root. The folders are matched as whole components (`next` is not `.next`), and the item itself does not count
    /// (a file named `Pods` is not inside `ios/Pods`).
    private func isInProjectBuildFolder(_ components: [String]) -> Bool {
        let folders = components.dropLast()
        return env.projectRoots.map(Self.components(of:)).contains { root in
            guard folders.starts(with: root) else { return false }
            let below = Array(folders.dropFirst(root.count))
            return Self.projectBuildFolders.contains { pattern in
                below.count >= pattern.count
                    && (0...(below.count - pattern.count)).contains { below[$0..<($0 + pattern.count)].elementsEqual(pattern) }
            }
        }
    }

    private static let projectBuildFolders: [[String]] = Catalog.managedProjectFolders.map {
        $0.split(separator: "/").map(String.init)
    }

    private static func accessDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate
    }

    private static func components(of url: URL) -> [String] {
        url.path.split(separator: "/").map(String.init)
    }

    /// Oldest first, files without a date before the rest, then the largest, then by path so the order is stable.
    private static func isListedBefore(_ a: LargeFile, _ b: LargeFile) -> Bool {
        switch (a.lastOpened, b.lastOpened) {
        case (nil, .some): return true
        case (.some, nil): return false
        case let (x?, y?) where x != y: return x < y
        default: break
        }
        if a.bytes != b.bytes { return a.bytes > b.bytes }
        return a.url.path < b.url.path
    }
}

/// Passes progress on to the caller and never lets the count go down, whoever reports it.
private final class ProgressRelay: Sendable {
    private let forward: @Sendable (ScanProgress) -> Void
    private let highestReported = Mutex(0)

    init(_ forward: @escaping @Sendable (ScanProgress) -> Void) {
        self.forward = forward
    }

    /// The largest count reported so far.
    var highest: Int { highestReported.withLock { $0 } }

    func report(_ count: Int, path: String) {
        let isNew = highestReported.withLock { highest in
            guard count > highest else { return false }
            highest = count
            return true
        }
        if isNew { forward(ScanProgress(itemsScanned: count, currentPath: path)) }
    }
}
