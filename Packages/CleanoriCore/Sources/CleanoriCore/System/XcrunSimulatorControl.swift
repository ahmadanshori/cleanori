import Foundation
import Synchronization

/// Why an `xcrun simctl` call did not work. Its description is what the clean log and the UI show.
public enum XcrunError: Error, Equatable, LocalizedError {
    /// `delete` was asked for something that is not a device UDID. `simctl delete` also accepts `all` and
    /// `unavailable`, so nothing but a real UDID may reach it.
    case invalidUDID(String)
    /// The command ran and failed. `signaled` means it was killed by signal `status` rather than exiting.
    case failed(arguments: [String], status: Int32, signaled: Bool, stderr: String)
    /// The command was still running `after` it started, so it was stopped (a wedged CoreSimulator does that).
    case timedOut(arguments: [String], after: Duration)

    public var errorDescription: String? {
        switch self {
        case .invalidUDID(let udid):
            return "Not a simulator UDID: \(udid)"
        case .failed(let arguments, let status, let signaled, let stderr):
            let how = signaled ? "was killed by signal \(status)" : "failed with exit status \(status)"
            let message = String(stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_000))
            return "xcrun \(arguments.joined(separator: " ")) \(how)" + (message.isEmpty ? "" : ": \(message)")
        case .timedOut(let arguments, let after):
            return "xcrun \(arguments.joined(separator: " ")) did not finish within \(Self.describe(after)) and was stopped. "
                + "CoreSimulator may be stuck; restarting the Mac usually clears it."
        }
    }

    /// `30 seconds`, `0.3 seconds`, `1 second`.
    private static func describe(_ duration: Duration) -> String {
        let seconds = duration / .seconds(1)
        if seconds == 1 { return "1 second" }
        return seconds == seconds.rounded() ? "\(Int(seconds)) seconds" : String(format: "%g seconds", seconds)
    }
}

/// The live `SimulatorControl`: `xcrun simctl`, started directly (never through a shell).
///
/// Every call has a time limit, because a wedged CoreSimulator can leave `simctl` waiting for ever, which would hang a
/// scan, or a clean (which has no Cancel). When the limit is reached the command is sent SIGTERM, then SIGKILL if it is
/// still there `killGracePeriod` later, and the call throws `XcrunError.timedOut`. The signals go to the command's
/// whole process group, so what `xcrun` started (`simctl` itself) is stopped too.
public struct XcrunSimulatorControl: SimulatorControl {
    public static let defaultExecutable = URL(filePath: "/usr/bin/xcrun")
    public static let defaultListTimeout: Duration = .seconds(30)
    public static let defaultDeleteTimeout: Duration = .seconds(60)
    /// How long a command may take to end after SIGTERM before it is sent SIGKILL.
    public static let defaultKillGracePeriod: Duration = .seconds(2)

    private let executable: URL
    private let devicesRoot: URL
    private let listTimeout: Duration
    private let deleteTimeout: Duration
    private let killGracePeriod: Duration

    /// `devicesRoot` is the folder that holds one `<udid>` folder per device. `executable` and the time limits are for
    /// tests, which point it at a script instead of the real `xcrun` and use short limits.
    public init(
        devicesRoot: URL,
        executable: URL = XcrunSimulatorControl.defaultExecutable,
        listTimeout: Duration = XcrunSimulatorControl.defaultListTimeout,
        deleteTimeout: Duration = XcrunSimulatorControl.defaultDeleteTimeout,
        killGracePeriod: Duration = XcrunSimulatorControl.defaultKillGracePeriod
    ) {
        self.devicesRoot = devicesRoot
        self.executable = executable
        self.listTimeout = listTimeout
        self.deleteTimeout = deleteTimeout
        self.killGracePeriod = killGracePeriod
    }

    /// Where CoreSimulator keeps its devices: `~/Library/Developer/CoreSimulator/Devices`.
    public static func defaultDevicesRoot(home: URL) -> URL {
        home.appending(path: "Library/Developer/CoreSimulator/Devices", directoryHint: .isDirectory)
    }

    /// `xcrun simctl list devices --json`, stopped after `listTimeout`. A cancelled call ends the child process and
    /// throws `CancellationError`, which `simctl` can need when CoreSimulator is wedged.
    public func listDevices() async throws -> [SimulatorDevice] {
        let result = try await ChildProcess.run(
            executable, ["simctl", "list", "devices", "--json"],
            terminatesOnCancellation: true, timeout: listTimeout, killGracePeriod: killGracePeriod
        )
        try result.throwIfFailed()
        return try Self.parseDevices(result.stdout, devicesRoot: devicesRoot)
    }

    /// `xcrun simctl delete <udid>`. Once started it runs to the end even if the caller is cancelled: a
    /// half-finished delete is worse than a late one. Only `deleteTimeout` stops it, since one that hangs would
    /// otherwise hang the clean.
    public func delete(udid: String) async throws {
        guard UUID(uuidString: udid) != nil else { throw XcrunError.invalidUDID(udid) }
        let result = try await ChildProcess.run(
            executable, ["simctl", "delete", udid],
            terminatesOnCancellation: false, timeout: deleteTimeout, killGracePeriod: killGracePeriod
        )
        try result.throwIfFailed()
    }

    // MARK: - Parsing

    /// Reads the output of `simctl list devices --json`.
    ///
    /// Devices come back grouped by runtime, runtimes in a stable order, devices in `simctl`'s order. A device
    /// without a UDID or a name cannot be deleted or shown, so it is left out and the rest are kept. A device
    /// with no `isAvailable` counts as available: unavailable devices are what gets deleted by default.
    /// `dataURL` is `devicesRoot/<udid>`.
    public static func parseDevices(_ json: Data, devicesRoot: URL) throws -> [SimulatorDevice] {
        let listing = try JSONDecoder().decode(Listing.self, from: json)
        let runtimeKeys = listing.devices.keys.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        return runtimeKeys.flatMap { key in
            let runtime = runtimeName(forKey: key)
            return (listing.devices[key] ?? []).compactMap { $0.value }.filter { !$0.udid.isEmpty }.map { entry in
                SimulatorDevice(
                    udid: entry.udid,
                    name: entry.name,
                    runtime: runtime,
                    isAvailable: entry.isAvailable ?? true,
                    dataURL: devicesRoot.appending(path: entry.udid, directoryHint: .isDirectory)
                )
            }
        }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-3` becomes `iOS 26.3` (`iOS-26` becomes `iOS 26`); the
    /// runtime id calls visionOS `xrOS`. Anything that is not `<platform>-<number>(-<number>)*` is shown as
    /// `simctl` wrote it, minus the identifier prefix.
    static func runtimeName(forKey key: String) -> String {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        let name = key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : key
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard let platform = parts.first, !platform.isEmpty else { return name }
        let version = parts.dropFirst()
        guard version.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIINumber) }) else { return name }
        let displayPlatform = platform == "xrOS" ? "visionOS" : String(platform)
        return version.isEmpty ? displayPlatform : "\(displayPlatform) \(version.joined(separator: "."))"
    }

    private struct Listing: Decodable {
        var devices: [String: [Lossy<Entry>]]
    }

    private struct Entry: Decodable {
        var udid: String
        var name: String
        var isAvailable: Bool?
    }

    /// Decodes to `nil` instead of throwing, so one odd entry does not hide the others.
    private struct Lossy<Value: Decodable>: Decodable {
        var value: Value?

        init(from decoder: any Decoder) throws {
            value = try? Value(from: decoder)
        }
    }
}

private extension Character {
    var isASCIINumber: Bool { isASCII && isNumber }
}

// MARK: - Running a process

/// What a finished child process left behind.
private struct ChildResult: Sendable {
    var arguments: [String]
    var status: Int32
    var signaled: Bool
    var stdout: Data
    var stderr: Data

    func throwIfFailed() throws {
        guard status != 0 else { return } // a signal number is never 0, so a killed process fails too
        throw XcrunError.failed(
            arguments: arguments, status: status, signaled: signaled,
            stderr: String(decoding: stderr, as: UTF8.self)
        )
    }
}

/// Runs a program and collects what it writes.
///
/// Waiting for a process blocks a thread for as long as it lives, so the waiting is done on a Dispatch thread
/// and the caller is suspended on a continuation: a slow `simctl` ties up no thread of the cooperative pool,
/// which the rest of the app's async work shares.
private enum ChildProcess {
    /// Stops the running child when its caller is cancelled or its time is up: SIGTERM first, then SIGKILL if it is
    /// still running after the grace period. Foundation starts each child as the leader of a new process group, so
    /// the signals go to that group, and whatever the child started goes too (and with it, the pipes it holds open).
    private final class Terminator: Sendable {
        private struct State {
            var pid: pid_t?
            var isCancelled = false
            var isTimedOut = false
            var isStopping = false
            /// The child has exited and been reaped, so its ID may already belong to another process.
            var hasExited = false
        }

        private let state = Mutex(State())
        private let killGracePeriod: Duration

        init(killGracePeriod: Duration) {
            self.killGracePeriod = killGracePeriod
        }

        /// The child is running. If the caller already gave up, stop it at once.
        func started(pid: pid_t) {
            state.withLock { state in
                state.pid = pid
                if state.isCancelled { stop(&state) }
            }
        }

        func cancel() {
            state.withLock { state in
                state.isCancelled = true
                stop(&state)
            }
        }

        func timeOut() {
            state.withLock { state in
                guard !state.hasExited else { return }
                state.isTimedOut = true
                stop(&state)
            }
        }

        /// The child has exited. Returns whether the caller gave up on it and whether its time ran out.
        func exited() -> (isCancelled: Bool, isTimedOut: Bool) {
            state.withLock { state in
                state.hasExited = true
                return (state.isCancelled, state.isTimedOut)
            }
        }

        /// Sends SIGTERM, and SIGKILL after the grace period unless the child has exited by then. Called with the lock held.
        private func stop(_ state: inout State) {
            guard let pid = state.pid, !state.hasExited, !state.isStopping else { return }
            state.isStopping = true
            Self.signal(pid, SIGTERM)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.seconds(killGracePeriod)) {
                self.state.withLock { state in
                    if !state.hasExited { Self.signal(pid, SIGKILL) }
                }
            }
        }

        /// Signals the child's process group, or the child alone if it somehow leads no group.
        private static func signal(_ pid: pid_t, _ signal: Int32) {
            if killpg(pid, signal) != 0 { kill(pid, signal) }
        }

        static func seconds(_ duration: Duration) -> Double { duration / .seconds(1) }
    }

    /// Collects one pipe on a thread of its own.
    private final class Drain: Sendable {
        private let result = Mutex(Data())
        var data: Data { result.withLock { $0 } }

        func run(_ handle: FileHandle, in group: DispatchGroup) {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let data = (try? handle.readToEnd()) ?? Data()
                self.result.withLock { $0 = data }
                group.leave()
            }
        }
    }

    static func run(
        _ executable: URL, _ arguments: [String], terminatesOnCancellation: Bool, timeout: Duration, killGracePeriod: Duration
    ) async throws -> ChildResult {
        if terminatesOnCancellation { try Task.checkCancellation() }
        let terminator = Terminator(killGracePeriod: killGracePeriod)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try runAndWait(executable, arguments, timeout: timeout, killGracePeriod: killGracePeriod, terminator: terminator)
                    })
                }
            }
        } onCancel: {
            if terminatesOnCancellation { terminator.cancel() }
        }
    }

    /// Starts the program and blocks until it has ended. Both pipes are read at the same time as the program
    /// runs: reading one to its end first would leave the program stuck writing to the other once its buffer
    /// (64 KiB) is full, and the large JSON listing would do just that.
    private static func runAndWait(
        _ executable: URL, _ arguments: [String], timeout: Duration, killGracePeriod: Duration, terminator: Terminator
    ) throws -> ChildResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        terminator.started(pid: process.processIdentifier)
        let deadline = DispatchWorkItem { terminator.timeOut() }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + Terminator.seconds(timeout), execute: deadline
        )

        let group = DispatchGroup()
        let out = Drain()
        let err = Drain()
        out.run(stdout.fileHandleForReading, in: group)
        err.run(stderr.fileHandleForReading, in: group)
        process.waitUntilExit()
        deadline.cancel()
        let outcome = terminator.exited()
        if outcome.isCancelled || outcome.isTimedOut {
            // Its output is not needed any more. A process that left the group could hold a pipe open for ever, so
            // the wait for the end of the output is bounded.
            _ = group.wait(timeout: .now() + Terminator.seconds(killGracePeriod))
        } else {
            group.wait()
        }

        if outcome.isCancelled { throw CancellationError() }
        let status = process.terminationStatus
        let signaled = process.terminationReason == .uncaughtSignal
        // A command that still finished well as its time ran out did its work; anything else was cut short.
        if outcome.isTimedOut, signaled || status != 0 {
            throw XcrunError.timedOut(arguments: arguments, after: timeout)
        }
        return ChildResult(
            arguments: arguments,
            status: status,
            signaled: signaled,
            stdout: out.data,
            stderr: err.data
        )
    }
}
