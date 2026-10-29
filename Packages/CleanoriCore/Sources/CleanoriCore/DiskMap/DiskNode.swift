import Foundation

/// One folder, file or "other items" group in the Disk Map tree.
///
/// A folder keeps only its largest children (see `DiskMapScanner`); everything it dropped is summed into one
/// last child with `isOther` set, so `bytes` and `itemCount` of a folder always cover all of its content.
///
/// A scan can produce a lot of nodes, so a node stores its path once, and `id`, `name` and `url` are worked
/// out from it when asked (they are cheap, and a view reads only the few it shows).
public struct DiskNode: Sendable, Identifiable {
    /// The item's path, or for an "other" group the path of the folder it belongs to.
    private let location: String
    /// How many items an "other" group stands for; 0 for anything else.
    private let droppedCount: Int

    /// Space used on disk (allocated blocks).
    public let bytes: Int64
    /// How many files are in this item: 1 for a file, and the number of regular files below it for a folder
    /// (folders themselves are not counted), the same as `SizeResult.fileCount`.
    public let itemCount: Int
    public let isDirectory: Bool
    /// `true` for the group of items a folder did not keep. It has no `url` and no children.
    public let isOther: Bool
    /// `true` when something in this folder, or below it, could not be read, so `bytes` and `itemCount` may be too
    /// low. It is set on the folder that could not be read and on every folder above it up to the root.
    public let isApproximate: Bool
    /// The folder's largest children, biggest first, followed by the "other" group when something was dropped.
    /// Empty for a file and for an "other" group.
    public let children: [DiskNode]

    /// The path, or `"\(parent id)|other"` for the group of items a folder did not keep. Unique within one tree.
    public var id: String { isOther ? location + "|other" : location }

    /// The file or folder name, or `"\(n) other items"` for an "other" group (`"1 other item"` for one).
    public var name: String {
        if isOther { return droppedCount == 1 ? "1 other item" : "\(droppedCount) other items" }
        return Self.lastComponent(of: location)
    }

    /// Where the item is, spelled below the root the scan was given. `nil` for an "other" group.
    public var url: URL? {
        isOther ? nil : URL(filePath: location, directoryHint: isDirectory ? .isDirectory : .notDirectory)
    }

    /// A file or folder at `path`.
    public init(
        path: String,
        bytes: Int64,
        itemCount: Int,
        isDirectory: Bool,
        isApproximate: Bool = false,
        children: [DiskNode] = []
    ) {
        location = path
        droppedCount = 0
        self.bytes = bytes
        self.itemCount = itemCount
        self.isDirectory = isDirectory
        isOther = false
        self.isApproximate = isApproximate
        self.children = children
    }

    /// The group standing for `count` items (at least 1) that the folder at `parentPath` did not keep.
    public static func other(
        inFolderAt parentPath: String,
        count: Int,
        bytes: Int64,
        itemCount: Int,
        isApproximate: Bool = false
    ) -> DiskNode {
        DiskNode(otherAt: parentPath, count: max(1, count), bytes: bytes, itemCount: itemCount, isApproximate: isApproximate)
    }

    private init(otherAt parentPath: String, count: Int, bytes: Int64, itemCount: Int, isApproximate: Bool) {
        location = parentPath
        droppedCount = count
        self.bytes = bytes
        self.itemCount = itemCount
        isDirectory = false
        isOther = true
        self.isApproximate = isApproximate
        children = []
    }

    /// The part of `path` after its last `/` (the whole path for `/`). Works on UTF-8 so a name that starts with a
    /// combining mark cannot be glued to the `/` before it.
    private static func lastComponent(of path: String) -> String {
        let utf8 = path.utf8
        guard let slash = utf8.lastIndex(of: UInt8(ascii: "/")) else { return path }
        let start = utf8.index(after: slash)
        if start == utf8.endIndex { return path }
        return String(decoding: utf8[start...], as: UTF8.self)
    }
}
