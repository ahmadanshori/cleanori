#if DEBUG
import Foundation
import CleanoriCore

/// Debug builds only. The `Trasher` a Debug build uses when `CLEANORI_HOME` names a scratch home: it moves an item
/// into `<home>/.Trash` instead of the real Trash, so a manual check of Move to Trash never touches the owner's
/// Trash. A name that is taken there gets a number ("Movie 2.mov"), and nothing is ever overwritten.
///
/// Release builds do not contain this type; they always use `FileManagerTrasher`.
struct DebugHomeTrasher: Trasher {
    let trashDirectory: URL

    init(home: URL) {
        trashDirectory = home.appending(path: ".Trash", directoryHint: .isDirectory)
    }

    func trash(_ url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        try fileManager.moveItem(at: url, to: freeDestination(for: url))
    }

    /// `<.Trash>/<name>`, or the first of `<name> 2`, `<name> 3`, ... (extension kept) that nothing is at.
    /// A broken symlink counts as taken.
    private func freeDestination(for url: URL) -> URL {
        let name = url.lastPathComponent
        var candidate = trashDirectory.appending(path: name, directoryHint: .notDirectory)
        var number = 2
        while (try? FileManager.default.attributesOfItem(atPath: candidate.path)) != nil {
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            candidate = trashDirectory.appending(
                path: ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)",
                directoryHint: .notDirectory
            )
            number += 1
        }
        return candidate
    }
}
#endif
