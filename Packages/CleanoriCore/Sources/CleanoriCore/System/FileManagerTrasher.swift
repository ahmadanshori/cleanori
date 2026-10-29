import Foundation

/// The live `Trasher`: moves an item to the user's Trash, where it can still be put back.
public struct FileManagerTrasher: Trasher {
    public init() {}

    public func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
