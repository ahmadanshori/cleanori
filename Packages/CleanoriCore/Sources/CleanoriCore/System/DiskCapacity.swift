import Foundation

/// How full a volume is.
public struct DiskCapacity: Sendable, Equatable {
    /// Bytes available for "important" use, which counts space the system can purge (the number Finder shows).
    public var available: Int64
    public var total: Int64

    public init(available: Int64, total: Int64) {
        self.available = available
        self.total = total
    }

    /// The capacity of the volume that holds `url` (the startup volume by default).
    public static func current(for url: URL = URL(fileURLWithPath: "/")) throws -> DiskCapacity {
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ])
        guard let available = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url])
        }
        return DiskCapacity(available: available, total: Int64(total))
    }
}
