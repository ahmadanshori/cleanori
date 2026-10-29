import Foundation
import Testing
import CleanoriCore

private func folder(_ rel: String, in home: TempHome) -> URL {
    home.url.appending(path: rel, directoryHint: .isDirectory)
}

// MARK: - Refused folders

@Test func refusesTheHomeFolderItself() throws {
    let home = try TempHome(); defer { home.cleanup() }
    for spelling in [home.url, URL(fileURLWithPath: home.url.path + "/"), folder(".", in: home), folder("Developer/..", in: home)] {
        #expect(ProjectRootPolicy.problem(with: spelling, home: home.url) == .isHome, "\(spelling.path)")
    }
}

@Test func refusesAFolderThatContainsHome() throws {
    let home = try TempHome(); defer { home.cleanup() }
    for outer in [home.url.deletingLastPathComponent(), URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/private")] {
        #expect(ProjectRootPolicy.problem(with: outer, home: home.url) == .containsHome, "\(outer.path)")
    }
}

@Test func refusesLibraryAndEverythingInIt() throws {
    let home = try TempHome(); defer { home.cleanup() }
    for rel in ["Library", "Library/Developer/Xcode", "Library/Application Support/Code", "library/caches"] {
        #expect(ProjectRootPolicy.problem(with: folder(rel, in: home), home: home.url) == .inLibrary, "\(rel)")
    }
}

@Test func refusesFoldersOutsideHome() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let outside = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        URL(fileURLWithPath: "/tmp/projects", isDirectory: true),
        // Shares the home folder's name as a prefix, but is a sibling.
        URL(fileURLWithPath: home.url.path + "2", isDirectory: true),
        folder("../escape", in: home),
        URL(string: "https://example.com/Developer")!,
    ]
    for url in outside {
        #expect(ProjectRootPolicy.problem(with: url, home: home.url) == .outsideHome, "\(url)")
    }
}

@Test func refusesAFolderThatIsAlreadyListed() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let developer = folder("Developer", in: home)
    for spelling in [developer, URL(fileURLWithPath: developer.path + "/"), folder("./Developer", in: home), folder("developer", in: home)] {
        #expect(ProjectRootPolicy.problem(with: spelling, home: home.url, existing: [developer]) == .alreadyListed, "\(spelling.path)")
    }
}

@Test func refusesALinkThatLeadsToHomeOrLibrary() throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.dir("Library/Caches")
    let toHome = try home.symlink("Developer/home-link", to: home.url)
    let toLibrary = try home.symlink("Developer/caches-link", to: folder("Library/Caches", in: home))
    #expect(ProjectRootPolicy.problem(with: toHome, home: home.url) == .isHome)
    #expect(ProjectRootPolicy.problem(with: toLibrary, home: home.url) == .inLibrary)
}

@Test func anUnusableHomeRefusesEverything() throws {
    let anywhere = URL(fileURLWithPath: "/Users/someone/Developer", isDirectory: true)
    #expect(ProjectRootPolicy.problem(with: anywhere, home: URL(fileURLWithPath: "/")) != nil)
    #expect(ProjectRootPolicy.problem(with: anywhere, home: URL(string: "https://example.com/Users/someone")!) != nil)
}

// MARK: - Accepted folders

@Test func acceptsFoldersInsideHome() throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.dir("Developer")
    let existing = [folder("Developer", in: home)]
    // `Developer/Library` and `Libraryish` are not `~/Library`; a folder inside a listed one is a separate entry.
    for rel in ["Work/clients", "Libraryish", "Developer/Library", "Developer/app", ".worktrees", "Not Yet Created"] {
        #expect(ProjectRootPolicy.problem(with: folder(rel, in: home), home: home.url, existing: existing) == nil, "\(rel)")
    }
    #expect(ProjectRootPolicy.problem(with: folder("Developer", in: home), home: home.url) == nil)
}

// MARK: - Stored lists

@Test func allowedKeepsOnlyAcceptableFoldersInOrderWithoutDuplicates() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let stored = [
        home.url,
        folder("Work", in: home),
        URL(fileURLWithPath: "/tmp/projects", isDirectory: true),
        folder("Library/Developer", in: home),
        folder("Developer", in: home),
        folder("Work/", in: home),
        home.url.deletingLastPathComponent(),
    ]
    #expect(ProjectRootPolicy.allowed(stored, home: home.url).map(\.path) == [
        folder("Work", in: home).path, folder("Developer", in: home).path,
    ])
}

@Test func everyProblemHasAMessage() {
    let problems: [ProjectRootProblem] = [.isHome, .containsHome, .inLibrary, .outsideHome, .alreadyListed]
    #expect(problems.allSatisfy { !$0.message.isEmpty })
    #expect(Set(problems.map(\.message)).count == problems.count)
}
