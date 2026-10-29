import Foundation
import Observation
import CleanoriCore

/// The user's choices (spec §6.4). Each one is written to `UserDefaults` the moment it changes and read back
/// when the app starts, falling back to the default when nothing was saved.
@MainActor @Observable
final class AppSettings {
    static let defaultInactiveAfterDays = 60
    static let defaultLargeFilesMinBytes: Int64 = 100_000_000
    /// The inactive threshold Settings allows, in days.
    static let inactiveAfterDaysRange = 7...365
    /// The minimum sizes Settings and the Large Files menu offer: 100 MB, 500 MB, 1 GB and 5 GB.
    static let largeFilesMinBytesChoices: [Int64] = [100_000_000, 500_000_000, 1_000_000_000, 5_000_000_000]

    /// Projects not touched for this many days count as inactive.
    var inactiveAfterDays: Int {
        didSet { defaults.set(inactiveAfterDays, forKey: Key.inactiveAfterDays) }
    }

    /// The folders searched for projects. Saved as plain paths. Only folders `ProjectRootPolicy` accepts get in:
    /// `addProjectRoots` refuses the others, and a saved list is filtered when it is read back.
    var projectRoots: [URL] {
        didSet { defaults.set(projectRoots.map(\.path), forKey: Key.projectRoots) }
    }

    /// The smallest file Large Files lists, in bytes.
    var largeFilesMinBytes: Int64 {
        didSet { defaults.set(largeFilesMinBytes, forKey: Key.largeFilesMinBytes) }
    }

    /// Adds folders to the project folders. Returns the ones it refused, with the reason: the home folder, a folder
    /// that contains it, `~/Library` or anything in it, a folder outside the home folder, or one already listed.
    @discardableResult
    func addProjectRoots(_ folders: [URL]) -> [(folder: URL, problem: ProjectRootProblem)] {
        var refused: [(folder: URL, problem: ProjectRootProblem)] = []
        var roots = projectRoots
        for folder in folders {
            let url = URL(fileURLWithPath: folder.standardizedFileURL.path, isDirectory: true)
            if let problem = ProjectRootPolicy.problem(with: url, home: rootsHome, existing: roots) {
                refused.append((url, problem))
            } else {
                roots.append(url)
            }
        }
        if roots.count != projectRoots.count { projectRoots = roots }
        return refused
    }

    /// Takes folders out of the project folders. An empty list is allowed: it is saved as such.
    func removeProjectRoots(_ folders: Set<URL>) {
        let gone = Set(folders.map { $0.standardizedFileURL.path })
        projectRoots.removeAll { gone.contains($0.standardizedFileURL.path) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// The home folder project folders must lie in: the real one, even in a Debug build started with `CLEANORI_HOME`,
    /// because the list is saved to the real settings.
    @ObservationIgnored private let rootsHome: URL

    private enum Key {
        static let inactiveAfterDays = "inactiveAfterDays"
        static let projectRoots = "projectRoots"
        static let largeFilesMinBytes = "largeFilesMinBytes"
    }

    /// `home` only decides where the default project folder (`~/Developer`) is.
    init(
        defaults: UserDefaults = .standard,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.defaults = defaults
        rootsHome = home
        // A saved value outside what Settings allows (hand-edited, or from an older build) is not trusted: 0 or a negative
        // number would make every project look inactive, and inactive projects are ticked by default.
        inactiveAfterDays = (defaults.object(forKey: Key.inactiveAfterDays) as? Int)
            .flatMap { Self.inactiveAfterDaysRange.contains($0) ? $0 : nil }
            ?? Self.defaultInactiveAfterDays
        // A saved empty list is a real choice (no project folders), so only a missing key means "use the default".
        // A saved folder that Settings would now refuse (the home folder, saved by an older build) is left out; when
        // that leaves nothing of a list that was not empty, the default is used, as if nothing had been saved.
        let defaultRoots = [home.appending(path: "Developer", directoryHint: .isDirectory)]
        if let saved = defaults.stringArray(forKey: Key.projectRoots)?.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            let allowed = ProjectRootPolicy.allowed(saved, home: home)
            projectRoots = saved.isEmpty || !allowed.isEmpty ? allowed : defaultRoots
        } else {
            projectRoots = defaultRoots
        }
        largeFilesMinBytes = (defaults.object(forKey: Key.largeFilesMinBytes) as? NSNumber)?.int64Value
            ?? Self.defaultLargeFilesMinBytes
    }

    /// The home folder the app works on: the real one, or in a Debug build started with `CLEANORI_HOME` that folder.
    var home: URL {
        #if DEBUG
        if let home = Self.debugHome { return home }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// The environment a scan or clean runs with: the real home folder and the current settings.
    ///
    /// A Debug build started with `CLEANORI_HOME=<folder>` works on that folder instead (see `debugHome`), moves what
    /// should go to the Trash into `<folder>/.Trash` (see `DebugHomeTrasher`) and has no simulators (see `DebugNoSimulators`).
    func makeEnvironment() -> CoreEnvironment {
        var env = CoreEnvironment.live(projectRoots: projectRoots, inactiveAfterDays: inactiveAfterDays)
        #if DEBUG
        if let home = Self.debugHome {
            env.home = home
            env.projectRoots = [home.appending(path: "Developer", directoryHint: .isDirectory)]
            // No simulators at all (ruling R33): `simctl` would list, and a clean could delete, the machine's real ones.
            env.simulators = DebugNoSimulators()
            env.trasher = DebugHomeTrasher(home: home)
        }
        #endif
        return env
    }

    /// Where the clean log is written: `~/Library/Logs/Cleanori`, or inside `CLEANORI_HOME` in a Debug build
    /// that uses one, so a test run against a scratch folder never touches the real log.
    func makeCleanLog() -> CleanLog {
        #if DEBUG
        if let home = Self.debugHome {
            return CleanLog(
                directory: home.appending(path: "Library/Logs/Cleanori", directoryHint: .isDirectory),
                now: { Date() }
            )
        }
        #endif
        return CleanLog.live()
    }

    #if DEBUG
    /// The scratch folder named by the `CLEANORI_HOME` environment variable, for manual checks against a
    /// fake home. It exists in Debug builds only: a Release build always uses the real home folder.
    private static var debugHome: URL? {
        guard let path = ProcessInfo.processInfo.environment["CLEANORI_HOME"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
    #endif
}
