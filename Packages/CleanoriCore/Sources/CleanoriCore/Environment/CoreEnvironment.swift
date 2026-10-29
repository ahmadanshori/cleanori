import Foundation

/// Everything the core needs from the outside world, injected so tests can run against a temporary home.
public struct CoreEnvironment: Sendable {
    public var home: URL
    public var projectRoots: [URL]
    public var inactiveAfterDays: Int
    public var now: @Sendable () -> Date
    public var processes: any ProcessInspector
    public var simulators: any SimulatorControl
    public var trasher: any Trasher

    public init(
        home: URL,
        projectRoots: [URL],
        inactiveAfterDays: Int,
        now: @escaping @Sendable () -> Date,
        processes: any ProcessInspector,
        simulators: any SimulatorControl,
        trasher: any Trasher
    ) {
        self.home = home
        self.projectRoots = projectRoots
        self.inactiveAfterDays = inactiveAfterDays
        self.now = now
        self.processes = processes
        self.simulators = simulators
        self.trasher = trasher
    }
}

extension CoreEnvironment {
    /// The environment the app runs with: the real home folder, the running apps and processes, `xcrun simctl`
    /// and the Trash.
    public static func live(projectRoots: [URL], inactiveAfterDays: Int) -> CoreEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return CoreEnvironment(
            home: home,
            projectRoots: projectRoots,
            inactiveAfterDays: inactiveAfterDays,
            now: { Date() },
            processes: SystemProcessInspector(),
            simulators: XcrunSimulatorControl(devicesRoot: XcrunSimulatorControl.defaultDevicesRoot(home: home)),
            trasher: FileManagerTrasher()
        )
    }
}
