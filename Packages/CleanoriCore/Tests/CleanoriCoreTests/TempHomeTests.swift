import Foundation
import Testing
import CleanoriCore

@Test func createsFilesWithSizeAndDate() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let f = try home.file("Developer/app/package.json", bytes: 4096, modified: date)
    let attrs = try FileManager.default.attributesOfItem(atPath: f.path)
    #expect(attrs[.size] as? Int == 4096)
    #expect(attrs[.modificationDate] as? Date == date)
}

@Test func lockLabels() {
    #expect(LockReason.appRunning(name: "Xcode").label == "Xcode is running")
    #expect(LockReason.managedByDeveloperJunk.label == "Managed in Developer Junk")
    #expect(LockReason.protectedLocation.label == "Protected location")
}

@Test func urlIsCanonicalWithNoSymlinkedAncestor() throws {
    let home = try TempHome(); defer { home.cleanup() }
    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: home.url.path, isDirectory: &isDir))
    #expect(isDir.boolValue)
    // Like the real `/Users/<name>`: realpath(3) must report the very same path, `/private/var/...` here.
    let resolved = try #require(realpath(home.url.path, nil))
    defer { free(resolved) }
    #expect(home.url.path == String(cString: resolved))
    #expect(home.url.path.hasPrefix("/private/"))
}

@Test func fileDefaultsToOneMebibyteOfNonZeroBytes() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let f = try home.file("a.bin")
    let data = try Data(contentsOf: f)
    #expect(data.count == 1 << 20)
    #expect(data.allSatisfy { $0 != 0 })
}

@Test func createsPathsWithSpacesCommasAndParentheses() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let f = try home.file("Library/iOS DeviceSupport/iPhone14,5 27.0.1 (24A446)/Symbols/lib.dylib", bytes: 16)
    #expect(FileManager.default.fileExists(atPath: f.path))
    #expect(f.lastPathComponent == "lib.dylib")
    #expect(f.path.hasPrefix(home.url.path + "/Library/iOS DeviceSupport/iPhone14,5 27.0.1 (24A446)/"))
}

@Test func dirCreatesIntermediateDirectories() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let d = try home.dir("a/b/c")
    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: d.path, isDirectory: &isDir))
    #expect(isDir.boolValue)
    #expect(d == home.url.appending(path: "a/b/c", directoryHint: .isDirectory))
}

@Test func symlinkPointsAtTargetWithoutFollowing() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let target = try home.dir("real")
    let link = try home.symlink("links/alias", to: target)
    let dest = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
    #expect(dest == target.path)
    let attrs = try FileManager.default.attributesOfItem(atPath: link.path)
    #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
}

@Test func cleanupRemovesTheTree() throws {
    let home = try TempHome()
    try home.file("x/y.txt", bytes: 8)
    home.cleanup()
    #expect(!FileManager.default.fileExists(atPath: home.url.path))
}

@Test func twoTempHomesAreDistinct() throws {
    let a = try TempHome(); defer { a.cleanup() }
    let b = try TempHome(); defer { b.cleanup() }
    #expect(a.url != b.url)
}

@Test func cleanupRemovesTreeContainingUnreadableSubfolder() throws {
    let home = try TempHome()
    try home.file("proj/locked/inner/deep.bin", bytes: 8)
    let locked = home.url.appending(path: "proj/locked", directoryHint: .isDirectory)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    // Safety net so a failing run does not leak the tree; a no-op once cleanup() has succeeded.
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        try? FileManager.default.removeItem(at: home.url)
    }
    home.cleanup()
    #expect(!FileManager.default.fileExists(atPath: home.url.path))
}
