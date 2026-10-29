/// The measured size of a file or folder tree.
public struct SizeResult: Sendable, Equatable {
    public var bytes: Int64
    public var fileCount: Int
    /// True when the figure may be off, e.g. some entries were unreadable or hardlinks are shared.
    public var isApproximate: Bool

    public init(bytes: Int64, fileCount: Int, isApproximate: Bool = false) {
        self.bytes = bytes
        self.fileCount = fileCount
        self.isApproximate = isApproximate
    }

    public static let zero = SizeResult(bytes: 0, fileCount: 0, isApproximate: false)

    public static func + (lhs: SizeResult, rhs: SizeResult) -> SizeResult {
        SizeResult(
            bytes: lhs.bytes + rhs.bytes,
            fileCount: lhs.fileCount + rhs.fileCount,
            isApproximate: lhs.isApproximate || rhs.isApproximate
        )
    }
}
