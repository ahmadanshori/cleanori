import Foundation
import Synchronization

/// The items found for one `RuleGroup`, largest first.
public struct ScanGroup: Sendable, Identifiable {
    public let id: RuleGroup
    /// Shown in the order given; `JunkScanner` passes them sorted by size, largest first.
    public let items: [ScanItem]

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.size.bytes } }

    public init(id: RuleGroup, items: [ScanItem]) {
        self.id = id
        self.items = items
    }
}

/// Everything a Developer Junk scan found.
public struct JunkScanResult: Sendable {
    /// In `RuleGroup` display order. A group without items is left out.
    public let groups: [ScanGroup]

    public var totalBytes: Int64 { groups.reduce(0) { $0 + $1.totalBytes } }

    public init(groups: [ScanGroup]) {
        self.groups = groups
    }
}

/// Runs the cleanup rules, measures what they find and works out which items start ticked or locked (spec §5.5).
///
/// - At most `maxConcurrentRules` rules run at once, and they share one `InodeLedger`, so a hardlinked file
///   is charged once however many rules reach it. A new ledger is made for every `scan`.
/// - A rule whose `discover` fails contributes no items and the scan goes on.
/// - An item that is gone by the time it is sized is dropped. One that cannot be sized for another reason is
///   still listed, as `0` bytes and approximate, so it stays visible rather than silently disappearing.
/// - Cancelling the task running `scan` ends it with `CancellationError`.
public struct JunkScanner: Sendable {
    private let env: CoreEnvironment
    private let rules: [CleanupRule]
    private let maxConcurrentRules: Int

    /// A `maxConcurrentRules` below 1 is treated as 1.
    public init(env: CoreEnvironment, rules: [CleanupRule] = Catalog.all(), maxConcurrentRules: Int = 6) {
        self.env = env
        self.rules = rules
        self.maxConcurrentRules = max(1, maxConcurrentRules)
    }

    /// Scans every rule and returns the items grouped for the Developer Junk screen.
    ///
    /// `progress` reports how many entries have been measured in total so far. It may be called from several
    /// threads at once, but calls never overlap and the count never goes down.
    public func scan(progress: (@Sendable (ScanProgress) -> Void)? = nil) async throws -> JunkScanResult {
        try Task.checkCancellation()
        let run = Run(
            sizer: DirectorySizer(ledger: InodeLedger()),
            now: env.now(),
            progress: progress.map(ProgressTotal.init)
        )

        let found = try await withThrowingTaskGroup(of: (group: RuleGroup, items: [ScanItem]).self) { tasks in
            var byGroup: [RuleGroup: [ScanItem]] = [:]
            var pending = rules.makeIterator()
            var running = 0
            while true {
                while running < maxConcurrentRules, let rule = pending.next() {
                    tasks.addTask { (rule.group, try await self.items(for: rule, in: run)) }
                    running += 1
                }
                guard running > 0, let result = try await tasks.next() else { break }
                running -= 1
                byGroup[result.group, default: []] += result.items
            }
            return byGroup
        }
        // A rule that ignores cancellation must not turn a cancelled scan into a normal result.
        try Task.checkCancellation()

        return JunkScanResult(groups: RuleGroup.allCases.compactMap { group in
            guard let items = found[group], !items.isEmpty else { return nil }
            return ScanGroup(id: group, items: items.sorted(by: Self.isListedBefore))
        })
    }

    // MARK: - One rule

    /// Everything a rule needs from the scan it runs in.
    private struct Run: Sendable {
        let sizer: DirectorySizer
        /// Read once, so every `ifInactive` decision of a scan uses the same moment.
        let now: Date
        let progress: ProgressTotal?
    }

    private func items(for rule: CleanupRule, in run: Run) async throws -> [ScanItem] {
        try Task.checkCancellation()
        let discovered: [DiscoveredItem]
        do {
            discovered = try await rule.discover(env)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            // This rule offers nothing, but a failure that only shows up because the scan was cancelled is no
            // reason to carry on: it has to end the scan.
            try Task.checkCancellation()
            return []
        }
        guard !discovered.isEmpty else { return [] }

        let lock = rule.locks.lazy.compactMap { $0.evaluate(env.processes) }.first
        var items: [ScanItem] = []
        items.reserveCapacity(discovered.count)
        for found in discovered {
            try Task.checkCancellation()
            let size: SizeResult
            do {
                size = try await run.sizer.size(of: found.url, progress: run.progress?.callbackForOneItem())
            } catch let cancellation as CancellationError {
                throw cancellation
            } catch let error as POSIXError where error.code == .ENOENT {
                continue // deleted since it was discovered, so there is nothing left to offer
            } catch {
                size = SizeResult(bytes: 0, fileCount: 0, isApproximate: true)
            }
            items.append(ScanItem(
                ruleID: rule.id,
                url: found.url,
                displayName: found.displayName,
                detail: found.detail,
                size: size,
                lastActivity: found.lastActivity,
                method: rule.method,
                isSelectedByDefault: lock == nil && isSelectedByDefault(found, rule: rule, now: run.now),
                lock: lock,
                badges: found.badges,
                simulatorUDID: found.simulatorUDID
            ))
        }
        return items
    }

    private func isSelectedByDefault(_ item: DiscoveredItem, rule: CleanupRule, now: Date) -> Bool {
        // A `node_modules` with no `package.json` beside it may belong to a tool rather than a project, so being
        // idle says nothing about whether it is safe to delete. It is listed, but only the user can tick it.
        if item.badges.contains(.noPackageJSON) { return false }
        switch rule.defaultSelection {
        case .always:
            return true
        case .never:
            return false
        case .ifInactive:
            // Inactive means older than the threshold; exactly that old still counts as active, matching the
            // `active` badge that project discovery sets. With no date there is no sign the project is idle.
            guard let lastActivity = item.lastActivity else { return false }
            return now.timeIntervalSince(lastActivity) > Double(env.inactiveAfterDays) * 86_400
        case .ifUnavailable:
            return item.isUnavailable
        }
    }

    /// Largest first. Items finish in whatever order the rules do, so equal sizes fall back to the name
    /// (and then the id) to keep the order the same from one scan to the next.
    private static func isListedBefore(_ lhs: ScanItem, _ rhs: ScanItem) -> Bool {
        if lhs.size.bytes != rhs.size.bytes { return lhs.size.bytes > rhs.size.bytes }
        if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
        return lhs.id < rhs.id
    }
}

// MARK: - Progress

/// Adds up the counts that `DirectorySizer` reports for each item it measures.
///
/// Each sizing call counts entries from 0, and several rules are sized at once, so passing their reports on as
/// they are would make the number jump back and forth. The total is only ever increased, and it is passed on while the
/// lock is held so that reports reach the caller in order.
private final class ProgressTotal: Sendable {
    private let total = Mutex(0)
    private let forward: @Sendable (ScanProgress) -> Void

    init(_ forward: @escaping @Sendable (ScanProgress) -> Void) {
        self.forward = forward
    }

    /// The callback to give `DirectorySizer.size(of:progress:)` for one item.
    func callbackForOneItem() -> @Sendable (ScanProgress) -> Void {
        let item = EntryCount()
        return { progress in
            let added = item.advance(to: progress.itemsScanned)
            self.total.withLock { total in
                total += added
                self.forward(ScanProgress(itemsScanned: total, currentPath: progress.currentPath))
            }
        }
    }
}

/// The last count reported for one item.
private final class EntryCount: Sendable {
    private let last = Mutex(0)

    /// Records `count` and returns how much it is above the previous one.
    func advance(to count: Int) -> Int {
        last.withLock { last in
            defer { last = count }
            return count - last
        }
    }
}
