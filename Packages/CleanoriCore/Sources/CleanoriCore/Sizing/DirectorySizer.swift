import Foundation

/// A progress report from `DirectorySizer`, sent every 2,000 entries.
public struct ScanProgress: Sendable {
    public var itemsScanned: Int
    public var currentPath: String

    public init(itemsScanned: Int, currentPath: String) {
        self.itemsScanned = itemsScanned
        self.currentPath = currentPath
    }
}

/// Measures how much disk space a file or folder really uses (allocated blocks, not logical size).
///
/// - Symbolic links are never followed and count for 0 bytes.
/// - A folder on another volume (a mount point) is not entered.
/// - A file with more than one hardlink is charged once per `InodeLedger`, and the result is marked approximate.
/// - Anything unreadable is skipped and marks the result approximate; it never aborts the scan.
public struct DirectorySizer: Sendable {
    /// How many entries pass between two progress reports.
    static let progressInterval = 2_000

    private let ledger: InodeLedger

    public init(ledger: InodeLedger = InodeLedger()) {
        self.ledger = ledger
    }

    /// Sizes `url`, which may be a folder or a single file.
    ///
    /// `fileCount` counts the regular files found, hardlinks included, while `bytes` charges each hardlinked
    /// file only once. Throws `CancellationError` when the task is cancelled, and a `POSIXError` when `url`
    /// itself cannot be inspected (for instance when it does not exist).
    public func size(
        of url: URL,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> SizeResult {
        try Task.checkCancellation()
        let info = try Self.lstatInfo(of: url)
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            return try sizeOfFolder(at: url, progress: progress)
        case S_IFREG:
            var result = SizeResult.zero
            let allocated = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize
            addFile(info, allocatedSize: allocated, to: &result)
            return result
        default:
            return .zero // a symlink (never followed), socket, pipe or device
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

    private func sizeOfFolder(at root: URL, progress: (@Sendable (ScanProgress) -> Void)?) throws -> SizeResult {
        let rootVolume = (try? root.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        var hadFailures = false
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Self.keys,
            options: [],
            errorHandler: { _, _ in
                hadFailures = true
                return true // keep going; this entry is simply left out
            }
        ) else {
            throw POSIXError(.EIO)
        }

        var result = SizeResult.zero
        var entries = 0

        /// Visits one entry; returns `false` when the walk is finished.
        func visitNext() throws -> Bool {
            guard let item = enumerator.nextObject() as? URL else { return false }
            try Task.checkCancellation()
            entries += 1
            if entries % Self.progressInterval == 0 {
                progress?(ScanProgress(itemsScanned: entries, currentPath: item.path))
            }

            guard let values = try? item.resourceValues(forKeys: Self.keySet) else {
                result.isApproximate = true
                return true
            }
            if values.isSymbolicLink == true { return true }
            if values.isDirectory == true {
                // In practice Foundation's enumerator already stops at mount points; checking the volume
                // identifier keeps the "never cross volumes" rule explicit instead of relying on that.
                if let rootVolume, let volume = values.volumeIdentifier, !rootVolume.isEqual(volume) {
                    enumerator.skipDescendants()
                }
                return true
            }
            if values.isRegularFile == false { return true } // socket, pipe or device

            if values.isRegularFile == true, let links = values.linkCount, links <= 1,
               let allocated = values.totalFileAllocatedSize {
                // The common case: a single link, so nothing to dedupe and no `lstat` needed.
                result.bytes += Int64(allocated)
                result.fileCount += 1
                return true
            }
            // Hardlinked (or not fully described by the prefetched values): `lstat` gives the device and inode.
            guard let info = try? Self.lstatInfo(of: item) else {
                result.isApproximate = true
                return true
            }
            if info.st_mode & S_IFMT == S_IFREG {
                addFile(info, allocatedSize: values.totalFileAllocatedSize, to: &result)
            }
            return true
        }

        // Each visit is wrapped in its own autorelease pool, and so is `nextObject()` itself. Every step creates
        // autoreleased URLs, resource-value dictionaries and NSNumbers, and without draining them per entry the
        // walk holds on to roughly 1 KB per entry until it ends (about 440 MB for 230,000 files).
        while try autoreleasepool(invoking: visitNext) {}
        if hadFailures { result.isApproximate = true }
        return result
    }

    /// Adds one regular file to `result`, charging its bytes once even when it has several hardlinks.
    private func addFile(_ info: stat, allocatedSize: Int?, to result: inout SizeResult) {
        let bytes: Int64
        if let allocatedSize {
            bytes = Int64(allocatedSize)
        } else {
            bytes = Int64(info.st_blocks) * 512 // the resource value was unavailable; `stat` still knows
            result.isApproximate = true
        }

        var chargeBytes = true
        if info.st_nlink > 1 {
            // The space is shared with another location, so any total involving it is only a close estimate.
            result.isApproximate = true
            chargeBytes = ledger.claim(device: UInt64(truncatingIfNeeded: info.st_dev), inode: info.st_ino)
        }
        if chargeBytes { result.bytes += bytes }
        result.fileCount += 1
    }

    static func lstatInfo(of url: URL) throws -> stat {
        var info = stat()
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = ENOENT
                return -1
            }
            return lstat(path, &info)
        }
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return info
    }
}
