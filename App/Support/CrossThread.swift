import CleanoriCore
import Synchronization

// Helpers shared by the screens that scan and clean (Developer Junk, Large Files).

/// Holds the latest progress of a scan between the scanner's threads and the main actor.
///
/// The scanners call `progress` from whichever thread is measuring, so it must stay cheap: it only leaves the
/// latest value here, and the main actor picks it up a few times a second.
final class ProgressRelay: Sendable {
    private let latest = Mutex<ScanProgress?>(nil)

    func store(_ progress: ScanProgress) {
        latest.withLock { $0 = progress }
    }

    /// The newest progress not taken yet, if any.
    func take() -> ScanProgress? {
        latest.withLock { latest in
            defer { latest = nil }
            return latest
        }
    }
}

/// Counts the items a clean has finished with, from whichever thread reports them.
final class EventCounter: Sendable {
    private let count = Mutex(0)

    func next() -> Int {
        count.withLock { count in
            count += 1
            return count
        }
    }
}
