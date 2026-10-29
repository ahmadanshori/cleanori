import Foundation
import Synchronization
import Testing
import CleanoriCore

private let mib: Int64 = 1_048_576

/// A folder holding `folders * filesPerFolder` tiny files, i.e. `folders * (filesPerFolder + 1)` entries below it.
private func makeBigTree(in home: TempHome, folders: Int = 21, filesPerFolder: Int = 100) throws -> URL {
    for folder in 0..<folders {
        for index in 0..<filesPerFolder {
            try home.file("big/d\(folder)/f\(index).bin", bytes: 1)
        }
    }
    return home.url.appending(path: "big", directoryHint: .isDirectory)
}

@Test func sumsAllocatedSizes() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("tree/a.bin")
    try home.file("tree/sub/b.bin")
    try home.file("tree/sub/deeper/c.bin")
    let result = try await DirectorySizer().size(of: home.url.appending(path: "tree", directoryHint: .isDirectory))
    #expect(result.bytes == 3 * mib)
    #expect(result.fileCount == 3)
    #expect(!result.isApproximate)
}

@Test func plainFileReturnsItsOwnAllocatedSize() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let file = try home.file("one.bin")
    let result = try await DirectorySizer().size(of: file)
    #expect(result == SizeResult(bytes: mib, fileCount: 1, isApproximate: false))
}

@Test func countsHardlinkOnce() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let original = try home.file("tree/a.bin")
    try FileManager.default.linkItem(at: original, to: home.url.appending(path: "tree/b.bin"))
    let result = try await DirectorySizer().size(of: home.url.appending(path: "tree", directoryHint: .isDirectory))
    #expect(result.bytes == mib)
    #expect(result.isApproximate)
    // `bytes` is deduplicated; `fileCount` still counts every file entry the folder contains.
    #expect(result.fileCount == 2)
}

@Test func hardlinkedAndPlainFilesInOneWalk() async throws {
    // Single-link files take the fast path (no lstat); hardlinked ones are looked up by device and inode.
    let home = try TempHome(); defer { home.cleanup() }
    let original = try home.file("tree/linked-a.bin")
    try FileManager.default.linkItem(at: original, to: home.url.appending(path: "tree/linked-b.bin"))
    try home.file("tree/plain-1.bin")
    try home.file("tree/sub/plain-2.bin")
    let result = try await DirectorySizer().size(of: home.url.appending(path: "tree", directoryHint: .isDirectory))
    #expect(result.bytes == 3 * mib) // the linked pair once, plus two plain files
    #expect(result.fileCount == 4)
    #expect(result.isApproximate)
}

@Test func skipsPipesAndOtherNonRegularFiles() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("tree/real.bin")
    let fifo = home.url.appending(path: "tree/pipe", directoryHint: .notDirectory)
    #expect(mkfifo(fifo.path, 0o644) == 0)
    let result = try await DirectorySizer().size(of: home.url.appending(path: "tree", directoryHint: .isDirectory))
    #expect(result == SizeResult(bytes: mib, fileCount: 1, isApproximate: false))
}

@Test func sharedLedgerCountsHardlinkOnceAcrossFolders() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let original = try home.file("A/shared.bin")
    try home.dir("B")
    try FileManager.default.linkItem(at: original, to: home.url.appending(path: "B/shared.bin"))
    let sizer = DirectorySizer(ledger: InodeLedger())
    let a = try await sizer.size(of: home.url.appending(path: "A", directoryHint: .isDirectory))
    let b = try await sizer.size(of: home.url.appending(path: "B", directoryHint: .isDirectory))
    #expect((a + b).bytes == mib)
    #expect(a.isApproximate && b.isApproximate)
}

@Test func separateLedgersEachCountTheHardlink() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let original = try home.file("A/shared.bin")
    try home.dir("B")
    try FileManager.default.linkItem(at: original, to: home.url.appending(path: "B/shared.bin"))
    let a = try await DirectorySizer().size(of: home.url.appending(path: "A", directoryHint: .isDirectory))
    let b = try await DirectorySizer().size(of: home.url.appending(path: "B", directoryHint: .isDirectory))
    #expect((a + b).bytes == 2 * mib)
}

@Test func doesNotFollowSymlinks() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let outside = try home.file("outside/big.bin", bytes: 5 * 1_048_576)
    let folder = try home.dir("tree")
    try home.symlink("tree/link-to-file", to: outside)
    try home.symlink("tree/link-to-dir", to: home.url.appending(path: "outside", directoryHint: .isDirectory))
    let result = try await DirectorySizer().size(of: folder)
    #expect(result.bytes == 0)
    #expect(result.fileCount == 0)
    #expect(!result.isApproximate)
}

@Test func symlinkRootCountsZero() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("real/a.bin")
    let link = try home.symlink("link", to: home.url.appending(path: "real", directoryHint: .isDirectory))
    let result = try await DirectorySizer().size(of: link)
    #expect(result == .zero)
}

@Test func unreadableSubfolderMarksApproximate() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("tree/readable.bin")
    try home.file("tree/locked/hidden.bin")
    let locked = home.url.appending(path: "tree/locked", directoryHint: .isDirectory)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

    let result = try await DirectorySizer().size(of: home.url.appending(path: "tree", directoryHint: .isDirectory))
    #expect(result.bytes == mib)
    #expect(result.isApproximate)
}

@Test func missingPathThrows() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    await #expect(throws: POSIXError.self) {
        try await DirectorySizer().size(of: home.url.appending(path: "nope", directoryHint: .isDirectory))
    }
}

@Test func cancels() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let bigTree = try makeBigTree(in: home)
    let sizer = DirectorySizer()
    let task = Task {
        // Hold off until the cancel below has landed, so the outcome never depends on scheduling.
        while !Task.isCancelled { await Task.yield() }
        return try await sizer.size(of: bigTree)
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func cancelsInTheMiddleOfAWalk() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let bigTree = try makeBigTree(in: home)
    let task = Task {
        // The first progress report (after 2,000 entries) cancels the very task that is walking.
        try await DirectorySizer().size(of: bigTree) { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func reportsProgressEvery2000Entries() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let bigTree = try makeBigTree(in: home) // 21 folders + 2,100 files = 2,121 entries
    let reports = Mutex<[ScanProgress]>([])
    _ = try await DirectorySizer().size(of: bigTree) { update in
        reports.withLock { $0.append(update) }
    }
    let seen = reports.withLock { $0 }
    #expect(seen.map(\.itemsScanned) == [2_000])
    #expect(seen.first?.currentPath.hasPrefix(bigTree.path) == true)
}
