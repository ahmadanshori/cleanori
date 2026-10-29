import Foundation

/// Builds the size tree behind the read-only Disk Map screen (spec §5.7).
///
/// - One walk of the whole tree. Sizes are allocated blocks, measured the way `DirectorySizer` measures them.
/// - Each folder keeps only its `keepLargest` biggest children, sorted largest first, and only those of at least
///   `minimumChildBytes`. Everything else collapses into one last child (`isOther`, no `url`) that carries the
///   summed bytes and file counts, so the tree stays small however many entries the disk holds. Equal sizes are
///   ordered by name, so the result never depends on the order the file system lists a folder in.
/// - Symbolic links are never followed, and are not listed. Neither are sockets, pipes and devices.
/// - A folder on another volume (a mount point) is not entered and not listed.
/// - A file with more than one hardlink is charged once per scan. Its other names are still listed, with 0 bytes
///   (or folded into "other" with the rest of the small items).
/// - Anything unreadable is left out and never stops the walk. A folder whose content cannot be listed counts as
///   0 bytes and is marked `isApproximate`, together with every folder above it; so is a folder that lost an entry
///   whose attributes could not be read. With the default `minimumChildBytes` such an empty folder is too small to be
///   kept, so it is folded into its parent's "Other" group, which is then marked `isApproximate` too. Only with a
///   `minimumChildBytes` of 0 is it listed itself, empty.
/// - Cancelling the task running `scan` ends it with `CancellationError`.
///
/// ## How memory stays bounded
///
/// `FileManager.enumerator` walks depth first, parents before children. The scanner keeps a stack with one
/// `Frame` for each folder that is currently open, indexed by `enumerator.level`. When an entry at level `n`
/// arrives, every open folder at level `n` or deeper is finished. A finished folder is turned into a pruned
/// `DiskNode`, which is handed to its parent, so a folder's subtree is built bottom-up (post-order) and
/// whatever it drops is released immediately.
///
/// What a folder keeps is limited twice. Only children of at least `minimumChildBytes` are kept at all (a smaller
/// one is added to the folder's "other" totals the moment it is seen, and a small file never even becomes a node),
/// so the tree has roughly one node per `minimumChildBytes` of disk space, not one per entry. And of those, a
/// folder keeps no more than `keepLargest`. While a folder is still being read its buffer is pruned as soon as it
/// holds more than `max(2 * keepLargest, keepLargest + 16)` children: it is sorted, the largest `keepLargest` stay,
/// and the rest are folded into running totals. That is exact, because anything dropped had at least `keepLargest`
/// siblings ahead of it, so it can never end up in the final top group. The walk's working set is therefore the
/// stack depth times that buffer, plus the pruned tree being built.
public struct DiskMapScanner: Sendable {
    private let keepLargest: Int
    private let minimumChildBytes: Int64

    /// `keepLargest` is how many children each folder keeps. A value below 0 counts as 0, which keeps none.
    /// `minimumChildBytes` is the size under which a child is never kept (it goes into the folder's "other" group
    /// instead). The default, 1 MB, keeps the tree to roughly one node per MB of used space. Pass 0 to keep
    /// every child that `keepLargest` allows, whatever its size.
    public init(keepLargest: Int = 50, minimumChildBytes: Int64 = 1_000_000) {
        self.keepLargest = max(0, keepLargest)
        self.minimumChildBytes = max(0, minimumChildBytes)
    }

    /// Scans `root`, which may be a folder or a single file.
    ///
    /// Every path in the result is spelled below `root` as given, not as Foundation reports it (it resolves
    /// symbolic links in the ancestors of the folder it walks, such as `/var` to `/private/var`). Throws
    /// `CancellationError` when the task is cancelled, and a `POSIXError` when `root` itself cannot be inspected
    /// (for instance when it does not exist). A symbolic link as `root` is not followed, and gives an empty node.
    /// A `root` folder that cannot be read gives an empty, approximate node.
    public func scan(
        root: URL,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> DiskNode {
        try Task.checkCancellation()
        let info = try DirectorySizer.lstatInfo(of: root)
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            return try scanFolder(at: root, progress: progress)
        case S_IFREG:
            let allocated = (try? root.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize
            let bytes = allocated.map(Int64.init) ?? Int64(info.st_blocks) * 512
            return DiskNode(path: root.path, bytes: bytes, itemCount: 1, isDirectory: false)
        default:
            // A symlink (never followed), socket, pipe or device.
            return DiskNode(path: root.path, bytes: 0, itemCount: 0, isDirectory: false)
        }
    }

    // MARK: - Walking

    /// Prefetched by the enumerator in bulk. `isRegularFileKey` and `linkCountKey` let a file with a single
    /// link (nearly all of them) be sized without a separate `lstat`, which is needed only for `st_dev`/`st_ino`
    /// of the rare hardlinked file.
    private static let keys: [URLResourceKey] = [
        .totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .linkCountKey,
        .volumeIdentifierKey,
    ]
    private static let keySet = Set(keys)

    private func scanFolder(at root: URL, progress: (@Sendable (ScanProgress) -> Void)?) throws -> DiskNode {
        let rootVolume = (try? root.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        // The enumerator calls this while it is trying to read a folder it returned a moment ago (and for the root
        // itself, before it returns anything), so when it is set, the innermost open folder is the one that failed.
        var readFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Self.keys,
            options: [],
            errorHandler: { _, _ in
                readFailed = true
                return true // keep going; what could not be read is simply left out
            }
        ) else {
            throw POSIXError(.EIO)
        }

        // One ledger per scan: a ledger is never reset, so a rescan needs a fresh one.
        let ledger = InodeLedger()
        let limit = keepLargest
        let minimumBytes = minimumChildBytes
        // `stack[n]` is the open folder at level `n`, so while an entry at level `n` is handled, `stack[n - 1]`
        // is its parent. The root is level 0 and is never popped before the end.
        var stack = [Frame(path: root.path, limit: limit, minimumBytes: minimumBytes)]
        var entries = 0

        /// Finishes every open folder at `depth` or deeper, handing each to its parent.
        func close(downTo depth: Int) {
            while stack.count > depth {
                var frame = stack.removeLast()
                stack[stack.count - 1].add(frame.finish())
            }
        }

        /// Visits one entry; returns `false` when the walk is finished.
        func visitNext() throws -> Bool {
            let next = enumerator.nextObject()
            if readFailed {
                // Before any frame is closed: the innermost open folder is the one that could not be read.
                stack[stack.count - 1].markApproximate()
                readFailed = false
            }
            guard let item = next as? URL else { return false }
            try Task.checkCancellation()
            entries += 1
            if entries % DirectorySizer.progressInterval == 0 {
                progress?(ScanProgress(itemsScanned: entries, currentPath: item.path))
            }

            // Entries come parents first, so everything open at this level or deeper is complete.
            let level = enumerator.level
            close(downTo: level)

            // `skipDescendants()` is only called on a folder we really refuse to enter (below). Called on anything
            // else it leaves a skip pending, and Foundation then skips the next folder it would have entered, which
            // silently drops a whole subtree. So a link needs no call (the enumerator never follows one), and an
            // entry with no readable attributes is just left out: whatever is below it has no open parent, which
            // this check spots, so it is ignored entry by entry.
            guard stack.count == level else { return true }
            guard let values = try? item.resourceValues(forKeys: Self.keySet) else {
                stack[level - 1].markApproximate() // left out, so the folder may be missing something
                return true
            }
            if values.isSymbolicLink == true { return true } // never followed, never listed

            // Paths are built from the parent's path, not taken from `item`, so they stay spelled below the root as given.
            let parentPath = stack[level - 1].path
            if values.isDirectory == true {
                // In practice Foundation's enumerator already stops at mount points; checking the volume
                // identifier keeps the "never cross volumes" rule explicit instead of relying on that.
                if let rootVolume, let volume = values.volumeIdentifier, !rootVolume.isEqual(volume) {
                    enumerator.skipDescendants()
                    return true
                }
                let path = Self.path(in: parentPath, named: item.lastPathComponent)
                stack.append(Frame(path: path, limit: limit, minimumBytes: minimumBytes))
                return true
            }
            if values.isRegularFile != true { return true } // socket, pipe or device

            let bytes: Int64
            if let links = values.linkCount, links <= 1, let allocated = values.totalFileAllocatedSize {
                // The common case: a single link, so nothing to dedupe and no `lstat` needed.
                bytes = Int64(allocated)
            } else {
                // Hardlinked (or not fully described by the prefetched values): `lstat` gives the device and inode.
                guard let info = try? DirectorySizer.lstatInfo(of: item), info.st_mode & S_IFMT == S_IFREG else {
                    stack[level - 1].markApproximate()
                    return true
                }
                let allocated = values.totalFileAllocatedSize.map(Int64.init) ?? Int64(info.st_blocks) * 512
                let isFirstLink = info.st_nlink <= 1
                    || ledger.claim(device: UInt64(truncatingIfNeeded: info.st_dev), inode: info.st_ino)
                bytes = isFirstLink ? allocated : 0
            }
            if stack[level - 1].isTooSmall(bytes) {
                // Most files end here: counted in the folder's totals without ever becoming a node.
                stack[level - 1].addSmallFile(bytes: bytes)
                return true
            }
            let path = Self.path(in: parentPath, named: item.lastPathComponent)
            stack[level - 1].add(DiskNode(path: path, bytes: bytes, itemCount: 1, isDirectory: false))
            return true
        }

        // Each step creates autoreleased URLs and resource-value dictionaries; without draining them per entry,
        // memory would grow with the number of entries (see `DirectorySizer`).
        while try autoreleasepool(invoking: visitNext) {}
        close(downTo: 1)
        return stack[0].finish()
    }

    /// The path of the entry called `name` in the folder at `folder`.
    private static func path(in folder: String, named name: String) -> String {
        folder == "/" ? "/" + name : folder + "/" + name
    }

    // MARK: - Open folders

    /// A folder being read: its running totals and the children worth keeping so far.
    private struct Frame {
        let path: String
        private let limit: Int
        private let minimumBytes: Int64
        /// How many children may pile up before the smallest are folded away.
        private let bufferSize: Int

        private(set) var bytes: Int64 = 0
        private(set) var itemCount = 0
        private(set) var isApproximate = false
        private var kept: [DiskNode] = []
        private var droppedNodes = 0
        private var droppedBytes: Int64 = 0
        private var droppedItems = 0
        private var droppedApproximate = false

        init(path: String, limit: Int, minimumBytes: Int64) {
            self.path = path
            self.limit = limit
            self.minimumBytes = minimumBytes
            bufferSize = max(2 * limit, limit + 16)
        }

        /// Whether a child of this many bytes is too small to be kept (it goes straight into the "other" group).
        func isTooSmall(_ childBytes: Int64) -> Bool { childBytes < minimumBytes }

        /// Notes that something in this folder could not be read.
        mutating func markApproximate() { isApproximate = true }

        /// Adds a finished child. Its bytes and files count towards this folder whether or not it is kept.
        mutating func add(_ child: DiskNode) {
            bytes += child.bytes
            itemCount += child.itemCount
            if child.isApproximate { isApproximate = true }
            if isTooSmall(child.bytes) {
                fold(child)
                return
            }
            kept.append(child)
            if kept.count > bufferSize { prune() }
        }

        /// Adds a file that `isTooSmall`, without making a node for it. The same as `add` followed by a fold.
        mutating func addSmallFile(bytes fileBytes: Int64) {
            bytes += fileBytes
            itemCount += 1
            droppedNodes += 1
            droppedBytes += fileBytes
            droppedItems += 1
        }

        /// The folder as a node: the largest `limit` children (of the ones big enough), then one group for all the
        /// others. The children are copied into an array of exactly their size, since the buffer they were
        /// collected in can be many times larger.
        mutating func finish() -> DiskNode {
            prune()
            var children: [DiskNode] = []
            children.reserveCapacity(kept.count + (droppedNodes > 0 ? 1 : 0))
            children.append(contentsOf: kept)
            if droppedNodes > 0 {
                children.append(.other(
                    inFolderAt: path, count: droppedNodes, bytes: droppedBytes, itemCount: droppedItems,
                    isApproximate: droppedApproximate
                ))
            }
            return DiskNode(
                path: path, bytes: bytes, itemCount: itemCount, isDirectory: true,
                isApproximate: isApproximate, children: children
            )
        }

        /// Sorts what is held, largest first, and folds everything beyond `limit` into the dropped totals.
        private mutating func prune() {
            kept.sort(by: Self.isLarger)
            guard kept.count > limit else { return }
            for node in kept[limit...] { fold(node) }
            kept.removeSubrange(limit...)
        }

        private mutating func fold(_ node: DiskNode) {
            droppedNodes += 1
            droppedBytes += node.bytes
            droppedItems += node.itemCount
            if node.isApproximate { droppedApproximate = true }
        }

        /// A total order (a folder never holds two entries with the same name), so ties are decided by name.
        private static func isLarger(_ a: DiskNode, _ b: DiskNode) -> Bool {
            a.bytes != b.bytes ? a.bytes > b.bytes : a.name < b.name
        }
    }
}
