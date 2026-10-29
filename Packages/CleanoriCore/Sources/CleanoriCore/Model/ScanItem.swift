import Foundation

/// A marker shown next to an item in the UI.
public enum Badge: Sendable, Equatable {
    case active
    case unused
    /// A `node_modules` whose parent folder has no `package.json`, so it is not a project's own dependencies (a
    /// tool's install, an unplugged package...). It is listed but never ticked by default.
    case noPackageJSON
}

/// One cleanable thing found by a scan (a folder, a simulator, a large file...).
public struct ScanItem: Sendable, Identifiable, Equatable {
    public var ruleID: String
    public var url: URL
    public var displayName: String
    public var detail: String?
    public var size: SizeResult
    public var lastActivity: Date?
    public var method: CleanMethod
    public var isSelectedByDefault: Bool
    /// Non-nil means the item cannot be selected.
    public var lock: LockReason?
    public var badges: [Badge]
    /// Set for `.simctl` items; the device to pass to `SimulatorControl.delete(udid:)`.
    public var simulatorUDID: String?

    public var id: String { "\(ruleID)|\(url.path)" }

    public init(
        ruleID: String,
        url: URL,
        displayName: String,
        detail: String? = nil,
        size: SizeResult,
        lastActivity: Date? = nil,
        method: CleanMethod,
        isSelectedByDefault: Bool = false,
        lock: LockReason? = nil,
        badges: [Badge] = [],
        simulatorUDID: String? = nil
    ) {
        self.ruleID = ruleID
        self.url = url
        self.displayName = displayName
        self.detail = detail
        self.size = size
        self.lastActivity = lastActivity
        self.method = method
        self.isSelectedByDefault = isSelectedByDefault
        self.lock = lock
        self.badges = badges
        self.simulatorUDID = simulatorUDID
    }
}
