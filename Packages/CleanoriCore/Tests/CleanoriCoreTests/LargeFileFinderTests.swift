import Foundation
import Synchronization
import Testing
import CleanoriCore

private let mib: Int64 = 1 << 20

/// "Now" for a test, cut to whole seconds so a file dated N days before it reads back exactly N days old.
private func wholeSecondNow() -> Date {
    Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))
}

private extension Date {
    func daysEarlier(_ days: Int) -> Date { addingTimeInterval(-Double(days) * 86_400) }
}

/// A finder whose Spotlight lookup is replaced by `lastUsed`, keyed by the file's own name. Tests never rely on Spotlight.
private func makeFinder(
    in home: TempHome,
    now: Date = wholeSecondNow(),
    lastUsed: [String: Date] = [:]
) -> LargeFileFinder {
    LargeFileFinder(env: .test(home: home, now: now)) { url in lastUsed[url.lastPathComponent] }
}

/// Paths of `files` below `home`, in the order given.
private func relativePaths(_ files: [LargeFile], in home: TempHome) -> [String] {
    let prefix = home.url.path + "/"
    return files.map { $0.url.path.hasPrefix(prefix) ? String($0.url.path.dropFirst(prefix.count)) : $0.url.path }
}

/// Sets a file's access and modification dates (`FileManager` can only set the latter).
private func setAccessDate(_ date: Date, of url: URL) throws {
    let stamp = timeval(tv_sec: Int(date.timeIntervalSince1970), tv_usec: 0)
    var times = [stamp, stamp]
    guard utimes(url.path, &times) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

// MARK: - Threshold and kind

@Test func findsFilesAboveThreshold() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let big = try home.file("Downloads/a.dmg", bytes: 2 << 20)
    try home.file("Downloads/b.txt", bytes: 512 << 10)

    let files = try await makeFinder(in: home).find(minBytes: 1 << 20)

    #expect(files.map(\.url.path) == [big.path])
    let file = try #require(files.first)
    #expect(file.kind == .diskImage)
    #expect(file.id == big.path)
    #expect(file.bytes == 2 * mib)
    #expect(file.lock == nil)
}

@Test func fileExactlyAtThresholdIsIncluded() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Downloads/a.bin", bytes: 1 << 20)
    let files = try await makeFinder(in: home).find(minBytes: 1 << 20)
    #expect(relativePaths(files, in: home) == ["Downloads/a.bin"])
}

@Test func findsFilesInTheHomeRoot() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("big.zip", bytes: 2 << 20)
    let files = try await makeFinder(in: home).find(minBytes: 1 << 20)
    #expect(relativePaths(files, in: home) == ["big.zip"])
    #expect(files.first?.kind == .archive)
}

@Test func detectsKinds() {
    #expect(FileKind.of(URL(filePath: "/x/x.tpz")) == .archive)
    #expect(FileKind.of(URL(filePath: "/x/x.mov")) == .video)
    #expect(FileKind.of(URL(filePath: "/x/x.iso")) == .diskImage)
    #expect(FileKind.of(URL(filePath: "/x/x.bin")) == .other)

    for ext in ["dmg", "iso", "img"] { #expect(FileKind.of(URL(filePath: "/x/y.\(ext)")) == .diskImage) }
    for ext in ["zip", "tar", "gz", "tgz", "xip", "tpz", "7z", "rar"] {
        #expect(FileKind.of(URL(filePath: "/x/y.\(ext)")) == .archive)
    }
    #expect(FileKind.of(URL(filePath: "/x/y.mp4")) == .video)
    #expect(FileKind.of(URL(filePath: "/x/noextension")) == .other)
}

@Test func kindIgnoresExtensionCase() {
    #expect(FileKind.of(URL(filePath: "/x/BACKUP.ZIP")) == .archive)
    #expect(FileKind.of(URL(filePath: "/x/Installer.DMG")) == .diskImage)
    #expect(FileKind.of(URL(filePath: "/x/Clip.MOV")) == .video)
}

@Test func kindLabels() {
    #expect(FileKind.allCases.map(\.rawValue) == ["Disk images", "Archives", "Videos", "Other"])
    #expect(FileKind.allCases.map(\.singular) == ["Disk image", "Archive", "Video", "Other"])
}

// MARK: - Skipped folders

@Test func skipsLibraryAndNodeModules() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Library/Caches/x.zip", bytes: 2 << 20)
    try home.file("Developer/p/node_modules/x.zip", bytes: 2 << 20)
    let files = try await makeFinder(in: home).find(minBytes: 1 << 20)
    #expect(files.isEmpty)
}

@Test func skipsTrashAndGit() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file(".Trash/old.dmg", bytes: 2 << 20)
    try home.file("Developer/p/.git/objects/pack/pack-1.pack", bytes: 2 << 20)
    try home.file("Developer/p/deep/er/node_modules/pkg/x.bin", bytes: 2 << 20)
    let files = try await makeFinder(in: home).find(minBytes: 1 << 20)
    #expect(files.isEmpty)
}

@Test func entersFoldersNamedLibraryBelowTheHomeRoot() async throws {
    // Only `~/Library` is skipped. A folder called Library elsewhere (a Unity project's, a photographer's) is ordinary.
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Movies/Library/clip.bin", bytes: 2 << 20)
    let files = try await makeFinder(in: home).find(minBytes: 1 << 20)
    #expect(relativePaths(files, in: home) == ["Movies/Library/clip.bin"])
}

@Test func ignoresSymlinks() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let outside = try TempHome(); defer { outside.cleanup() }
    let target = try home.file("Downloads/real.bin", bytes: 2 << 20)
    let outsideFile = try outside.file("secret/big.bin", bytes: 2 << 20)
    try home.symlink("Desktop/link.bin", to: target)
    try home.symlink("Desktop/linkdir", to: outside.url)
    try home.symlink("Desktop/linkfile", to: outsideFile)

    let files = try await makeFinder(in: home).find(minBytes: 1 << 20)

    // Neither a link to a file nor a link to a folder is listed or followed.
    #expect(relativePaths(files, in: home) == ["Downloads/real.bin"])
}

@Test func foldersListedAfterASymlinkAreStillWalked() async throws {
    // Foundation's enumerator has a quirk: `skipDescendants()` called on a link (not a folder) makes it skip the
    // next folder it would have entered. Links (to files and to folders) and real folders are interleaved by name
    // here, so whatever order the file system lists them in, some folder comes right after a link, and every
    // large file in every real folder must still be found.
    let home = try TempHome(); defer { home.cleanup() }
    let outside = try TempHome(); defer { outside.cleanup() }
    let outsideFile = try outside.file("big.bin", bytes: 2 << 20)
    try outside.file("folder/big.bin", bytes: 2 << 20)
    var expected: [String] = []
    for index in 0..<10 {
        let n = String(format: "%02d", index)
        try home.file("Archive/dir\(n)/big.bin", bytes: 2 << 20)
        expected.append("Archive/dir\(n)/big.bin")
        // `dir00`, `link00`, `dir01`, `link01`...: sorted by name, links and folders alternate.
        if index.isMultiple(of: 2) {
            try home.symlink("Archive/dir\(n)-link", to: outside.url.appending(path: "folder", directoryHint: .isDirectory))
        } else {
            try home.symlink("Archive/dir\(n)-link", to: outsideFile)
        }
    }

    let files = try await makeFinder(in: home).find(minBytes: 1 << 20)

    #expect(Set(relativePaths(files, in: home)) == Set(expected))
    #expect(files.count == 10)
}

// MARK: - Packages

@Test func packageIsOneItemWithItsWholeSize() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Pictures/Holiday.photoslibrary/originals/a.bin", bytes: 1 << 20)
    try home.file("Pictures/Holiday.photoslibrary/originals/b.bin", bytes: 1 << 20)
    try home.file("Pictures/Holiday.photoslibrary/database/c.bin", bytes: 1 << 20)
    try home.file("Applications/Tool.app/Contents/Resources/d.bin", bytes: 1 << 20)
    try home.file("Applications/Tool.app/Contents/MacOS/e.bin", bytes: 1 << 20)

    let files = try await makeFinder(in: home).find(minBytes: 2 << 20)

    // Each package is measured whole and reported once; none of the files inside is listed on its own.
    #expect(relativePaths(files, in: home).sorted() == ["Applications/Tool.app", "Pictures/Holiday.photoslibrary"])
    let library = try #require(files.first { $0.url.lastPathComponent == "Holiday.photoslibrary" })
    #expect(library.bytes == 3 * mib)
    #expect(library.kind == .other)
    let app = try #require(files.first { $0.url.lastPathComponent == "Tool.app" })
    #expect(app.bytes == 2 * mib)
    // `~/Pictures` is protected, so its package is listed but locked. `~/Applications` is not.
    #expect(library.lock == .protectedLocation)
    #expect(app.lock == nil)
}

@Test func packageBelowThresholdIsLeftOut() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Applications/Tool.app/Contents/small.bin", bytes: 1 << 20)
    let files = try await makeFinder(in: home).find(minBytes: 2 << 20)
    #expect(files.isEmpty)
}

// MARK: - Last opened

@Test func notOpenedFilter() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let now = wholeSecondNow()
    try home.file("Downloads/recent.bin", bytes: 2 << 20)
    try home.file("Downloads/old.bin", bytes: 2 << 20)

    let finder = makeFinder(in: home, now: now, lastUsed: [
        "recent.bin": now.daysEarlier(10),
        "old.bin": now.daysEarlier(200),
    ])
    let files = try await finder.find(minBytes: 1 << 20, notOpenedInDays: 90)

    #expect(relativePaths(files, in: home) == ["Downloads/old.bin"])
    #expect(files.first?.lastOpened == now.daysEarlier(200))

    let all = try await finder.find(minBytes: 1 << 20)
    #expect(relativePaths(all, in: home).sorted() == ["Downloads/old.bin", "Downloads/recent.bin"])
}

@Test func notOpenedFilterBoundary() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let now = wholeSecondNow()
    try home.file("a.bin", bytes: 2 << 20)
    try home.file("b.bin", bytes: 2 << 20)
    try home.file("c.bin", bytes: 2 << 20)
    let finder = makeFinder(in: home, now: now, lastUsed: [
        "a.bin": now.daysEarlier(90), // opened within 90 days (exactly 90 still counts)
        "b.bin": now.daysEarlier(90).addingTimeInterval(-1),
        "c.bin": now.addingTimeInterval(3_600), // a date in the future is recent
    ])
    let files = try await finder.find(minBytes: 1 << 20, notOpenedInDays: 90)
    #expect(relativePaths(files, in: home) == ["b.bin"])
}

@Test func notOpenedFilterUsesTheAccessDateWhenSpotlightKnowsNothing() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let file = try home.file("Downloads/a.bin", bytes: 2 << 20)
    try setAccessDate(wholeSecondNow().daysEarlier(400), of: file)

    let files = try await makeFinder(in: home).find(minBytes: 1 << 20, notOpenedInDays: 365)
    #expect(relativePaths(files, in: home) == ["Downloads/a.bin"])
    let recent = try await makeFinder(in: home).find(minBytes: 1 << 20, notOpenedInDays: 500)
    #expect(recent.isEmpty)
}

@Test func lastOpenedFallsBackToAccessDate() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let now = wholeSecondNow()
    let accessed = now.daysEarlier(40)
    let file = try home.file("Downloads/a.bin", bytes: 2 << 20)
    try setAccessDate(accessed, of: file)

    let files = try await makeFinder(in: home, now: now).find(minBytes: 1 << 20)

    #expect(files.first?.lastOpened == accessed)
}

@Test func spotlightDateWinsOverAccessDate() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let now = wholeSecondNow()
    let file = try home.file("Downloads/a.bin", bytes: 2 << 20)
    try setAccessDate(now.daysEarlier(500), of: file)

    let files = try await makeFinder(in: home, now: now, lastUsed: ["a.bin": now.daysEarlier(5)]).find(minBytes: 1 << 20)

    #expect(files.first?.lastOpened == now.daysEarlier(5))
}

// MARK: - Order

@Test func sortsByLastOpenedAscendingThenBySizeDescending() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let now = wholeSecondNow()
    try home.file("old-small.bin", bytes: 2 << 20)
    try home.file("old-big.bin", bytes: 4 << 20)
    try home.file("new.bin", bytes: 8 << 20)
    try home.file("never.bin", bytes: 3 << 20)

    // Dates are injected, so the order depends on them alone. (A file with no date at all sorts before these;
    // the file system always has an access date, so a test cannot make one.)
    let finder = makeFinder(in: home, now: now, lastUsed: [
        "old-small.bin": now.daysEarlier(300),
        "old-big.bin": now.daysEarlier(300),
        "new.bin": now.daysEarlier(2),
        "never.bin": now.daysEarlier(900),
    ])
    let files = try await finder.find(minBytes: 1 << 20)

    #expect(files.map(\.url.lastPathComponent) == ["never.bin", "old-big.bin", "old-small.bin", "new.bin"])
}

// MARK: - Managed roots

@Test func managedRootsAreLocked() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let managed = try home.file(".android/avd/Pixel.avd/userdata-qemu.img.qcow2", bytes: 2 << 20)
    try home.file(".gradle/caches/big.bin", bytes: 2 << 20)
    try home.file(".bun/install/cache/pkg.bin", bytes: 2 << 20)
    try home.file(".npm/_cacache/blob.bin", bytes: 2 << 20)
    let other = try home.file(".android-notes/big.bin", bytes: 2 << 20) // a sibling that only shares a name prefix
    try home.file(".bun/other/big.bin", bytes: 2 << 20)               // inside `.bun`, but not `.bun/install/cache`

    let files = try await makeFinder(in: home).find(minBytes: 1 << 20)

    let locks = Dictionary(uniqueKeysWithValues: files.map { ($0.url.path, $0.lock) })
    #expect(locks[managed.path] == .managedByDeveloperJunk)
    #expect(locks[home.url.appending(path: ".gradle/caches/big.bin").path] == .managedByDeveloperJunk)
    #expect(locks[home.url.appending(path: ".bun/install/cache/pkg.bin").path] == .managedByDeveloperJunk)
    #expect(locks[home.url.appending(path: ".npm/_cacache/blob.bin").path] == .managedByDeveloperJunk)
    #expect(locks[other.path] == .some(nil))
    #expect(locks[home.url.appending(path: ".bun/other/big.bin").path] == .some(nil))
    #expect(files.count == 6)
    #expect(files.first { $0.url.path == managed.path }?.lock?.label == "Managed in Developer Junk")
}

@Test func filesInProjectBuildFoldersAreLocked() async throws {
    // Developer Junk offers these folders (build.android, build.ios, build.pods, build.web), so Large Files must not
    // offer what is inside them as well. They are found at any depth below a project root.
    let home = try TempHome(); defer { home.cleanup() }
    let managed = [
        "Developer/app/android/app/build/outputs/apk/debug/app-debug.apk",
        "Developer/app/android/.gradle/8.5/executionHistory/executionHistory.bin",
        "Developer/app/ios/build/Build/Products/App.app.dSYM.zip",
        "Developer/app/ios/Pods/Hermes/destroot/hermes.xcframework.zip",
        "Developer/web/.next/cache/webpack/server.pack",
        "Developer/client/mobile/.expo/web/cache/bundle.bin",
        "Developer/game/.worktrees/m1/android/app/build/intermediates/big.bin",
    ]
    for rel in managed { try home.file(rel, bytes: 2 << 20) }
    let free = [
        "Developer/app/android/app/release.aab",        // next to the build folder, not in it
        "Developer/app/ios/App/build/notes.zip",          // `build` without `ios/` right above it
        "Developer/app/android/build/big.bin",            // `android/build` is not one of the folders
        "Developer/web/next/cache.bin",                   // `next` is not `.next`
        "Developer/app/ios/Pods.zip",                     // a file named like the folder
        "Movies/android/app/build/screen.mov",            // not below a project root
    ]
    for rel in free { try home.file(rel, bytes: 2 << 20) }

    let files = try await makeFinder(in: home).find(minBytes: 1 << 20)

    let locks = Dictionary(uniqueKeysWithValues: zip(relativePaths(files, in: home), files.map(\.lock)))
    #expect(locks.count == managed.count + free.count)
    for rel in managed { #expect(locks[rel] == .some(.managedByDeveloperJunk), "\(rel)") }
    for rel in free { #expect(locks[rel] == .some(nil), "\(rel)") }
}

@Test func projectBuildFoldersAreLockedUnderEveryProjectRoot() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Work/site/.next/trace.bin", bytes: 2 << 20)
    try home.file("Developer/site/.next/trace.bin", bytes: 2 << 20)
    var env = CoreEnvironment.test(home: home)
    env.projectRoots = [home.url.appending(path: "Work", directoryHint: .isDirectory)]

    let files = try await LargeFileFinder(env: env) { _ in nil }.find(minBytes: 1 << 20)

    let locks = Dictionary(uniqueKeysWithValues: zip(relativePaths(files, in: home), files.map(\.lock)))
    #expect(locks["Work/site/.next/trace.bin"] == .some(.managedByDeveloperJunk))
    #expect(locks["Developer/site/.next/trace.bin"] == .some(nil)) // `Developer` is not a project root here
}

// MARK: - Protected locations

@Test func largeFileInDocumentsOrDesktopStaysUnlocked() async throws {
    // A file there may be moved to the Trash (it can be put back), so the guard allows it.
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Documents/Work/render.mov", bytes: 2 << 20)
    try home.file("Desktop/old.dmg", bytes: 2 << 20)

    let files = try await makeFinder(in: home).find(minBytes: 1 << 20)

    #expect(relativePaths(files, in: home).sorted() == ["Desktop/old.dmg", "Documents/Work/render.mov"])
    #expect(files.allSatisfy { $0.lock == nil })
}

@Test func protectedPackageIsListedAndLocked() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Pictures/Photos Library.photoslibrary/originals/a.bin", bytes: 2 << 20)
    try home.file("Documents/Archive.photoslibrary/originals/b.bin", bytes: 2 << 20)
    try home.file("Desktop/Mockups.photoslibrary/c.bin", bytes: 2 << 20)

    let files = try await makeFinder(in: home).find(minBytes: 1 << 20)

    // Only a file (not a folder) may be trashed from Documents or Desktop, and nothing from Pictures.
    #expect(relativePaths(files, in: home).sorted() == [
        "Desktop/Mockups.photoslibrary", "Documents/Archive.photoslibrary", "Pictures/Photos Library.photoslibrary",
    ])
    #expect(files.allSatisfy { $0.lock == .protectedLocation })
}

@Test func largeFileInPicturesOrSshIsLocked() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Pictures/Trip/clip.mov", bytes: 2 << 20)
    try home.file(".ssh/backup.zip", bytes: 2 << 20)

    let files = try await makeFinder(in: home).find(minBytes: 1 << 20)

    #expect(relativePaths(files, in: home).sorted() == [".ssh/backup.zip", "Pictures/Trip/clip.mov"])
    #expect(files.allSatisfy { $0.lock == .protectedLocation })
}

@Test func packageDirectlyInTheHomeFolderIsLocked() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Loose.photoslibrary/a.bin", bytes: 2 << 20)
    try home.file("loose.dmg", bytes: 2 << 20)

    let files = try await makeFinder(in: home).find(minBytes: 1 << 20)

    // A folder directly in home is never cleaned, but a plain file there may be.
    let locks = Dictionary(uniqueKeysWithValues: files.map { ($0.url.lastPathComponent, $0.lock) })
    #expect(locks["Loose.photoslibrary"] == .some(.protectedLocation))
    #expect(locks["loose.dmg"] == .some(nil))
}

@Test func managedLockWinsOverProtectedLocation() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    // `.android` is managed by Developer Junk. Its folders would also be refused by the guard
    // (a folder directly in home), but the reason shown is the more specific one.
    try home.file(".android/avd/Pixel.avd/userdata.img", bytes: 2 << 20)
    let files = try await makeFinder(in: home).find(minBytes: 1 << 20)
    #expect(files.map(\.lock) == [.managedByDeveloperJunk])
}

// MARK: - Awkward names and unreadable folders

@Test func findsFileWithSpacesCommasAndPercentInItsName() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let file = try home.file("Movies/My Clips (2025), v2/Screen Recording (1), 10%.mov", bytes: 2 << 20)

    let files = try await makeFinder(in: home).find(minBytes: 1 << 20)

    let found = try #require(files.first)
    #expect(files.count == 1)
    #expect(found.url.path == file.path)
    #expect(found.id == file.path)
    #expect(FileManager.default.fileExists(atPath: found.url.path))
    #expect(found.kind == .video)
    #expect(found.bytes == 2 * mib)
    #expect(found.lock == nil)
}

@Test func largeFileScanSkipsUnreadableFolders() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    // Folders are walked in name order or not, so put the unreadable one on both sides of the readable one.
    let before = try home.dir("A-locked")
    try home.file("A-locked/hidden.bin", bytes: 2 << 20)
    try home.file("B-open/big.bin", bytes: 2 << 20)
    let after = try home.dir("C-locked")
    try home.file("C-locked/hidden.bin", bytes: 2 << 20)
    try home.file("D-open/big.bin", bytes: 2 << 20)
    #expect(chmod(before.path, 0o000) == 0)
    #expect(chmod(after.path, 0o000) == 0)
    defer {
        chmod(before.path, 0o755)
        chmod(after.path, 0o755)
    }

    let files = try await makeFinder(in: home).find(minBytes: 1 << 20)

    #expect(relativePaths(files, in: home).sorted() == ["B-open/big.bin", "D-open/big.bin"])
}

// MARK: - Spotlight

@Test func spotlightLastUsedIsNilForAFileItDoesNotKnow() throws {
    let home = try TempHome(); defer { home.cleanup() }
    #expect(LargeFileFinder.spotlightLastUsed(home.url.appending(path: "missing.bin", directoryHint: .notDirectory)) == nil)
}

// MARK: - Progress and cancellation

@Test func largeFileScanReportsProgressEvery2000Entries() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    for folder in 0..<21 {
        for index in 0..<100 { try home.file("Many/d\(folder)/f\(index).bin", bytes: 1) }
    }
    let reports = Mutex<[Int]>([])

    _ = try await makeFinder(in: home).find(minBytes: 1 << 20) { progress in
        reports.withLock { $0.append(progress.itemsScanned) }
    }

    // 21 folders + 2,100 files + `Many` itself: 2,122 entries, so exactly one report, at the 2,000th.
    let seen = reports.withLock { $0 }
    #expect(seen == [2_000])
}

@Test func cancelledLargeFileScanThrows() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Downloads/a.bin", bytes: 2 << 20)
    let finder = makeFinder(in: home)

    let task = Task { () throws -> [LargeFile] in
        // Hold off until the cancel below has landed, so the outcome never depends on scheduling.
        while !Task.isCancelled { await Task.yield() }
        return try await finder.find(minBytes: 1 << 20)
    }
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func packageProgressCountsOnFromTheWalk() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    for folder in 0..<21 {
        for index in 0..<100 { try home.file("Pictures/Big.photoslibrary/d\(folder)/f\(index).bin", bytes: 1) }
    }
    let reports = Mutex<[ScanProgress]>([])

    let files = try await makeFinder(in: home).find(minBytes: 1 << 20) { update in
        reports.withLock { $0.append(update) }
    }

    // The walk sees `Pictures` and the package (2 entries), then the package's own 2,121 entries are measured.
    #expect(files.map(\.url.lastPathComponent) == ["Big.photoslibrary"])
    let seen = reports.withLock { $0 }
    #expect(seen.map(\.itemsScanned) == [2_002])
    #expect(seen.first?.currentPath.contains("Big.photoslibrary") == true)
}

@Test func largeFileScanCancelsInTheMiddleOfAWalk() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    // 41 folders + 4,100 files + `Many` itself: 4,142 entries, so an uninterrupted walk reports at the 2,000th
    // and at the 4,000th. Nothing here is large, so nothing but the walk itself can notice the cancellation.
    for folder in 0..<41 {
        for index in 0..<100 { try home.file("Many/d\(folder)/f\(index).bin", bytes: 1) }
    }
    let finder = makeFinder(in: home)
    let reports = Mutex(0)
    let task = Task {
        // The first progress report (after 2,000 entries) cancels the very task that is walking.
        try await finder.find(minBytes: 1 << 20) { _ in
            reports.withLock { $0 += 1 }
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    // The walk stopped at the next entry. Without that per-entry check it would run on to the 4,000th entry.
    #expect(reports.withLock { $0 } == 1)
}
