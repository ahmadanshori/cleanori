import Foundation
import Synchronization
import CleanoriCore

struct FakeProcessInspector: ProcessInspector {
    var bundleIDs: Set<String> = []
    var processes: [RunningProcess] = []

    func runningBundleIDs() -> Set<String> { bundleIDs }
    func runningProcesses() -> [RunningProcess] { processes }
}

/// The error the fakes throw when told to fail.
struct FakeFailure: Error, Equatable, LocalizedError {
    var errorDescription: String? { "Fake failure" }
}

/// A one-shot gate: `wait()` suspends until `open()` has been called. Opening it twice is harmless.
final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// How many callers are suspended in `wait()` right now.
    var waiting: Int { state.withLock { $0.waiters.count } }

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let isOpen = state.withLock { state in
                if !state.isOpen { state.waiters.append(continuation) }
                return state.isOpen
            }
            if isOpen { continuation.resume() }
        }
    }

    /// Returns once someone is suspended in `wait()`, and throws when that takes more than five seconds.
    func waitUntilSomeoneWaits() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while waiting == 0 {
            guard ContinuousClock.now < deadline else { throw FakeFailure() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

final class FakeSimulatorControl: SimulatorControl {
    private let listing: Result<[SimulatorDevice], any Error>
    private let deleteGate: Gate?
    private let deletedUDIDs = Mutex<[String]>([])

    /// With a `deleteGate`, every `delete(udid:)` records its UDID and then suspends until the gate opens.
    init(devices: [SimulatorDevice] = [], deleteGate: Gate? = nil) {
        listing = .success(devices)
        self.deleteGate = deleteGate
    }

    /// `listDevices()` throws `error`, like a failing `xcrun simctl`.
    init(throwing error: any Error) {
        listing = .failure(error)
        deleteGate = nil
    }

    /// UDIDs passed to `delete(udid:)`, in call order.
    var deleted: [String] { deletedUDIDs.withLock { $0 } }

    func listDevices() async throws -> [SimulatorDevice] {
        try listing.get()
    }

    func delete(udid: String) async throws {
        deletedUDIDs.withLock { $0.append(udid) }
        await deleteGate?.wait()
    }
}

final class FakeTrasher: Trasher {
    private let failing: [URL]
    private let error: any Error & Sendable
    private let trashedURLs = Mutex<[URL]>([])

    /// `trash(_:)` throws `error` for each of `failing` (compared by path) and records the rest.
    init(failing: [URL] = [], error: any Error & Sendable = FakeFailure()) {
        self.failing = failing
        self.error = error
    }

    /// URLs successfully passed to `trash(_:)`, in call order. Failed calls are not recorded.
    var trashed: [URL] { trashedURLs.withLock { $0 } }

    func trash(_ url: URL) throws {
        if failing.contains(where: { $0.path == url.path }) { throw error }
        trashedURLs.withLock { $0.append(url) }
    }
}

extension CoreEnvironment {
    /// An environment rooted in `home`: project roots `[home/Developer]`, inactive after 60 days.
    static func test(
        home: TempHome,
        now: Date = .now,
        processes: any ProcessInspector = FakeProcessInspector(),
        simulators: any SimulatorControl = FakeSimulatorControl(),
        trasher: any Trasher = FakeTrasher()
    ) -> CoreEnvironment {
        CoreEnvironment(
            home: home.url,
            projectRoots: [home.url.appending(path: "Developer", directoryHint: .isDirectory)],
            inactiveAfterDays: 60,
            now: { now },
            processes: processes,
            simulators: simulators,
            trasher: trasher
        )
    }
}
