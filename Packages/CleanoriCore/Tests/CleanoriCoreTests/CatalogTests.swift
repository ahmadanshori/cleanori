import Foundation
import Testing
import CleanoriCore

private func discover(_ ruleID: String, in home: TempHome) async throws -> [DiscoveredItem] {
    let rule = try #require(Catalog.rule(id: ruleID))
    return try await rule.discover(.test(home: home))
}

private func names(_ items: [DiscoveredItem]) -> [String] {
    items.map(\.displayName).sorted()
}

// MARK: - Discovery

@Test func derivedDataYieldsOneItemPerProject() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Library/Developer/Xcode/DerivedData/A-x/Build/a.o", bytes: 16)
    try home.file("Library/Developer/Xcode/DerivedData/B-y/Build/b.o", bytes: 16)
    let items = try await discover("xcode.derivedData", in: home)
    #expect(names(items) == ["A-x", "B-y"])
    let derivedData = home.url.appending(path: "Library/Developer/Xcode/DerivedData", directoryHint: .isDirectory)
    #expect(items.allSatisfy { $0.url.deletingLastPathComponent().path == derivedData.path })
}

@Test func fixedRulesSkipMissingPaths() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file(".npm/_cacache/index-v5/aa", bytes: 16)
    let npm = try await discover("cache.npm", in: home)
    #expect(npm.map(\.displayName) == [".npm/_cacache"])
    #expect(npm.first?.url.path == home.url.appending(path: ".npm/_cacache").path)
    let yarn = try await discover("cache.yarn", in: home)
    #expect(yarn.isEmpty)
}

@Test func fixedRulesReturnEveryExistingPath() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file(".npm/_cacache/a", bytes: 16)
    try home.file(".npm/_npx/b", bytes: 16)
    try home.file("Library/pnpm/store/v3/c", bytes: 16)
    try home.file("Library/Caches/pnpm/d", bytes: 16)
    try home.file(".bun/install/cache/e", bytes: 16)
    try home.file("Library/Caches/Yarn/f", bytes: 16)
    // Fixed paths are named by their path below home, because bare names like `store` or `cache` are ambiguous.
    #expect(names(try await discover("cache.npm", in: home)) == [".npm/_cacache", ".npm/_npx"])
    #expect(names(try await discover("cache.pnpm", in: home)) == ["Library/Caches/pnpm", "Library/pnpm/store"])
    #expect(names(try await discover("cache.bun", in: home)) == [".bun/install/cache"])
    #expect(names(try await discover("cache.yarn", in: home)) == ["Library/Caches/Yarn"])
}

@Test func toolCachesYieldOneItemPerExistingPath() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Library/Caches/Homebrew/downloads/x", bytes: 16)
    try home.file("Library/Caches/pip/y", bytes: 16)
    try home.file("Library/Caches/CocoaPods/z", bytes: 16)
    let items = try await discover("cache.tools", in: home)
    #expect(names(items) == ["Library/Caches/CocoaPods", "Library/Caches/Homebrew", "Library/Caches/pip"])
}

@Test func gradleCachesPointsAtGradleCaches() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file(".gradle/caches/modules-2/x", bytes: 16)
    try home.file(".gradle/wrapper/dists/gradle-8.5-bin/x", bytes: 16)
    let items = try await discover("gradle.caches", in: home)
    #expect(items.map(\.url.path) == [home.url.appending(path: ".gradle/caches").path])
    #expect(items.map(\.displayName) == [".gradle/caches"])
}

@Test func gradleKeepsNewestWrapper() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    for version in ["gradle-9.3.1-bin", "gradle-9.4.1-bin", "gradle-9.10.0-bin"] {
        try home.file(".gradle/wrapper/dists/\(version)/hash/x", bytes: 16)
    }
    let items = try await discover("gradle.wrappers", in: home)
    #expect(names(items) == ["gradle-9.3.1-bin", "gradle-9.4.1-bin"])
}

@Test func gradleWrappersReturnNothingForOneOrNoWrapper() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    #expect(try await discover("gradle.wrappers", in: home).isEmpty)
    try home.file(".gradle/wrapper/dists/gradle-8.5-bin/hash/x", bytes: 16)
    #expect(try await discover("gradle.wrappers", in: home).isEmpty)
}

@Test func deviceSupportYieldsPathsWithSpacesCommasAndParentheses() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let name = "iPhone14,5 27.0.1 (24A446)"
    try home.file("Library/Developer/Xcode/iOS DeviceSupport/\(name)/Symbols/x", bytes: 16)
    let items = try await discover("xcode.deviceSupport", in: home)
    #expect(items.map(\.displayName) == [name])
    let expected = home.url.appending(path: "Library/Developer/Xcode/iOS DeviceSupport/\(name)", directoryHint: .isDirectory)
    #expect(items.first?.url.path == expected.path)
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: try #require(items.first).url.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
}

@Test func archivesFindsXcarchives() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Library/Developer/Xcode/Archives/2026-10-01/App 1.xcarchive/Info.plist", bytes: 16)
    let items = try await discover("xcode.archives", in: home)
    #expect(items.map(\.displayName) == ["App 1.xcarchive"])
}

@Test func archivesIgnoreOtherFoldersAndDoNotEnterBundles() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let archives = "Library/Developer/Xcode/Archives"
    try home.file("\(archives)/2026-10-01/A.xcarchive/Products/Applications/Nested.xcarchive/x", bytes: 16)
    try home.file("\(archives)/2026-10-02/B.xcarchive/Info.plist", bytes: 16)
    try home.file("\(archives)/2026-10-02/notes.txt", bytes: 16)
    try home.file("\(archives)/2026-10-03/deeper/C.xcarchive/Info.plist", bytes: 16)
    try home.file("\(archives)/Loose.xcarchive/Info.plist", bytes: 16)
    let items = try await discover("xcode.archives", in: home)
    // Two levels deep: a bundle straight in Archives counts, one under a date folder counts,
    // one a third level down does not, and nothing inside a bundle is looked at.
    #expect(names(items) == ["A.xcarchive", "B.xcarchive", "Loose.xcarchive"])
}

@Test func archivesDoNotLookInsideABundleOrCountPlainFiles() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    // `Inner.xcarchive` is only two levels deep, so the depth limit alone would not exclude it:
    // it must stay hidden because it is inside a bundle.
    try home.file("Library/Developer/Xcode/Archives/Loose.xcarchive/Inner.xcarchive/Info.plist", bytes: 16)
    try home.file("Library/Developer/Xcode/Archives/2026-10-01/NotABundle.xcarchive", bytes: 16)
    let items = try await discover("xcode.archives", in: home)
    #expect(items.map(\.displayName) == ["Loose.xcarchive"])
}

@Test func strayFilesInChildFoldersAreNotItems() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let derivedData = "Library/Developer/Xcode/DerivedData"
    let deviceSupport = "Library/Developer/Xcode/iOS DeviceSupport"
    try home.file("\(derivedData)/.DS_Store", bytes: 16)
    try home.file("\(derivedData)/App-1/x", bytes: 16)
    try home.file("\(deviceSupport)/.DS_Store", bytes: 16)
    try home.file("\(deviceSupport)/iPhone14,5 27.0.1 (24A446)/x", bytes: 16)
    try home.file(".gradle/wrapper/dists/.DS_Store", bytes: 16)
    try home.file(".gradle/wrapper/dists/gradle-8.5-bin/x", bytes: 16)
    try home.file(".gradle/wrapper/dists/gradle-9.4.1-bin/x", bytes: 16)

    #expect(names(try await discover("xcode.derivedData", in: home)) == ["App-1"])
    #expect(names(try await discover("xcode.deviceSupport", in: home)) == ["iPhone14,5 27.0.1 (24A446)"])
    #expect(names(try await discover("gradle.wrappers", in: home)) == ["gradle-8.5-bin"])
}

@Test func gradleWrappersWithOnlyAStrayFileAndOneWrapperReturnNothing() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file(".gradle/wrapper/dists/.DS_Store", bytes: 16)
    try home.file(".gradle/wrapper/dists/gradle-8.5-bin/x", bytes: 16)
    #expect(try await discover("gradle.wrappers", in: home).isEmpty)
}

@Test func strayFileNamedAboveTheWrappersDoesNotBecomeTheNewest() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    // A file that sorts after every `gradle-…` name must not hide the real newest wrapper.
    try home.file(".gradle/wrapper/dists/zz-notes.txt", bytes: 16)
    try home.file(".gradle/wrapper/dists/gradle-8.5-bin/x", bytes: 16)
    try home.file(".gradle/wrapper/dists/gradle-9.4.1-bin/x", bytes: 16)
    #expect(names(try await discover("gradle.wrappers", in: home)) == ["gradle-8.5-bin"])
}

@Test func strayFolderInGradleDistsIsNeitherTheNewestNorAnItem() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    // Only `gradle-*` folders are wrapper versions. A stray folder that sorts above them must not hide the real
    // newest wrapper, and it is not offered for deletion either: nothing says what is in it.
    try home.file(".gradle/wrapper/dists/zz-tmp/x", bytes: 16)
    try home.file(".gradle/wrapper/dists/tmp/x", bytes: 16)
    try home.file(".gradle/wrapper/dists/gradle-8.5-bin/x", bytes: 16)
    try home.file(".gradle/wrapper/dists/gradle-9.4.1-bin/x", bytes: 16)
    #expect(names(try await discover("gradle.wrappers", in: home)) == ["gradle-8.5-bin"])
}

@Test func gradleDistsWithOneWrapperAndStrayFoldersReturnNothing() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file(".gradle/wrapper/dists/99-stray/x", bytes: 16)
    try home.file(".gradle/wrapper/dists/gradle-8.5-bin/x", bytes: 16)
    #expect(try await discover("gradle.wrappers", in: home).isEmpty)
}

@Test func lastActivityIsContentModificationDate() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let modified = Date(timeIntervalSince1970: 1_700_000_000)
    let file = try home.file("Library/Developer/Xcode/DerivedData/A-x/a.o", bytes: 16)
    try FileManager.default.setAttributes(
        [.modificationDate: modified], ofItemAtPath: file.deletingLastPathComponent().path
    )
    let items = try await discover("xcode.derivedData", in: home)
    let item = try #require(items.first)
    let expected = try #require(
        try item.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    )
    #expect(item.lastActivity == expected)
    #expect(abs(expected.timeIntervalSince(modified)) < 1)
}

@Test func discoverySkipsSymlinks() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let outside = try home.dir("Elsewhere/real")
    // A symlinked fixed path, a symlinked child, and a symlinked date folder are never followed.
    try home.dir(".npm")
    try home.symlink(".npm/_cacache", to: outside)
    try home.file(".npm/_npx/x", bytes: 16)
    try home.file("Library/Developer/Xcode/DerivedData/Real-1/x", bytes: 16)
    try home.symlink("Library/Developer/Xcode/DerivedData/Linked-2", to: outside)
    try home.dir("Library/Developer/Xcode/Archives")
    try home.symlink("Library/Developer/Xcode/Archives/2026-10-05", to: outside)
    try home.file("Elsewhere/real/Escaped.xcarchive/Info.plist", bytes: 16)

    #expect(names(try await discover("cache.npm", in: home)) == [".npm/_npx"])
    #expect(names(try await discover("xcode.derivedData", in: home)) == ["Real-1"])
    #expect(try await discover("xcode.archives", in: home).isEmpty)
}

@Test func discoveryDoesNotFollowASymlinkedParentFolder() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let outside = try home.dir("Elsewhere/DerivedData")
    try home.file("Elsewhere/DerivedData/Escaped-1/x", bytes: 16)
    try home.dir("Library/Developer/Xcode")
    try home.symlink("Library/Developer/Xcode/DerivedData", to: outside)
    // The folder itself is a link, so there is nothing to list below it.
    #expect(try await discover("xcode.derivedData", in: home).isEmpty)
}

@Test func discoveredItemDefaults() {
    let item = DiscoveredItem(url: URL(filePath: "/tmp/x"), displayName: "x")
    #expect(item.detail == nil)
    #expect(item.lastActivity == nil)
    #expect(item.badges.isEmpty)
    #expect(item.simulatorUDID == nil)
    #expect(!item.isUnavailable)
}

// MARK: - Locks

@Test func appLockEvaluates() {
    let running = FakeProcessInspector(bundleIDs: ["com.apple.dt.Xcode"])
    #expect(LockCondition.xcode.evaluate(running) == .appRunning(name: "Xcode"))
    #expect(LockCondition.xcode.evaluate(FakeProcessInspector()) == nil)
    #expect(LockCondition.androidStudio.evaluate(running) == nil)
}

@Test func namedLocksUseTheDocumentedIdentifiers() {
    #expect(LockCondition.xcode == .appRunning(bundleID: "com.apple.dt.Xcode", name: "Xcode"))
    #expect(LockCondition.androidStudio == .appRunning(bundleID: "com.google.android.studio", name: "Android Studio"))
    #expect(LockCondition.simulator == .appRunning(bundleID: "com.apple.iphonesimulator", name: "Simulator"))
    #expect(LockCondition.gradleDaemon == .processRunning(executable: "java", argumentContains: "GradleDaemon", name: "Gradle daemon"))
    #expect(LockCondition.emulator == .processRunning(executable: "qemu-system-aarch64", argumentContains: nil, name: "Android emulator"))
}

@Test func processLockMatchesArguments() {
    let daemon = RunningProcess(
        executable: "java",
        arguments: ["-cp", "x", "org.gradle.launcher.daemon.bootstrap.GradleDaemon"]
    )
    let plainJava = RunningProcess(executable: "java", arguments: ["-jar", "app.jar"])
    #expect(LockCondition.gradleDaemon.evaluate(FakeProcessInspector(processes: [daemon])) == .processRunning(name: "Gradle daemon"))
    #expect(LockCondition.gradleDaemon.evaluate(FakeProcessInspector(processes: [plainJava])) == nil)
    #expect(LockCondition.gradleDaemon.evaluate(FakeProcessInspector()) == nil)
}

@Test func processLockMatchesFullExecutablePathButNotOtherPrograms() {
    let daemonByPath = RunningProcess(
        executable: "/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home/bin/java",
        arguments: ["org.gradle.launcher.daemon.bootstrap.GradleDaemon"]
    )
    let notJava = RunningProcess(executable: "python3", arguments: ["GradleDaemon"])
    #expect(LockCondition.gradleDaemon.evaluate(FakeProcessInspector(processes: [daemonByPath])) != nil)
    #expect(LockCondition.gradleDaemon.evaluate(FakeProcessInspector(processes: [notJava])) == nil)
}

@Test func processLockWithoutArgumentFilterMatchesByExecutable() {
    let emulator = RunningProcess(executable: "qemu-system-aarch64", arguments: ["-avd", "Pixel_8"])
    #expect(LockCondition.emulator.evaluate(FakeProcessInspector(processes: [emulator])) == .processRunning(name: "Android emulator"))
    #expect(LockCondition.emulator.evaluate(FakeProcessInspector()) == nil)
}

// MARK: - Catalog

@Test func catalogIDsAreUnique() {
    #expect(Set(Catalog.all().map(\.id)).count == Catalog.all().count)
}

@Test func catalogLookupFindsRulesByID() {
    #expect(Catalog.rule(id: "xcode.derivedData")?.title == "Xcode DerivedData")
    #expect(Catalog.rule(id: "no.such.rule") == nil)
}

@Test func ruleGroupsAreInDisplayOrder() {
    #expect(RuleGroup.allCases.map(\.title) == [
        "Xcode DerivedData", "node_modules", "Package caches", "Project builds", "Gradle caches",
        "Other tool caches", "iOS Simulators", "Old Android SDKs", "iOS DeviceSupport",
        "Xcode Archives", "Android emulators",
    ])
}

@Test func catalogMatchesTheRuleTable() throws {
    // id → group, method, default selection, locks, title (spec §5.3).
    let expected: [(String, RuleGroup, CleanMethod, DefaultSelection, [LockCondition], String)] = [
        ("xcode.derivedData", .xcodeDerivedData, .delete, .always, [.xcode], "Xcode DerivedData"),
        ("cache.npm", .packageCaches, .delete, .always, [], "npm"),
        ("cache.pnpm", .packageCaches, .delete, .always, [], "pnpm"),
        ("cache.yarn", .packageCaches, .delete, .always, [], "Yarn"),
        ("cache.bun", .packageCaches, .delete, .always, [], "Bun"),
        ("gradle.caches", .gradle, .delete, .always, [.androidStudio, .gradleDaemon], "Gradle caches"),
        ("gradle.wrappers", .gradle, .delete, .always, [.gradleDaemon], "Old wrappers"),
        ("cache.tools", .toolCaches, .delete, .always, [], "Other tool caches"),
        ("xcode.deviceSupport", .deviceSupport, .trash, .never, [.xcode], "iOS DeviceSupport"),
        ("xcode.archives", .archives, .trash, .never, [], "Xcode Archives"),
    ]
    for (id, group, method, selection, locks, title) in expected {
        let rule = try #require(Catalog.rule(id: id), "missing rule \(id)")
        #expect(rule.group == group, "\(id) group")
        #expect(rule.method == method, "\(id) method")
        #expect(rule.defaultSelection == selection, "\(id) default selection")
        #expect(rule.locks == locks, "\(id) locks")
        #expect(rule.title == title, "\(id) title")
        #expect(!rule.regenerateHint.isEmpty, "\(id) regenerate hint")
    }
}

@Test func managedRootsAreTheDeveloperJunkFolders() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let roots = Catalog.managedRoots(home: home.url).map(\.path)
    #expect(roots == [".android", ".gradle", ".npm", ".bun/install/cache", "Library/pnpm"].map {
        home.url.appending(path: $0, directoryHint: .isDirectory).path
    })
}

// MARK: - Help text (spec §9)

private func hint(_ ruleID: String) throws -> String {
    try #require(Catalog.rule(id: ruleID)).regenerateHint
}

@Test func everyRuleHasAShortHint() {
    for rule in Catalog.all() {
        #expect(!rule.regenerateHint.isEmpty, "\(rule.id)")
        // Shown on one line of the table, so it has to stay short.
        #expect(rule.regenerateHint.count <= 105, "\(rule.id): \(rule.regenerateHint.count) characters")
        #expect(!rule.regenerateHint.hasSuffix("."), "\(rule.id)")
    }
}

@Test func hintsWarnWhereDataIsLostForGood() throws {
    #expect(try hint("xcode.archives").hasPrefix("Cannot be rebuilt"))
    #expect(try hint("xcode.archives").localizedCaseInsensitiveContains("lost for good"))
    #expect(try hint("sim.devices").contains("apps and data"))
    #expect(try hint("sim.devices").localizedCaseInsensitiveContains("deleted for good"))
    #expect(try hint("android.avd").contains("apps and data are lost"))
}

@Test func pnpmHintSaysTheStoreMayFreeMuchLessThanShown() throws {
    let pnpm = try hint("cache.pnpm")
    #expect(pnpm.contains("much less than shown"))
    #expect(pnpm.contains("node_modules"))
}

@Test func hintLinesOfOneRuleAreItsHint() throws {
    #expect(Catalog.hintLines(forRules: ["xcode.archives"]) == [try hint("xcode.archives")])
    #expect(Catalog.hintLines(forRules: []) == [])
    #expect(Catalog.hintLines(forRules: ["no.such.rule"]) == [])
}

@Test func rulesThatShareAHintGiveOneLineWithoutTitles() throws {
    let builds = Catalog.hintLines(forRules: ["build.web", "build.android", "build.ios"])
    #expect(builds == [try hint("build.android")])
}

@Test func rulesWithDifferentHintsGiveOneTitledLineEachInCatalogOrder() throws {
    // Repeated IDs and any order: what counts is which rules are there.
    let caches = Catalog.hintLines(forRules: ["cache.bun", "cache.yarn", "cache.pnpm", "cache.npm", "cache.bun"])
    #expect(caches == [
        "npm: \(try hint("cache.npm"))",
        "pnpm: \(try hint("cache.pnpm"))",
        "Yarn · Bun: \(try hint("cache.yarn"))",
    ])
    let builds = Catalog.hintLines(forRules: ["build.pods", "build.android", "build.web"])
    #expect(builds == ["Project builds: \(try hint("build.android"))", "Pods: \(try hint("build.pods"))"])
}
