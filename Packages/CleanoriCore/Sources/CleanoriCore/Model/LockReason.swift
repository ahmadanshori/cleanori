/// Why an item cannot be selected for cleaning.
public enum LockReason: Sendable, Equatable {
    case appRunning(name: String)
    case processRunning(name: String)
    case managedByDeveloperJunk
    /// `SafetyGuard` would refuse to touch the item (a package in `~/Pictures`, a folder in `~/Documents`...).
    case protectedLocation

    public var label: String {
        switch self {
        case .appRunning(let name), .processRunning(let name):
            "\(name) is running"
        case .managedByDeveloperJunk:
            "Managed in Developer Junk"
        case .protectedLocation:
            "Protected location"
        }
    }
}
