import Foundation
import Testing
import CleanoriCore

private let mib: Int64 = 1_048_576

/// An item that exists only in memory: nothing here touches the disk.
private func item(
    _ name: String,
    bytes: Int64 = mib,
    method: CleanMethod = .delete,
    selected: Bool = false,
    lock: LockReason? = nil
) -> ScanItem {
    ScanItem(
        ruleID: "test.rule",
        url: URL(filePath: "/nonexistent/cleanori-selection-tests/\(name)", directoryHint: .isDirectory),
        displayName: name,
        size: SizeResult(bytes: bytes, fileCount: 1),
        method: method,
        isSelectedByDefault: selected,
        lock: lock
    )
}

private func result(_ groups: [(RuleGroup, [ScanItem])]) -> JunkScanResult {
    JunkScanResult(groups: groups.map { ScanGroup(id: $0.0, items: $0.1) })
}

// MARK: - Initial selection

@Test func startsWithTheItemsSelectedByDefault() {
    let selection = JunkSelection(result: result([
        (.nodeModules, [item("a", selected: true), item("b")]),
    ]))
    #expect(selection.isSelected(item("a").id))
    #expect(!selection.isSelected(item("b").id))
    #expect(selection.selectedItems.map(\.displayName) == ["a"])
}

@Test func lockedItemIsNeverSelectedEvenWhenTheResultSaysSo() {
    let locked = item("locked", selected: true, lock: .appRunning(name: "Xcode"))
    let selection = JunkSelection(result: result([(.xcodeDerivedData, [locked])]))
    #expect(!selection.isSelected(locked.id))
    #expect(selection.selectedItems.isEmpty)
    #expect(selection.totals == SelectionTotals(deleteBytes: 0, trashBytes: 0, simctlBytes: 0))
}

// MARK: - User choices

@Test func aChoiceBeatsTheDefaultInBothDirections() {
    let ticked = item("ticked", selected: true), unticked = item("unticked", selected: false)
    let selection = JunkSelection(
        result: result([(.nodeModules, [ticked, unticked])]),
        userChoices: [ticked.id: false, unticked.id: true]
    )
    #expect(!selection.isSelected(ticked.id))
    #expect(selection.isSelected(unticked.id))
}

@Test func anItemWithoutAChoiceFollowsItsDefault() {
    let a = item("a", selected: true), b = item("b", selected: false), c = item("c", selected: false)
    let selection = JunkSelection(result: result([(.nodeModules, [a, b, c])]), userChoices: [c.id: true])
    #expect(selection.isSelected(a.id))
    #expect(!selection.isSelected(b.id))
    #expect(selection.isSelected(c.id))
}

@Test func noChoicesIsTheSameAsTheDefaultInitializer() {
    let scan = result([
        (.nodeModules, [item("a", selected: true), item("b"), item("c", selected: true, lock: .appRunning(name: "Xcode"))]),
        (.gradle, [item("d", selected: true)]),
    ])
    let plain = JunkSelection(result: scan)
    let empty = JunkSelection(result: scan, userChoices: [:])
    #expect(plain.selectedItems.map(\.id) == empty.selectedItems.map(\.id))
    #expect(plain.totals == empty.totals)
}

/// A tick that only came from the default must not outlive a scan that changes the default: a project that
/// became active is no longer ticked by the next scan, and nobody had chosen to delete it.
@Test func aDefaultThatChangesBetweenScansIsFollowedWhenTheUserChoseNothing() {
    let wasIdle = item("project", selected: true), nowActive = item("project", selected: false)
    #expect(wasIdle.id == nowActive.id)
    #expect(JunkSelection(result: result([(.nodeModules, [wasIdle])]), userChoices: [:]).isSelected(wasIdle.id))
    #expect(!JunkSelection(result: result([(.nodeModules, [nowActive])]), userChoices: [:]).isSelected(nowActive.id))
}

@Test func anExplicitTickSurvivesTheItemBecomingActive() {
    let nowActive = item("project", selected: false)
    let selection = JunkSelection(result: result([(.nodeModules, [nowActive])]), userChoices: [nowActive.id: true])
    #expect(selection.isSelected(nowActive.id))
}

@Test func anExplicitUntickSurvivesTheDefaultBecomingOn() {
    let nowIdle = item("project", selected: true)
    let selection = JunkSelection(result: result([(.nodeModules, [nowIdle])]), userChoices: [nowIdle.id: false])
    #expect(!selection.isSelected(nowIdle.id))
}

@Test func aLockedItemIsNeverSelectedWhateverTheChoice() {
    let locked = item("locked", selected: true, lock: .appRunning(name: "Xcode"))
    let selection = JunkSelection(result: result([(.xcodeDerivedData, [locked])]), userChoices: [locked.id: true])
    #expect(!selection.isSelected(locked.id))
    #expect(selection.selectedItems.isEmpty)
}

/// Untick, a lock appears, the lock goes away: the item must still be unticked, not back on its default.
@Test func anUntickSurvivesALockCycle() {
    let id = item("project").id
    var choices: [String: Bool] = [:]

    let open = item("project", selected: true)
    var selection = JunkSelection(result: result([(.nodeModules, [open])]), userChoices: choices)
    selection.toggle(itemID: id) // the user unticks it
    choices[id] = selection.isSelected(id)
    #expect(choices[id] == false)

    let locked = item("project", selected: true, lock: .appRunning(name: "Xcode"))
    selection = JunkSelection(result: result([(.nodeModules, [locked])]), userChoices: choices)
    #expect(!selection.isSelected(id))

    selection = JunkSelection(result: result([(.nodeModules, [open])]), userChoices: choices)
    #expect(!selection.isSelected(id))
}

@Test func choicesAboutItemsThatAreNotInTheResultAreIgnored() {
    let a = item("a", selected: true)
    let selection = JunkSelection(
        result: result([(.nodeModules, [a])]),
        userChoices: ["test.rule|/nonexistent/gone": true, "test.rule|/nonexistent/other": false]
    )
    #expect(selection.selectedItems.map(\.id) == [a.id])
    #expect(selection.totals == SelectionTotals(deleteBytes: mib, deleteCount: 1))
}

// MARK: - Toggling items

@Test func togglingAnItemFlipsIt() {
    let a = item("a")
    var selection = JunkSelection(result: result([(.nodeModules, [a])]))
    selection.toggle(itemID: a.id)
    #expect(selection.isSelected(a.id))
    selection.toggle(itemID: a.id)
    #expect(!selection.isSelected(a.id))
}

@Test func lockedItemCannotBeSelected() {
    let locked = item("locked", lock: .processRunning(name: "Gradle daemon"))
    var selection = JunkSelection(result: result([(.gradle, [locked])]))
    selection.toggle(itemID: locked.id)
    #expect(!selection.isSelected(locked.id))
}

@Test func togglingAnUnknownItemChangesNothing() {
    let a = item("a", selected: true)
    var selection = JunkSelection(result: result([(.nodeModules, [a])]))
    selection.toggle(itemID: "test.rule|/nonexistent/other")
    #expect(!selection.isSelected("test.rule|/nonexistent/other"))
    #expect(selection.selectedItems.map(\.id) == [a.id])
}

// MARK: - Groups

@Test func groupTriState() {
    let a = item("a"), b = item("b")
    var selection = JunkSelection(result: result([(.nodeModules, [a, b])]))
    #expect(selection.state(of: .nodeModules) == .off)
    selection.toggle(itemID: a.id)
    #expect(selection.state(of: .nodeModules) == .mixed)
    selection.toggle(group: .nodeModules)
    #expect(selection.state(of: .nodeModules) == .on)
    #expect(selection.isSelected(a.id) && selection.isSelected(b.id))
    selection.toggle(group: .nodeModules)
    #expect(selection.state(of: .nodeModules) == .off)
    #expect(!selection.isSelected(a.id) && !selection.isSelected(b.id))
}

@Test func groupToggleFromOffSelectsEveryUnlockedItem() {
    let a = item("a"), b = item("b")
    var selection = JunkSelection(result: result([(.nodeModules, [a, b])]))
    selection.toggle(group: .nodeModules)
    #expect(selection.state(of: .nodeModules) == .on)
}

@Test func groupToggleSkipsLockedItemsAndStaysOnWithoutThem() {
    let free = item("free"), locked = item("locked", lock: .appRunning(name: "Xcode"))
    var selection = JunkSelection(result: result([(.xcodeDerivedData, [free, locked])]))
    selection.toggle(group: .xcodeDerivedData)
    #expect(selection.isSelected(free.id))
    #expect(!selection.isSelected(locked.id))
    // Every item that can be selected is, so the group reads as fully selected, not mixed.
    #expect(selection.state(of: .xcodeDerivedData) == .on)
    selection.toggle(group: .xcodeDerivedData)
    #expect(selection.state(of: .xcodeDerivedData) == .off)
}

@Test func groupWithOnlyLockedItemsIsOffAndCannotBeToggled() {
    let locked = item("locked", lock: .appRunning(name: "Xcode"))
    var selection = JunkSelection(result: result([(.xcodeDerivedData, [locked])]))
    #expect(selection.state(of: .xcodeDerivedData) == .off)
    selection.toggle(group: .xcodeDerivedData)
    #expect(selection.state(of: .xcodeDerivedData) == .off)
    #expect(selection.selectedItems.isEmpty)
}

@Test func groupToggleOnlyAffectsThatGroup() {
    let node = item("node"), cache = item("cache", selected: true)
    var selection = JunkSelection(result: result([(.nodeModules, [node]), (.packageCaches, [cache])]))
    selection.toggle(group: .nodeModules)
    #expect(selection.state(of: .nodeModules) == .on)
    #expect(selection.state(of: .packageCaches) == .on)
    selection.toggle(group: .nodeModules)
    #expect(selection.state(of: .nodeModules) == .off)
    #expect(selection.isSelected(cache.id))
}

@Test func aGroupThatIsNotInTheResultIsOffAndTogglingItDoesNothing() {
    var selection = JunkSelection(result: result([(.nodeModules, [item("a", selected: true)])]))
    #expect(selection.state(of: .gradle) == .off)
    selection.toggle(group: .gradle)
    #expect(selection.state(of: .gradle) == .off)
    #expect(selection.selectedItems.count == 1)
}

// MARK: - Selected items and totals

@Test func selectedItemsKeepDisplayOrder() {
    let a = item("a"), b = item("b"), c = item("c"), d = item("d")
    var selection = JunkSelection(result: result([(.nodeModules, [a, b]), (.packageCaches, [c, d])]))
    for id in [d.id, a.id, c.id] { selection.toggle(itemID: id) }
    #expect(selection.selectedItems.map(\.displayName) == ["a", "c", "d"])
}

@Test func totalsSplitByMethod() {
    var selection = JunkSelection(result: result([
        (.nodeModules, [item("modules", bytes: 3 * mib, method: .delete)]),
        (.archives, [item("archive", bytes: mib, method: .trash)]),
        (.simulators, [item("device", bytes: 5 * mib, method: .simctl)]),
    ]))
    selection.toggle(group: .nodeModules)
    selection.toggle(group: .archives)
    #expect(selection.totals == SelectionTotals(deleteBytes: 3 * mib, trashBytes: mib, simctlBytes: 0, deleteCount: 1, trashCount: 1))
    #expect(selection.totals.totalBytes == 4 * mib)

    selection.toggle(group: .simulators)
    #expect(selection.totals == SelectionTotals(
        deleteBytes: 3 * mib, trashBytes: mib, simctlBytes: 5 * mib, deleteCount: 1, trashCount: 1, simctlCount: 1
    ))
    #expect(selection.totals.totalBytes == 9 * mib)
}

@Test func totalsCountTheItemsOfEachMethodEvenWithoutBytes() {
    // A ticked item of 0 bytes (or "≈ 0", when it could not be measured) still leaves the disk its own way, so the
    // confirmation must name that way: what decides it is the number of items, not their bytes.
    let selection = JunkSelection(result: result([
        (.nodeModules, [item("empty", bytes: 0, method: .delete, selected: true)]),
        (.archives, [item("archive", bytes: mib, method: .trash, selected: true)]),
        (.simulators, [item("device", bytes: 0, method: .simctl)]),
    ]))
    let totals = selection.totals
    #expect(totals == SelectionTotals(deleteBytes: 0, trashBytes: mib, simctlBytes: 0, deleteCount: 1, trashCount: 1))
    #expect([CleanMethod.delete, .trash, .simctl].map(totals.count(of:)) == [1, 1, 0])
    #expect([CleanMethod.delete, .trash, .simctl].map(totals.bytes(of:)) == [0, mib, 0])
    #expect(totals.itemCount == 2)
}

@Test func totalsFollowTheSelection() {
    let a = item("a", bytes: 2 * mib), b = item("b", bytes: 3 * mib)
    var selection = JunkSelection(result: result([(.nodeModules, [a, b])]))
    #expect(selection.totals == SelectionTotals(deleteBytes: 0, trashBytes: 0, simctlBytes: 0))
    selection.toggle(itemID: a.id)
    selection.toggle(itemID: b.id)
    selection.toggle(itemID: a.id)
    #expect(selection.totals.deleteBytes == 3 * mib)
}

// MARK: - Result

@Test func resultAddsUpGroupTotals() {
    let scanResult = result([
        (.nodeModules, [item("a", bytes: 2 * mib), item("b", bytes: mib)]),
        (.packageCaches, [item("c", bytes: 4 * mib)]),
    ])
    #expect(scanResult.groups.map(\.totalBytes) == [3 * mib, 4 * mib])
    #expect(scanResult.totalBytes == 7 * mib)
    #expect(JunkScanResult(groups: []).totalBytes == 0)
}
