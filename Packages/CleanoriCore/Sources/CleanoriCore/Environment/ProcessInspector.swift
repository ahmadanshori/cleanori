/// A running process that is not necessarily a GUI app (e.g. `qemu-system-aarch64`, a Gradle daemon JVM).
public struct RunningProcess: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

/// Reports what is currently running, so locked items can be detected.
public protocol ProcessInspector: Sendable {
    /// Bundle identifiers of running GUI apps.
    func runningBundleIDs() -> Set<String>
    /// Every running process with its arguments.
    func runningProcesses() -> [RunningProcess]
}
