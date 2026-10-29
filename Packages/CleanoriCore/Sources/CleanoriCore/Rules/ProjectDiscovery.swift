import Foundation

/// A software project folder, found by `ProjectDiscovery`.
struct Project: Sendable {
    /// The project folder, spelled like the project root it was found under.
    let root: URL
    /// The newest change to one of the project's own files near its top (spec §5.4). Never a date in
    /// `node_modules` or `.git`, which change whenever a package is installed or a commit is made.
    let lastActivity: Date
    /// The project's path below the project root it was found under (`acme/uat/app_v2`).
    /// The last folder name alone repeats across projects; this does not. A project that is a project
    /// root itself is named after that root.
    let name: String

    /// Whether the project was worked on within the last `inactiveAfterDays` days (exactly that many still counts).
    func isActive(at now: Date, inactiveAfterDays: Int) -> Bool {
        now.timeIntervalSince(lastActivity) <= Double(inactiveAfterDays) * 86_400
    }
}

/// Finds the project folders under `CoreEnvironment.projectRoots` (spec §5.4).
///
/// Walking a project root must stay cheap and bounded, because it holds 50 GB of `node_modules`:
/// - `node_modules` is reported and never entered, and neither are `.git`, `Pods`, `DerivedData`, `build`
///   or a package (`.app`, `.xcarchive`, `.xcodeproj`...).
/// - `.next`, `.expo`, `.gradle` and `.cxx` are not entered either. They are build output (the first three
///   are offered for deletion as a whole by `build.web` and `build.android`), and build output holds copies of
///   `node_modules` that would otherwise show up as extra, overlapping items: Next.js puts one in
///   `.next/standalone`, and Android's CMake output (`android/app/.cxx`) mirrors the absolute path of the
///   sources it compiles, `node_modules` included.
/// - Tool folders are not entered: `.nvm`, `.vscode`, `.vscode-insiders`, `.cursor`, `.yarn`, `.cache`, `.local`,
///   `.config`, `.npm`, `.pnpm-store`, `.bun`, `.android`, `.cargo` and `.rustup`. They hold `node_modules` that
///   belong to a tool, not to a project (npm itself and the global packages in `.nvm/versions/node/*/lib`, editor
///   extensions, Yarn PnP's `.yarn/unplugged`), and some are caches other rules already offer. Every other hidden
///   folder is walked, so projects in `.worktrees` are found.
/// - Neither is a folder named `Library`, at any depth below a project root. macOS uses that name for the support
///   folders of a home and of every app container (`~/Library`, `Containers/<id>/Data/Library`, a copied-over
///   old home), which hold app data and caches, never one's own projects; Unity's `Library` is a cache too. At
///   worst a project kept in a folder that happens to be called `Library` is not offered, which never deletes
///   anything by mistake. A project root that is itself called `Library` is walked, since the user chose it.
/// - Symbolic links are never followed: a link is neither entered nor reported, and a project root that is
///   itself a link is not walked.
/// - Unreadable folders are skipped; they never stop the walk.
enum ProjectDiscovery {
    /// Every `node_modules` below the project roots with the project that owns it (its parent folder).
    /// Projects nested in one another (a worktree, a monorepo package) are separate projects, each with
    /// its own `node_modules` and its own activity date. Sorted by path.
    static func nodeModules(in env: CoreEnvironment) throws -> [(project: Project, nodeModules: URL)] {
        let now = env.now()
        var found: [(project: Project, nodeModules: URL)] = []
        var seen = Set<String>()
        try walk(env.projectRoots, onFolder: { _ in }, onNodeModules: { location in
            guard seen.insert(location.url.path).inserted else { return }
            found.append((project(at: location.parent, now: now), location.url))
        })
        return found.sorted { $0.nodeModules.path < $1.nodeModules.path }
    }

    /// Every folder below the project roots (and every root) that `marker` accepts, as a project.
    /// `marker` is given the candidate project folder, for instance to look for `package.json` in it.
    /// Sorted by path.
    static func projects(in env: CoreEnvironment, marker: (URL) -> Bool) throws -> [Project] {
        let now = env.now()
        var found: [Project] = []
        var seen = Set<String>()
        try walk(env.projectRoots, onFolder: { location in
            guard seen.insert(location.url.path).inserted, marker(location.url) else { return }
            found.append(project(at: location, now: now))
        }, onNodeModules: { _ in })
        return found.sorted { $0.root.path < $1.root.path }
    }

    // MARK: - Project markers (spec §5.3)

    /// `android/settings.gradle` or `android/settings.gradle.kts`.
    static func hasAndroidSettings(_ project: URL) -> Bool {
        let android = project.appending(path: "android", directoryHint: .isDirectory)
        return children(of: android).contains {
            $0.hasPrefix("settings.gradle") && fileType(at: android.appending(path: $0, directoryHint: .notDirectory)) == S_IFREG
        }
    }

    /// An Xcode project folder (`ios/*.xcodeproj`).
    static func hasXcodeProject(_ project: URL) -> Bool {
        let ios = project.appending(path: "ios", directoryHint: .isDirectory)
        return children(of: ios).contains {
            $0.hasSuffix(".xcodeproj") && fileType(at: ios.appending(path: $0, directoryHint: .isDirectory)) == S_IFDIR
        }
    }

    /// `ios/Podfile`.
    static func hasPodfile(_ project: URL) -> Bool {
        fileType(at: project.appending(path: "ios/Podfile", directoryHint: .notDirectory)) == S_IFREG
    }

    /// `package.json`.
    static func hasPackageJSON(_ project: URL) -> Bool {
        fileType(at: project.appending(path: "package.json", directoryHint: .notDirectory)) == S_IFREG
    }

    /// Whether `relPath` (such as `android/app/build`) below `project` is a real folder: every component
    /// on the way must be a folder too, so a link in the middle cannot lead out of the project.
    static func containsRealFolder(_ relPath: String, in project: URL) -> Bool {
        var current = project
        for component in relPath.split(separator: "/") {
            current = current.appending(path: String(component), directoryHint: .isDirectory)
            guard fileType(at: current) == S_IFDIR else { return false }
        }
        return true
    }

    // MARK: - Walking

    private static let nodeModulesName = "node_modules"

    /// Folders that are never entered or considered as projects: version control, build output, and the folders
    /// tools and macOS keep their own files in (see the type's documentation).
    private static let skippedFolders: Set<String> = [
        ".git", "Pods", "DerivedData", "build", ".next", ".expo", ".gradle", ".cxx",
        "Library",
        ".nvm", ".vscode", ".vscode-insiders", ".cursor", ".yarn", ".cache", ".local", ".config", ".npm",
        ".pnpm-store", ".bun", ".android", ".cargo", ".rustup",
    ]

    /// Folders that are excluded when measuring a project's activity.
    private static let excludedFromActivity: Set<String> = [nodeModulesName, ".git"]

    /// Requested up front, so the enumerator reads them while it lists each folder rather than on every lookup.
    private static let walkKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
    private static let walkKeySet = Set(walkKeys)

    private static let activityKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey,
    ]
    private static let activityKeySet = Set(activityKeys)

    /// A folder found below a project root.
    private struct Location {
        /// The project root being walked, exactly as given.
        let root: URL
        /// How many levels the folder is below `root` (0 is `root` itself).
        let level: Int
        /// The folder as the enumerator reported it. Foundation resolves symlinks in the ancestors of the
        /// root (`/tmp` becomes `/private/tmp`), so this is only good for reading, never for building paths.
        let reported: URL

        /// Path components of the folder below `root`.
        var components: [String] { Array(reported.pathComponents.suffix(level)) }

        /// The folder, spelled below `root` as given, so items stay lexically below the caller's own paths
        /// (`SafetyGuard` compares paths lexically).
        var url: URL {
            let components = components
            return components.isEmpty ? root : root.appending(path: components.joined(separator: "/"), directoryHint: .isDirectory)
        }

        /// The folder that contains this one.
        var parent: Location {
            Location(root: root, level: level - 1, reported: reported.deletingLastPathComponent())
        }

        /// `acme/uat/app_v2`; the root's own name for the root itself.
        var name: String {
            let components = components
            return components.isEmpty ? root.lastPathComponent : components.joined(separator: "/")
        }
    }

    /// Walks each of `roots` that is a real folder, calling `onFolder` for the root and for every folder
    /// below it that may hold a project, and `onNodeModules` for every `node_modules` folder (which is not entered).
    private static func walk(
        _ roots: [URL],
        onFolder: (Location) -> Void,
        onNodeModules: (Location) -> Void
    ) throws {
        for root in roots where fileType(at: root) == S_IFDIR {
            try Task.checkCancellation()
            onFolder(Location(root: root, level: 0, reported: root))
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: walkKeys,
                options: [],
                errorHandler: { _, _ in true } // an unreadable folder is simply left out
            ) else { continue }

            /// Visits one entry; returns `false` when the walk is finished.
            func visitNext() throws -> Bool {
                guard let url = enumerator.nextObject() as? URL else { return false }
                try Task.checkCancellation()
                guard let values = try? url.resourceValues(forKeys: walkKeySet) else { return true }
                // A link is neither reported nor entered. The enumerator never follows one, so it needs no
                // `skipDescendants()`; called on anything but a folder, that call makes Foundation skip the next
                // folder it would have entered, silently dropping a whole project. It is only called on folders, below.
                if values.isSymbolicLink == true { return true }
                guard values.isDirectory == true else { return true }

                let location = Location(root: root, level: enumerator.level, reported: url)
                let name = url.lastPathComponent
                if name == nodeModulesName {
                    onNodeModules(location)
                    enumerator.skipDescendants()
                } else if skippedFolders.contains(name) || values.isPackage == true {
                    enumerator.skipDescendants()
                } else {
                    onFolder(location)
                }
                return true
            }

            // Each step creates autoreleased URLs and resource-value dictionaries; without draining them per
            // entry, memory would grow with the number of entries in the tree (see `DirectorySizer`).
            while try autoreleasepool(invoking: visitNext) {}
        }
    }

    // MARK: - Projects

    private static func project(at location: Location, now: Date) -> Project {
        let lastActivity = autoreleasepool {
            newestChange(in: location.reported) ?? modificationDate(of: location.reported) ?? now
        }
        return Project(root: location.url, lastActivity: lastActivity, name: location.name)
    }

    /// The newest modification date among the regular files at most two levels below `root` (`root/a.json`,
    /// `root/src/a.ts`), leaving out `node_modules` and `.git`. `nil` when there is no such file.
    private static func newestChange(in root: URL) -> Date? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: activityKeys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return nil }

        var newest: Date?
        func visitNext() -> Bool {
            guard let url = enumerator.nextObject() as? URL else { return false }
            // `skipDescendants()` is only called on a folder. Called on anything else (in a git worktree `.git` is a
            // file) it makes Foundation skip the next folder it would have entered, which hides the files below
            // it. So an excluded name that is not a folder is just left out, without that call.
            guard let values = try? url.resourceValues(forKeys: activityKeySet) else { return true }
            let isExcluded = excludedFromActivity.contains(url.lastPathComponent)
            if values.isDirectory == true {
                // A folder at the second level is not entered: its files would be three levels down.
                if isExcluded || enumerator.level >= 2 { enumerator.skipDescendants() }
            } else if !isExcluded, values.isRegularFile == true, let date = values.contentModificationDate,
                      newest.map({ date > $0 }) ?? true {
                newest = date
            }
            return true
        }
        while autoreleasepool(invoking: visitNext) {}
        return newest
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    // MARK: - File system

    /// The type of the file itself (`S_IFDIR`, `S_IFREG`, `S_IFLNK`...), never of a link's target.
    /// `nil` when it does not exist or cannot be inspected.
    private static func fileType(at url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    /// The names inside `dir`; empty when it is missing, unreadable, or a link.
    private static func children(of dir: URL) -> [String] {
        guard fileType(at: dir) == S_IFDIR else { return [] }
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }
}

// MARK: - Rules

extension Discovery {
    /// Every `node_modules` below the project roots, named after its project's path below its root
    /// (`acme/uat/app_v2`; the last folder name alone is ambiguous). The detail is how long ago the
    /// project was last worked on, and a project worked on within `inactiveAfterDays` carries the `active` badge.
    /// A `node_modules` whose folder has no `package.json` is not a project's own dependencies, so it carries the
    /// `noPackageJSON` badge, which keeps it from being ticked by default.
    static func nodeModules() -> Function {
        { env in
            let now = env.now()
            return try ProjectDiscovery.nodeModules(in: env).map { project, nodeModules in
                var badges: [Badge] = []
                if project.isActive(at: now, inactiveAfterDays: env.inactiveAfterDays) { badges.append(.active) }
                if !ProjectDiscovery.hasPackageJSON(project.root) { badges.append(.noPackageJSON) }
                return DiscoveredItem(
                    url: nodeModules,
                    displayName: project.name,
                    detail: relativeAge(of: project.lastActivity, now: now),
                    lastActivity: project.lastActivity,
                    badges: badges
                )
            }
        }
    }

    /// Each of `artifacts` (folders relative to a project, such as `android/app/build`) that exists in a
    /// project accepted by `marker`, named `<project path below its root>/<artifact>`
    /// (`kavitorihr/kavitorihr_mobile/android/app/build`). Each item carries its project's last activity.
    static func projectBuilds(artifacts: [String], marker: @escaping @Sendable (URL) -> Bool) -> Function {
        { env in
            // A folder without any artifact is the common case, so that is checked before the marker.
            let projects = try ProjectDiscovery.projects(in: env) { project in
                artifacts.contains { ProjectDiscovery.containsRealFolder($0, in: project) } && marker(project)
            }
            return projects.flatMap { project in
                artifacts
                    .filter { ProjectDiscovery.containsRealFolder($0, in: project.root) }
                    .map { artifact in
                        DiscoveredItem(
                            url: project.root.appending(path: artifact, directoryHint: .isDirectory),
                            displayName: "\(project.name)/\(artifact)",
                            lastActivity: project.lastActivity
                        )
                    }
            }
        }
    }

    /// `"today"`, `"1 day"`, `"2 days"`: whole days since `date`. A date in the future counts as today.
    private static func relativeAge(of date: Date, now: Date) -> String {
        let days = Int(max(0, now.timeIntervalSince(date)) / 86_400)
        switch days {
        case 0: return "today"
        case 1: return "1 day"
        default: return "\(days) days"
        }
    }
}
