import Foundation

/// Moves items to the Trash (wrapper around `FileManager.trashItem`).
public protocol Trasher: Sendable {
    func trash(_ url: URL) throws
}
