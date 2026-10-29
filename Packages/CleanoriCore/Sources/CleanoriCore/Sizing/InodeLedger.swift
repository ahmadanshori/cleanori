import Synchronization

/// Remembers which `(device, inode)` pairs have already been counted, so a hardlinked file
/// (for example in a pnpm store) is only charged once. Use one ledger per scan session and share it
/// between every `DirectorySizer` in that session. A ledger is never reset, so make a fresh one for a rescan:
/// reusing it would report 0 bytes for files an earlier scan already claimed.
public final class InodeLedger: Sendable {
    private struct Key: Hashable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    private let claimed = Mutex<Set<Key>>([])

    public init() {}

    /// Returns `true` the first time a file is claimed and `false` on every later claim of the same file.
    public func claim(device: UInt64, inode: UInt64) -> Bool {
        claimed.withLock { $0.insert(Key(device: device, inode: inode)).inserted }
    }
}
