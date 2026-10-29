import Foundation
import Synchronization
import Testing
import CleanoriCore

private let mib: Int64 = 1_048_576
private let derivedData = "Library/Developer/Xcode/DerivedData"
private let deviceSupport = "Library/Developer/Xcode/iOS DeviceSupport"
private let xcodeRunning = FakeProcessInspector(bundleIDs: ["com.apple.dt.Xcode"])

/// A temporary home, plus a separate temporary folder for the clean log.
private struct Sandbox {
    let home: TempHome
    let logs: TempHome
    let now = Date.now

    init() throws {
        home = try TempHome()
        logs = try TempHome()
    }

    var log: CleanLog { CleanLog(directory: logs.url, now: { [now] in now }) }

    func env(
        processes: any ProcessInspector = FakeProcessInspector(),
        simulators: any SimulatorControl = FakeSimulatorControl(),
        trasher: any Trasher = FakeTrasher()
    ) -> CoreEnvironment {
        .test(home: home, now: now, processes: processes, simulators: simulators, trasher: trasher)
    }

    func url(_ rel: String, directory: Bool = true) -> URL {
        home.url.appending(path: rel, directoryHint: directory ? .isDirectory : .notDirectory)
    }

    /// Scans the whole catalog the way the app does and returns every item found.
    func scan(
        processes: any ProcessInspector = FakeProcessInspector(),
        simulators: any SimulatorControl = FakeSimulatorControl()
    ) async throws -> [ScanItem] {
        try await JunkScanner(env: env(processes: processes, simulators: simulators)).scan().groups.flatMap(\.items)
    }

    /// The lines written to today's clean log so far.
    func entries() throws -> [CleanLogEntry] {
        let file = log.currentFileURL
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            try decoder.decode(CleanLogEntry.self, from: Data($0.utf8))
        }
    }

    func cleanup() {
        home.cleanup()
        logs.cleanup()
    }
}

private func item(_ items: [ScanItem], rule ruleID: String, named name: String) throws -> ScanItem {
    try #require(items.first { $0.ruleID == ruleID && $0.displayName == name })
}

private func handMade(
    _ ruleID: String, _ url: URL, method: CleanMethod, bytes: Int64 = mib, udid: String? = nil
) -> ScanItem {
    ScanItem(
        ruleID: ruleID, url: url, displayName: url.lastPathComponent,
        size: SizeResult(bytes: bytes, fileCount: 1), method: method, simulatorUDID: udid
    )
}

/// Whether something (a link included, never its target) is at `url`.
private func exists(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
}

private func isSymlink(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
}

/// A value tests can read and change from `@Sendable` closures.
private final class Locked<Value: Sendable>: Sendable {
    private let value: Mutex<Value>
    init(_ initial: Value) { value = Mutex(initial) }
    var current: Value { value.withLock { $0 } }
    func update(_ change: (inout Value) -> Void) { value.withLock { change(&$0) } }
}

private func testRule(
    _ id: String, method: CleanMethod = .delete, locks: [LockCondition] = [],
    discover: @escaping @Sendable (CoreEnvironment) async throws -> [DiscoveredItem]
) -> CleanupRule {
    CleanupRule(
        id: id, title: id, group: .toolCaches, method: method, defaultSelection: .always,
        locks: locks, regenerateHint: "test", discover: discover
    )
}

/// Apps can be started while a clean is under way.
private final class SwitchableProcesses: ProcessInspector {
    private let bundleIDs = Mutex<Set<String>>([])
    func start(_ bundleID: String) { bundleIDs.withLock { _ = $0.insert(bundleID) } }
    func runningBundleIDs() -> Set<String> { bundleIDs.withLock { $0 } }
    func runningProcesses() -> [RunningProcess] { [] }
}

private struct Unreachable: Error {}

// MARK: - Each method

@Test func deletesCatalogItem() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    try s.home.file("\(derivedData)/A/Build/out.bin", bytes: 2 * Int(mib))
    try s.home.file("\(derivedData)/B/Build/out.bin")
    let a = try item(try await s.scan(), rule: "xcode.derivedData", named: "A")

    let report = try await Cleaner(env: s.env(), log: s.log).clean([a])

    #expect(!exists(a.url))
    #expect(exists(s.url("\(derivedData)/B/Build/out.bin", directory: false)))
    #expect(a.size.bytes == 2 * mib)
    #expect(report == CleanReport(deletedBytes: a.size.bytes))
    let entries = try s.entries()
    #expect(entries.count == 1)
    let line = try #require(entries.first)
    #expect(line.action == "delete")
    #expect(line.result == "ok")
    #expect(line.ruleID == "xcode.derivedData")
    #expect(line.path == a.url.path)
    #expect(line.bytes == a.size.bytes)
    #expect(line.message == nil)
}

@Test func deletingAFolderNeverFollowsLinksInsideIt() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    // pnpm-style `node_modules` are full of links to folders that must outlive them.
    try s.home.file("\(derivedData)/A/Build/out.bin")
    let keepFile = try s.home.file("Elsewhere/Keep/file.bin", bytes: 16)
    try s.home.symlink("\(derivedData)/A/Build/linkToFolder", to: s.url("Elsewhere/Keep"))
    try s.home.symlink("\(derivedData)/A/linkToFile", to: keepFile)
    let a = try item(try await s.scan(), rule: "xcode.derivedData", named: "A")

    let report = try await Cleaner(env: s.env(), log: s.log).clean([a])

    #expect(report.deletedBytes == a.size.bytes)
    #expect(!exists(a.url))
    #expect(exists(keepFile))
    #expect(try FileManager.default.contentsOfDirectory(atPath: s.url("Elsewhere/Keep").path) == ["file.bin"])
}

@Test func trashesViaTrasher() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    try s.home.file("\(deviceSupport)/iPhone15,2 18.1 (22B83)/Symbols/dyld")
    let ds = try item(try await s.scan(), rule: "xcode.deviceSupport", named: "iPhone15,2 18.1 (22B83)")
    let trasher = FakeTrasher()

    let report = try await Cleaner(env: s.env(trasher: trasher), log: s.log).clean([ds])

    #expect(trasher.trashed == [ds.url])
    #expect(exists(ds.url)) // the fake trasher leaves the disk alone
    #expect(report == CleanReport(trashedBytes: ds.size.bytes))
    #expect(try s.entries().map { "\($0.action) \($0.result)" } == ["trash ok"])
}

@Test func deletesSimulatorViaSimctl() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    let udid = UUID().uuidString
    let data = try s.home.dir("Library/Developer/CoreSimulator/Devices/\(udid)")
    try s.home.file("Library/Developer/CoreSimulator/Devices/\(udid)/data/db.bin")
    let sims = FakeSimulatorControl(devices: [
        SimulatorDevice(udid: udid, name: "iPhone 16", runtime: "iOS 26.3", isAvailable: false, dataURL: data),
    ])
    let sim = try item(try await s.scan(simulators: sims), rule: "sim.devices", named: "iPhone 16 (iOS 26.3)")

    let report = try await Cleaner(env: s.env(simulators: sims), log: s.log).clean([sim])

    #expect(sims.deleted == [udid])
    #expect(report == CleanReport(simctlBytes: sim.size.bytes))
    #expect(exists(data)) // removing the folder is simctl's job, not the cleaner's
    #expect(try s.entries().map { "\($0.action) \($0.result)" } == ["simctl ok"])
}

@Test func skipsSimulatorWithoutAValidUDID() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    let sims = FakeSimulatorControl()
    let noUDID = handMade("sim.devices", try s.home.dir("Library/Developer/CoreSimulator/Devices/A"), method: .simctl)
    // `simctl delete all` would remove every simulator.
    let all = handMade(
        "sim.devices", try s.home.dir("Library/Developer/CoreSimulator/Devices/B"), method: .simctl, udid: "all"
    )

    let report = try await Cleaner(env: s.env(simulators: sims), log: s.log).clean([noUDID, all])

    #expect(sims.deleted.isEmpty)
    #expect(report == CleanReport(skipped: [
        noUDID.id: "Missing simulator UDID",
        all.id: "Invalid simulator UDID",
    ]))
}

// MARK: - Revalidation

@Test func skipsMissingItem() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    try s.home.file("\(derivedData)/A/Build/out.bin")
    let a = try item(try await s.scan(), rule: "xcode.derivedData", named: "A")
    try FileManager.default.removeItem(at: a.url)

    let report = try await Cleaner(env: s.env(), log: s.log).clean([a])

    #expect(report == CleanReport(skipped: [a.id: "No longer exists"]))
    let line = try #require(try s.entries().first)
    #expect(line.action == "skip")
    #expect(line.result == "skipped")
    #expect(line.message == "No longer exists")
}

@Test func skipsItemThatVanishesWhileBeingRevalidated() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    try s.home.file("Library/Caches/Vanishing/blob.bin")
    let vanishing = s.url("Library/Caches/Vanishing")
    // Lists the folder, then it disappears before the cleaner gets to it.
    let racy = testRule("test.racy") { _ in
        defer { try? FileManager.default.removeItem(at: vanishing) }
        return [DiscoveredItem(url: vanishing, displayName: "Vanishing")]
    }

    let report = try await Cleaner(env: s.env(), rules: [racy], log: s.log)
        .clean([handMade("test.racy", vanishing, method: .delete)])

    #expect(report == CleanReport(skipped: ["test.racy|\(vanishing.path)": "No longer exists"]))
}

@Test func skipsWhenLockAppears() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    try s.home.file("\(derivedData)/A/Build/out.bin")
    let a = try item(try await s.scan(), rule: "xcode.derivedData", named: "A")
    #expect(a.lock == nil)

    let report = try await Cleaner(env: s.env(processes: xcodeRunning), log: s.log).clean([a])

    #expect(report == CleanReport(skipped: [a.id: "Xcode is running"]))
    #expect(exists(a.url))
    let line = try #require(try s.entries().first)
    #expect(line.action == "skip")
    #expect(line.message == "Xcode is running")
}

@Test func reevaluatesLocksInsteadOfTrustingTheScan() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    try s.home.file("\(derivedData)/A/Build/out.bin")
    let a = try item(try await s.scan(processes: xcodeRunning), rule: "xcode.derivedData", named: "A")
    #expect(a.lock == .appRunning(name: "Xcode"))

    // Xcode has quit since the scan.
    let report = try await Cleaner(env: s.env(), log: s.log).clean([a])

    #expect(report == CleanReport(deletedBytes: a.size.bytes))
    #expect(!exists(a.url))
}

@Test func skipsItemReplacedBySymlink() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    try s.home.file("\(derivedData)/A/Build/out.bin")
    try s.home.file("\(deviceSupport)/iPhone14,5 27.0.1 (24A446)/Symbols/dyld")
    let keep = try s.home.file("Elsewhere/Target/keep.txt", bytes: 16)
    let target = s.url("Elsewhere/Target")
    let scanned = try await s.scan()
    let a = try item(scanned, rule: "xcode.derivedData", named: "A")
    let ds = try item(scanned, rule: "xcode.deviceSupport", named: "iPhone14,5 27.0.1 (24A446)")
    // Between scan and clean, both folders are swapped for links to a folder that must survive.
    for swapped in [a, ds] {
        try FileManager.default.removeItem(at: swapped.url)
        try FileManager.default.createSymbolicLink(at: swapped.url, withDestinationURL: target)
    }
    let trasher = FakeTrasher()

    let report = try await Cleaner(env: s.env(trasher: trasher), log: s.log).clean([a, ds])

    #expect(report == CleanReport(skipped: [a.id: "Is a symbolic link", ds.id: "Is a symbolic link"]))
    #expect(trasher.trashed.isEmpty)
    #expect(isSymlink(a.url))
    #expect(isSymlink(ds.url))
    #expect(exists(keep))
    let entries = try s.entries()
    #expect(entries.map(\.action) == ["skip", "skip"])
    #expect(entries.map(\.result) == ["skipped", "skipped"])
    #expect(entries.map(\.message) == ["SafetyGuard: Is a symbolic link", "SafetyGuard: Is a symbolic link"])
}

@Test func skipsItemReachedThroughASymlinkedFolder() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    // The real folders live elsewhere in home; `DerivedData` and `iOS DeviceSupport` are links to them.
    let keepBuild = try s.home.file("Elsewhere/DerivedData/A/Build/out.bin")
    let keepSymbols = try s.home.file("Elsewhere/DeviceSupport/iPhone 15 (22B83)/Symbols/dyld")
    try s.home.symlink(derivedData, to: s.url("Elsewhere/DerivedData"))
    try s.home.symlink(deviceSupport, to: s.url("Elsewhere/DeviceSupport"))
    let throughLink = s.url("\(derivedData)/A")
    // Unlike the catalog, this rule follows links, so the item passes the catalog check and SafetyGuard
    // (which looks only at the item itself); only the walk from home to the item can stop it.
    let followsLinks = testRule("test.followsLinks") { _ in [DiscoveredItem(url: throughLink, displayName: "A")] }
    let deleted = handMade("test.followsLinks", throughLink, method: .delete)
    let trashed = handMade("xcode.deviceSupport", s.url("\(deviceSupport)/iPhone 15 (22B83)"), method: .trash)
    let trasher = FakeTrasher()

    let report = try await Cleaner(env: s.env(trasher: trasher), rules: Catalog.all() + [followsLinks], log: s.log)
        .clean([deleted, trashed])

    #expect(report == CleanReport(skipped: [
        deleted.id: "Path goes through a symbolic link",
        trashed.id: "Path goes through a symbolic link",
    ]))
    #expect(trasher.trashed.isEmpty)
    #expect(exists(keepBuild))
    #expect(exists(keepSymbols))
    #expect(try s.entries().map(\.message) == Array(repeating: "Path goes through a symbolic link", count: 2))
}

@Test func rejectsNonCatalogDelete() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    let yarnBlob = try s.home.file("Library/Caches/Yarn/v6/blob.bin") // the rule does find something
    let document = try s.home.file("Documents/x", bytes: 16)
    let otherBlob = try s.home.file("Library/Caches/Other/blob.bin")
    let protected = handMade("cache.yarn", document, method: .delete)
    let unlisted = handMade("cache.yarn", s.url("Library/Caches/Other"), method: .delete)

    let report = try await Cleaner(env: s.env(), log: s.log).clean([protected, unlisted])

    #expect(report == CleanReport(skipped: [
        protected.id: "Protected location",
        unlisted.id: "Not found by a cleanup rule",
    ]))
    #expect(exists(document))
    #expect(exists(otherBlob))
    #expect(exists(yarnBlob))
    let entries = try s.entries()
    #expect(entries.map(\.result) == ["skipped", "skipped"])
    #expect(entries.map(\.message) == ["SafetyGuard: Protected location", "SafetyGuard: Not found by a cleanup rule"])
}

@Test func checksCatalogMembershipOncePerRulePerClean() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    let names = ["one", "two", "three"]
    for name in names { try s.home.file("Library/Caches/Counted/\(name)/blob.bin") }
    let urls = names.map { s.url("Library/Caches/Counted/\($0)") }
    let calls = Locked(0)
    let counted = testRule("test.counted") { _ in
        calls.update { $0 += 1 }
        return urls.map { DiscoveredItem(url: $0, displayName: $0.lastPathComponent) }
    }
    let cleaner = Cleaner(env: s.env(), rules: [counted], log: s.log)

    let first = try await cleaner.clean(urls.prefix(2).map { handMade("test.counted", $0, method: .delete) })
    #expect(first.deletedBytes == 2 * mib)
    #expect(calls.current == 1)

    // A later clean asks the rule again rather than trusting an old answer.
    let second = try await cleaner.clean([handMade("test.counted", urls[2], method: .delete)])
    #expect(second.deletedBytes == mib)
    #expect(calls.current == 2)
    #expect(urls.allSatisfy { !exists($0) })
}

@Test func skipsMethodThatDoesNotMatchItsRule() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    try s.home.file("\(deviceSupport)/iPhone 15 (22B83)/Symbols/dyld")
    try s.home.file("\(derivedData)/A/Build/out.bin")
    // DeviceSupport is only ever trashed: it must never be deleted for good, even though its rule finds it.
    let deleteDeviceSupport = handMade("xcode.deviceSupport", s.url("\(deviceSupport)/iPhone 15 (22B83)"), method: .delete)
    let trashDerivedData = handMade("xcode.derivedData", s.url("\(derivedData)/A"), method: .trash)
    let trasher = FakeTrasher()

    let report = try await Cleaner(env: s.env(trasher: trasher), log: s.log)
        .clean([deleteDeviceSupport, trashDerivedData])

    #expect(report == CleanReport(skipped: [
        deleteDeviceSupport.id: "Clean method does not match its rule",
        trashDerivedData.id: "Clean method does not match its rule",
    ]))
    #expect(exists(deleteDeviceSupport.url))
    #expect(trasher.trashed.isEmpty)
}

@Test func skipsUnknownRuleUnlessTrashingALargeFile() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    try s.home.file("Library/Caches/Mystery/blob.bin")
    let data = try s.home.dir("Library/Developer/CoreSimulator/Devices/X")
    let dmg = try s.home.file("Downloads/a.dmg", bytes: 16)
    let delete = handMade("largeFiles", s.url("Library/Caches/Mystery"), method: .delete)
    let simctl = handMade("no.such.rule", data, method: .simctl, udid: UUID().uuidString)
    // Only Large Files may trash without a rule; any other unknown rule may not, even for the Trash.
    let trash = handMade("diskMap", dmg, method: .trash)
    let sims = FakeSimulatorControl()
    let trasher = FakeTrasher()

    let report = try await Cleaner(env: s.env(simulators: sims, trasher: trasher), log: s.log)
        .clean([delete, simctl, trash])

    #expect(report == CleanReport(skipped: [
        delete.id: "Unknown rule", simctl.id: "Unknown rule", trash.id: "Unknown rule",
    ]))
    #expect(exists(delete.url))
    #expect(sims.deleted.isEmpty)
    #expect(trasher.trashed.isEmpty)
}

@Test func skipsWhenALockAppearsWhileTheRuleIsRechecked() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    let processes = SwitchableProcesses()
    let build = try s.home.file("Library/Caches/Slow/blob.bin")
    let folder = s.url("Library/Caches/Slow")
    let udid = UUID().uuidString
    let data = try s.home.dir("Library/Developer/CoreSimulator/Devices/\(udid)")
    // Each rule is unlocked when its item is first checked; the app starts while the rule is re-run.
    let slowDelete = testRule("test.slowDelete", locks: [.xcode]) { _ in
        processes.start("com.apple.dt.Xcode")
        return [DiscoveredItem(url: folder, displayName: "Slow")]
    }
    let slowSimctl = testRule("test.slowSimctl", method: .simctl, locks: [.simulator]) { _ in
        processes.start("com.apple.iphonesimulator")
        return [DiscoveredItem(url: data, displayName: "iPhone", simulatorUDID: udid)]
    }
    let sims = FakeSimulatorControl()
    let deleteItem = handMade("test.slowDelete", folder, method: .delete)
    let simItem = handMade("test.slowSimctl", data, method: .simctl, udid: udid)

    let report = try await Cleaner(
        env: s.env(processes: processes, simulators: sims), rules: [slowDelete, slowSimctl], log: s.log
    ).clean([deleteItem, simItem])

    #expect(report == CleanReport(skipped: [deleteItem.id: "Xcode is running", simItem.id: "Simulator is running"]))
    #expect(exists(build))
    #expect(sims.deleted.isEmpty)
}

@Test func skipsEveryItemOfARuleThatCannotBeRechecked() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    let calls = Locked(0)
    let failing = testRule("test.failing") { _ in
        calls.update { $0 += 1 }
        throw Unreachable()
    }
    let failingSims = testRule("test.failingSims", method: .simctl) { _ in throw Unreachable() }
    let one = try s.home.file("Library/Caches/Unsure/one/blob.bin")
    let two = try s.home.file("Library/Caches/Unsure/two/blob.bin")
    let data = try s.home.dir("Library/Developer/CoreSimulator/Devices/X")
    let items = [
        handMade("test.failing", s.url("Library/Caches/Unsure/one"), method: .delete),
        handMade("test.failing", s.url("Library/Caches/Unsure/two"), method: .delete),
        handMade("test.failingSims", data, method: .simctl, udid: UUID().uuidString),
    ]
    let sims = FakeSimulatorControl()

    let report = try await Cleaner(env: s.env(simulators: sims), rules: [failing, failingSims], log: s.log)
        .clean(items)

    #expect(report == CleanReport(skipped: Dictionary(uniqueKeysWithValues: items.map {
        ($0.id, "Could not re-check rule")
    })))
    #expect(calls.current == 1) // a failure is remembered for the rest of the clean too
    #expect(exists(one))
    #expect(exists(two))
    #expect(sims.deleted.isEmpty)
}

@Test func simulatorMustStillBeListed() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    let listed = UUID().uuidString
    let gone = UUID().uuidString
    let listedData = try s.home.dir("Library/Developer/CoreSimulator/Devices/\(listed)")
    let goneData = try s.home.dir("Library/Developer/CoreSimulator/Devices/\(gone)")
    let calls = Locked(0)
    let sims = testRule("test.sims", method: .simctl) { _ in
        calls.update { $0 += 1 }
        return [DiscoveredItem(url: listedData, displayName: "iPhone 16", simulatorUDID: listed)]
    }
    let control = FakeSimulatorControl()
    let listedItem = handMade("test.sims", listedData, method: .simctl, udid: listed)
    let goneItem = handMade("test.sims", goneData, method: .simctl, udid: gone)

    let report = try await Cleaner(env: s.env(simulators: control), rules: [sims], log: s.log)
        .clean([listedItem, goneItem])

    #expect(control.deleted == [listed])
    #expect(report == CleanReport(simctlBytes: mib, skipped: [goneItem.id: "Not found by a cleanup rule"]))
    #expect(calls.current == 1)
}

@Test func skipsMalformedPaths() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    // `Downloads/x` is a link, so the kernel resolves `Downloads/x/../a.dmg` to `Elsewhere/a.dmg`, while the
    // text says `Downloads/a.dmg`.
    try s.home.file("Elsewhere/deep/marker", bytes: 16)
    try s.home.file("Elsewhere/a.dmg", bytes: 16)
    try s.home.file("Downloads/a.dmg", bytes: 16)
    try s.home.symlink("Downloads/x", to: s.url("Elsewhere/deep"))
    try s.home.dir("Downloads/real")
    let dotDot = handMade("largeFiles", s.url("Downloads/x/../a.dmg", directory: false), method: .trash)
    // Harmless here, but `..` is refused whatever it passes through.
    let plainDotDot = handMade("largeFiles", s.url("Downloads/real/../a.dmg", directory: false), method: .trash)
    let notAFile = handMade("largeFiles", try #require(URL(string: "https://example.com/a.dmg")), method: .trash)
    // `lstat` would stop reading at the NUL and look at `Downloads/a.dmg`.
    let nulURL = try #require(URL(string: s.url("Downloads/a.dmg", directory: false).absoluteString + "%00/x"))
    #expect(nulURL.path.contains("\0"))
    let withNUL = handMade("largeFiles", nulURL, method: .trash)
    let trasher = FakeTrasher()

    let report = try await Cleaner(env: s.env(trasher: trasher), log: s.log).clean([dotDot, plainDotDot, notAFile, withNUL])

    #expect(report == CleanReport(skipped: [
        dotDot.id: "Outside home folder",
        plainDotDot.id: "Outside home folder",
        notAFile.id: "Outside home folder",
        withNUL.id: "Invalid path",
    ]))
    #expect(trasher.trashed.isEmpty)
}

// MARK: - Large Files and unusual names

@Test func trashesLargeFileOutsideCatalog() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    let dmg = try s.home.file("Downloads/a.dmg", bytes: 16)
    let iso = try s.home.file("Documents/old.iso", bytes: 16) // files in Documents may go to the Trash
    let items = [
        handMade("largeFiles", dmg, method: .trash, bytes: 300 * mib),
        handMade("largeFiles", iso, method: .trash, bytes: 200 * mib),
    ]
    let trasher = FakeTrasher()

    // A running app is no reason to keep a large file: Large Files has no locks.
    let report = try await Cleaner(env: s.env(processes: xcodeRunning, trasher: trasher), log: s.log).clean(items)

    #expect(trasher.trashed == [dmg, iso])
    #expect(report == CleanReport(trashedBytes: 500 * mib))
    let entries = try s.entries()
    #expect(entries.map { "\($0.action) \($0.ruleID) \($0.result)" } == ["trash largeFiles ok", "trash largeFiles ok"])
    #expect(entries.map(\.path) == [dmg.path, iso.path])
}

@Test func cleansPathWithSpacesAndParentheses() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    let symbols = "iPhone14,5 27.0.1 (24A446)"
    let build = "My App (Beta), v2-abcdefgh"
    try s.home.file("\(deviceSupport)/\(symbols)/Symbols/dyld")
    try s.home.file("\(deviceSupport)/iPhone14,5 27.0.1/Symbols/dyld") // a sibling named like a prefix
    try s.home.file("\(derivedData)/\(build)/Build/out.bin")
    let sibling = try s.home.file("\(derivedData)/My App/Build/out.bin")
    let scanned = try await s.scan()
    let ds = try item(scanned, rule: "xcode.deviceSupport", named: symbols)
    let dd = try item(scanned, rule: "xcode.derivedData", named: build)
    let trasher = FakeTrasher()

    let report = try await Cleaner(env: s.env(trasher: trasher), log: s.log).clean([ds, dd])

    #expect(trasher.trashed == [ds.url])
    #expect(trasher.trashed.first?.path == s.home.url.path + "/\(deviceSupport)/\(symbols)")
    #expect(!exists(dd.url))
    #expect(exists(sibling))
    #expect(report == CleanReport(deletedBytes: dd.size.bytes, trashedBytes: ds.size.bytes))
    #expect(try s.entries().map(\.path) == [
        s.home.url.path + "/\(deviceSupport)/\(symbols)",
        s.home.url.path + "/\(derivedData)/\(build)",
    ])
}

// MARK: - Failures, events and concurrency

@Test func oneFailureDoesNotStopOthers() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    try s.home.file("\(deviceSupport)/first/Symbols/dyld")
    try s.home.file("\(deviceSupport)/second/Symbols/dyld")
    try s.home.file("\(derivedData)/A/Build/out.bin")
    let scanned = try await s.scan()
    let first = try item(scanned, rule: "xcode.deviceSupport", named: "first")
    let second = try item(scanned, rule: "xcode.deviceSupport", named: "second")
    let a = try item(scanned, rule: "xcode.derivedData", named: "A")
    let trasher = FakeTrasher(failing: [first.url])

    let report = try await Cleaner(env: s.env(trasher: trasher), log: s.log).clean([first, second, a])

    #expect(trasher.trashed == [second.url])
    #expect(!exists(a.url))
    #expect(report == CleanReport(
        deletedBytes: a.size.bytes, trashedBytes: second.size.bytes, failed: [first.id: "Fake failure"]
    ))
    let entries = try s.entries()
    #expect(entries.map { "\($0.action) \($0.result)" } == ["trash failed", "trash ok", "delete ok"])
    #expect(entries.first?.message == "Fake failure")
}

@Test func noSuchFileErrorForAnItemThatIsStillThereIsAFailure() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    let dmg = try s.home.file("Downloads/a.dmg", bytes: 16)
    let trasher = FakeTrasher(failing: [dmg], error: CocoaError(.fileNoSuchFile))
    let item = handMade("largeFiles", dmg, method: .trash)

    let report = try await Cleaner(env: s.env(trasher: trasher), log: s.log).clean([item])

    #expect(report.skipped.isEmpty)
    #expect(report.failed[item.id] == CocoaError(.fileNoSuchFile).localizedDescription)
    #expect(exists(dmg))
}

@Test func cleansEachItemOnce() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    try s.home.file("\(derivedData)/A/Build/out.bin")
    let dmg = try s.home.file("Downloads/a.dmg", bytes: 16)
    let a = try item(try await s.scan(), rule: "xcode.derivedData", named: "A")
    let largeFile = handMade("largeFiles", dmg, method: .trash)
    let trasher = FakeTrasher()
    let events = Locked<[String]>([])

    let report = try await Cleaner(env: s.env(trasher: trasher), log: s.log)
        .clean([a, largeFile, a, largeFile]) { event in
            if case .started(let item) = event { events.update { $0.append(item.displayName) } }
        }

    #expect(report == CleanReport(deletedBytes: a.size.bytes, trashedBytes: mib))
    #expect(trasher.trashed == [dmg])
    #expect(events.current == ["A", "a.dmg"])
    #expect(try s.entries().map { "\($0.action) \($0.result)" } == ["delete ok", "trash ok"])
}

@Test func refusesToCleanWhenTheLogCannotBeWritten() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    try s.home.file("\(derivedData)/A/Build/out.bin")
    let dmg = try s.home.file("Downloads/a.dmg", bytes: 16)
    let a = try item(try await s.scan(), rule: "xcode.derivedData", named: "A")
    let blocker = try s.logs.file("Cleanori", bytes: 16) // a file where the log folder should be
    let trasher = FakeTrasher()
    let events = Locked(0)
    let cleaner = Cleaner(env: s.env(trasher: trasher), log: CleanLog(directory: blocker, now: { .now }))

    // Twice: the second call shows the first one did not leave the cleaner marked as running.
    for _ in 0..<2 {
        let error = await #expect(throws: CleanerError.self) {
            try await cleaner.clean([a, handMade("largeFiles", dmg, method: .trash)]) { _ in
                events.update { $0 += 1 }
            }
        }
        guard case .logUnavailable(let message)? = error else {
            Issue.record("Expected logUnavailable, got \(String(describing: error))")
            return
        }
        #expect(!message.isEmpty)
    }
    #expect(exists(a.url))
    #expect(trasher.trashed.isEmpty)
    #expect(events.current == 0)
}

@Test func reportsALogFailureWithoutFailingTheItem() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    let logFile = s.log.currentFileURL
    try s.home.file("Library/Caches/Logged/blob.bin")
    let folder = s.url("Library/Caches/Logged")
    let dmg = try s.home.file("Downloads/a.dmg", bytes: 16)
    // The log passes the check at the start of the clean; then its file is replaced by a folder.
    let sabotage = testRule("test.sabotage") { _ in
        try FileManager.default.removeItem(at: logFile)
        try FileManager.default.createDirectory(at: logFile, withIntermediateDirectories: false)
        return [DiscoveredItem(url: folder, displayName: "Logged")]
    }
    let trasher = FakeTrasher()
    let items = [handMade("test.sabotage", folder, method: .delete), handMade("largeFiles", dmg, method: .trash)]

    let report = try await Cleaner(env: s.env(trasher: trasher), rules: [sabotage], log: s.log).clean(items)

    // Both actions happened and count as done; the first failure to log them is reported.
    #expect(report == CleanReport(
        deletedBytes: mib, trashedBytes: mib, logError: POSIXError(.EISDIR).localizedDescription
    ))
    #expect(!exists(folder))
    #expect(trasher.trashed == [dmg])
}

@Test func reportsEachItemAsStartedThenItsOutcome() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    let ok = try s.home.file("Downloads/ok.dmg", bytes: 16)
    let failing = try s.home.file("Downloads/failing.dmg", bytes: 16)
    let items = [
        handMade("largeFiles", ok, method: .trash),
        handMade("largeFiles", s.url("Downloads/missing.dmg", directory: false), method: .trash),
        handMade("largeFiles", failing, method: .trash),
    ]
    let events = Locked<[String]>([])

    _ = try await Cleaner(env: s.env(trasher: FakeTrasher(failing: [failing])), log: s.log).clean(items) { event in
        let line = switch event {
        case .started(let item): "started \(item.displayName)"
        case .finished(let item, let bytes): "finished \(item.displayName) \(bytes)"
        case .skipped(let item, let reason): "skipped \(item.displayName) \(reason)"
        case .failed(let item, let message): "failed \(item.displayName) \(message)"
        }
        events.update { $0.append(line) }
    }

    #expect(events.current == [
        "started ok.dmg", "finished ok.dmg \(mib)",
        "started missing.dmg", "skipped missing.dmg No longer exists",
        "started failing.dmg", "failed failing.dmg Fake failure",
    ])
}

@Test func rejectsConcurrentClean() async throws {
    let s = try Sandbox(); defer { s.cleanup() }
    let gate = Gate()
    defer { gate.open() } // never leave the first clean hanging, even when an expectation throws
    let udid = UUID().uuidString
    let data = try s.home.dir("Library/Developer/CoreSimulator/Devices/\(udid)")
    let dmg = try s.home.file("Downloads/a.dmg", bytes: 16)
    let sims = FakeSimulatorControl(
        devices: [SimulatorDevice(udid: udid, name: "iPhone 16", runtime: "iOS 26.3", isAvailable: true, dataURL: data)],
        deleteGate: gate
    )
    let trasher = FakeTrasher()
    let cleaner = Cleaner(env: s.env(simulators: sims, trasher: trasher), log: s.log)
    let sim = handMade("sim.devices", data, method: .simctl, udid: udid)
    let largeFile = handMade("largeFiles", dmg, method: .trash)

    // The first clean suspends inside `simctl delete` until the gate opens.
    let first = Task { try await cleaner.clean([sim]) }
    try await gate.waitUntilSomeoneWaits()

    await #expect(throws: CleanerError.alreadyRunning) { try await cleaner.clean([largeFile]) }
    #expect(trasher.trashed.isEmpty)
    #expect(try s.entries().isEmpty)

    gate.open()
    #expect(try await first.value == CleanReport(simctlBytes: mib))
    #expect(sims.deleted == [udid])

    // Once the first clean is over, the next one runs.
    #expect(try await cleaner.clean([largeFile]) == CleanReport(trashedBytes: mib))
    #expect(trasher.trashed == [dmg])
    #expect(try s.entries().map(\.action) == ["simctl", "trash"])
}
