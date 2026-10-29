import Foundation
import Synchronization
import Testing
import CleanoriCore

private let mib: Int64 = 1_048_576
private let mibInt = 1_048_576

/// A folder holding `folders * filesPerFolder` tiny files, i.e. `folders * (filesPerFolder + 1)` entries below it.
private func makeBigTree(in home: TempHome, folders: Int = 21, filesPerFolder: Int = 100) throws -> URL {
    for folder in 0..<folders {
        for index in 0..<filesPerFolder {
            try home.file("big/d\(folder)/f\(index).bin", bytes: 1)
        }
    }
    return home.url.appending(path: "big", directoryHint: .isDirectory)
}

private func folder(_ home: TempHome, _ rel: String) -> URL {
    home.url.appending(path: rel, directoryHint: .isDirectory)
}

// MARK: - Sizes and structure

@Test func aggregatesSizes() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("root/a", bytes: 2 * mibInt)
    try home.file("root/b/c", bytes: mibInt)
    let root = try await DiskMapScanner().scan(root: folder(home, "root"))
    #expect(root.bytes == 3 * mib)
    #expect(root.children.map(\.name) == ["a", "b"])
    #expect(root.children.map(\.bytes) == [2 * mib, mib])
    #expect(root.isDirectory)
    #expect(!root.isOther)
}

@Test func collapsesBeyondKeepLargest() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    for index in 1...5 { try home.file("root/f\(index)", bytes: mibInt) }
    let root = try await DiskMapScanner(keepLargest: 2).scan(root: folder(home, "root"))
    #expect(root.children.count == 3)
    #expect(root.bytes == 5 * mib)
    #expect(root.itemCount == 5)
    // Equal sizes tie-break by name, so which files survive does not depend on directory order.
    #expect(root.children.prefix(2).map(\.name) == ["f1", "f2"])

    let other = try #require(root.children.last)
    #expect(other.isOther)
    #expect(other.name == "3 other items")
    #expect(other.bytes == 3 * mib)
    #expect(other.itemCount == 3)
    #expect(other.url == nil)
    #expect(!other.isDirectory)
    #expect(other.children.isEmpty)
    #expect(other.id == "\(root.id)|other")
}

@Test func keepsAllChildrenWhenThereAreNoMoreThanKeepLargest() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    for index in 1...3 { try home.file("root/f\(index)", bytes: mibInt) }
    let root = try await DiskMapScanner(keepLargest: 3).scan(root: folder(home, "root"))
    #expect(root.children.count == 3)
    #expect(root.children.allSatisfy { !$0.isOther })
}

@Test func prunesEveryFolderOnItsOwn() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("root/big/x", bytes: 3 * mibInt)
    try home.file("root/big/y", bytes: mibInt)
    try home.file("root/small/z", bytes: 2 * mibInt)
    try home.file("root/loose", bytes: mibInt)
    let root = try await DiskMapScanner(keepLargest: 1).scan(root: folder(home, "root"))

    #expect(root.bytes == 7 * mib)
    #expect(root.children.map(\.name) == ["big", "2 other items"])
    let other = try #require(root.children.last)
    #expect(other.isOther)
    #expect(other.bytes == 3 * mib) // small (2 MiB) + loose (1 MiB)
    #expect(other.itemCount == 2)

    // The folder that survived is pruned by the same rule, and a collapsed folder's subtree is dropped.
    let big = try #require(root.children.first)
    #expect(big.bytes == 4 * mib)
    #expect(big.children.map(\.name) == ["x", "1 other item"])
    #expect(big.children.last?.bytes == mib)
    #expect(big.children.last?.id == "\(big.id)|other")
}

@Test func compactsHugeFoldersWhileWalking() async throws {
    // 40 files in one folder, with sizes that all differ. A buffer that only prunes once the folder is done
    // would hold all 40; this checks that the incremental pruning still keeps exactly the true top 3.
    let home = try TempHome(); defer { home.cleanup() }
    for index in 1...40 { try home.file("root/f\(index)", bytes: index * 8_192) }
    let expected = try await DirectorySizer().size(of: folder(home, "root"))

    let root = try await DiskMapScanner(keepLargest: 3, minimumChildBytes: 0).scan(root: folder(home, "root"))
    #expect(root.children.map(\.name) == ["f40", "f39", "f38", "37 other items"])
    #expect(root.bytes == expected.bytes)
    #expect(root.itemCount == expected.fileCount)
    // The folder's buffer grew to ~20 nodes while it was read; the node keeps an array of just its 4 children.
    #expect(root.children.capacity <= root.children.count + 2)
    let kept = root.children.prefix(3)
    #expect(kept.map(\.bytes) == kept.map(\.bytes).sorted(by: >))
    let other = try #require(root.children.last)
    #expect(other.bytes == root.bytes - kept.map(\.bytes).reduce(0, +))
    #expect(other.itemCount == 37)
}

@Test func sortsChildrenLargestFirstAtEveryLevel() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("root/small.bin", bytes: mibInt)
    try home.file("root/dir/low.bin", bytes: mibInt)
    try home.file("root/dir/high.bin", bytes: 2 * mibInt)
    try home.file("root/medium.bin", bytes: 2 * mibInt)
    let root = try await DiskMapScanner().scan(root: folder(home, "root"))
    #expect(root.children.map(\.name) == ["dir", "medium.bin", "small.bin"]) // 3 MiB, 2 MiB, 1 MiB
    #expect(root.children.first?.children.map(\.name) == ["high.bin", "low.bin"])
}

@Test func itemCountCountsFilesAndFlagsFolders() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("root/a")
    try home.file("root/b/c")
    try home.file("root/b/d/e")
    let root = try await DiskMapScanner().scan(root: folder(home, "root"))
    #expect(root.itemCount == 3)
    let b = try #require(root.children.first { $0.name == "b" })
    let a = try #require(root.children.first { $0.name == "a" })
    #expect(b.itemCount == 2)
    #expect(b.isDirectory)
    #expect(a.itemCount == 1)
    #expect(!a.isDirectory)
    #expect(a.children.isEmpty)
}

@Test func emptyFolderIsAnEmptyNode() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.dir("root")
    let root = try await DiskMapScanner().scan(root: folder(home, "root"))
    #expect(root.bytes == 0)
    #expect(root.itemCount == 0)
    #expect(root.children.isEmpty)
    #expect(root.isDirectory)
}

@Test func matchesDirectorySizerOnTheSameTree() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("root/a.bin", bytes: 5_000)
    try home.file("root/x/b.bin", bytes: 70_000)
    try home.file("root/x/y/c.bin", bytes: 1)
    try home.file("root/x/y/d.bin", bytes: 123_456)
    let expected = try await DirectorySizer().size(of: folder(home, "root"))
    let root = try await DiskMapScanner().scan(root: folder(home, "root"))
    #expect(root.bytes == expected.bytes)
    #expect(root.itemCount == expected.fileCount)
}

// MARK: - What is and is not counted

@Test func diskMapCountsHardlinkOnce() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let original = try home.file("root/a.bin")
    try FileManager.default.linkItem(at: original, to: home.url.appending(path: "root/b.bin"))
    let root = try await DiskMapScanner(minimumChildBytes: 0).scan(root: folder(home, "root"))
    #expect(root.bytes == mib)
    #expect(root.itemCount == 2) // both names are files in the folder; only one of them is charged
    #expect(root.children.map(\.bytes).sorted() == [0, mib])
    #expect(!root.isApproximate) // sharing is not the same as not being able to read
}

@Test func diskMapDoesNotFollowSymlinks() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let outside = try home.file("outside/big.bin", bytes: 5 * mibInt)
    let tree = try home.dir("tree")
    try home.symlink("tree/link-to-file", to: outside)
    try home.symlink("tree/link-to-dir", to: folder(home, "outside"))
    let root = try await DiskMapScanner().scan(root: tree)
    #expect(root.bytes == 0)
    #expect(root.itemCount == 0)
    #expect(root.children.isEmpty) // a link is neither sized nor listed
}

@Test func foldersListedAfterASymlinkAreStillScanned() async throws {
    // Foundation's enumerator has a quirk: `skipDescendants()` called on a link (not a folder) makes it skip the
    // next folder it would have entered. Links and folders are interleaved here, so whatever order the file
    // system lists them in, some folder comes after a link, and every one of them must still be scanned.
    let home = try TempHome(); defer { home.cleanup() }
    let outside = try home.dir("outside")
    try home.file("outside/big.bin", bytes: 5 * mibInt)
    for index in 0..<10 {
        try home.symlink("tree/link\(index)", to: outside)
        try home.file("tree/dir\(index)/data.bin")
    }
    let root = try await DiskMapScanner().scan(root: folder(home, "tree"))
    #expect(root.bytes == 10 * mib)
    #expect(root.itemCount == 10)
    #expect(root.children.count == 10)
    #expect(root.children.allSatisfy { $0.isDirectory && $0.bytes == mib && $0.children.count == 1 })
}

@Test func aSymlinkAsRootIsNotFollowed() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("real/a.bin")
    let link = try home.symlink("link", to: folder(home, "real"))
    let root = try await DiskMapScanner().scan(root: link)
    #expect(root.bytes == 0)
    #expect(root.children.isEmpty)
}

@Test func aFileAsRootIsASingleNode() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let file = try home.file("one.bin")
    let root = try await DiskMapScanner().scan(root: file)
    #expect(root.bytes == mib)
    #expect(root.itemCount == 1)
    #expect(!root.isDirectory)
    #expect(root.children.isEmpty)
}

@Test func ignoresPipesAndOtherNonRegularFiles() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("root/real.bin")
    let fifo = home.url.appending(path: "root/pipe", directoryHint: .notDirectory)
    #expect(mkfifo(fifo.path, 0o644) == 0)
    let root = try await DiskMapScanner().scan(root: folder(home, "root"))
    #expect(root.children.map(\.name) == ["real.bin"])
    #expect(root.bytes == mib)
}

/// Makes `dir` unreadable. `TempHome.cleanup()` gives access back before it removes the tree.
private func lockFolder(_ dir: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
}

/// Every node of the tree, the node itself first.
private func allNodes(_ node: DiskNode) -> [DiskNode] {
    [node] + node.children.flatMap { allNodes($0) }
}

@Test func unreadableSubfolderDoesNotAbortTheScan() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("root/readable.bin")
    try home.file("root/locked/hidden.bin")
    try home.file("root/other/visible.bin")
    try lockFolder(folder(home, "root/locked"))

    // Tiny items are kept here (no size cutoff), so the unreadable folder shows up in the tree.
    let root = try await DiskMapScanner(minimumChildBytes: 0).scan(root: folder(home, "root"))
    // Everything readable is still there, before and after the folder that could not be opened.
    #expect(root.bytes == 2 * mib)
    #expect(root.itemCount == 2)
    #expect(Set(root.children.map(\.name)).isSuperset(of: ["readable.bin", "other"]))
    // The folder itself is listed, but empty: nothing could be read from it.
    let lockedNode = try #require(root.children.first { $0.name == "locked" })
    #expect(lockedNode.bytes == 0)
    #expect(lockedNode.children.isEmpty)
}

@Test func unreadableSubfolderMarksItAndEveryFolderAboveItApproximate() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("root/ok/fine.bin")
    try home.file("root/mid/readable.bin")
    try home.file("root/mid/sibling/x.bin")
    try home.file("root/mid/locked/hidden.bin")
    try home.file("root/mid/locked/sub/deeper.bin")
    try lockFolder(folder(home, "root/mid/locked"))

    let root = try await DiskMapScanner(minimumChildBytes: 0).scan(root: folder(home, "root"))

    // The folder that could not be read, and each folder on the way up to the root, are approximate...
    #expect(root.isApproximate)
    let mid = try #require(root.children.first { $0.name == "mid" })
    #expect(mid.isApproximate)
    let locked = try #require(mid.children.first { $0.name == "locked" })
    #expect(locked.isApproximate)
    // ...and nothing else is: a readable sibling (and its files) is exact.
    let approximate = allNodes(root).filter(\.isApproximate).map(\.name)
    #expect(approximate.sorted() == ["locked", "mid", "root"])
    let ok = try #require(root.children.first { $0.name == "ok" })
    let sibling = try #require(mid.children.first { $0.name == "sibling" })
    #expect(!ok.isApproximate && !sibling.isApproximate)
    #expect(root.bytes == 3 * mib) // what could be read is still counted
}

@Test func anUnreadableFolderFoldedIntoOtherStillMarksTheGroupApproximate() async throws {
    // With the default size cutoff the empty unreadable folder is not listed, but the folders around it must
    // still say that their numbers are not complete.
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("root/ok/data.bin")
    try home.file("root/locked/hidden.bin")
    try lockFolder(folder(home, "root/locked"))

    let root = try await DiskMapScanner().scan(root: folder(home, "root"))
    #expect(root.isApproximate)
    #expect(root.children.map(\.name) == ["ok", "1 other item"])
    #expect(root.children.last?.isApproximate == true)
    #expect(root.children.first?.isApproximate == false)
}

@Test func unreadableRootIsApproximate() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("root/hidden.bin")
    try lockFolder(folder(home, "root"))

    let root = try await DiskMapScanner().scan(root: folder(home, "root"))
    #expect(root.isApproximate)
    #expect(root.bytes == 0)
    #expect(root.children.isEmpty)
    #expect(root.isDirectory)
}

@Test func aFullyReadableTreeIsNeverApproximate() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("root/a/b/c.bin")
    try home.file("root/a/d.bin")
    try home.file("root/e.bin")
    try home.dir("root/empty")
    try home.symlink("root/link", to: folder(home, "root/a"))
    let root = try await DiskMapScanner(minimumChildBytes: 0).scan(root: folder(home, "root"))
    #expect(allNodes(root).count > 5)
    #expect(allNodes(root).allSatisfy { !$0.isApproximate })
}

// MARK: - Paths

@Test func nodeURLsStayUnderTheGivenRoot() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let odd = "iOS DeviceSupport/iPhone14,5 27.0.1 (24A446)/100% done #1.bin"
    try home.file("root/\(odd)")
    try home.file("root/plain.bin")
    let rootURL = folder(home, "root")
    let root = try await DiskMapScanner().scan(root: rootURL)

    #expect(root.url == rootURL)
    #expect(root.id == rootURL.path)
    let support = try #require(root.children.first { $0.name == "iOS DeviceSupport" })
    let device = try #require(support.children.first)
    let file = try #require(device.children.first)
    #expect(device.name == "iPhone14,5 27.0.1 (24A446)")
    #expect(file.name == "100% done #1.bin")
    #expect(file.url?.path == home.url.appending(path: "root/\(odd)").path)
    #expect(file.id == file.url?.path)
    #expect(file.url.map { FileManager.default.fileExists(atPath: $0.path) } == true)
}

@Test func nodeURLsFollowTheRootAsGivenEvenBehindASymlinkedAncestor() async throws {
    // The temp folder is really under /private (`/var` and `/tmp` are links). Foundation reports URLs
    // with those links resolved, but the Disk Map must hand back paths spelled like the root it was given,
    // so they compare (and Reveal in Finder) exactly like everything else in the app.
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("root/sub/a.bin")
    try #require(home.url.path.hasPrefix("/private/"))
    let aliasedRoot = URL(
        filePath: String(home.url.path.dropFirst("/private".count)) + "/root", directoryHint: .isDirectory
    )
    let root = try await DiskMapScanner().scan(root: aliasedRoot)

    let sub = try #require(root.children.first)
    let file = try #require(sub.children.first)
    #expect(sub.url?.path == aliasedRoot.path + "/sub")
    #expect(file.url?.path == aliasedRoot.path + "/sub/a.bin")
    #expect(file.id == aliasedRoot.path + "/sub/a.bin")
    #expect(root.bytes == mib)
}

@Test func missingRootThrows() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    await #expect(throws: POSIXError.self) {
        try await DiskMapScanner().scan(root: folder(home, "nope"))
    }
}

// MARK: - Keeping the tree small

@Test func smallFilesFoldIntoOtherNextToABigOne() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    for index in 0..<30 { try home.file("root/small\(index).bin", bytes: 10_000) }
    try home.file("root/big.bin", bytes: 2 * mibInt)
    let expected = try await DirectorySizer().size(of: folder(home, "root"))

    let root = try await DiskMapScanner().scan(root: folder(home, "root"))
    #expect(root.children.map(\.name) == ["big.bin", "30 other items"])
    #expect(root.bytes == expected.bytes)
    #expect(root.itemCount == 31)
    let other = try #require(root.children.last)
    #expect(other.isOther)
    #expect(other.bytes == expected.bytes - 2 * mib) // everything except the big file
    #expect(other.itemCount == 30)
    #expect(other.url == nil)
}

@Test func manySmallNestedFoldersCollapseIntoOneGroup() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    for dir in 0..<20 {
        for file in 0..<5 { try home.file("root/d\(dir)/inner/f\(file).bin", bytes: 1_000) }
    }
    try home.file("root/chain/a/b/c/d/e/tiny.bin", bytes: 1_000)
    let expected = try await DirectorySizer().size(of: folder(home, "root"))

    let root = try await DiskMapScanner().scan(root: folder(home, "root"))
    // No folder reaches 1 MB, so none of them is kept, however deep or full: the whole tree is the root and one group.
    #expect(root.children.map(\.name) == ["21 other items"])
    #expect(allNodes(root).count == 2)
    #expect(root.bytes == expected.bytes)
    #expect(root.itemCount == 101)
    #expect(root.children.first?.bytes == expected.bytes)
    #expect(root.children.first?.itemCount == 101)
}

@Test func smallItemsAreFoldedAtEveryLevelOfABigFolder() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("root/big/x", bytes: 2 * mibInt)
    try home.file("root/big/tiny", bytes: 1_000)
    try home.file("root/big/deep/leaf", bytes: 500)
    try home.file("root/big/keep/y", bytes: mibInt)
    try home.file("root/big/keep/crumb", bytes: 100)
    let root = try await DiskMapScanner().scan(root: folder(home, "root"))

    let big = try #require(root.children.first)
    #expect(root.children.map(\.name) == ["big"]) // nothing else is in the root
    #expect(big.children.map(\.name) == ["x", "keep", "2 other items"]) // `tiny` and the folder `deep`
    let keep = try #require(big.children.first { $0.name == "keep" })
    #expect(keep.children.map(\.name) == ["y", "1 other item"])
    #expect(big.itemCount == 5)
}

@Test func theSizeCutoffIsInclusiveAndConfigurable() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let file = try home.file("root/small.bin", bytes: 1_000)
    let allocated = try await DirectorySizer().size(of: file).bytes

    let kept = try await DiskMapScanner(minimumChildBytes: allocated).scan(root: folder(home, "root"))
    #expect(kept.children.map(\.name) == ["small.bin"]) // a child exactly at the cutoff is kept
    let folded = try await DiskMapScanner(minimumChildBytes: allocated + 1).scan(root: folder(home, "root"))
    #expect(folded.children.map(\.name) == ["1 other item"])
    let negative = try await DiskMapScanner(minimumChildBytes: -5).scan(root: folder(home, "root"))
    #expect(negative.children.map(\.name) == ["small.bin"]) // below 0 counts as 0: nothing is too small
}

@Test func keepLargestAndTheSizeCutoffBothApply() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    for index in 1...5 { try home.file("root/big\(index)", bytes: mibInt) }
    for index in 1...10 { try home.file("root/small\(index)", bytes: 1_000) }
    let root = try await DiskMapScanner(keepLargest: 2).scan(root: folder(home, "root"))
    #expect(root.children.map(\.name) == ["big1", "big2", "13 other items"])
    #expect(root.itemCount == 15)
    #expect(root.children.last?.itemCount == 13)
}

@Test func retainedNodesFollowBytesNotEntries() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    for dir in 0..<40 {
        // 200 tiny files (4 KiB each on disk), about 800 KB in all: under the 1 MB cutoff, however many entries.
        for file in 0..<5 { try home.file("root/crowd/d\(dir)/f\(file).bin", bytes: 1) }
    }
    for index in 0..<3 { try home.file("root/big\(index)/data.bin", bytes: 2 * mibInt) }

    let root = try await DiskMapScanner().scan(root: folder(home, "root"))
    #expect(root.itemCount == 203)
    // The root, its three big folders with their one file each, and one group for the crowd.
    #expect(allNodes(root).count == 8)
    #expect(root.children.map(\.name) == ["big0", "big1", "big2", "1 other item"])
    #expect(root.children.last?.itemCount == 200)
}

// MARK: - DiskNode

@Test func aNodeDerivesIdNameAndURLFromItsPath() {
    let path = "/Users/me/My Files/report (final), v2 100%.pdf"
    let file = DiskNode(path: path, bytes: 5, itemCount: 1, isDirectory: false)
    #expect(file.id == path)
    #expect(file.name == "report (final), v2 100%.pdf")
    #expect(file.url == URL(filePath: path))
    #expect(file.url?.path == path)
    #expect(!file.isOther && !file.isApproximate && file.children.isEmpty)

    let folder = DiskNode(path: "/Users/me/My Files", bytes: 5, itemCount: 1, isDirectory: true, children: [file])
    #expect(folder.name == "My Files")
    #expect(folder.url?.hasDirectoryPath == true)
    #expect(folder.children.map(\.id) == [path])

    #expect(DiskNode(path: "/", bytes: 0, itemCount: 0, isDirectory: true).name == "/")
    // A name that starts with a combining mark is still the part after the last slash.
    #expect(DiskNode(path: "/a/\u{301}b", bytes: 0, itemCount: 1, isDirectory: false).name == "\u{301}b")
}

@Test func anOtherGroupHasNoURLAndDerivesItsNameFromItsCount() {
    let many = DiskNode.other(inFolderAt: "/Users/me", count: 3, bytes: 9, itemCount: 40, isApproximate: true)
    #expect(many.isOther && !many.isDirectory && many.isApproximate)
    #expect(many.id == "/Users/me|other")
    #expect(many.name == "3 other items")
    #expect(many.url == nil)
    #expect(many.children.isEmpty)
    #expect(many.itemCount == 40)

    #expect(DiskNode.other(inFolderAt: "/x", count: 1, bytes: 0, itemCount: 1).name == "1 other item")
    #expect(DiskNode.other(inFolderAt: "/x", count: 0, bytes: 0, itemCount: 0).name == "1 other item") // at least one
    #expect(DiskNode.other(inFolderAt: "/", count: 2, bytes: 0, itemCount: 2).id == "/|other")
}

@Test func aNodeKeepsOnlyOnePathInMemory() {
    // One string for the path, a few numbers and flags, and the children array: no second copy of the path as a
    // name or URL, which is what made nodes cost several hundred bytes each.
    #expect(MemoryLayout<DiskNode>.size <= 64)
}

// MARK: - Progress and cancellation

@Test func diskMapReportsProgressEvery2000Entries() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let bigTree = try makeBigTree(in: home) // 21 folders + 2,100 files = 2,121 entries
    let reports = Mutex<[ScanProgress]>([])
    _ = try await DiskMapScanner().scan(root: bigTree) { update in
        reports.withLock { $0.append(update) }
    }
    let seen = reports.withLock { $0 }
    #expect(seen.map(\.itemsScanned) == [2_000])
    #expect(seen.first?.currentPath.hasPrefix(bigTree.path) == true)
}

@Test func diskMapCancels() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let bigTree = try makeBigTree(in: home)
    let scanner = DiskMapScanner()
    let task = Task {
        // Hold off until the cancel below has landed, so the outcome never depends on scheduling.
        while !Task.isCancelled { await Task.yield() }
        return try await scanner.scan(root: bigTree)
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func diskMapCancelsInTheMiddleOfAWalk() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let bigTree = try makeBigTree(in: home, folders: 41) // 41 folders + 4,100 files = 4,141 entries
    let reports = Mutex(0)
    let task = Task {
        // The first progress report (after 2,000 entries) cancels the very task that is walking. Without the
        // per-entry check the walk would run on to the report at 4,000 entries and succeed.
        try await DiskMapScanner().scan(root: bigTree) { _ in
            reports.withLock { $0 += 1 }
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(reports.withLock { $0 } == 1)
}
