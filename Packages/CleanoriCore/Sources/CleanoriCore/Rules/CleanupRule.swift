import Foundation

/// A section of the Developer Junk screen, declared in display order.
public enum RuleGroup: String, CaseIterable, Sendable {
    case xcodeDerivedData
    case nodeModules
    case packageCaches
    case projectBuilds
    case gradle
    case toolCaches
    case simulators
    case androidSDK
    case deviceSupport
    case archives
    case androidEmulators

    public var title: String {
        switch self {
        case .xcodeDerivedData: "Xcode DerivedData"
        case .nodeModules: "node_modules"
        case .packageCaches: "Package caches"
        case .projectBuilds: "Project builds"
        case .gradle: "Gradle caches"
        case .toolCaches: "Other tool caches"
        case .simulators: "iOS Simulators"
        case .androidSDK: "Old Android SDKs"
        case .deviceSupport: "iOS DeviceSupport"
        case .archives: "Xcode Archives"
        case .androidEmulators: "Android emulators"
        }
    }
}

/// Whether the items of a rule start out ticked.
public enum DefaultSelection: Sendable {
    case always
    case never
    /// Ticked when the item's last activity is older than `inactiveAfterDays`.
    case ifInactive
    /// Ticked when the item is unavailable (e.g. a simulator whose runtime was removed).
    case ifUnavailable
}

/// Something that makes an item unsafe to clean while it is happening.
public enum LockCondition: Sendable, Equatable {
    /// A GUI app with this bundle identifier is running.
    case appRunning(bundleID: String, name: String)
    /// A process with this executable name is running, optionally with an argument containing a substring.
    case processRunning(executable: String, argumentContains: String?, name: String)

    public static let xcode = LockCondition.appRunning(bundleID: "com.apple.dt.Xcode", name: "Xcode")
    public static let androidStudio = LockCondition.appRunning(
        bundleID: "com.google.android.studio", name: "Android Studio"
    )
    public static let simulator = LockCondition.appRunning(bundleID: "com.apple.iphonesimulator", name: "Simulator")
    public static let gradleDaemon = LockCondition.processRunning(
        executable: "java", argumentContains: "GradleDaemon", name: "Gradle daemon"
    )
    public static let emulator = LockCondition.processRunning(
        executable: "qemu-system-aarch64", argumentContains: nil, name: "Android emulator"
    )

    /// The reason to lock an item right now, or `nil` when the condition does not hold.
    public func evaluate(_ p: any ProcessInspector) -> LockReason? {
        switch self {
        case .appRunning(let bundleID, let name):
            return p.runningBundleIDs().contains(bundleID) ? .appRunning(name: name) : nil
        case .processRunning(let executable, let argumentContains, let name):
            let isRunning = p.runningProcesses().contains { process in
                // `executable` may be a bare name or a full path; match on the program name.
                guard process.executable.split(separator: "/").last.map(String.init) == executable else {
                    return false
                }
                guard let argumentContains else { return true }
                return process.arguments.contains { $0.contains(argumentContains) }
            }
            return isRunning ? .processRunning(name: name) : nil
        }
    }
}

/// What a rule's `discover` found, before it is sized and locked.
public struct DiscoveredItem: Sendable {
    public var url: URL
    public var displayName: String
    public var detail: String?
    public var lastActivity: Date?
    public var badges: [Badge]
    public var simulatorUDID: String?
    public var isUnavailable: Bool

    public init(
        url: URL,
        displayName: String,
        detail: String? = nil,
        lastActivity: Date? = nil,
        badges: [Badge] = [],
        simulatorUDID: String? = nil,
        isUnavailable: Bool = false
    ) {
        self.url = url
        self.displayName = displayName
        self.detail = detail
        self.lastActivity = lastActivity
        self.badges = badges
        self.simulatorUDID = simulatorUDID
        self.isUnavailable = isUnavailable
    }
}

/// One kind of cleanable thing: how to find it, how to remove it, and when it is locked (spec §5.3).
public struct CleanupRule: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let group: RuleGroup
    public let method: CleanMethod
    public let defaultSelection: DefaultSelection
    public let locks: [LockCondition]
    public let regenerateHint: String
    /// Finds the items of this rule on disk. `Cleaner` calls it again to revalidate before removing anything.
    public let discover: @Sendable (CoreEnvironment) async throws -> [DiscoveredItem]

    public init(
        id: String,
        title: String,
        group: RuleGroup,
        method: CleanMethod,
        defaultSelection: DefaultSelection,
        locks: [LockCondition] = [],
        regenerateHint: String,
        discover: @escaping @Sendable (CoreEnvironment) async throws -> [DiscoveredItem]
    ) {
        self.id = id
        self.title = title
        self.group = group
        self.method = method
        self.defaultSelection = defaultSelection
        self.locks = locks
        self.regenerateHint = regenerateHint
        self.discover = discover
    }
}
