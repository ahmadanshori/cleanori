import Foundation
import Observation
import CleanoriCore

/// The state of the Developer Junk screen (spec §6.2): what it is doing, what the last scan found and which
/// items are ticked. It never touches the disk itself: scanning is `JunkScanner`'s job and every removal goes
/// through `Cleaner`.
@MainActor @Observable
final class DeveloperJunkModel {
    enum Phase {
        /// Nothing scanned yet.
        case idle
        case scanning(ScanProgress)
        /// The table of the last scan.
        case results
        /// A clean is running. Once `done` reaches `total` the list is being refreshed.
        case cleaning(done: Int, total: Int)
        /// The table again, with what the last clean did above it.
        case report(CleanReport)
    }

    private(set) var phase: Phase = .idle

    /// What the last scan found; `nil` until a scan has finished. The shell (`AppModel`, sidebar, Overview) reads it.
    private(set) var result: JunkScanResult?
    private(set) var selection: JunkSelection?

    /// What the user ticked or unticked on purpose, by item ID, for the whole session (ruling R26b). Only a toggle
    /// by the user writes here. Every selection is built from it: an item with an entry takes the entry, any
    /// other item takes the scan's default. So a tick that merely came from a default is worked out again by each
    /// scan, and a choice made about an item survives rescans, refreshes and the item being locked for a while.
    private(set) var userChoices: [String: Bool] = [:]

    /// The groups whose items are shown under their row.
    var expanded: Set<RuleGroup> = []
    /// Whether `node_modules` lists every folder or only the largest few (see `collapsedNodeModulesCount`).
    var showsAllNodeModules = false

    /// Why `xcrun simctl` could not list simulators during the last scan (spec §7, ruling R24), or `nil` when it could.
    private(set) var simulatorsSkippedReason: String?
    /// What the report banner needs besides the `CleanReport` itself.
    private(set) var reportContext = CleanReportContext()
    /// The size of each item of the clean in progress, for the bubbles that pop as they are done.
    private(set) var cleaningSizes: [Int64] = []
    /// Whether any of `cleaningSizes` may be off (ruling R11).
    private(set) var cleaningSizesAreApproximate = false
    /// Set when a clean could not start; the screen shows it as an alert.
    var cleanProblem: CleanProblem?

    /// What the ticked items would do, for the bottom bar and the confirmation sheet.
    struct CleanPreview {
        var totals = SelectionTotals()
        /// The methods that have an approximate item among the ticked ones.
        var approximateMethods: Set<CleanMethod> = []

        var isApproximate: Bool { !approximateMethods.isEmpty }
        func isApproximate(_ method: CleanMethod) -> Bool { approximateMethods.contains(method) }
    }

    /// `node_modules` shows this many folders, largest first, and sums up the rest as "+ N more folders".
    static let collapsedNodeModulesCount = 3

    let settings: AppSettings

    /// The environment of the last scan. A clean and the refresh after it use the same one, so what `Cleaner`
    /// re-checks is what the user was shown, even if the settings changed in between.
    @ObservationIgnored private var environment: CoreEnvironment?
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - State

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    var isCleaning: Bool {
        if case .cleaning = phase { return true }
        return false
    }

    /// Clean is available when a table is showing and something is ticked. Not while scanning or cleaning.
    var canClean: Bool {
        switch phase {
        case .results, .report: !(selection?.selectedItems.isEmpty ?? true)
        case .idle, .scanning, .cleaning: false
        }
    }

    /// Whether the user has ticked or unticked anything, so "Reset to defaults" has something to do.
    var hasUserChoices: Bool { !userChoices.isEmpty }

    var cleanPreview: CleanPreview {
        guard let selection else { return CleanPreview() }
        let approximate = selection.selectedItems.filter(\.size.isApproximate).map(\.method)
        return CleanPreview(totals: selection.totals, approximateMethods: Set(approximate))
    }

    // MARK: - Scanning

    /// Scans every rule. A scan that is already running is joined rather than started twice, and nothing starts
    /// while a clean is running. Cancelling the calling task cancels the scan.
    func scan() async {
        if let scanTask {
            await scanTask.value
            return
        }
        guard !isCleaning else { return }
        // Set before the task starts: between here and the task's first line nothing else may begin a clean.
        phase = .scanning(ScanProgress(itemsScanned: 0, currentPath: ""))
        let task = Task { await self.performScan() }
        scanTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Stops the running scan. The screen goes back to the earlier results, or to the start.
    func cancelScan() {
        scanTask?.cancel()
    }

    private func performScan() async {
        defer { scanTask = nil }
        let env = settings.makeEnvironment()

        // `JunkScanner` calls `progress` under a lock, from whichever thread is measuring. It must stay cheap, so
        // it only leaves the latest value in `relay`; the main actor picks it up a few times a second.
        let relay = ProgressRelay()
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let progress = relay.take() else { continue }
                self?.show(progress)
            }
        }
        defer { ticker.cancel() }

        do {
            async let simulatorsProblem = Self.simulatorsProblem(env)
            let found = try await JunkScanner(env: env).scan(progress: { relay.store($0) })
            simulatorsSkippedReason = await simulatorsProblem

            environment = env
            if result == nil, found.groups.contains(where: { $0.id == .nodeModules }) {
                // The one group where the user has to decide folder by folder.
                expanded.insert(.nodeModules)
            }
            selection = JunkSelection(result: found, userChoices: userChoices)
            result = found
            phase = .results
        } catch {
            // `JunkScanner` only throws when cancelled. Either way the screen returns to where it was.
            phase = result == nil ? .idle : .results
        }
    }

    private func show(_ progress: ScanProgress) {
        if case .scanning = phase {
            phase = .scanning(progress)
        }
    }

    /// Why `xcrun simctl` cannot list simulators (ruling R24), or `nil` when it can. A cancelled call is not a failure.
    private nonisolated static func simulatorsProblem(_ env: CoreEnvironment) async -> String? {
        do {
            _ = try await env.simulators.listDevices()
            return nil
        } catch is CancellationError {
            return nil
        } catch XcrunError.timedOut {
            return "simctl did not answer in time"
        } catch {
            return "Xcode command line tools not found"
        }
    }

    // MARK: - Selection

    func toggle(itemID: String) {
        guard let item = result?.groups.lazy.flatMap(\.items).first(where: { $0.id == itemID }) else { return }
        selection?.toggle(itemID: itemID)
        recordChoices(for: [item])
    }

    func toggle(group: RuleGroup) {
        selection?.toggle(group: group)
        recordChoices(for: result?.groups.filter { $0.id == group }.flatMap(\.items) ?? [])
    }

    /// The checkbox of a set of items that is not a group of its own ("+ N more folders").
    func state(of items: [ScanItem]) -> TriState {
        guard let selection else { return .off }
        let selectable = items.filter { $0.lock == nil }
        let ticked = selectable.count { selection.isSelected($0.id) }
        if ticked == 0 { return .off }
        return ticked == selectable.count ? .on : .mixed
    }

    /// Ticks every unlocked item of `items` when they are not all ticked, and unticks them all when they are.
    func toggle(items: [ScanItem]) {
        guard var updated = selection else { return }
        let allTicked = state(of: items) == .on
        for item in items where item.lock == nil && updated.isSelected(item.id) == allTicked {
            updated.toggle(itemID: item.id)
        }
        selection = updated
        recordChoices(for: items)
    }

    /// Remembers the tick the user just gave `items`. A locked item cannot be ticked, so it has no choice to keep.
    private func recordChoices(for items: [ScanItem]) {
        guard let selection else { return }
        for item in items where item.lock == nil {
            userChoices[item.id] = selection.isSelected(item.id)
        }
    }

    /// Forgets every choice and goes back to the ticks the scan suggests.
    func resetToDefaults() {
        guard let result, !isScanning, !isCleaning else { return }
        userChoices = [:]
        selection = JunkSelection(result: result)
    }

    func toggleExpanded(_ group: RuleGroup) {
        if !expanded.insert(group).inserted {
            expanded.remove(group)
        }
    }

    // MARK: - Cleaning

    /// Cleans the ticked items with `Cleaner`, then scans again the rules they came from.
    func clean() async {
        let previous = phase
        switch previous {
        case .results, .report: break
        case .idle, .scanning, .cleaning: return
        }
        guard let selection, let env = environment else { return }
        let items = selection.selectedItems
        guard !items.isEmpty else { return }

        cleaningSizes = items.map(\.size.bytes)
        cleaningSizesAreApproximate = items.contains { $0.size.isApproximate }
        phase = .cleaning(done: 0, total: items.count)
        let total = items.count
        let counter = EventCounter()
        let cleaner = Cleaner(env: env, log: settings.makeCleanLog())
        let report: CleanReport
        do {
            report = try await cleaner.clean(items) { event in
                if case .started = event { return }
                let done = counter.next()
                Task { @MainActor [weak self] in self?.noteCleaned(done, of: total) }
            }
        } catch CleanerError.alreadyRunning {
            // The Clean button is disabled while a clean runs, so this is not expected; nothing was done.
            phase = previous
            return
        } catch CleanerError.logUnavailable(let message) {
            // Nothing was touched (ruling R13).
            phase = previous
            cleanProblem = CleanProblem(title: "Can't write the cleanup log", message: "\(message)\n\nNothing was cleaned.")
            return
        } catch {
            // `Cleaner` throws nothing else today. Do not blame the log for an error that is not about it.
            phase = previous
            cleanProblem = CleanProblem(title: "Couldn't clean", message: error.localizedDescription)
            return
        }

        let cleaned = items.filter { report.skipped[$0.id] == nil && report.failed[$0.id] == nil }
        reportContext = CleanReportContext(
            names: Dictionary(items.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first }),
            freedIsApproximate: cleaned.contains { $0.method != .trash && $0.size.isApproximate },
            trashedIsApproximate: cleaned.contains { $0.method == .trash && $0.size.isApproximate }
        )
        phase = .cleaning(done: total, total: total)
        await refresh(rules: Set(items.map(\.ruleID)), env: env)
        // An item that was cleaned and is gone is a different thing if it comes back, so its choice goes too.
        let stillListed = Set(result?.groups.flatMap(\.items).map(\.id) ?? [])
        for item in cleaned where !stillListed.contains(item.id) {
            userChoices[item.id] = nil
        }
        phase = .report(report)
    }

    private func noteCleaned(_ done: Int, of total: Int) {
        if case .cleaning(let shown, _) = phase, done > shown {
            phase = .cleaning(done: done, total: total)
        }
    }

    func dismissReport() {
        if case .report = phase { phase = .results }
    }

    /// Scans `ruleIDs` again and swaps what they find into the table. The ticks are rebuilt from the user's
    /// choices and the scan's defaults, like after any scan.
    private func refresh(rules ruleIDs: Set<String>, env: CoreEnvironment) async {
        guard let old = result else { return }
        let rules = Catalog.all().filter { ruleIDs.contains($0.id) }
        guard let fresh = try? await JunkScanner(env: env, rules: rules).scan() else { return }

        let merged = Self.merge(old, replacingRules: ruleIDs, with: fresh)
        selection = JunkSelection(result: merged, userChoices: userChoices)
        result = merged
    }

    /// `old` with the items of `ruleIDs` replaced by those of `fresh`, in the order `JunkScanner` lists them.
    private static func merge(_ old: JunkScanResult, replacingRules ruleIDs: Set<String>, with fresh: JunkScanResult) -> JunkScanResult {
        var byGroup: [RuleGroup: [ScanItem]] = [:]
        for group in old.groups {
            byGroup[group.id, default: []] += group.items.filter { !ruleIDs.contains($0.ruleID) }
        }
        for group in fresh.groups {
            byGroup[group.id, default: []] += group.items
        }
        return JunkScanResult(groups: RuleGroup.allCases.compactMap { group in
            guard let items = byGroup[group], !items.isEmpty else { return nil }
            return ScanGroup(id: group, items: items.sorted(by: isListedBefore))
        })
    }

    /// Largest first, then by name and id so equal sizes keep a stable order (the same order as `JunkScanner`).
    private static func isListedBefore(_ lhs: ScanItem, _ rhs: ScanItem) -> Bool {
        if lhs.size.bytes != rhs.size.bytes { return lhs.size.bytes > rhs.size.bytes }
        if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
        return lhs.id < rhs.id
    }
}

// MARK: - Totals

/// How many items, and how much space, with `≈` when any of them is approximate (ruling R11).
struct ItemTotal: Equatable {
    var count = 0
    var bytes: Int64 = 0
    var isApproximate = false

    init(_ items: some Sequence<ScanItem>) {
        for item in items {
            count += 1
            bytes += item.size.bytes
            isApproximate = isApproximate || item.size.isApproximate
        }
    }

    var sizeText: String { bytes.sizeText(approximate: isApproximate) }
}

extension JunkScanResult {
    /// What can be cleaned now: the items that are not locked. The banner and the sidebar show this (ruling R25).
    var cleanable: ItemTotal { ItemTotal(groups.lazy.flatMap(\.items).filter { $0.lock == nil }) }
    /// What a lock holds back for now.
    var locked: ItemTotal { ItemTotal(groups.lazy.flatMap(\.items).filter { $0.lock != nil }) }
}
