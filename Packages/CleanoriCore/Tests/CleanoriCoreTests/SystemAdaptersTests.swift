import Foundation
import Testing
import CleanoriCore

// MARK: - simctl JSON

private let devicesRoot = URL(filePath: "/tmp/CoreSimulator/Devices", directoryHint: .isDirectory)

private func fixtureData(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private let iOS26 = "com.apple.CoreSimulator.SimRuntime.iOS-26-3"

/// A `simctl list devices --json` document with one device per runtime key.
private func listing(_ devices: [(runtimeKey: String, udid: String)]) -> Data {
    var byRuntime: [String: [String]] = [:]
    for (key, udid) in devices {
        byRuntime[key, default: []].append(#"{"udid": "\#(udid)", "name": "Device \#(udid)", "isAvailable": true}"#)
    }
    let body = byRuntime.map { #""\#($0.key)": [\#($0.value.joined(separator: ","))]"# }.joined(separator: ",")
    return Data(#"{"devices": {\#(body)}}"#.utf8)
}

@Test func parsesSimctlJSON() throws {
    let devices = try XcrunSimulatorControl.parseDevices(try fixtureData("simctl-devices"), devicesRoot: devicesRoot)
    #expect(devices == [
        SimulatorDevice(
            udid: "ABC", name: "iPhone 17", runtime: "iOS 26.3", isAvailable: false,
            dataURL: devicesRoot.appending(path: "ABC", directoryHint: .isDirectory)
        ),
    ])
}

@Test func simctlRuntimeKeysBecomeDisplayNames() throws {
    let prefix = "com.apple.CoreSimulator.SimRuntime."
    let cases: [(key: String, display: String)] = [
        (prefix + "iOS-26-3", "iOS 26.3"),
        (prefix + "iOS-26", "iOS 26"),               // no minor version
        (prefix + "iOS-17-0-1", "iOS 17.0.1"),       // patch version
        (prefix + "watchOS-11-0", "watchOS 11.0"),
        (prefix + "tvOS-18-2", "tvOS 18.2"),
        (prefix + "xrOS-2-0", "visionOS 2.0"),       // the runtime id still says xrOS
        (prefix + "visionOS-26-0", "visionOS 26.0"),
        (prefix + "futureOS-3-1", "futureOS 3.1"),   // a platform this code has never heard of
        (prefix + "iOS-26-3-beta", "iOS-26-3-beta"), // not a plain version: shown as simctl names it
        (prefix + "Weird", "Weird"),
        ("some runtime", "some runtime"),            // not a CoreSimulator identifier at all
    ]
    for (key, display) in cases {
        let devices = try XcrunSimulatorControl.parseDevices(listing([(key, "U")]), devicesRoot: devicesRoot)
        #expect(devices.map(\.runtime) == [display], "\(key)")
    }
}

@Test func simctlWithNoDevicesGivesNoDevices() throws {
    for json in [#"{"devices": {}}"#, #"{"devices": {"\#(iOS26)": []}}"#] {
        #expect(try XcrunSimulatorControl.parseDevices(Data(json.utf8), devicesRoot: devicesRoot).isEmpty, "\(json)")
    }
}

@Test func simctlDevicesComeBackInRuntimeOrder() throws {
    let prefix = "com.apple.CoreSimulator.SimRuntime."
    let json = listing([
        (prefix + "tvOS-18-2", "T"), (prefix + "iOS-26-3", "I"), (prefix + "iOS-9-0", "N"), (prefix + "iOS-26-3", "J"),
    ])
    let devices = try XcrunSimulatorControl.parseDevices(json, devicesRoot: devicesRoot)
    #expect(devices.map(\.udid) == ["N", "I", "J", "T"])
}

@Test func simctlJSONThatIsNotAListingThrows() {
    for bad in ["", "not json", "[]", #"{"runtimes": []}"#, #"{"devices": []}"#, #"{"devices": {"k": "x"}}"#] {
        #expect(throws: (any Error).self, "\(bad)") {
            try XcrunSimulatorControl.parseDevices(Data(bad.utf8), devicesRoot: devicesRoot)
        }
    }
}

@Test func simctlEntryWithoutUDIDOrNameIsSkippedAndTheRestKept() throws {
    let json = Data("""
    {"devices": {"\(iOS26)": [
      {"name": "No UDID", "isAvailable": true},
      {"udid": "NONAME", "isAvailable": true},
      {"udid": "", "name": "Empty UDID", "isAvailable": true},
      {"udid": "GOOD", "name": "Good", "isAvailable": true}
    ]}}
    """.utf8)
    let devices = try XcrunSimulatorControl.parseDevices(json, devicesRoot: devicesRoot)
    #expect(devices.map(\.udid) == ["GOOD"])
}

@Test func simctlDeviceWithoutAvailabilityIsTreatedAsAvailable() throws {
    // Unavailable devices are selected for deletion by default, so a missing flag must not mean "unavailable".
    let json = Data(#"{"devices": {"\#(iOS26)": [{"udid": "A", "name": "A"}]}}"#.utf8)
    #expect(try XcrunSimulatorControl.parseDevices(json, devicesRoot: devicesRoot).map(\.isAvailable) == [true])
}

// MARK: - KERN_PROCARGS2 buffer

/// `argc` as the kernel writes it (a host-order `Int32`) followed by `rest`.
private func procArgs(argc: Int32, _ rest: String) -> Data {
    var data = withUnsafeBytes(of: argc) { Data($0) }
    data.append(contentsOf: Array(rest.utf8))
    return data
}

@Test func parsesProcArgs() {
    let data = procArgs(argc: 2, "/usr/bin/java\0\0\0java\0GradleDaemon\0")
    #expect(SystemProcessInspector.parseProcArgs(data)
        == RunningProcess(executable: "java", arguments: ["GradleDaemon"]))
}

@Test func procArgsExcludeArgvZeroAndTheEnvironment() {
    let data = procArgs(
        argc: 3, "/opt/x/bin/qemu-system-aarch64\0\0\0\0qemu\0-m\0 4096\0PATH=/usr/bin\0HOME=/Users/x\0"
    )
    #expect(SystemProcessInspector.parseProcArgs(data) == RunningProcess(
        executable: "qemu-system-aarch64", arguments: ["-m", " 4096"]
    ))
    // argc 1: only argv[0].
    #expect(SystemProcessInspector.parseProcArgs(procArgs(argc: 1, "/bin/ls\0\0ls\0HOME=/x\0"))
        == RunningProcess(executable: "ls", arguments: []))
}

@Test func procArgsKeepEmptyAndNonASCIIArguments() {
    let data = procArgs(argc: 4, "/usr/bin/java\0\0\0java\0\0Ünïcode ✓\0a b\0")
    #expect(SystemProcessInspector.parseProcArgs(data)?.arguments == ["", "Ünïcode ✓", "a b"])
}

@Test func procArgsWithNoUsablePathAreNil() {
    #expect(SystemProcessInspector.parseProcArgs(Data()) == nil)
    #expect(SystemProcessInspector.parseProcArgs(Data([2, 0, 0])) == nil)             // shorter than argc
    #expect(SystemProcessInspector.parseProcArgs(procArgs(argc: 2, "")) == nil)        // no exec path
    #expect(SystemProcessInspector.parseProcArgs(procArgs(argc: 2, "/usr/bin/ja")) == nil) // path cut off
    #expect(SystemProcessInspector.parseProcArgs(procArgs(argc: 2, "\0\0java\0x\0")) == nil) // empty path
    #expect(SystemProcessInspector.parseProcArgs(procArgs(argc: 2, "/\0\0java\0x\0")) == nil) // no program name
    #expect(SystemProcessInspector.parseProcArgs(procArgs(argc: -1, "/usr/bin/java\0\0java\0")) == nil)
}

@Test func procArgsKeepWhatIsCompleteWhenTheBufferIsCutShort() {
    // argc says 5, only argv[0] and one more are there.
    #expect(SystemProcessInspector.parseProcArgs(procArgs(argc: 5, "/usr/bin/java\0\0\0java\0GradleDaemon\0"))
        == RunningProcess(executable: "java", arguments: ["GradleDaemon"]))
    // Cut inside the second argument: the half-written one is dropped.
    #expect(SystemProcessInspector.parseProcArgs(procArgs(argc: 3, "/usr/bin/java\0\0\0java\0-Xmx1g\0Gradle"))
        == RunningProcess(executable: "java", arguments: ["-Xmx1g"]))
    // Only the path made it, or only the padding after it.
    #expect(SystemProcessInspector.parseProcArgs(procArgs(argc: 2, "/usr/bin/java\0"))
        == RunningProcess(executable: "java", arguments: []))
    #expect(SystemProcessInspector.parseProcArgs(procArgs(argc: 2, "/usr/bin/java\0\0\0\0"))
        == RunningProcess(executable: "java", arguments: []))
    // A huge argc is only an upper bound.
    #expect(SystemProcessInspector.parseProcArgs(procArgs(argc: .max, "/usr/bin/java\0\0java\0a\0"))
        == RunningProcess(executable: "java", arguments: ["a"]))
}

@Test func procArgsNeverReadPastAnyPrefixOfARealBuffer() {
    let full = procArgs(argc: 3, "/usr/bin/java\0\0\0java\0-Xmx1g\0GradleDaemon\0PATH=/bin\0")
    for length in 0...full.count {
        let cut = Data(full.prefix(length))
        let parsed = SystemProcessInspector.parseProcArgs(cut)
        // Whatever comes back is a prefix of the full answer.
        if let parsed {
            #expect(parsed.executable == "java")
            #expect(["-Xmx1g", "GradleDaemon"].starts(with: parsed.arguments))
        }
    }
}

// MARK: - Disk capacity

@Test func diskCapacityIsPositive() throws {
    let capacity = try DiskCapacity.current()
    #expect(capacity.total > 0)
    #expect(capacity.available >= 0)
    #expect(capacity.available <= capacity.total)
}

// MARK: - The live process inspector

@Test func liveInspectorSeesTheTestProcessAndItsArguments() throws {
    // This process is always readable, so it must be in the list, with argv[0] split off.
    let argv = CommandLine.arguments
    let name = try #require(argv.first?.split(separator: "/").last.map(String.init))
    let processes = SystemProcessInspector().runningProcesses()
    #expect(processes.count > 10)
    #expect(processes.contains(RunningProcess(executable: name, arguments: Array(argv.dropFirst()))))
}

@Test func liveInspectorSkipsProcessesItCannotReadWithoutFailing() {
    // launchd (pid 1) belongs to root: the sweep passes it by and still returns the user's own processes.
    let processes = SystemProcessInspector().runningProcesses()
    #expect(processes.allSatisfy { !$0.executable.isEmpty && !$0.executable.contains("/") })
}

@Test func liveInspectorReportsBundleIDsOfRunningApps() {
    // Which apps run depends on the machine; whatever comes back must be real identifiers.
    #expect(SystemProcessInspector().runningBundleIDs().allSatisfy { !$0.isEmpty })
}

// MARK: - xcrun, against a stand-in script (never the real simctl)

/// An executable shell script in `home` that stands in for `xcrun`. It is given the same arguments `xcrun`
/// would get, and records them one per line in `<script>.args`.
@discardableResult
private func fakeXcrun(_ body: String, in home: TempHome) throws -> URL {
    let url = home.url.appending(path: "fake-xcrun", directoryHint: .notDirectory)
    try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$0.args\"\n\(body)\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

/// The arguments the stand-in script was called with, or `nil` when it never ran.
private func recordedArguments(of script: URL) -> [String]? {
    guard let text = try? String(contentsOf: URL(filePath: script.path + ".args"), encoding: .utf8) else { return nil }
    return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

private let someUDID = "8F86859F-F9C0-46CD-8E6F-FF416EC7DCAC"

@Test func listDevicesRunsSimctlListAndParsesItsOutput() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let json = try home.file("devices.json", bytes: 0)
    try fixtureData("simctl-devices").write(to: json)
    let xcrun = try fakeXcrun("cat '\(json.path)'", in: home)

    let devices = try await XcrunSimulatorControl(devicesRoot: devicesRoot, executable: xcrun).listDevices()

    #expect(recordedArguments(of: xcrun) == ["simctl", "list", "devices", "--json"])
    #expect(devices.map(\.udid) == ["ABC"])
    #expect(devices.first?.dataURL == devicesRoot.appending(path: "ABC", directoryHint: .isDirectory))
}

@Test func listDevicesFailureReportsExitStatusAndStderr() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let xcrun = try fakeXcrun("echo 'xcrun: error: unable to find utility \"simctl\"' >&2\nexit 72", in: home)

    let error = await #expect(throws: XcrunError.self) {
        try await XcrunSimulatorControl(devicesRoot: devicesRoot, executable: xcrun).listDevices()
    }
    #expect(error == .failed(
        arguments: ["simctl", "list", "devices", "--json"], status: 72, signaled: false,
        stderr: "xcrun: error: unable to find utility \"simctl\"\n"
    ))
    let message = error?.localizedDescription ?? ""
    #expect(message.contains("exit status 72"))
    #expect(message.contains("unable to find utility"))
}

@Test func listDevicesRejectsOutputThatIsNotJSON() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let xcrun = try fakeXcrun("echo 'Xcode is not installed'", in: home)
    await #expect(throws: DecodingError.self) {
        try await XcrunSimulatorControl(devicesRoot: devicesRoot, executable: xcrun).listDevices()
    }
}

@Test(.timeLimit(.minutes(1)))
func listDevicesHandlesLargeOutputOnBothPipes() async throws {
    // 2 MB on stderr first and then a 2 MB listing on stdout. Reading either pipe to its end before the other
    // would leave the script blocked on a full 64 KiB pipe, and this test would hang.
    let home = try TempHome(); defer { home.cleanup() }
    let xcrun = try fakeXcrun("""
    head -c 2000000 /dev/zero | tr '\\0' 'e' >&2
    awk 'BEGIN { printf "{\\"devices\\": {\\"\(iOS26)\\": ["
      for (i = 0; i < 25000; i++)
        printf "%s{\\"udid\\": \\"U%d\\", \\"name\\": \\"Device %d\\", \\"isAvailable\\": true}", (i ? "," : ""), i, i
      printf "]}}" }'
    """, in: home)

    let devices = try await XcrunSimulatorControl(devicesRoot: devicesRoot, executable: xcrun).listDevices()
    #expect(devices.count == 25_000)
    #expect(devices.last?.udid == "U24999")
}

@Test func cancellingListDevicesEndsTheChildProcess() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let started = home.url.appending(path: "started", directoryHint: .notDirectory)
    let xcrun = try fakeXcrun("touch '\(started.path)'\nexec sleep 60", in: home)

    let clock = ContinuousClock()
    let begin = clock.now
    let task = Task { try await XcrunSimulatorControl(devicesRoot: devicesRoot, executable: xcrun).listDevices() }
    while !FileManager.default.fileExists(atPath: started.path) {
        try #require(clock.now - begin < .seconds(20), "the stand-in script never started")
        try await Task.sleep(for: .milliseconds(10))
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(clock.now - begin < .seconds(30), "the 60 s sleep should have been killed, not waited out")
}

@Test func listDevicesDoesNotLaunchWhenAlreadyCancelled() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let xcrun = try fakeXcrun("echo '{\"devices\": {}}'", in: home)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await XcrunSimulatorControl(devicesRoot: devicesRoot, executable: xcrun).listDevices()
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(recordedArguments(of: xcrun) == nil)
}

@Test func missingXcrunThrowsInsteadOfCrashing() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let nowhere = home.url.appending(path: "no-such-xcrun", directoryHint: .notDirectory)
    let simulators = XcrunSimulatorControl(devicesRoot: devicesRoot, executable: nowhere)
    await #expect(throws: (any Error).self) { try await simulators.listDevices() }
    await #expect(throws: (any Error).self) { try await simulators.delete(udid: someUDID) }
}

@Test func deleteRunsSimctlDeleteWithTheUDID() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let xcrun = try fakeXcrun("exit 0", in: home)
    try await XcrunSimulatorControl(devicesRoot: devicesRoot, executable: xcrun).delete(udid: someUDID)
    #expect(recordedArguments(of: xcrun) == ["simctl", "delete", someUDID])
}

@Test func deleteFailureReportsStderr() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let xcrun = try fakeXcrun("echo 'Unable to delete device: it is booted' >&2\nexit 1", in: home)
    let error = await #expect(throws: XcrunError.self) {
        try await XcrunSimulatorControl(devicesRoot: devicesRoot, executable: xcrun).delete(udid: someUDID)
    }
    #expect(error?.localizedDescription
        == "xcrun simctl delete \(someUDID) failed with exit status 1: Unable to delete device: it is booted")
}

@Test func deleteOnlyAcceptsRealUDIDs() async throws {
    // `simctl delete all` would wipe every simulator; none of these may even start xcrun.
    let home = try TempHome(); defer { home.cleanup() }
    let xcrun = try fakeXcrun("exit 0", in: home)
    let simulators = XcrunSimulatorControl(devicesRoot: devicesRoot, executable: xcrun)
    for bad in ["all", "unavailable", "", "booted", "-h", "ABC", someUDID + " ", "../" + someUDID, "\(someUDID);all"] {
        let error = await #expect(throws: XcrunError.self, "\(bad)") { try await simulators.delete(udid: bad) }
        #expect(error == .invalidUDID(bad))
    }
    #expect(recordedArguments(of: xcrun) == nil)
}

@Test func deleteKeepsRunningWhenTheCallerIsCancelled() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let started = home.url.appending(path: "started", directoryHint: .notDirectory)
    let finished = home.url.appending(path: "finished", directoryHint: .notDirectory)
    let xcrun = try fakeXcrun("touch '\(started.path)'\nsleep 1\ntouch '\(finished.path)'", in: home)

    let simulators = XcrunSimulatorControl(devicesRoot: devicesRoot, executable: xcrun)
    let task = Task { try await simulators.delete(udid: someUDID) }
    let clock = ContinuousClock()
    let begin = clock.now
    while !FileManager.default.fileExists(atPath: started.path) {
        try #require(clock.now - begin < .seconds(20), "the stand-in script never started")
        try await Task.sleep(for: .milliseconds(10))
    }
    task.cancel()
    try await task.value // a started delete is allowed to finish
    #expect(FileManager.default.fileExists(atPath: finished.path))
}

// MARK: - Trash

@Test func trasherSurfacesFileNotFoundForAMissingItem() throws {
    // Never moves a real file: the real Trash is in the real home, and tests keep out of it.
    let home = try TempHome(); defer { home.cleanup() }
    let missing = home.url.appending(path: "Library/Caches/gone", directoryHint: .isDirectory)
    let error = #expect(throws: CocoaError.self) { try FileManagerTrasher().trash(missing) }
    #expect(error?.code == .fileNoSuchFile)
}

// MARK: - Full Disk Access

// `isGranted` is `false` only when macOS answers the probe with a permission error (EPERM or EACCES). A missing
// folder says nothing about access, so it never raises the banner (ruling R32).

@Test func fullDiskAccessIsNotDeniedWhenTheProbeFolderIsMissing() throws {
    let home = try TempHome(); defer { home.cleanup() }
    #expect(FullDiskAccess.isGranted(home: home.url))
}

@Test func fullDiskAccessIsNotDeniedWhenTheProbeFolderIsMissingUnderAnExistingLibrary() throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.dir("Library/Containers/com.example.Other")
    #expect(FullDiskAccess.isGranted(home: home.url))
}

@Test func fullDiskAccessIsGrantedWhenTheProbeFolderCanBeListed() throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.dir("Library/Containers/com.apple.Safari/Data")
    #expect(FullDiskAccess.isGranted(home: home.url))
}

@Test func fullDiskAccessIsGrantedWhenTheProbeFolderIsEmpty() throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.dir("Library/Containers/com.apple.Safari")
    #expect(FullDiskAccess.isGranted(home: home.url))
}

@Test func fullDiskAccessIsNotGrantedWhenTheProbeFolderIsUnreadable() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let probe = try home.dir("Library/Containers/com.apple.Safari")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: probe.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: probe.path) }
    #expect(!FullDiskAccess.isGranted(home: home.url))
}

@Test func fullDiskAccessIsNotGrantedWhenAFolderAboveTheProbeCannotBeEntered() throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.dir("Library/Containers/com.apple.Safari")
    let containers = home.url.appending(path: "Library/Containers", directoryHint: .isDirectory)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: containers.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: containers.path) }
    #expect(!FullDiskAccess.isGranted(home: home.url))
}

@Test func fullDiskAccessIsNotDeniedWhenTheProbePathIsNotAFolder() throws {
    // Some other error than a permission one (here ENOTDIR) is no sign of missing access.
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Library/Containers/com.apple.Safari", bytes: 1)
    #expect(FullDiskAccess.isGranted(home: home.url))
}

@Test func fullDiskAccessOpensThePrivacyPane() {
    #expect(FullDiskAccess.settingsURL.absoluteString
        == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
}

// MARK: - CoreEnvironment.live

@Test func liveEnvironmentUsesTheRealHomeAndTheGivenSettings() {
    let roots = [URL(filePath: "/tmp/projects-a"), URL(filePath: "/tmp/projects-b")]
    let before = Date()
    let env = CoreEnvironment.live(projectRoots: roots, inactiveAfterDays: 45)
    #expect(env.home == FileManager.default.homeDirectoryForCurrentUser)
    #expect(env.projectRoots == roots)
    #expect(env.inactiveAfterDays == 45)
    #expect(env.processes is SystemProcessInspector)
    #expect(env.simulators is XcrunSimulatorControl)
    #expect(env.trasher is FileManagerTrasher)
    #expect(env.now() >= before && env.now() <= Date())
}

// MARK: - xcrun timeouts

@Test func simctlTimeoutsDefaultTo30SecondsForListAnd60ForDelete() {
    #expect(XcrunSimulatorControl.defaultListTimeout == .seconds(30))
    #expect(XcrunSimulatorControl.defaultDeleteTimeout == .seconds(60))
    #expect(XcrunSimulatorControl.defaultKillGracePeriod == .seconds(2))
}

/// Whether a process with this ID still exists, waiting up to five seconds for it to go.
private func processIsGone(_ pid: pid_t) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while kill(pid, 0) == 0 || errno != ESRCH {
        guard ContinuousClock.now < deadline else { return false }
        try await Task.sleep(for: .milliseconds(20))
    }
    return true
}

private func pid(in file: URL) throws -> pid_t {
    let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    return try #require(pid_t(text))
}

// The limits below are short, but long enough for the stand-in script to start while the whole suite runs at once,
// even with a build running beside it (at 1.5 s the stand-in was sometimes stopped before it wrote its PID).

@Test(.timeLimit(.minutes(1)))
func listDevicesThatHangsIsStoppedWithSIGKILLAfterTheGracePeriod() async throws {
    // Like a wedged CoreSimulator: the stand-in ignores SIGTERM, and a process it started holds both pipes open.
    let home = try TempHome(); defer { home.cleanup() }
    let scriptPID = home.url.appending(path: "script.pid", directoryHint: .notDirectory)
    let sleeperPID = home.url.appending(path: "sleeper.pid", directoryHint: .notDirectory)
    let xcrun = try fakeXcrun("""
    trap '' TERM
    echo $$ > '\(scriptPID.path)'
    sleep 30 &
    echo $! > '\(sleeperPID.path)'
    while :; do wait; done
    """, in: home)
    let simulators = XcrunSimulatorControl(
        devicesRoot: devicesRoot, executable: xcrun,
        listTimeout: .seconds(3), killGracePeriod: .milliseconds(500)
    )

    let clock = ContinuousClock()
    let begin = clock.now
    let error = await #expect(throws: XcrunError.self) { try await simulators.listDevices() }
    #expect(clock.now - begin < .seconds(10), "the call should end soon after the timeout, not wait for the 30 s sleep")
    #expect(error == .timedOut(arguments: ["simctl", "list", "devices", "--json"], after: .seconds(3)))
    #expect(error?.localizedDescription.hasPrefix(
        "xcrun simctl list devices --json did not finish within 3 seconds and was stopped."
    ) == true)
    // Both the stand-in and the process it started are gone.
    #expect(try await processIsGone(try pid(in: scriptPID)))
    #expect(try await processIsGone(try pid(in: sleeperPID)))
}

@Test(.timeLimit(.minutes(1)))
func listDevicesThatHangsButHonoursSIGTERMEndsWithoutTheGracePeriod() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let xcrun = try fakeXcrun("exec sleep 30", in: home)
    // A grace period far longer than the test allows: SIGTERM alone has to end it.
    let simulators = XcrunSimulatorControl(
        devicesRoot: devicesRoot, executable: xcrun, listTimeout: .milliseconds(200), killGracePeriod: .seconds(120)
    )
    let clock = ContinuousClock()
    let begin = clock.now
    let error = await #expect(throws: XcrunError.self) { try await simulators.listDevices() }
    #expect(error == .timedOut(arguments: ["simctl", "list", "devices", "--json"], after: .milliseconds(200)))
    #expect(clock.now - begin < .seconds(10))
}

@Test(.timeLimit(.minutes(1)))
func deleteThatHangsTimesOut() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let xcrun = try fakeXcrun("exec sleep 30", in: home)
    let simulators = XcrunSimulatorControl(
        devicesRoot: devicesRoot, executable: xcrun,
        deleteTimeout: .seconds(3), killGracePeriod: .milliseconds(500)
    )
    let error = await #expect(throws: XcrunError.self) { try await simulators.delete(udid: someUDID) }
    #expect(error == .timedOut(arguments: ["simctl", "delete", someUDID], after: .seconds(3)))
    #expect(error?.localizedDescription.hasPrefix(
        "xcrun simctl delete \(someUDID) did not finish within 3 seconds and was stopped."
    ) == true)
    #expect(recordedArguments(of: xcrun) == ["simctl", "delete", someUDID])
}

@Test func aCallThatFinishesInTimeIsNotAffectedByTheTimeout() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let xcrun = try fakeXcrun("sleep 0.2\necho '{\"devices\": {}}'", in: home)
    let simulators = XcrunSimulatorControl(devicesRoot: devicesRoot, executable: xcrun, listTimeout: .seconds(20))
    #expect(try await simulators.listDevices().isEmpty)
    try await XcrunSimulatorControl(devicesRoot: devicesRoot, executable: xcrun, deleteTimeout: .seconds(20))
        .delete(udid: someUDID)
}
