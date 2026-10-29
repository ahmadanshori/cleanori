import Foundation

/// The cleanup rules Cleanori knows about, in display order (spec §5.3).
public enum Catalog {
    public static func all() -> [CleanupRule] { rules }

    public static func rule(id: String) -> CleanupRule? {
        rules.first { $0.id == id }
    }

    /// Folders that Developer Junk manages. The Large Files and Disk Map screens lock items inside them
    /// (`LockReason.managedByDeveloperJunk`) so one folder is never offered for cleaning in two places.
    public static func managedRoots(home: URL) -> [URL] {
        [".android", ".gradle", ".npm", ".bun/install/cache", "Library/pnpm"].map {
            home.appending(path: $0, directoryHint: .isDirectory)
        }
    }

    /// Folders inside a project that Developer Junk manages (`build.android`, `build.ios`, `build.pods` and
    /// `build.web`), relative to the project. Large Files locks a file in one of them anywhere below a project root.
    /// (`node_modules`, which `node.modules` manages, is never entered by Large Files at all.)
    public static let managedProjectFolders: [String] = [
        "android/app/build", "android/.gradle", "ios/build", "ios/Pods", ".next", ".expo",
    ]

    /// The help text for the rules with these IDs (the rules of one table group), one line per distinct
    /// `regenerateHint`, in catalog order. When the rules have more than one hint, each line starts with the titles
    /// of the rules it is for (`"Yarn · Bun: Packages are…"`); when they share one, the line is the hint alone.
    /// Unknown IDs are ignored.
    public static func hintLines(forRules ruleIDs: some Collection<String>) -> [String] {
        let wanted = Set(ruleIDs)
        var hints: [(hint: String, titles: [String])] = []
        for rule in rules where wanted.contains(rule.id) {
            if let index = hints.firstIndex(where: { $0.hint == rule.regenerateHint }) {
                if !hints[index].titles.contains(rule.title) { hints[index].titles.append(rule.title) }
            } else {
                hints.append((rule.regenerateHint, [rule.title]))
            }
        }
        guard hints.count > 1 else { return hints.map(\.hint) }
        return hints.map { "\($0.titles.joined(separator: " · ")): \($0.hint)" }
    }

    private static let rules: [CleanupRule] = [
        CleanupRule(
            id: "xcode.derivedData",
            title: "Xcode DerivedData",
            group: .xcodeDerivedData,
            method: .delete,
            defaultSelection: .always,
            locks: [.xcode],
            regenerateHint: "Rebuilt automatically on the next Xcode build",
            discover: Discovery.children(of: "Library/Developer/Xcode/DerivedData")
        ),
        CleanupRule(
            id: "node.modules",
            title: "node_modules",
            group: .nodeModules,
            method: .delete,
            defaultSelection: .ifInactive,
            regenerateHint: "Restored by running npm, pnpm, yarn or bun install in the project",
            discover: Discovery.nodeModules()
        ),
        CleanupRule(
            id: "cache.npm",
            title: "npm",
            group: .packageCaches,
            method: .delete,
            defaultSelection: .always,
            regenerateHint: "Packages are downloaded again when needed; npx tools such as MCP servers fetch theirs on their next run",
            discover: Discovery.fixed([".npm/_cacache", ".npm/_npx"])
        ),
        CleanupRule(
            id: "cache.pnpm",
            title: "pnpm",
            group: .packageCaches,
            method: .delete,
            defaultSelection: .always,
            regenerateHint: "Downloaded again when needed. May free much less than shown while node_modules still link to the store",
            discover: Discovery.fixed(["Library/pnpm/store", "Library/Caches/pnpm"])
        ),
        CleanupRule(
            id: "cache.yarn",
            title: "Yarn",
            group: .packageCaches,
            method: .delete,
            defaultSelection: .always,
            regenerateHint: "Packages are downloaded again when needed, so the next install is slower",
            discover: Discovery.fixed(["Library/Caches/Yarn"])
        ),
        CleanupRule(
            id: "cache.bun",
            title: "Bun",
            group: .packageCaches,
            method: .delete,
            defaultSelection: .always,
            regenerateHint: "Packages are downloaded again when needed, so the next install is slower",
            discover: Discovery.fixed([".bun/install/cache"])
        ),
        CleanupRule(
            id: "build.android",
            title: "Project builds",
            group: .projectBuilds,
            method: .delete,
            defaultSelection: .always,
            locks: [.gradleDaemon],
            regenerateHint: "Rebuilt automatically the next time the project is built or run",
            discover: Discovery.projectBuilds(
                artifacts: ["android/app/build", "android/.gradle"],
                marker: ProjectDiscovery.hasAndroidSettings
            )
        ),
        CleanupRule(
            id: "build.ios",
            title: "Project builds",
            group: .projectBuilds,
            method: .delete,
            defaultSelection: .always,
            locks: [.xcode],
            regenerateHint: "Rebuilt automatically the next time the project is built or run",
            discover: Discovery.projectBuilds(artifacts: ["ios/build"], marker: ProjectDiscovery.hasXcodeProject)
        ),
        CleanupRule(
            id: "build.web",
            title: "Project builds",
            group: .projectBuilds,
            method: .delete,
            defaultSelection: .always,
            regenerateHint: "Rebuilt automatically the next time the project is built or run",
            discover: Discovery.projectBuilds(artifacts: [".next", ".expo"], marker: ProjectDiscovery.hasPackageJSON)
        ),
        CleanupRule(
            id: "build.pods",
            title: "Pods",
            group: .projectBuilds,
            method: .delete,
            defaultSelection: .never,
            locks: [.xcode],
            regenerateHint: "Restored by running pod install in the project's ios folder",
            discover: Discovery.projectBuilds(artifacts: ["ios/Pods"], marker: ProjectDiscovery.hasPodfile)
        ),
        CleanupRule(
            id: "gradle.caches",
            title: "Gradle caches",
            group: .gradle,
            method: .delete,
            defaultSelection: .always,
            locks: [.androidStudio, .gradleDaemon],
            regenerateHint: "Dependencies are downloaded again on the next Gradle build",
            discover: Discovery.fixed([".gradle/caches"])
        ),
        CleanupRule(
            id: "gradle.wrappers",
            title: "Old wrappers",
            group: .gradle,
            method: .delete,
            defaultSelection: .always,
            locks: [.gradleDaemon],
            regenerateHint: "A project that needs an old Gradle version downloads it again",
            // Only `gradle-<version>-<type>` folders are wrappers; anything else there is left alone.
            discover: Discovery.allButHighestVersion(in: ".gradle/wrapper/dists") { $0.hasPrefix("gradle-") }
        ),
        CleanupRule(
            id: "cache.tools",
            title: "Other tool caches",
            group: .toolCaches,
            method: .delete,
            defaultSelection: .always,
            regenerateHint: "Each tool downloads or rebuilds its cache when it needs it",
            discover: Discovery.fixed([
                "Library/Caches/Homebrew",
                "Library/Caches/org.swift.swiftpm",
                "Library/Caches/CocoaPods",
                "Library/Caches/ReactNative",
                "Library/Caches/pip",
            ])
        ),
        CleanupRule(
            id: "sim.devices",
            title: "iOS Simulators",
            group: .simulators,
            method: .simctl,
            defaultSelection: .ifUnavailable,
            locks: [.simulator],
            regenerateHint: "Deleted for good with all its apps and data. Make a new one in Xcode's Devices and Simulators window",
            discover: Discovery.simulators()
        ),
        CleanupRule(
            id: "android.ndk",
            title: "NDK",
            group: .androidSDK,
            method: .trash,
            defaultSelection: .never,
            locks: [.androidStudio],
            regenerateHint: "If a project needs this NDK version again, Gradle or Android Studio's SDK Manager installs it again",
            discover: Discovery.androidNDKs()
        ),
        CleanupRule(
            id: "android.systemImages",
            title: "System images",
            group: .androidSDK,
            method: .trash,
            defaultSelection: .never,
            locks: [.androidStudio],
            regenerateHint: "Emulators that use it won't start until it is installed again in Android Studio's SDK Manager",
            discover: Discovery.androidSystemImages()
        ),
        CleanupRule(
            id: "xcode.deviceSupport",
            title: "iOS DeviceSupport",
            group: .deviceSupport,
            method: .trash,
            defaultSelection: .never,
            locks: [.xcode],
            regenerateHint: "Xcode copies the symbols from the device again the next time it connects",
            discover: Discovery.children(of: "Library/Developer/Xcode/iOS DeviceSupport")
        ),
        CleanupRule(
            id: "xcode.archives",
            title: "Xcode Archives",
            group: .archives,
            method: .trash,
            defaultSelection: .never,
            regenerateHint: "Cannot be rebuilt: holds a released build and its debug symbols. Lost for good once the Trash is emptied",
            discover: Discovery.bundles(withExtension: "xcarchive", under: "Library/Developer/Xcode/Archives", levels: 2)
        ),
        CleanupRule(
            id: "android.avd",
            title: "Android emulators",
            group: .androidEmulators,
            method: .trash,
            defaultSelection: .never,
            locks: [.emulator],
            regenerateHint: "Its apps and data are lost once the Trash is emptied. Make a new one in Android Studio's Device Manager",
            discover: Discovery.androidEmulators()
        ),
    ]
}
