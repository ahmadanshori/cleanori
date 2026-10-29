import Foundation
import Testing
import CleanoriCore

// MARK: - Rules 1 and 2: inside home, never home or a top-level folder

@Test func deniesHomeAndTopLevelFolders() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    let library = try home.dir("Library")
    let developer = try home.dir("Developer")
    for method in [CleanMethod.delete, .trash] {
        #expect(g.check(home.url, method: method, isCatalogItem: true) == .denied("Top-level home folder"))
        #expect(g.check(library, method: method, isCatalogItem: true) == .denied("Top-level home folder"))
        #expect(g.check(developer, method: method, isCatalogItem: true) == .denied("Top-level home folder"))
    }
}

@Test func allowsFileAtHomeRootForTrash() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    let dmg = try home.file("big.dmg", bytes: 16)
    #expect(g.check(dmg, method: .trash, isCatalogItem: false) == .allowed)
}

@Test func deniesOutsideHome() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    #expect(g.check(URL(fileURLWithPath: "/tmp/x"), method: .trash, isCatalogItem: true) == .denied("Outside home folder"))
    #expect(g.check(URL(fileURLWithPath: "/tmp/x"), method: .delete, isCatalogItem: true) == .denied("Outside home folder"))
    #expect(g.check(URL(fileURLWithPath: "/"), method: .trash, isCatalogItem: true) == .denied("Outside home folder"))
}

@Test func deniesDotDotEscape() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    let escape = home.url.appending(path: "Developer/../../etc", directoryHint: .notDirectory)
    #expect(g.check(escape, method: .delete, isCatalogItem: true) == .denied("Outside home folder"))
    #expect(g.check(escape, method: .trash, isCatalogItem: true) == .denied("Outside home folder"))
}

@Test func deniesSiblingFolderSharingTheHomePrefix() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    // `<home>-evil/x` starts with the home *string* but is not inside the home folder.
    let sibling = URL(fileURLWithPath: home.url.path + "-evil/x")
    #expect(g.check(sibling, method: .trash, isCatalogItem: true) == .denied("Outside home folder"))
}

@Test func deniesNonFileURLs() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    let web = try #require(URL(string: "https://example.com/x"))
    #expect(g.check(web, method: .trash, isCatalogItem: true) == .denied("Outside home folder"))
}

@Test func anUnusableHomeDeniesEverything() throws {
    // Fail closed: a home of `/` would put every path "inside home", and a home that is not a file URL has no path.
    let home = try TempHome(); defer { home.cleanup() }
    let file = try home.file("Developer/app/big.dmg", bytes: 16)
    let folder = try home.dir("Library/Developer/Xcode/DerivedData/App-1")
    let unusable = [URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/.."), try #require(URL(string: "https://example.com/Users/me"))]
    for badHome in unusable {
        let g = SafetyGuard(home: badHome)
        for url in [file, folder, URL(fileURLWithPath: "/"), home.url] {
            for method in [CleanMethod.delete, .trash, .simctl] {
                #expect(g.check(url, method: method, isCatalogItem: true) == .denied("Outside home folder"), "\(badHome) \(url.path)")
            }
        }
    }
}

@Test func judgesPathsByTextEvenWhenTheyDoNotExistYet() throws {
    // `standardizedFileURL` strips `/private` only for paths that exist, so a not-yet-existing item
    // under the `/private/var/...` temp home must still be judged inside home, like an existing one.
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    #expect(home.url.path.hasPrefix("/private/"))
    let missing = home.url.appending(path: "Library/Caches/Yarn", directoryHint: .notDirectory)
    #expect(!FileManager.default.fileExists(atPath: missing.path))
    #expect(g.check(missing, method: .delete, isCatalogItem: true) == .allowed)
    #expect(g.check(missing, method: .delete, isCatalogItem: false) == .denied("Not found by a cleanup rule"))
    let ssh = home.url.appending(path: ".ssh/id", directoryHint: .notDirectory)
    #expect(g.check(ssh, method: .trash, isCatalogItem: false) == .denied("Protected location"))
}

@Test func resolvesDotDotInsideHomeBeforeChecking() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    // Still inside home after standardizing, so it is judged as the folder it really names.
    let viaDotDot = home.url.appending(path: "Developer/../.ssh/id", directoryHint: .notDirectory)
    #expect(g.check(viaDotDot, method: .trash, isCatalogItem: true) == .denied("Protected location"))
    let cache = home.url.appending(path: "Developer/../Library/Caches/Yarn", directoryHint: .notDirectory)
    #expect(g.check(cache, method: .delete, isCatalogItem: true) == .allowed)
}

// MARK: - Rule 3: never a symbolic link

@Test func deniesSymlink() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    let link = try home.symlink("Developer/link", to: URL(fileURLWithPath: "/tmp"))
    #expect(g.check(link, method: .delete, isCatalogItem: true) == .denied("Is a symbolic link"))
    #expect(g.check(link, method: .trash, isCatalogItem: true) == .denied("Is a symbolic link"))
    #expect(g.check(link, method: .simctl, isCatalogItem: true) == .denied("Is a symbolic link"))
}

@Test func deniesSymlinkAtTopLevelOfHome() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    let target = try home.dir("real")
    let link = try home.symlink("alias", to: target)
    #expect(g.check(link, method: .trash, isCatalogItem: false) == .denied("Is a symbolic link"))
}

@Test func deniesSymlinkInsideDocumentsEvenForTrash() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    let link = try home.symlink("Documents/alias", to: URL(fileURLWithPath: "/tmp"))
    #expect(g.check(link, method: .trash, isCatalogItem: false) == .denied("Is a symbolic link"))
}

// MARK: - Rule 4: protected locations

@Test func deniesProtectedLocations() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    let rels = [
        ".ssh/id", ".gnupg/pubring.kbx", "Pictures/photo.jpg",
        "Library/Keychains/x", "Library/Mobile Documents/x", "Library/Mail/x", "Library/Messages/x",
        "Library/Application Support/MobileSync/Backup/abc",
    ]
    for rel in rels {
        let url = try home.file(rel, bytes: 8)
        for method in [CleanMethod.delete, .trash] {
            #expect(g.check(url, method: method, isCatalogItem: true) == .denied("Protected location"), "\(rel) \(method)")
        }
    }
}

@Test func deniesTheProtectedFoldersThemselves() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    for rel in ["Documents", "Desktop", "Pictures", ".ssh", ".gnupg", "Library/Mail", "Library/Mobile Documents",
                "Library/Application Support/MobileSync"] {
        let dir = try home.dir(rel)
        for method in [CleanMethod.delete, .trash] {
            let verdict = g.check(dir, method: method, isCatalogItem: true)
            #expect(verdict != .allowed, "\(rel) \(method)")
        }
    }
    // Library/Application Support itself is not protected, only MobileSync inside it.
    let appSupportChild = try home.dir("Library/Application Support/SomeApp/Cache")
    #expect(g.check(appSupportChild, method: .delete, isCatalogItem: true) == .allowed)
}

@Test func doesNotTreatSiblingNamesAsProtected() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    // Compared by path component, so `Documents2` and `.ssh-old` are not `Documents` and `.ssh`.
    let docs2 = try home.file("Documents2/movie.mov", bytes: 8)
    let sshOld = try home.file(".ssh-old/id", bytes: 8)
    let mailbox = try home.file("Library/Mailbox/x", bytes: 8)
    for url in [docs2, sshOld, mailbox] {
        #expect(g.check(url, method: .delete, isCatalogItem: true) == .allowed, "\(url.path)")
        #expect(g.check(url, method: .trash, isCatalogItem: true) == .allowed, "\(url.path)")
    }
}

@Test func protectedListIgnoresLetterCase() throws {
    // The default macOS volume is case-insensitive: `~/documents` is `~/Documents`.
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    let ssh = home.url.appending(path: ".SSH/id", directoryHint: .notDirectory)
    let keychains = home.url.appending(path: "library/keychains/x", directoryHint: .notDirectory)
    for url in [ssh, keychains] {
        for method in [CleanMethod.delete, .trash] {
            #expect(g.check(url, method: method, isCatalogItem: true) == .denied("Protected location"), "\(url.path)")
        }
    }
    let lowercaseFolder = home.url.appending(path: "documents/Folder", directoryHint: .isDirectory)
    #expect(g.check(lowercaseFolder, method: .trash, isCatalogItem: true) == .denied("Protected location"))
}

@Test func allowsTrashingFileInDocuments() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    let movie = try home.file("Documents/movie.mov", bytes: 16)
    #expect(g.check(movie, method: .trash, isCatalogItem: false) == .allowed)
    #expect(g.check(movie, method: .delete, isCatalogItem: true) == .denied("Protected location"))
    let folder = try home.dir("Documents/Folder")
    #expect(g.check(folder, method: .trash, isCatalogItem: false) == .denied("Protected location"))
    #expect(g.check(folder, method: .delete, isCatalogItem: true) == .denied("Protected location"))
}

@Test func allowsTrashingFilesOnDesktopAndNestedInDocuments() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    let onDesktop = try home.file("Desktop/recording.mov", bytes: 16)
    let nested = try home.file("Documents/Projects/2024/render.mp4", bytes: 16)
    #expect(g.check(onDesktop, method: .trash, isCatalogItem: false) == .allowed)
    #expect(g.check(nested, method: .trash, isCatalogItem: false) == .allowed)
    #expect(g.check(onDesktop, method: .delete, isCatalogItem: true) == .denied("Protected location"))
    #expect(g.check(nested, method: .simctl, isCatalogItem: true) == .denied("Protected location"))
}

@Test func trashExceptionDoesNotReachOtherProtectedLocations() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    for rel in ["Pictures/photo.jpg", "Library/Mobile Documents/com~apple~CloudDocs/a.pdf", ".ssh/id_ed25519"] {
        let url = try home.file(rel, bytes: 8)
        #expect(g.check(url, method: .trash, isCatalogItem: false) == .denied("Protected location"), "\(rel)")
    }
}

// MARK: - Rule 5: .delete only

@Test func deleteRequiresCatalogItem() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    let yarn = try home.dir("Library/Caches/Yarn")
    #expect(g.check(yarn, method: .delete, isCatalogItem: false) == .denied("Not found by a cleanup rule"))
    #expect(g.check(yarn, method: .delete, isCatalogItem: true) == .allowed)
}

@Test func deleteDeniesGitAndProjectFolders() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    let repo = try home.dir("Developer/repo")
    try home.dir("Developer/repo/.git")
    #expect(g.check(repo, method: .delete, isCatalogItem: true) == .denied("Contains a git repository"))

    let project = try home.dir("Developer/app")
    try home.file("Developer/app/package.json", bytes: 8)
    #expect(g.check(project, method: .delete, isCatalogItem: true) == .denied("Is a project folder"))

    let modules = try home.dir("Developer/app/node_modules")
    #expect(g.check(modules, method: .delete, isCatalogItem: true) == .allowed)
}

@Test func deleteDeniesTheDotGitFolderItself() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    let dotGit = try home.dir("Developer/repo/.git")
    #expect(g.check(dotGit, method: .delete, isCatalogItem: true) == .denied("Contains a git repository"))
}

@Test func deleteDeniesWorktreeWhoseDotGitIsAFile() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    let worktree = try home.dir("Developer/repo/.worktrees/feature")
    try home.file("Developer/repo/.worktrees/feature/.git", bytes: 8)
    #expect(g.check(worktree, method: .delete, isCatalogItem: true) == .denied("Contains a git repository"))
}

@Test(arguments: [
    "package.json", "Package.swift", "settings.gradle", "settings.gradle.kts", "MyApp.xcodeproj/project.pbxproj",
])
func deleteDeniesFolderWithProjectMarker(marker: String) throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    let project = try home.dir("Developer/thing")
    try home.file("Developer/thing/\(marker)", bytes: 8)
    #expect(g.check(project, method: .delete, isCatalogItem: true) == .denied("Is a project folder"), "\(marker)")
}

@Test func deleteChecksProjectMarkersOnlyAtItsOwnLevel() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    // A marker one level down does not make the folder itself a project folder.
    let outer = try home.dir("Library/Caches/Thing")
    try home.file("Library/Caches/Thing/sub/package.json", bytes: 8)
    #expect(g.check(outer, method: .delete, isCatalogItem: true) == .allowed)
}

// MARK: - Ruling R1: artifact folders may carry project markers

@Test func deleteAllowsArtifactFoldersWithProjectMarkers() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    // Next.js writes `.next/package.json`; CocoaPods creates `Pods/Pods.xcodeproj`.
    let next = try home.dir("Developer/site/.next")
    try home.file("Developer/site/.next/package.json", bytes: 8)
    let pods = try home.dir("Developer/ios/Pods")
    try home.dir("Developer/ios/Pods/Pods.xcodeproj")
    #expect(g.check(next, method: .delete, isCatalogItem: true) == .allowed)
    #expect(g.check(pods, method: .delete, isCatalogItem: true) == .allowed)
}

@Test(arguments: ["node_modules", ".next", ".expo", "build", "Pods", ".gradle"])
func artifactFoldersSkipOnlyTheProjectFolderCheck(name: String) throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    let folder = try home.dir("Developer/proj/\(name)")
    try home.file("Developer/proj/\(name)/package.json", bytes: 8)
    // Still goes through the catalog-membership check...
    #expect(g.check(folder, method: .delete, isCatalogItem: false) == .denied("Not found by a cleanup rule"), "\(name)")
    #expect(g.check(folder, method: .delete, isCatalogItem: true) == .allowed, "\(name)")
    // ...and the protected list.
    let protectedBuild = try home.dir("Documents/proj/\(name)")
    #expect(g.check(protectedBuild, method: .delete, isCatalogItem: true) == .denied("Protected location"), "\(name)")
}

@Test func artifactFolderContainingGitIsStillDenied() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    let build = try home.dir("Developer/proj/build")
    try home.dir("Developer/proj/build/.git")
    #expect(g.check(build, method: .delete, isCatalogItem: true) == .denied("Contains a git repository"))
}

@Test func projectFolderCheckStillAppliesToOtherNames() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    // Only the exact artifact names are exempt; a similarly named folder is judged as a project.
    let almost = try home.dir("Developer/proj/builds")
    try home.file("Developer/proj/builds/package.json", bytes: 8)
    #expect(g.check(almost, method: .delete, isCatalogItem: true) == .denied("Is a project folder"))
}

// MARK: - Method scoping

@Test func catalogGitAndProjectRulesApplyOnlyToDelete() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    let repo = try home.dir("Developer/repo")
    try home.dir("Developer/repo/.git")
    let project = try home.dir("Developer/app")
    try home.file("Developer/app/package.json", bytes: 8)
    for url in [repo, project] {
        #expect(g.check(url, method: .trash, isCatalogItem: false) == .allowed, "\(url.path)")
        #expect(g.check(url, method: .simctl, isCatalogItem: false) == .allowed, "\(url.path)")
    }
}

@Test func simctlStillObeysTheCommonRules() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    let device = try home.dir("Library/Developer/CoreSimulator/Devices/6C3E1B2A-0000-4000-8000-000000000001")
    #expect(g.check(device, method: .simctl, isCatalogItem: true) == .allowed)
    #expect(g.check(URL(fileURLWithPath: "/tmp/x"), method: .simctl, isCatalogItem: true) == .denied("Outside home folder"))
    let keychains = try home.dir("Library/Keychains")
    #expect(g.check(keychains, method: .simctl, isCatalogItem: true) == .denied("Protected location"))
}

// MARK: - Review focus: awkward but legitimate paths

@Test func allowsPathsWithSpacesCommasAndParentheses() throws {
    let home = try TempHome(); defer { home.cleanup() }
    let g = SafetyGuard(home: home.url)
    let support = try home.dir("Library/Developer/Xcode/iOS DeviceSupport/iPhone14,5 27.0.1 (24A446)")
    #expect(g.check(support, method: .delete, isCatalogItem: true) == .allowed)
    #expect(g.check(support, method: .trash, isCatalogItem: false) == .allowed)
}
