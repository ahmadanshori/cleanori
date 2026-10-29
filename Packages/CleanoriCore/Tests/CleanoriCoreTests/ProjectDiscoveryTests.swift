import Foundation
import Testing
import CleanoriCore

/// "Now" for a test, cut to whole seconds so a file dated N days before it reads back exactly N days old.
private func wholeSecondNow() -> Date {
    Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))
}

private extension Date {
    func daysEarlier(_ days: Int) -> Date { addingTimeInterval(-Double(days) * 86_400) }
}

private func discover(_ ruleID: String, using env: CoreEnvironment) async throws -> [DiscoveredItem] {
    let rule = try #require(Catalog.rule(id: ruleID))
    return try await rule.discover(env)
}

private func discover(
    _ ruleID: String, in home: TempHome, now: Date = wholeSecondNow()
) async throws -> [DiscoveredItem] {
    try await discover(ruleID, using: .test(home: home, now: now))
}

private func names(_ items: [DiscoveredItem]) -> [String] {
    items.map(\.displayName).sorted()
}

private func path(_ rel: String, in home: TempHome) -> String {
    home.url.appending(path: rel, directoryHint: .notDirectory).path
}

// MARK: - node_modules

@Test func findsTopLevelNodeModulesOnly() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Developer/app/node_modules/pkg/index.js", bytes: 16)
    try home.file("Developer/app/node_modules/pkg/node_modules/dep/index.js", bytes: 16)
    try home.file("Developer/app/src/index.ts", bytes: 16)
    let items = try await discover("node.modules", in: home)
    #expect(items.map(\.displayName) == ["app"])
    #expect(items.map(\.url.path) == [path("Developer/app/node_modules", in: home)])
}

@Test func discoversWorktreeAndMonorepoProjects() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let now = wholeSecondNow()
    // A worktree inside a repository, and a package inside a monorepo. Each has its own node_modules,
    // and the repository and the monorepo root have newer files of their own than the package below them.
    try home.file("Developer/game/README.md", bytes: 16, modified: now.daysEarlier(1))
    try home.file("Developer/game/.worktrees/m1/package.json", bytes: 16, modified: now.daysEarlier(10))
    try home.file("Developer/game/.worktrees/m1/node_modules/a/index.js", bytes: 16)
    try home.file("Developer/mono/package.json", bytes: 16, modified: now.daysEarlier(3))
    try home.file("Developer/mono/packages/web/package.json", bytes: 16, modified: now.daysEarlier(200))
    try home.file("Developer/mono/packages/web/node_modules/a/index.js", bytes: 16)

    let items = try await discover("node.modules", in: home, now: now)
    #expect(names(items) == ["game/.worktrees/m1", "mono/packages/web"])

    let worktree = try #require(items.first { $0.displayName == "game/.worktrees/m1" })
    let package = try #require(items.first { $0.displayName == "mono/packages/web" })
    // Each item is the node_modules of its own project root...
    #expect(worktree.url.path == path("Developer/game/.worktrees/m1/node_modules", in: home))
    #expect(package.url.path == path("Developer/mono/packages/web/node_modules", in: home))
    // ...and carries that project's own activity, not the one of the repository or monorepo around it.
    #expect(abs(try #require(worktree.lastActivity).timeIntervalSince(now.daysEarlier(10))) < 1)
    #expect(abs(try #require(package.lastActivity).timeIntervalSince(now.daysEarlier(200))) < 1)
    #expect(worktree.detail == "10 days")
    #expect(package.detail == "200 days")
    #expect(worktree.badges == [.active])
    #expect(package.badges == [])
}

@Test func aRepositoryAndItsWorktreeAreSeparateProjects() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let now = wholeSecondNow()
    try home.file("Developer/game/README.md", bytes: 16, modified: now.daysEarlier(100))
    try home.file("Developer/game/package.json", bytes: 16, modified: now.daysEarlier(100))
    try home.file("Developer/game/node_modules/a/index.js", bytes: 16)
    try home.file("Developer/game/.worktrees/m1/package.json", bytes: 16, modified: now.daysEarlier(1))
    try home.file("Developer/game/.worktrees/m1/src/main.ts", bytes: 16, modified: now.daysEarlier(1))
    try home.file("Developer/game/.worktrees/m1/node_modules/a/index.js", bytes: 16)

    let items = try await discover("node.modules", in: home, now: now)
    #expect(names(items) == ["game", "game/.worktrees/m1"])
    let repository = try #require(items.first { $0.displayName == "game" })
    let worktree = try #require(items.first { $0.displayName == "game/.worktrees/m1" })
    #expect(repository.url.path == path("Developer/game/node_modules", in: home))
    #expect(worktree.url.path == path("Developer/game/.worktrees/m1/node_modules", in: home))
    // The worktree's files sit three or four levels below the repository, so they do not make it active.
    #expect(repository.detail == "100 days")
    #expect(repository.badges == [])
    #expect(worktree.detail == "1 day")
    #expect(worktree.badges == [.active])
}

@Test func activityIgnoresNodeModulesAndGit() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let now = wholeSecondNow()
    try home.file("Developer/app/package.json", bytes: 16, modified: now.daysEarlier(100))
    try home.file("Developer/app/src/index.ts", bytes: 16, modified: now.daysEarlier(100))
    // Both of these are within two levels of the project, so only the exclusion keeps them out.
    try home.file("Developer/app/node_modules/.package-lock.json", bytes: 16, modified: now)
    try home.file("Developer/app/.git/HEAD", bytes: 16, modified: now)

    let item = try #require(try await discover("node.modules", in: home, now: now).first)
    #expect(abs(try #require(item.lastActivity).timeIntervalSince(now.daysEarlier(100))) < 1)
    #expect(item.badges == [])
    #expect(item.detail == "100 days")
}

@Test func activityLooksTwoLevelsDeep() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let now = wholeSecondNow()
    try home.file("Developer/app/package.json", bytes: 16, modified: now.daysEarlier(50))
    try home.file("Developer/app/src/a.ts", bytes: 16, modified: now.daysEarlier(20))
    try home.file("Developer/app/src/deep/b.ts", bytes: 16, modified: now)
    try home.file("Developer/app/node_modules/a", bytes: 16)
    let item = try #require(try await discover("node.modules", in: home, now: now).first)
    // `src/a.ts` is two levels down and counts; `src/deep/b.ts` is three levels down and does not.
    #expect(item.detail == "20 days")
}

@Test func activityCountsFoldersListedAfterAGitFile() async throws {
    // In a git worktree `.git` is a file, not a folder. Foundation's enumerator skips the next folder it would have
    // entered when `skipDescendants()` is called on a non-folder, so the files below that folder were never seen,
    // which made an active project look inactive. Each worktree-style project here has a `.git` file next to
    // `src/`, which holds its newest file, so whatever order the file system lists them in, `src/` follows
    // the `.git` file in some of them.
    let home = try TempHome(); defer { home.cleanup() }
    let now = wholeSecondNow()
    for index in 0..<10 {
        let n = String(format: "%02d", index)
        try home.file("Developer/wt\(n)/.git", bytes: 16, modified: now)
        try home.file("Developer/wt\(n)/package.json", bytes: 16, modified: now.daysEarlier(100))
        try home.file("Developer/wt\(n)/src/main.ts", bytes: 16, modified: now.daysEarlier(2))
        try home.file("Developer/wt\(n)/docs/old.md", bytes: 16, modified: now.daysEarlier(150))
        try home.file("Developer/wt\(n)/node_modules/a", bytes: 16)
    }

    let items = try await discover("node.modules", in: home, now: now)

    #expect(items.count == 10)
    for item in items {
        // The newest file is `src/main.ts`; the `.git` file itself is never counted.
        #expect(abs(try #require(item.lastActivity).timeIntervalSince(now.daysEarlier(2))) < 1, "\(item.displayName)")
        #expect(item.detail == "2 days", "\(item.displayName)")
        #expect(item.badges == [.active], "\(item.displayName)")
    }
}

@Test func activityFallsBackToTheProjectFolderDate() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let now = wholeSecondNow()
    // Nothing but node_modules inside, so there is no project file to look at.
    try home.file("Developer/app/node_modules/pkg/index.js", bytes: 16, modified: now)
    try FileManager.default.setAttributes(
        [.modificationDate: now.daysEarlier(90)],
        ofItemAtPath: path("Developer/app", in: home)
    )
    let item = try #require(try await discover("node.modules", in: home, now: now).first)
    #expect(abs(try #require(item.lastActivity).timeIntervalSince(now.daysEarlier(90))) < 1)
    #expect(item.detail == "90 days")
    #expect(item.badges == [.noPackageJSON]) // not active, and there is no package.json either
}

@Test func recentProjectIsActive() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let now = wholeSecondNow()
    try home.file("Developer/app/package.json", bytes: 16, modified: now.daysEarlier(30))
    try home.file("Developer/app/src/index.ts", bytes: 16, modified: now.daysEarlier(2))
    try home.file("Developer/app/node_modules/pkg/index.js", bytes: 16)
    let item = try #require(try await discover("node.modules", in: home, now: now).first)
    #expect(item.badges == [.active])
    #expect(item.detail == "2 days")
}

@Test func projectStaysActiveUpToTheThresholdAndNotBeyond() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let now = wholeSecondNow()
    try home.file("Developer/atLimit/package.json", bytes: 16, modified: now.daysEarlier(60))
    try home.file("Developer/atLimit/node_modules/a", bytes: 16)
    try home.file("Developer/pastLimit/package.json", bytes: 16, modified: now.daysEarlier(61))
    try home.file("Developer/pastLimit/node_modules/a", bytes: 16)

    let items = try await discover("node.modules", in: home, now: now)
    let atLimit = try #require(items.first { $0.displayName == "atLimit" })
    let pastLimit = try #require(items.first { $0.displayName == "pastLimit" })
    #expect(atLimit.badges == [.active])
    #expect(pastLimit.badges == [])
}

@Test func detailReadsAsRelativeAge() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let now = wholeSecondNow()
    for (name, days) in [("today", 0), ("one", 1), ("two", 2), ("many", 120)] {
        try home.file("Developer/\(name)/package.json", bytes: 16, modified: now.daysEarlier(days))
        try home.file("Developer/\(name)/node_modules/a", bytes: 16)
    }
    let items = try await discover("node.modules", in: home, now: now)
    let detail = Dictionary(uniqueKeysWithValues: items.map { ($0.displayName, $0.detail) })
    #expect(detail == ["today": "today", "one": "1 day", "two": "2 days", "many": "120 days"])
}

@Test func nodeModulesItemsAreNamedByPathBelowTheProjectRoot() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    // Three projects with the same folder name: the last path component alone would be ambiguous.
    for parent in ["acme", "acme/uat", "acme/migration"] {
        try home.file("Developer/\(parent)/app_v2/node_modules/a", bytes: 16)
    }
    let items = try await discover("node.modules", in: home)
    #expect(names(items) == [
        "acme/app_v2", "acme/migration/app_v2", "acme/uat/app_v2",
    ])
}

@Test func nodeModulesNamesKeepSpacesCommasParenthesesAndURLCharacters() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    // `#`, `%` and `?` mean something in a URL; they must stay literal characters of the folder name.
    let name = "My App (v2, final) #1 100% done?"
    try home.file("Developer/Client Work/\(name)/node_modules/a", bytes: 16)
    try home.file("Developer/Client Work/\(name)/package.json", bytes: 16)
    try home.file("Developer/Client Work/\(name)/.next/BUILD_ID", bytes: 16)
    let item = try #require(try await discover("node.modules", in: home).first)
    #expect(item.displayName == "Client Work/\(name)")
    #expect(item.url.path == path("Developer/Client Work/\(name)/node_modules", in: home))
    #expect(FileManager.default.fileExists(atPath: item.url.path))
    let build = try #require(try await discover("build.web", in: home).first)
    #expect(build.url.path == path("Developer/Client Work/\(name)/.next", in: home))
    #expect(FileManager.default.fileExists(atPath: build.url.path))
}

@Test func aFileNamedNodeModulesIsNotAnItem() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Developer/app/node_modules", bytes: 16)
    try home.file("Developer/ok/node_modules/a", bytes: 16)
    #expect(names(try await discover("node.modules", in: home)) == ["ok"])
}

// MARK: - Walking

@Test func doesNotDescendIntoFoldersThatNeverHoldProjects() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Developer/app/node_modules/a", bytes: 16) // the one real project
    // A node_modules below any of these must not be reported: it is a copy inside something else.
    for hidden in [
        "app/.git/hooks", "app/build", "app/ios/Pods/Foo", "DerivedData/Foo", "app/.next/standalone",
        "app/.expo", "app/.gradle", "Tool.app/Contents/Resources",
        // Android's CMake output (`.cxx`) mirrors the absolute path of the sources it compiles,
        // `node_modules` included: on the owner's Mac that is 173 of the 213 folders with that name.
        "app/android/app/.cxx/Debug/4x3b/arm64-v8a/CMakeFiles/lib.dir/Users/me/Developer/app",
    ] {
        try home.file("Developer/\(hidden)/node_modules/a", bytes: 16)
    }
    let items = try await discover("node.modules", in: home)
    #expect(items.map(\.url.path) == [path("Developer/app/node_modules", in: home)])
}

@Test func doesNotWalkToolFoldersOrLibrary() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Developer/app/package.json", bytes: 16)
    try home.file("Developer/app/node_modules/a", bytes: 16)
    // What a review found ticked for deletion: npm itself with the global packages, an editor extension and an
    // unplugged Yarn PnP package. Each folder here has a package.json, so only the walk can keep them out.
    let skipped = [
        ".nvm/versions/node/v20.0.0/lib", ".vscode/extensions/acme.tool-1.0.0",
        ".vscode-insiders/extensions/acme.tool-1.0.0", ".cursor/extensions/acme.tool-1.0.0",
        "app/.yarn/unplugged/esbuild-npm-0.19.0-abc", ".cache/tool", ".local/share/tool", ".config/tool",
        ".npm/_npx/1234", ".pnpm-store/v3/tmp", ".bun/install/global", ".gradle/caches/tool", ".android/tool",
        ".cargo/registry/tool", ".rustup/toolchains/tool",
        // `Library` is skipped at any depth below a project root.
        "Library/Application Support/Code/tool", "app/Library/tool", "backup/old-mac/Library/Caches/tool",
    ]
    for folder in skipped {
        try home.file("Developer/\(folder)/package.json", bytes: 16)
        try home.file("Developer/\(folder)/node_modules/a", bytes: 16)
        try home.file("Developer/\(folder)/.next/BUILD_ID", bytes: 16)
    }
    #expect(names(try await discover("node.modules", in: home)) == ["app"])
    #expect(try await discover("build.web", in: home).isEmpty)
}

@Test func otherHiddenFoldersAreStillWalked() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    // Worktrees live in a hidden folder, and so do other projects; names that only start like a skipped one
    // (`.config-app`, `Libraryish`) are ordinary folders.
    for project in ["game/.worktrees/m1", ".experiments/proto", ".config-app", "Libraryish/site"] {
        try home.file("Developer/\(project)/package.json", bytes: 16)
        try home.file("Developer/\(project)/node_modules/a", bytes: 16)
    }
    #expect(names(try await discover("node.modules", in: home)) == [
        ".config-app", ".experiments/proto", "Libraryish/site", "game/.worktrees/m1",
    ])
}

@Test func aProjectRootNamedLibraryIsStillWalked() async throws {
    // Only folders below a root are skipped by name: a root the user chose is walked whatever it is called.
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Developer/Library/app/package.json", bytes: 16)
    try home.file("Developer/Library/app/node_modules/a", bytes: 16)
    var env = CoreEnvironment.test(home: home)
    env.projectRoots = [home.url.appending(path: "Developer/Library", directoryHint: .isDirectory)]
    #expect(names(try await discover("node.modules", using: env)) == ["app"])
}

@Test func aHomeFolderRootSkipsLibraryAndToolFolders() async throws {
    // Settings refuses the home folder as a project folder, but the walk must stay safe if one ever gets through.
    let home = try TempHome(); defer { home.cleanup() }
    try home.file(".nvm/versions/node/v20.0.0/lib/node_modules/npm/package.json", bytes: 16)
    try home.file(".vscode/extensions/acme.tool-1.0.0/package.json", bytes: 16)
    try home.file(".vscode/extensions/acme.tool-1.0.0/node_modules/a", bytes: 16)
    try home.file("Library/Application Support/Code/User/tool/package.json", bytes: 16)
    try home.file("Library/Application Support/Code/User/tool/node_modules/a", bytes: 16)
    try home.file("Developer/app/package.json", bytes: 16)
    try home.file("Developer/app/node_modules/a", bytes: 16)
    var env = CoreEnvironment.test(home: home)
    env.projectRoots = [home.url]
    #expect(names(try await discover("node.modules", using: env)) == ["Developer/app"])
}

@Test func nodeModulesWithoutAPackageJSONBesideItIsMarked() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Developer/app/package.json", bytes: 16)
    try home.file("Developer/app/node_modules/a", bytes: 16)
    try home.file("Developer/loose/notes.md", bytes: 16)
    try home.file("Developer/loose/node_modules/a", bytes: 16)
    // A folder called package.json is not a manifest.
    try home.dir("Developer/odd/package.json")
    try home.file("Developer/odd/node_modules/a", bytes: 16)
    let items = try await discover("node.modules", in: home)
    let badges = Dictionary(uniqueKeysWithValues: items.map { ($0.displayName, $0.badges) })
    #expect(badges == ["app": [.active], "loose": [.active, .noPackageJSON], "odd": [.active, .noPackageJSON]])
}

@Test func symlinkedFoldersAreNeverFollowed() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Elsewhere/proj/node_modules/a", bytes: 16)
    // A project folder that is a link, and a node_modules that is a link: neither is an item.
    try home.dir("Developer")
    try home.symlink("Developer/linkedProject", to: home.url.appending(path: "Elsewhere/proj", directoryHint: .isDirectory))
    try home.file("Developer/linkedModules/src/a.ts", bytes: 16)
    try home.symlink(
        "Developer/linkedModules/node_modules",
        to: home.url.appending(path: "Elsewhere/proj/node_modules", directoryHint: .isDirectory)
    )
    try home.file("Developer/ok/node_modules/a", bytes: 16)
    #expect(names(try await discover("node.modules", in: home)) == ["ok"])
}

@Test func projectsListedAfterASymlinkAreStillWalked() async throws {
    // Foundation's enumerator has a quirk: `skipDescendants()` called on a link (not a folder) makes it skip the
    // next folder it would have entered. Links (to folders and to files) and real project folders are interleaved
    // by name here, so whatever order the file system lists them in, some project comes right after a link, and
    // every project's node_modules must still be found.
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Elsewhere/proj/node_modules/a", bytes: 16)
    let linkedFile = try home.file("Elsewhere/notes.txt", bytes: 16)
    var expected: [String] = []
    for index in 0..<10 {
        let n = String(format: "%02d", index)
        try home.file("Developer/proj\(n)/package.json", bytes: 16)
        try home.file("Developer/proj\(n)/node_modules/a", bytes: 16)
        expected.append("proj\(n)")
        // `proj00`, `proj00-link`, `proj01`, `proj01-link`...: sorted by name, links and projects alternate.
        if index.isMultiple(of: 2) {
            try home.symlink("Developer/proj\(n)-link", to: home.url.appending(path: "Elsewhere/proj", directoryHint: .isDirectory))
        } else {
            try home.symlink("Developer/proj\(n)-link", to: linkedFile)
        }
    }

    #expect(names(try await discover("node.modules", in: home)) == expected)
}

@Test func aSymlinkedProjectRootIsNotWalked() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Elsewhere/app/node_modules/a", bytes: 16)
    try home.symlink("Developer", to: home.url.appending(path: "Elsewhere", directoryHint: .isDirectory))
    #expect(try await discover("node.modules", in: home).isEmpty)
}

@Test func unreadableFolderDoesNotStopTheWalk() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Developer/locked/inner/node_modules/a", bytes: 16)
    try home.file("Developer/ok/node_modules/a", bytes: 16)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path("Developer/locked", in: home))
    #expect(names(try await discover("node.modules", in: home)) == ["ok"])
    #expect(names(try await discover("build.web", in: home)).isEmpty)
}

@Test func missingProjectRootIsSkipped() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Work/app/node_modules/a", bytes: 16)
    var env = CoreEnvironment.test(home: home)
    env.projectRoots = [
        home.url.appending(path: "Developer", directoryHint: .isDirectory), // does not exist
        home.url.appending(path: "Work", directoryHint: .isDirectory),
    ]
    #expect(names(try await discover("node.modules", using: env)) == ["app"])
}

@Test func eachProjectRootNamesItsProjectsRelativeToItself() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Developer/a/node_modules/x", bytes: 16)
    try home.file("Work/client/b/node_modules/x", bytes: 16)
    var env = CoreEnvironment.test(home: home)
    env.projectRoots = ["Developer", "Work"].map { home.url.appending(path: $0, directoryHint: .isDirectory) }
    #expect(names(try await discover("node.modules", using: env)) == ["a", "client/b"])
}

@Test func overlappingProjectRootsReportAProjectOnce() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Developer/app/node_modules/a", bytes: 16)
    try home.file("Developer/app/package.json", bytes: 16)
    try home.file("Developer/app/.next/BUILD_ID", bytes: 16)
    var env = CoreEnvironment.test(home: home)
    env.projectRoots = ["Developer", "Developer/app"].map { home.url.appending(path: $0, directoryHint: .isDirectory) }
    #expect(try await discover("node.modules", using: env).count == 1)
    #expect(try await discover("build.web", using: env).count == 1)
}

@Test func aProjectRootThatIsAProjectIsNamedAfterItself() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Developer/app/node_modules/a", bytes: 16)
    try home.file("Developer/app/package.json", bytes: 16)
    try home.file("Developer/app/.next/BUILD_ID", bytes: 16)
    var env = CoreEnvironment.test(home: home)
    env.projectRoots = [home.url.appending(path: "Developer/app", directoryHint: .isDirectory)]
    #expect(names(try await discover("node.modules", using: env)) == ["app"])
    #expect(names(try await discover("build.web", using: env)) == ["app/.next"])
}

@Test func itemsKeepTheSpellingOfTheRootTheyWereFoundUnder() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Real/Developer/app/node_modules/a", bytes: 16)
    try home.file("Real/Developer/app/package.json", bytes: 16)
    try home.file("Real/Developer/app/.next/BUILD_ID", bytes: 16)
    // `Via` is a link to `Real`, so the root is reached through a symlinked ancestor. Foundation's enumerator
    // reports canonical paths, but items must stay below the root as given (SafetyGuard compares paths lexically).
    try home.symlink("Via", to: home.url.appending(path: "Real", directoryHint: .isDirectory))
    var env = CoreEnvironment.test(home: home)
    env.projectRoots = [home.url.appending(path: "Via/Developer", directoryHint: .isDirectory)]

    let modules = try await discover("node.modules", using: env)
    #expect(modules.map(\.displayName) == ["app"])
    #expect(modules.map(\.url.path) == [path("Via/Developer/app/node_modules", in: home)])
    let builds = try await discover("build.web", using: env)
    #expect(builds.map(\.displayName) == ["app/.next"])
    #expect(builds.map(\.url.path) == [path("Via/Developer/app/.next", in: home)])
}

// MARK: - Project builds

@Test func androidBuildRequiresSettingsGradle() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let project = "Developer/kavitorihr/kavitorihr_mobile"
    try home.file("\(project)/android/app/build/outputs/app.apk", bytes: 16)
    try home.file("\(project)/android/.gradle/8.5/fileHashes", bytes: 16)
    #expect(try await discover("build.android", in: home).isEmpty)

    try home.file("\(project)/android/settings.gradle", bytes: 16)
    let items = try await discover("build.android", in: home)
    #expect(names(items) == [
        "kavitorihr/kavitorihr_mobile/android/.gradle", "kavitorihr/kavitorihr_mobile/android/app/build",
    ])
    #expect(Set(items.map(\.url.path)) == [
        path("\(project)/android/.gradle", in: home), path("\(project)/android/app/build", in: home),
    ])
}

@Test func androidBuildAcceptsKotlinSettingsScript() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Developer/app/android/app/build/a", bytes: 16)
    try home.file("Developer/app/android/settings.gradle.kts", bytes: 16)
    #expect(names(try await discover("build.android", in: home)) == ["app/android/app/build"])
}

@Test func androidBuildOnlyListsFoldersThatExist() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Developer/app/android/settings.gradle", bytes: 16)
    try home.file("Developer/app/android/.gradle/a", bytes: 16)
    #expect(names(try await discover("build.android", in: home)) == ["app/android/.gradle"])
}

@Test func iosBuildRequiresAnXcodeProject() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Developer/mobile/ios/build/Debug/app.o", bytes: 16)
    #expect(try await discover("build.ios", in: home).isEmpty)

    try home.file("Developer/mobile/ios/Runner.xcodeproj/project.pbxproj", bytes: 16)
    let items = try await discover("build.ios", in: home)
    #expect(names(items) == ["mobile/ios/build"])
    #expect(items.map(\.url.path) == [path("Developer/mobile/ios/build", in: home)])
}

@Test func podsDefaultNeverAndRequiresPodfile() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Developer/mobile/ios/Pods/Pods.xcodeproj/project.pbxproj", bytes: 16)
    #expect(try await discover("build.pods", in: home).isEmpty)

    try home.file("Developer/mobile/ios/Podfile", bytes: 16)
    let items = try await discover("build.pods", in: home)
    #expect(names(items) == ["mobile/ios/Pods"])
    #expect(items.map(\.url.path) == [path("Developer/mobile/ios/Pods", in: home)])
    let rule = try #require(Catalog.rule(id: "build.pods"))
    #expect(rule.defaultSelection == .never)
}

@Test func webBuildRequiresPackageJSON() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    // Next.js puts a package.json inside .next; that must not make .next itself a project.
    try home.file("Developer/site/.next/package.json", bytes: 16)
    try home.file("Developer/site/.next/BUILD_ID", bytes: 16)
    try home.file("Developer/site/.expo/settings.json", bytes: 16)
    #expect(try await discover("build.web", in: home).isEmpty)

    try home.file("Developer/site/package.json", bytes: 16)
    let items = try await discover("build.web", in: home)
    #expect(names(items) == ["site/.expo", "site/.next"])
    #expect(Set(items.map(\.url.path)) == [
        path("Developer/site/.expo", in: home), path("Developer/site/.next", in: home),
    ])
}

@Test func buildsAreFoundInWorktreesAndMonorepoPackages() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    for project in ["mono", "mono/packages/web", "game/.worktrees/m1"] {
        try home.file("Developer/\(project)/package.json", bytes: 16)
        try home.file("Developer/\(project)/.next/BUILD_ID", bytes: 16)
    }
    #expect(names(try await discover("build.web", in: home)) == [
        "game/.worktrees/m1/.next", "mono/.next", "mono/packages/web/.next",
    ])
}

@Test func projectBuildItemsCarryTheirProjectsActivity() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    let now = wholeSecondNow()
    try home.file("Developer/site/package.json", bytes: 16, modified: now.daysEarlier(30))
    // Files in `.next` are two levels down, so they count as project activity too: date them as well.
    try home.file("Developer/site/.next/BUILD_ID", bytes: 16, modified: now.daysEarlier(40))
    let item = try #require(try await discover("build.web", in: home, now: now).first)
    #expect(abs(try #require(item.lastActivity).timeIntervalSince(now.daysEarlier(30))) < 1)
    #expect(item.badges == [])
}

@Test func buildFoldersBehindSymlinksAreIgnored() async throws {
    let home = try TempHome(); defer { home.cleanup() }
    try home.file("Elsewhere/android/settings.gradle", bytes: 16)
    try home.file("Elsewhere/android/app/build/a", bytes: 16)
    try home.file("Elsewhere/cache/a", bytes: 16)
    // `android` is a link to a folder elsewhere: nothing below it may be offered for deletion.
    try home.file("Developer/linkedAndroid/package.json", bytes: 16)
    try home.symlink("Developer/linkedAndroid/android", to: home.url.appending(path: "Elsewhere/android", directoryHint: .isDirectory))
    // `build` itself is a link.
    try home.file("Developer/linkedBuild/android/settings.gradle", bytes: 16)
    try home.dir("Developer/linkedBuild/android/app")
    try home.symlink("Developer/linkedBuild/android/app/build", to: home.url.appending(path: "Elsewhere/cache", directoryHint: .isDirectory))
    // `.next` is a link.
    try home.file("Developer/linkedNext/package.json", bytes: 16)
    try home.symlink("Developer/linkedNext/.next", to: home.url.appending(path: "Elsewhere/cache", directoryHint: .isDirectory))

    #expect(try await discover("build.android", in: home).isEmpty)
    #expect(try await discover("build.web", in: home).isEmpty)
}

// MARK: - Rules

@Test func projectRulesMatchTheRuleTable() throws {
    // id → group, method, default selection, locks, title (spec §5.3).
    let expected: [(String, RuleGroup, DefaultSelection, [LockCondition], String)] = [
        ("node.modules", .nodeModules, .ifInactive, [], "node_modules"),
        ("build.android", .projectBuilds, .always, [.gradleDaemon], "Project builds"),
        ("build.ios", .projectBuilds, .always, [.xcode], "Project builds"),
        ("build.web", .projectBuilds, .always, [], "Project builds"),
        ("build.pods", .projectBuilds, .never, [.xcode], "Pods"),
    ]
    for (id, group, selection, locks, title) in expected {
        let rule = try #require(Catalog.rule(id: id), "missing rule \(id)")
        #expect(rule.group == group, "\(id) group")
        #expect(rule.method == .delete, "\(id) method")
        #expect(rule.defaultSelection == selection, "\(id) default selection")
        #expect(rule.locks == locks, "\(id) locks")
        #expect(rule.title == title, "\(id) title")
        #expect(!rule.regenerateHint.isEmpty, "\(id) regenerate hint")
    }
}

@Test func projectRulesComeInTheOrderOfTheRuleTable() {
    let ids = Catalog.all().map(\.id)
    let order = ["xcode.derivedData", "node.modules", "cache.npm", "cache.bun", "build.android", "build.ios",
                 "build.web", "build.pods", "gradle.caches"]
    #expect(order.compactMap(ids.firstIndex(of:)) == order.compactMap(ids.firstIndex(of:)).sorted())
    #expect(order.allSatisfy(ids.contains))
}
