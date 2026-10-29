import Foundation
import Testing
import CleanoriCore

private func discover(
    _ ruleID: String, in home: TempHome, simulators: any SimulatorControl = FakeSimulatorControl()
) async throws -> [DiscoveredItem] {
    let rule = try #require(Catalog.rule(id: ruleID))
    return try await rule.discover(.test(home: home, simulators: simulators))
}

private func names(_ items: [DiscoveredItem]) -> [String] {
    items.map(\.displayName).sorted()
}

/// An AVD folder like the ones Android Studio makes, with a `config.ini` that points at `sysdir`.
@discardableResult
private func makeAVD(_ name: String, sysdir: String?, in home: TempHome) throws -> URL {
    let dir = try home.dir(".android/avd/\(name).avd")
    var lines = ["AvdId=\(name)", "PlayStore.enabled=true", "abi.type=arm64-v8a", "hw.cpu.arch=arm64"]
    if let sysdir { lines.append("image.sysdir.1=\(sysdir)") }
    lines.append("tag.id=google_apis_playstore")
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: dir.appending(path: "config.ini"))
    return dir
}

private let sdk = "Library/Android/sdk"

// MARK: - android.ndk

@Test func ndkKeepsHighestVersion() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    for version in ["27.0.12077973", "27.1.12297006", "27.2.12479018"] {
        try home.file("\(sdk)/ndk/\(version)/toolchains/x", bytes: 16)
    }
    let items = try await discover("android.ndk", in: home)
    #expect(names(items) == ["27.0.12077973", "27.1.12297006"])
    #expect(items.allSatisfy { $0.url.deletingLastPathComponent().path == home.url.appending(path: "\(sdk)/ndk").path })
}

@Test func ndkComparesVersionsNumerically() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    for version in ["26.1.10909125", "27.9.1", "27.10.0"] {
        try home.dir("\(sdk)/ndk/\(version)")
    }
    // As text "27.9.1" sorts above "27.10.0"; as numbers 27.10.0 is the newest.
    #expect(names(try await discover("android.ndk", in: home)) == ["26.1.10909125", "27.9.1"])
}

@Test func ndkNeverOffersTheOnlyVersionOrAStrayFile() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    #expect(try await discover("android.ndk", in: home).isEmpty) // no ndk folder at all
    try home.dir("\(sdk)/ndk/27.2.12479018")
    try home.file("\(sdk)/ndk/.DS_Store", bytes: 16)
    #expect(try await discover("android.ndk", in: home).isEmpty)
}

// MARK: - android.systemImages

@Test func systemImageUnusedDetection() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("\(sdk)/system-images/android-33/google_apis_playstore/arm64-v8a/system.img", bytes: 16)
    try home.file("\(sdk)/system-images/android-36.1/google_apis_playstore/arm64-v8a/system.img", bytes: 16)
    try makeAVD("Pixel_10_Pro", sysdir: "system-images/android-36.1/google_apis_playstore/arm64-v8a/", in: home)

    let items = try await discover("android.systemImages", in: home)
    let old = try #require(items.first { $0.displayName == "android-33 · google_apis_playstore" })
    let current = try #require(items.first { $0.displayName == "android-36.1 · google_apis_playstore" })
    #expect(items.count == 2)
    #expect(old.badges == [.unused])
    #expect(old.detail == "unused")
    #expect(current.badges.isEmpty)
    #expect(current.detail == nil)
    #expect(old.url.path == home.url.appending(path: "\(sdk)/system-images/android-33/google_apis_playstore").path)
}

@Test func systemImageTagThatIsAPrefixOfAnotherDoesNotMatch() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.dir("\(sdk)/system-images/android-36.1/google_apis_playstore")
    try home.dir("\(sdk)/system-images/android-36.1/google_apis_playstore_ps16k")
    try makeAVD("Phone", sysdir: "system-images/android-36.1/google_apis_playstore/arm64-v8a/", in: home)

    var items = try await discover("android.systemImages", in: home)
    #expect(items.first { $0.displayName.hasSuffix("google_apis_playstore") }?.badges == [])
    #expect(items.first { $0.displayName.hasSuffix("google_apis_playstore_ps16k") }?.badges == [.unused])

    // And the other way around: an AVD on the 16k image does not use the plain one.
    try makeAVD("Phone", sysdir: "system-images/android-36.1/google_apis_playstore_ps16k/arm64-v8a/", in: home)
    items = try await discover("android.systemImages", in: home)
    #expect(items.first { $0.displayName.hasSuffix("google_apis_playstore") }?.badges == [.unused])
    #expect(items.first { $0.displayName.hasSuffix("google_apis_playstore_ps16k") }?.badges == [])
}

@Test func systemImageApiThatIsAPrefixOfAnotherDoesNotMatch() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.dir("\(sdk)/system-images/android-36/default")
    try home.dir("\(sdk)/system-images/android-36.1/default")
    try makeAVD("Phone", sysdir: "system-images/android-36.1/default/arm64-v8a/", in: home)
    let items = try await discover("android.systemImages", in: home)
    #expect(items.first { $0.displayName == "android-36 · default" }?.badges == [.unused])
    #expect(items.first { $0.displayName == "android-36.1 · default" }?.badges == [])
}

@Test func systemImagesAreUnusedWithoutAnyEmulator() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.dir("\(sdk)/system-images/android-29/google_apis_playstore")
    try home.dir("\(sdk)/system-images/android-36/default")
    let items = try await discover("android.systemImages", in: home)
    #expect(names(items) == ["android-29 · google_apis_playstore", "android-36 · default"])
    #expect(items.allSatisfy { $0.badges == [.unused] && $0.detail == "unused" })
}

@Test func systemImageReferencesFromAnyEmulatorCount() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.dir("\(sdk)/system-images/android-29/google_apis_playstore")
    try home.dir("\(sdk)/system-images/android-30/google_apis_playstore")
    try home.dir("\(sdk)/system-images/android-33/google_apis_playstore")
    try home.dir("\(sdk)/system-images/android-36/default")
    // An absolute path, a path without the trailing slash, an emulator without image.sysdir.1, and a plain one.
    try makeAVD("A", sysdir: "\(home.url.path)/\(sdk)/system-images/android-29/google_apis_playstore/arm64-v8a/", in: home)
    try makeAVD("B", sysdir: "system-images/android-30/google_apis_playstore/arm64-v8a", in: home)
    try makeAVD("C", sysdir: nil, in: home)
    try makeAVD("D", sysdir: "system-images/android-36/default/arm64-v8a/", in: home)

    let items = try await discover("android.systemImages", in: home)
    #expect(items.filter { $0.badges == [.unused] }.map(\.displayName) == ["android-33 · google_apis_playstore"])
}

@Test func systemImageIgnoresOtherConfigKeysAndFilesThatAreNotAVDConfigs() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.dir("\(sdk)/system-images/android-33/google_apis_playstore")
    // The key must be image.sysdir.1; other keys that merely mention the image do not count.
    let dir = try home.dir(".android/avd/Other.avd")
    let text = "avd.ini.displayname=system-images/android-33/google_apis_playstore/arm64-v8a/\n"
    try Data(text.utf8).write(to: dir.appending(path: "config.ini"))
    // A stray .ini next to the AVD folders, and an AVD folder with no config.ini at all.
    try Data("path=x\n".utf8).write(to: home.url.appending(path: ".android/avd/Other.ini"))
    try home.dir(".android/avd/Empty.avd")
    let items = try await discover("android.systemImages", in: home)
    #expect(items.map(\.badges) == [[.unused]])
}

@Test func systemImageUsedByALinkedEmulatorIsNotUnused() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.dir("\(sdk)/system-images/android-33/google_apis_playstore")
    try home.dir("\(sdk)/system-images/android-36/default")
    // The emulator lives on another disk and is linked into ~/.android/avd; it still needs its image.
    let dir = try home.dir("elsewhere/Phone.avd")
    try Data("image.sysdir.1=system-images/android-33/google_apis_playstore/arm64-v8a/\n".utf8)
        .write(to: dir.appending(path: "config.ini"))
    try home.symlink(".android/avd/Phone.avd", to: dir)

    let items = try await discover("android.systemImages", in: home)
    #expect(items.first { $0.displayName == "android-33 · google_apis_playstore" }?.badges == [])
    #expect(items.first { $0.displayName == "android-36 · default" }?.badges == [.unused])
}

@Test func systemImagesSkipStrayFilesAndSymlinks() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.dir("\(sdk)/system-images/android-33/google_apis_playstore")
    try home.file("\(sdk)/system-images/.DS_Store", bytes: 16)
    try home.file("\(sdk)/system-images/android-33/.DS_Store", bytes: 16)
    let elsewhere = try home.dir("elsewhere/images")
    try home.symlink("\(sdk)/system-images/android-33/linked", to: elsewhere)
    try home.symlink("\(sdk)/system-images/android-34", to: elsewhere)
    let items = try await discover("android.systemImages", in: home)
    #expect(names(items) == ["android-33 · google_apis_playstore"])
}

@Test func systemImagesReturnNothingWithoutAnSDK() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    #expect(try await discover("android.systemImages", in: home).isEmpty)
}

// MARK: - android.avd

@Test func avdListsEachEmulator() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file(".android/avd/Pixel_10_Pro.avd/userdata-qemu.img", bytes: 16)
    let items = try await discover("android.avd", in: home)
    #expect(items.count == 1)
    #expect(items.first?.displayName == "Pixel_10_Pro.avd")
    #expect(items.first?.url.path == home.url.appending(path: ".android/avd/Pixel_10_Pro.avd").path)
}

@Test func avdIgnoresIniFilesOtherFoldersAndSymlinks() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file(".android/avd/A.avd/userdata-qemu.img", bytes: 16)
    try home.file(".android/avd/B.avd/userdata-qemu.img", bytes: 16)
    try home.file(".android/avd/A.ini", bytes: 16)           // the pointer file Android keeps beside each AVD
    try home.file(".android/avd/.DS_Store", bytes: 16)
    try home.dir(".android/avd/not-an-emulator")
    try home.symlink(".android/avd/Linked.avd", to: try home.dir("elsewhere/Linked.avd"))
    #expect(names(try await discover("android.avd", in: home)) == ["A.avd", "B.avd"])
}

@Test func avdReturnsNothingWithoutEmulators() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    #expect(try await discover("android.avd", in: home).isEmpty)
}

// MARK: - sim.devices

private func device(
    _ udid: String, _ name: String, _ runtime: String, available: Bool = true, in home: TempHome
) -> SimulatorDevice {
    SimulatorDevice(
        udid: udid, name: name, runtime: runtime, isAvailable: available,
        dataURL: home.url.appending(path: "Library/Developer/CoreSimulator/Devices/\(udid)/data", directoryHint: .isDirectory)
    )
}

@Test func simulatorsFromSimctl() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let ok = device("AAAA-1111", "iPhone 16", "iOS 26.3", in: home)
    let gone = device("BBBB-2222", "iPhone 12", "iOS 15.5", available: false, in: home)
    let items = try await discover("sim.devices", in: home, simulators: FakeSimulatorControl(devices: [ok, gone]))

    #expect(items.count == 2)
    let first = try #require(items.first { $0.simulatorUDID == "AAAA-1111" })
    let second = try #require(items.first { $0.simulatorUDID == "BBBB-2222" })
    #expect(first.displayName == "iPhone 16 (iOS 26.3)")
    #expect(first.url == ok.dataURL)
    #expect(!first.isUnavailable)
    #expect(second.displayName == "iPhone 12 (iOS 15.5)")
    #expect(second.url == gone.dataURL)
    #expect(second.isUnavailable)
}

@Test func simulatorsWithoutDevicesYieldNothing() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    #expect(try await discover("sim.devices", in: home).isEmpty)
}

@Test func simctlFailureYieldsNoItems() async throws {
    struct SimctlFailed: Error {}
    let home = try TempHome(); defer { home.cleanup() }
    let items = try await discover("sim.devices", in: home, simulators: FakeSimulatorControl(throwing: SimctlFailed()))
    #expect(items.isEmpty)
}

@Test func simulatorDiscoveryPassesCancellationOn() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    await #expect(throws: CancellationError.self) {
        _ = try await discover("sim.devices", in: home, simulators: FakeSimulatorControl(throwing: CancellationError()))
    }
}

// MARK: - Catalog rows

@Test func androidAndSimulatorRulesMatchTheRuleTable() throws {
    // id → group, method, default selection, locks, title (spec §5.3).
    let expected: [(String, RuleGroup, CleanMethod, DefaultSelection, [LockCondition], String)] = [
        ("sim.devices", .simulators, .simctl, .ifUnavailable, [.simulator], "iOS Simulators"),
        ("android.ndk", .androidSDK, .trash, .never, [.androidStudio], "NDK"),
        ("android.systemImages", .androidSDK, .trash, .never, [.androidStudio], "System images"),
        ("android.avd", .androidEmulators, .trash, .never, [.emulator], "Android emulators"),
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

@Test func catalogListsRulesInGroupDisplayOrder() {
    let order = RuleGroup.allCases
    let positions = Catalog.all().compactMap { order.firstIndex(of: $0.group) }
    #expect(positions == positions.sorted())
}
