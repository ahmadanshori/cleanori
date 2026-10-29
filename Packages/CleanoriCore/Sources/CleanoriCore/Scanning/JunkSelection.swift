/// How much of a group is ticked: the state of a group's checkbox.
public enum TriState: Sendable {
    case on, off, mixed
}

/// What the current selection would remove, split by how each item is removed: how many items and how many bytes.
///
/// Whether a way of removing is used at all is decided by its item count, never by its bytes: a ticked item of
/// 0 bytes (or one that could not be measured) is still deleted permanently, and the confirmation has to say so.
public struct SelectionTotals: Equatable, Sendable {
    public var deleteBytes: Int64
    public var trashBytes: Int64
    public var simctlBytes: Int64
    public var deleteCount: Int
    public var trashCount: Int
    public var simctlCount: Int

    public var totalBytes: Int64 { deleteBytes + trashBytes + simctlBytes }
    public var itemCount: Int { deleteCount + trashCount + simctlCount }

    public init(
        deleteBytes: Int64 = 0, trashBytes: Int64 = 0, simctlBytes: Int64 = 0,
        deleteCount: Int = 0, trashCount: Int = 0, simctlCount: Int = 0
    ) {
        self.deleteBytes = deleteBytes
        self.trashBytes = trashBytes
        self.simctlBytes = simctlBytes
        self.deleteCount = deleteCount
        self.trashCount = trashCount
        self.simctlCount = simctlCount
    }

    /// How many ticked items are removed with `method`.
    public func count(of method: CleanMethod) -> Int {
        switch method {
        case .delete: deleteCount
        case .trash: trashCount
        case .simctl: simctlCount
        }
    }

    /// The bytes of the ticked items removed with `method`.
    public func bytes(of method: CleanMethod) -> Int64 {
        switch method {
        case .delete: deleteBytes
        case .trash: trashBytes
        case .simctl: simctlBytes
        }
    }
}

/// Which items of a scan result are ticked. This is the model behind the checkboxes and totals of the
/// Developer Junk screen, and it never touches the disk.
///
/// A locked item can never be selected, whatever `isSelectedByDefault` says.
public struct JunkSelection: Sendable {
    private let groups: [ScanGroup]
    private var selectedIDs: Set<String>

    /// Starts with the items the scan marked as selected by default, minus any that are locked.
    /// The same as `init(result:userChoices:)` with no choices.
    public init(result: JunkScanResult) {
        self.init(result: result, userChoices: [:])
    }

    /// Starts from what the user chose and, for every item they made no choice about, from the scan's default.
    ///
    /// `userChoices` maps an item ID to the tick the user gave it on purpose. An item takes its choice when it
    /// has one and `isSelectedByDefault` when it has not. Only the user's own choices outlive a scan: a tick that
    /// came from a default is worked out again each time, so an item whose default changed (a project that
    /// became active, a changed inactivity threshold, a simulator that became available) follows the new default.
    ///
    /// A locked item is never selected, whatever the choice says. A choice made about an item that is locked
    /// right now still applies once the lock is gone. Choices for IDs that are not in `result` are ignored.
    public init(result: JunkScanResult, userChoices: [String: Bool]) {
        groups = result.groups
        selectedIDs = Set(
            result.groups.lazy.flatMap(\.items)
                .filter { $0.lock == nil && (userChoices[$0.id] ?? $0.isSelectedByDefault) }
                .map(\.id)
        )
    }

    /// Ticks or unticks one item. Does nothing for a locked item or an id that is not in the result.
    public mutating func toggle(itemID: String) {
        guard let item = groups.lazy.flatMap(\.items).first(where: { $0.id == itemID }), item.lock == nil else {
            return
        }
        if !selectedIDs.insert(itemID).inserted {
            selectedIDs.remove(itemID)
        }
    }

    /// Ticks every unlocked item of the group when it is `.off` or `.mixed`, and unticks them all when it is `.on`.
    public mutating func toggle(group: RuleGroup) {
        let selectable = selectableItems(in: group).map(\.id)
        if state(of: group) == .on {
            selectedIDs.subtract(selectable)
        } else {
            selectedIDs.formUnion(selectable)
        }
    }

    public func isSelected(_ itemID: String) -> Bool {
        selectedIDs.contains(itemID)
    }

    /// `.on` when every unlocked item of the group is ticked, `.off` when none is (or none can be), else `.mixed`.
    public func state(of group: RuleGroup) -> TriState {
        let selectable = selectableItems(in: group)
        let ticked = selectable.count { selectedIDs.contains($0.id) }
        if ticked == 0 { return .off }
        return ticked == selectable.count ? .on : .mixed
    }

    /// The ticked items, in the order the groups and their items are shown.
    public var selectedItems: [ScanItem] {
        groups.flatMap(\.items).filter { selectedIDs.contains($0.id) }
    }

    public var totals: SelectionTotals {
        var totals = SelectionTotals()
        for item in selectedItems {
            switch item.method {
            case .delete:
                totals.deleteBytes += item.size.bytes
                totals.deleteCount += 1
            case .trash:
                totals.trashBytes += item.size.bytes
                totals.trashCount += 1
            case .simctl:
                totals.simctlBytes += item.size.bytes
                totals.simctlCount += 1
            }
        }
        return totals
    }

    /// The items of `group` that are not locked, so can be ticked.
    private func selectableItems(in group: RuleGroup) -> [ScanItem] {
        groups.filter { $0.id == group }.flatMap(\.items).filter { $0.lock == nil }
    }
}
