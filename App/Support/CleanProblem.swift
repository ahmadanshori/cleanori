/// Why a clean could not start, for an alert.
struct CleanProblem {
    let title: String
    let message: String
}

/// What the report banner needs besides the `CleanReport` itself.
struct CleanReportContext {
    /// Item ID to item name for the items of the last clean (for the skipped and failed lists).
    var names: [String: String] = [:]
    /// Whether the sizes behind "Freed" and "moved to Trash" may be off (ruling R11).
    var freedIsApproximate = false
    var trashedIsApproximate = false
    /// A line under the banner's title, for something the report itself does not say (Large Files: files that
    /// changed after the confirmation sheet was shown).
    var note: String?
}
