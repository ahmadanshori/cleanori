/// How a cleanup item is removed from disk.
public enum CleanMethod: String, Sendable, Codable {
    /// Permanent removal via `FileManager.removeItem`.
    case delete
    /// Moved to the Trash via `Trasher`.
    case trash
    /// Removed through `xcrun simctl delete` via `SimulatorControl`.
    case simctl
}
