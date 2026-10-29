import Foundation
import Testing
import CleanoriCore

private struct Boom: Error, Equatable {}

private func device(_ udid: String) -> SimulatorDevice {
    SimulatorDevice(
        udid: udid, name: "iPhone 16", runtime: "iOS 26.3", isAvailable: true,
        dataURL: URL(filePath: "/tmp/\(udid)")
    )
}

@Test func fakeProcessInspectorReportsConfiguredState() {
    let p = FakeProcessInspector(
        bundleIDs: ["com.apple.dt.Xcode"],
        processes: [RunningProcess(executable: "qemu-system-aarch64", arguments: ["-m", "4096"])]
    )
    #expect(p.runningBundleIDs() == ["com.apple.dt.Xcode"])
    #expect(p.runningProcesses().map(\.executable) == ["qemu-system-aarch64"])
    #expect(FakeProcessInspector().runningBundleIDs().isEmpty)
    #expect(FakeProcessInspector().runningProcesses().isEmpty)
}

@Test func fakeSimulatorControlListsAndRecordsDeletes() async throws {
    let sim = FakeSimulatorControl(devices: [device("A"), device("B")])
    #expect(try await sim.listDevices().map(\.udid) == ["A", "B"])
    try await sim.delete(udid: "B")
    try await sim.delete(udid: "A")
    #expect(sim.deleted == ["B", "A"])
}

@Test func fakeSimulatorControlCanThrowFromListDevices() async {
    let sim = FakeSimulatorControl(throwing: Boom())
    await #expect(throws: Boom.self) { try await sim.listDevices() }
    #expect(sim.deleted.isEmpty)
}

@Test func fakeTrasherRecordsInOrder() throws {
    let t = FakeTrasher()
    try t.trash(URL(filePath: "/tmp/a"))
    try t.trash(URL(filePath: "/tmp/b"))
    #expect(t.trashed == [URL(filePath: "/tmp/a"), URL(filePath: "/tmp/b")])
}

@Test func testEnvironmentUsesTempHomeAndDefaults() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let fixed = Date(timeIntervalSince1970: 1_700_000_000)
    let env = CoreEnvironment.test(home: home, now: fixed)
    #expect(env.home == home.url)
    #expect(env.projectRoots == [home.url.appending(path: "Developer", directoryHint: .isDirectory)])
    #expect(env.inactiveAfterDays == 60)
    #expect(env.now() == fixed)
    #expect(env.processes.runningBundleIDs().isEmpty)
}

@Test func testEnvironmentAcceptsInjectedFakes() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let trasher = FakeTrasher()
    let sims = FakeSimulatorControl(devices: [device("Z")])
    let env = CoreEnvironment.test(
        home: home,
        processes: FakeProcessInspector(bundleIDs: ["x.y"]),
        simulators: sims,
        trasher: trasher
    )
    #expect(env.processes.runningBundleIDs() == ["x.y"])
    #expect(try await env.simulators.listDevices().map(\.udid) == ["Z"])
    try env.trasher.trash(URL(filePath: "/tmp/q"))
    #expect(trasher.trashed == [URL(filePath: "/tmp/q")])
}
