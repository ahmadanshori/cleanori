import Foundation
import Synchronization
import Testing
import CleanoriCore

private let mib: Int64 = 1_048_576

/// "Now" for a test, cut to whole seconds so a file dated N days before it reads back exactly N days old.
private func wholeSecondNow() -> Date {
    Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))
}

private extension Date {
    func daysEarlier(_ days: Int) -> Date { addingTimeInterval(-Double(days) * 86_400) }
}

private struct Boom: Error {}

private func rule(
    _ id: String,
    group: RuleGroup = .toolCaches,
    method: CleanMethod = .delete,
    selection: DefaultSelection = .always,
    locks: [LockCondition] = [],
    discover: @escaping @Sendable (CoreEnvironment) async throws -> [DiscoveredItem]
) -> CleanupRule {
    CleanupRule(
        id: id, title: id, group: group, method: method, defaultSelection: selection,
        locks: locks, regenerateHint: "test", discover: discover
    )
}

/// A rule that offers each of `urls` as an item named after its last path component.
private func rule(
    _ id: String,
    group: RuleGroup = .toolCaches,
    method: CleanMethod = .delete,
    selection: DefaultSelection = .always,
    locks: [LockCondition] = [],
    items urls: [URL]
) -> CleanupRule {
    rule(id, group: group, method: method, selection: selection, locks: locks) { _ in
        urls.map { DiscoveredItem(url: $0, displayName: $0.lastPathComponent) }
    }
}

/// DerivedData/A 2 MiB, .npm/_cacache 1 MiB, an old project (last worked on 100 days ago) and a new one
/// (1 day ago), each with a 1 MiB node_modules.
private func makeScenario(in home: TempHome, now: Date) throws {
    try home.file("Library/Developer/Xcode/DerivedData/A/Build/out.bin", bytes: 2 * Int(mib))
    try home.file(".npm/_cacache/content/blob.bin")
    try home.file("Developer/old/package.json", bytes: 16, modified: now.daysEarlier(100))
    try home.file("Developer/old/node_modules/pkg/index.js")
    try home.file("Developer/new/package.json", bytes: 16, modified: now.daysEarlier(1))
    try home.file("Developer/new/src/index.ts", bytes: 16, modified: now.daysEarlier(1))
    try home.file("Developer/new/node_modules/pkg/index.js")
}

private func scanScenario(
    in home: TempHome, now: Date, processes: any ProcessInspector = FakeProcessInspector()
) async throws -> JunkScanResult {
    try makeScenario(in: home, now: now)
    return try await JunkScanner(env: .test(home: home, now: now, processes: processes)).scan()
}

private func items(of group: RuleGroup, in result: JunkScanResult) -> [ScanItem] {
    result.groups.first { $0.id == group }?.items ?? []
}

/// Counts how many closures are inside it at once, so a test can see the highest number reached.
private final class ConcurrencyProbe: Sendable {
    private struct State { var running = 0, peak = 0, entered = 0 }
    private let state = Mutex(State())

    var running: Int { state.withLock { $0.running } }
    var peak: Int { state.withLock { $0.peak } }
    var entered: Int { state.withLock { $0.entered } }

    func enter() {
        state.withLock {
            $0.running += 1
            $0.entered += 1
            $0.peak = max($0.peak, $0.running)
        }
    }

    func leave() { state.withLock { $0.running -= 1 } }

    /// Returns once `count` closures are inside at the same time, or after `timeout`.
    func waitUntilRunning(atLeast count: Int, timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        while running < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

// MARK: - Grouping and totals

@Test func groupsInDisplayOrderWithTotals() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let result = try await scanScenario(in: home, now: wholeSecondNow())
    #expect(result.groups.map(\.id) == [.xcodeDerivedData, .nodeModules, .packageCaches])
    #expect(result.groups.map(\.totalBytes) == [2 * mib, 2 * mib, mib])
    #expect(result.totalBytes == 5 * mib)
}

@Test func groupsFollowDisplayOrderNotRuleOrderAndEmptyGroupsAreOmitted() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let sim = try home.dir("sim")
    let caches = try home.dir("caches")
    try home.file("sim/data.bin")
    try home.file("caches/data.bin")
    let rules = [
        rule("test.sim", group: .simulators, method: .simctl, items: [sim]),
        rule("test.nothing", group: .gradle) { _ in [] },
        rule("test.caches", group: .packageCaches, items: [caches]),
    ]
    let result = try await JunkScanner(env: .test(home: home), rules: rules).scan()
    #expect(result.groups.map(\.id) == [.packageCaches, .simulators])
}

@Test func sortsItemsLargestFirstAndBreaksTiesByName() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("c/data.bin", bytes: Int(mib))
    try home.file("a/data.bin", bytes: 3 * Int(mib))
    try home.file("b/data.bin", bytes: Int(mib))
    try home.file("d/data.bin", bytes: 2 * Int(mib))
    let urls = ["c", "a", "b", "d"].map { home.url.appending(path: $0, directoryHint: .isDirectory) }
    let result = try await JunkScanner(env: .test(home: home), rules: [rule("test.sizes", items: urls)]).scan()
    let group = try #require(result.groups.first)
    #expect(group.items.map(\.displayName) == ["a", "d", "b", "c"])
    #expect(group.totalBytes == 7 * mib)
}

@Test func sizesItemsOfSeveralRulesIntoOneGroup() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("one/data.bin")
    try home.file("two/data.bin", bytes: 2 * Int(mib))
    let rules = [
        rule("test.one", group: .packageCaches, items: [home.url.appending(path: "one", directoryHint: .isDirectory)]),
        rule("test.two", group: .packageCaches, items: [home.url.appending(path: "two", directoryHint: .isDirectory)]),
    ]
    let result = try await JunkScanner(env: .test(home: home), rules: rules).scan()
    #expect(result.groups.count == 1)
    #expect(result.groups[0].items.map(\.ruleID) == ["test.two", "test.one"])
    #expect(result.groups[0].items.map(\.size.bytes) == [2 * mib, mib])
}

@Test func carriesDiscoveredFieldsOntoTheItem() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let device = try home.dir("CoreSimulator/Devices/UDID-1")
    try home.file("CoreSimulator/Devices/UDID-1/data/db.bin")
    let activity = wholeSecondNow().daysEarlier(5)
    let rules = [
        rule("test.device", group: .simulators, method: .simctl, selection: .never) { _ in
            [DiscoveredItem(
                url: device, displayName: "iPhone 16 (iOS 26.3)", detail: "unused", lastActivity: activity,
                badges: [.unused, .active], simulatorUDID: "UDID-1"
            )]
        },
    ]
    let result = try await JunkScanner(env: .test(home: home), rules: rules).scan()
    let item = try #require(result.groups.first?.items.first)
    #expect(item.ruleID == "test.device")
    #expect(item.id == "test.device|\(device.path)")
    #expect(item.url == device)
    #expect(item.displayName == "iPhone 16 (iOS 26.3)")
    #expect(item.detail == "unused")
    #expect(item.lastActivity == activity)
    #expect(item.method == .simctl)
    #expect(item.badges == [.unused, .active])
    #expect(item.simulatorUDID == "UDID-1")
    #expect(item.size == SizeResult(bytes: mib, fileCount: 1))
}

// MARK: - Default selection and locks

@Test func resolvesDefaultSelection() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let result = try await scanScenario(in: home, now: wholeSecondNow())
    let nodeModules = items(of: .nodeModules, in: result)
    let old = try #require(nodeModules.first { $0.displayName == "old" })
    let new = try #require(nodeModules.first { $0.displayName == "new" })
    #expect(old.isSelectedByDefault)
    #expect(!new.isSelectedByDefault)
    #expect(new.badges == [.active])
    let derivedData = try #require(items(of: .xcodeDerivedData, in: result).first)
    #expect(derivedData.isSelectedByDefault)
}

@Test func resolvesEveryDefaultSelectionKind() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let now = wholeSecondNow()
    func folder(_ name: String) throws -> URL {
        try home.file("\(name)/data.bin", bytes: 16)
        return home.url.appending(path: name, directoryHint: .isDirectory)
    }
    func item(_ name: String, activity: Date? = nil, unavailable: Bool = false) throws -> DiscoveredItem {
        DiscoveredItem(url: try folder(name), displayName: name, lastActivity: activity, isUnavailable: unavailable)
    }
    let always = try item("always")
    let never = try item("never")
    let unavailable = try item("unavailable", unavailable: true)
    let available = try item("available")
    let longAgo = try item("longAgo", activity: now.daysEarlier(61))
    let sixtyDaysAndASecond = try item("sixtyDaysAndASecond", activity: now.daysEarlier(60).addingTimeInterval(-1))
    let exactlySixtyDays = try item("exactlySixtyDays", activity: now.daysEarlier(60))
    let yesterday = try item("yesterday", activity: now.daysEarlier(1))
    let unknownActivity = try item("unknownActivity")
    let rules = [
        rule("test.always", group: .xcodeDerivedData, selection: .always) { _ in [always] },
        rule("test.never", group: .nodeModules, selection: .never) { _ in [never] },
        rule("test.unavailable", group: .simulators, selection: .ifUnavailable) { _ in [unavailable, available] },
        rule("test.inactive", group: .packageCaches, selection: .ifInactive) { _ in
            [longAgo, sixtyDaysAndASecond, exactlySixtyDays, yesterday, unknownActivity]
        },
    ]
    let result = try await JunkScanner(env: .test(home: home, now: now), rules: rules).scan()
    let selected = Dictionary(
        uniqueKeysWithValues: result.groups.flatMap(\.items).map { ($0.displayName, $0.isSelectedByDefault) }
    )
    #expect(selected == [
        "always": true,
        "never": false,
        "unavailable": true,
        "available": false,
        // Older than the threshold is inactive; exactly the threshold still counts as active (like the `active` badge).
        "longAgo": true,
        "sixtyDaysAndASecond": true,
        "exactlySixtyDays": false,
        "yesterday": false,
        // Without a date there is no evidence the project is idle, so it stays unticked.
        "unknownActivity": false,
    ])
}

@Test func nodeModulesWithoutAPackageJSONIsListedButNeverTickedByDefault() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let now = wholeSecondNow()
    try home.file("Developer/old/package.json", bytes: 16, modified: now.daysEarlier(100))
    try home.file("Developer/old/node_modules/pkg/index.js")
    // Just as idle, but nothing says it is a project's own dependencies (npm's global lib folder looks like this).
    try home.file("Developer/lib/README.md", bytes: 16, modified: now.daysEarlier(100))
    try home.file("Developer/lib/node_modules/npm/index.js")

    let result = try await JunkScanner(env: .test(home: home, now: now)).scan()
    let nodeModules = items(of: .nodeModules, in: result)
    let old = try #require(nodeModules.first { $0.displayName == "old" })
    let lib = try #require(nodeModules.first { $0.displayName == "lib" })
    #expect(old.isSelectedByDefault)
    #expect(!lib.isSelectedByDefault)
    #expect(lib.badges == [.noPackageJSON])
    #expect(lib.lock == nil) // still listed, and can be ticked by hand
}

@Test func anItemMarkedNoPackageJSONIsNeverTickedWhateverItsRuleSays() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let now = wholeSecondNow()
    try home.file("loose/a.bin", bytes: 16)
    let url = home.url.appending(path: "loose", directoryHint: .isDirectory)
    let marked = DiscoveredItem(url: url, displayName: "loose", lastActivity: now.daysEarlier(400), badges: [.noPackageJSON])
    let rules = [
        rule("test.always", group: .xcodeDerivedData, selection: .always) { _ in [marked] },
        rule("test.inactive", group: .nodeModules, selection: .ifInactive) { _ in [marked] },
    ]
    let result = try await JunkScanner(env: .test(home: home, now: now), rules: rules).scan()
    let all = result.groups.flatMap(\.items)
    #expect(all.count == 2)
    #expect(all.allSatisfy { !$0.isSelectedByDefault })
}

@Test func lockForcesUnselected() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let result = try await scanScenario(
        in: home, now: wholeSecondNow(),
        processes: FakeProcessInspector(bundleIDs: ["com.apple.dt.Xcode"])
    )
    let derivedData = try #require(items(of: .xcodeDerivedData, in: result).first)
    #expect(derivedData.lock == .appRunning(name: "Xcode"))
    #expect(!derivedData.isSelectedByDefault) // `.always`, yet locked

    // A lock belongs to the rules that declare it: npm has none.
    let npm = try #require(items(of: .packageCaches, in: result).first)
    #expect(npm.lock == nil)
    #expect(npm.isSelectedByDefault)
}

@Test func usesTheFirstActiveLock() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("data/blob.bin")
    let locked = rule(
        "test.locked", locks: [.androidStudio, .xcode, .gradleDaemon],
        items: [home.url.appending(path: "data", directoryHint: .isDirectory)]
    )
    let processes = FakeProcessInspector(
        bundleIDs: ["com.apple.dt.Xcode"],
        processes: [RunningProcess(executable: "/usr/bin/java", arguments: ["-cp", "GradleDaemon"])]
    )
    let result = try await JunkScanner(env: .test(home: home, processes: processes), rules: [locked]).scan()
    #expect(result.groups.first?.items.first?.lock == .appRunning(name: "Xcode")) // Android Studio is not running
}

// MARK: - Failures

@Test func failingRuleDoesNotAbortScan() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try makeScenario(in: home, now: wholeSecondNow())
    let failing = rule("test.failing", group: .gradle) { _ in throw Boom() }
    let scanner = JunkScanner(env: .test(home: home), rules: Catalog.all() + [failing])
    let result = try await scanner.scan()
    #expect(result.groups.map(\.id) == [.xcodeDerivedData, .nodeModules, .packageCaches])
    #expect(result.totalBytes == 5 * mib)
}

@Test func itemDeletedBeforeSizingIsDropped() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("kept/data.bin")
    try home.file("vanishing/data.bin")
    let kept = home.url.appending(path: "kept", directoryHint: .isDirectory)
    let vanishing = home.url.appending(path: "vanishing", directoryHint: .isDirectory)
    let racy = rule("test.racy") { _ in
        let found = [DiscoveredItem(url: kept, displayName: "kept"), DiscoveredItem(url: vanishing, displayName: "vanishing")]
        try FileManager.default.removeItem(at: vanishing) // gone between discovery and sizing
        return found
    }
    let result = try await JunkScanner(env: .test(home: home), rules: [racy]).scan()
    #expect(result.groups.flatMap(\.items).map(\.displayName) == ["kept"])
    #expect(result.totalBytes == mib)
}

@Test func itemThatCannotBeSizedIsKeptAsApproximateZero() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("fine/data.bin")
    let fine = home.url.appending(path: "fine", directoryHint: .isDirectory)
    // A name over 255 bytes cannot be inspected: `lstat` fails with ENAMETOOLONG, not ENOENT.
    let unreadable = home.url.appending(path: String(repeating: "x", count: 300), directoryHint: .isDirectory)
    let rules = [
        rule("test.mixed") { _ in
            [DiscoveredItem(url: fine, displayName: "fine"), DiscoveredItem(url: unreadable, displayName: "unreadable")]
        },
    ]
    let result = try await JunkScanner(env: .test(home: home), rules: rules).scan()
    let items = try #require(result.groups.first?.items)
    #expect(items.map(\.displayName) == ["fine", "unreadable"])
    #expect(items[1].size == SizeResult(bytes: 0, fileCount: 0, isApproximate: true))
    #expect(result.totalBytes == mib)
}

// MARK: - Cancellation and concurrency

private final class Flag: Sendable {
    private let isSet = Mutex(false)

    func set() { isSet.withLock { $0 = true } }

    /// Returns once the flag is set, and fails the test when that takes more than five seconds.
    func waitUntilSet() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !isSet.withLock({ $0 }) {
            guard ContinuousClock.now < deadline else { throw Boom() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@Test func cancellingTheScanningTaskThrowsCancellationError() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let started = Flag()
    let hanging = rule("test.hanging") { _ in
        started.set()
        try await Task.sleep(for: .seconds(60)) // throws CancellationError as soon as the task is cancelled
        return []
    }
    let scanner = JunkScanner(env: .test(home: home), rules: [hanging])
    let task = Task { try await scanner.scan() }
    try await started.waitUntilSet()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func aRuleFailingBecauseOfCancellationStillCancelsTheScan() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let started = Flag()
    // Some other error (a failed subprocess, say) surfacing after the task was cancelled is no "empty rule".
    let failing = rule("test.failingOnCancel") { _ in
        started.set()
        while !Task.isCancelled { try await Task.sleep(for: .milliseconds(5)) }
        throw Boom()
    }
    let scanner = JunkScanner(env: .test(home: home), rules: [failing])
    let task = Task { try await scanner.scan() }
    try await started.waitUntilSet()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func aRuleThatIgnoresCancellationCannotMakeTheScanSucceed() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let started = Flag()
    let stubborn = rule("test.stubborn") { _ in
        started.set()
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        return [] // finishes normally even though the task was cancelled
    }
    let scanner = JunkScanner(env: .test(home: home), rules: [stubborn])
    let task = Task { try await scanner.scan() }
    try await started.waitUntilSet()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func scanStartedInACancelledTaskThrows() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("data/blob.bin")
    let plain = rule("test.plain", items: [home.url.appending(path: "data", directoryHint: .isDirectory)])
    let scanner = JunkScanner(env: .test(home: home), rules: [plain])
    let task = Task {
        while !Task.isCancelled { await Task.yield() }
        return try await scanner.scan()
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func neverRunsMoreRulesAtOnceThanTheCap() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let cap = 3
    let probe = ConcurrencyProbe()
    let rules = (0..<12).map { index in
        rule("test.probe\(index)") { _ in
            probe.enter()
            defer { probe.leave() }
            if index < cap {
                // The first wave starts together; waiting for it to fill proves the cap is reached.
                try await probe.waitUntilRunning(atLeast: cap)
            } else {
                try await Task.sleep(for: .milliseconds(10))
            }
            return []
        }
    }
    let scanner = JunkScanner(env: .test(home: home), rules: rules, maxConcurrentRules: cap)
    _ = try await scanner.scan()
    #expect(probe.entered == 12) // every rule ran
    #expect(probe.peak == cap)   // and never more than `cap` at once
}

@Test func aCapBelowOneStillRunsEveryRule() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let probe = ConcurrencyProbe()
    let rules = (0..<4).map { index in
        rule("test.probe\(index)") { _ in
            probe.enter()
            defer { probe.leave() }
            try await Task.sleep(for: .milliseconds(5))
            return []
        }
    }
    _ = try await JunkScanner(env: .test(home: home), rules: rules, maxConcurrentRules: 0).scan()
    #expect(probe.entered == 4)
    #expect(probe.peak == 1)
}

// MARK: - Shared ledger and progress

@Test func hardlinkedFileIsCountedOnceAcrossRules() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let original = try home.file("store/a/shared.bin")
    try home.dir("store/b")
    try FileManager.default.linkItem(at: original, to: home.url.appending(path: "store/b/shared.bin"))
    let rules = [
        rule("test.a", items: [home.url.appending(path: "store/a", directoryHint: .isDirectory)]),
        rule("test.b", items: [home.url.appending(path: "store/b", directoryHint: .isDirectory)]),
    ]
    let scanner = JunkScanner(env: .test(home: home), rules: rules)
    // One ledger serves every rule of a scan, so the shared file is charged once whichever rule reaches it
    // first. A scan starts a new ledger, or a rescan would find everything already claimed and report 0 bytes.
    for _ in 1...2 {
        let result = try await scanner.scan()
        #expect(result.groups.flatMap(\.items).count == 2)
        #expect(result.totalBytes == mib)
    }
}

@Test func progressCountsEntriesAcrossItemsAndNeverGoesBack() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    // Each tree has 2,121 entries below it, so the sizer reports once (at 2,000) while measuring each.
    for tree in ["one", "two"] {
        for folder in 0..<21 {
            for index in 0..<100 {
                try home.file("\(tree)/d\(folder)/f\(index).bin", bytes: 1)
            }
        }
    }
    let urls = ["one", "two"].map { home.url.appending(path: $0, directoryHint: .isDirectory) }
    let reports = Mutex<[Int]>([])
    let scanner = JunkScanner(env: .test(home: home), rules: [rule("test.trees", items: urls)])
    _ = try await scanner.scan { progress in reports.withLock { $0.append(progress.itemsScanned) } }
    #expect(reports.withLock { $0 } == [2_000, 4_000])
}
