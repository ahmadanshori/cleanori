import Foundation

/// Why a folder cannot be one of the folders searched for projects.
public enum ProjectRootProblem: Sendable, Equatable {
    case isHome
    case containsHome
    case inLibrary
    case outsideHome
    case alreadyListed

    /// What Settings says when it refuses the folder.
    public var message: String {
        switch self {
        case .isHome:
            "Your home folder can't be a project folder. Add the folders that hold your projects, such as ~/Developer."
        case .containsHome:
            "It contains your home folder. Add the folders that hold your projects instead."
        case .inLibrary:
            "Folders in ~/Library hold app data, not projects."
        case .outsideHome:
            "Only folders inside your home folder can be project folders."
        case .alreadyListed:
            "It is already in the list."
        }
    }
}

/// Which folders may be searched for projects (Settings › Project folders, spec §6.4).
///
/// The project walk lists every `node_modules` below these folders and ticks the inactive ones for permanent deletion,
/// so a folder that holds more than projects is refused: the home folder, anything that contains it, `~/Library` and
/// anything in it, and anything outside the home folder. Paths are compared by their components after removing `.`
/// and `..`, ignoring letter case (the default macOS volume does), and once more with symbolic links resolved, so a
/// link that leads to the home folder or into `~/Library` is refused too.
public enum ProjectRootPolicy {
    /// Why `folder` cannot be added to `existing`, or `nil` when it can.
    public static func problem(with folder: URL, home: URL, existing: [URL] = []) -> ProjectRootProblem? {
        guard let homeParts = components(of: home), !homeParts.isEmpty,
              let parts = components(of: folder)
        else { return .outsideHome }
        if let problem = placement(of: parts, home: homeParts) { return problem }
        // The same folder reached through a link: only what makes a walk too wide is checked here, since a root that
        // is itself a link is never walked.
        if let resolvedHome = components(of: home.resolvingSymlinksInPath()), !resolvedHome.isEmpty,
           let resolved = components(of: folder.resolvingSymlinksInPath()),
           let problem = placement(of: resolved, home: resolvedHome), problem != .outsideHome {
            return problem
        }
        if existing.contains(where: { components(of: $0).map { isSame($0, parts) } ?? false }) { return .alreadyListed }
        return nil
    }

    /// The folders of `stored` that may be searched, in their order, each once. Used for a list saved by an older
    /// build, so a folder Settings would now refuse is never walked.
    public static func allowed(_ stored: [URL], home: URL) -> [URL] {
        var kept: [URL] = []
        for folder in stored where problem(with: folder, home: home, existing: kept) == nil {
            kept.append(folder)
        }
        return kept
    }

    // MARK: - Paths

    private static func placement(of parts: [String], home: [String]) -> ProjectRootProblem? {
        if isSame(parts, home) { return .isHome }
        if isInside(home, parts) { return .containsHome }
        guard isInside(parts, home) else { return .outsideHome }
        if isInside(parts, home + ["Library"]) || isSame(parts, home + ["Library"]) { return .inLibrary }
        return nil
    }

    /// Splits a file URL's path into components, dropping `.` and resolving `..` lexically. `nil` for other URLs.
    private static func components(of url: URL) -> [String]? {
        guard url.isFileURL else { return nil }
        var stack: [String] = []
        for part in url.path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !stack.isEmpty { stack.removeLast() }
            default: stack.append(String(part))
            }
        }
        return stack
    }

    private static func isSame(_ a: [String], _ b: [String]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.caseInsensitiveCompare($1) == .orderedSame }
    }

    /// Whether `path` is strictly below `folder`.
    private static func isInside(_ path: [String], _ folder: [String]) -> Bool {
        path.count > folder.count && isSame(Array(path.prefix(folder.count)), folder)
    }
}
