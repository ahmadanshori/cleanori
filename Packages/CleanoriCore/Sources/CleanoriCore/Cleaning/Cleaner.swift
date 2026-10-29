import Foundation

/// Progress of a clean, reported once per step of each item: `started`, then exactly one of the others.
public enum CleanEvent: Sendable {
    case started(ScanItem)
    case finished(ScanItem, bytes: Int64)
    case skipped(ScanItem, reason: String)
    case failed(ScanItem, message: String)
}

/// What a clean did. Byte counts are the sizes measured by the scan.
public struct CleanReport: Sendable, Equatable {
    public var deletedBytes: Int64
    public var trashedBytes: Int64
    public var simctlBytes: Int64
    /// Item ID to the reason it was left alone.
    public var skipped: [String: String]
    /// Item ID to the system's error message.
    public var failed: [String: String]
    /// The first failure to write a log line, if any. The item it belongs to was still cleaned (or skipped).
    public var logError: String?

    public init(
        deletedBytes: Int64 = 0,
        trashedBytes: Int64 = 0,
        simctlBytes: Int64 = 0,
        skipped: [String: String] = [:],
        failed: [String: String] = [:],
        logError: String? = nil
    ) {
        self.deletedBytes = deletedBytes
        self.trashedBytes = trashedBytes
        self.simctlBytes = simctlBytes
        self.skipped = skipped
        self.failed = failed
        self.logError = logError
    }
}

public enum CleanerError: Error, Equatable {
    /// `clean` was called while another clean was still running.
    case alreadyRunning
    /// The clean log cannot be written, so nothing was cleaned. Carries the system's message.
    case logUnavailable(String)
}

/// The only component that deletes, trashes or removes anything (spec §5.9).
///
/// A clean first makes sure the log can be written (otherwise it throws `logUnavailable` and touches nothing),
/// then takes each item once, in order (a repeated item ID is ignored). Every item is revalidated right before
/// it is acted on; the first check that fails skips the item and nothing else happens to it:
/// 1. The path is a plain absolute file path: no `..` (the kernel resolves `..` after following links, while
///    `SafetyGuard` judges it as text) and no NUL (C APIs would stop reading there).
/// 2. Something still exists at the path (`lstat`); if not, `"No longer exists"`, which is not an error.
/// 3. The item's rule is known and uses the item's method, and none of the rule's locks hold right now (the
///    lock found by the scan is not trusted). Only Large Files (`largeFiles`, `.trash`) needs no rule, and has
///    no locks.
/// 4. `.simctl`: a well-formed simulator UDID that the rule's `discover`, run again, still lists; the locks
///    once more; then `SimulatorControl.delete(udid:)`. The path rules below do not apply, since nothing is
///    removed by path.
/// 5. `.delete`: the rule's `discover`, run again, still finds exactly this path.
/// 6. `.delete`, `.trash`: the rule's locks once more, since one may have appeared while `discover` ran.
/// 7. `.delete`, `.trash`: no folder between home and the item is a symbolic link (`lstat` on each).
/// 8. `SafetyGuard.check` allows exactly this URL, which is then removed (`FileManager.removeItem`) or moved
///    to the Trash (`Trasher.trash`). Nothing is awaited between this check and the action.
///
/// A rule's `discover` runs at most once per clean; when it throws, every item of that rule that needs it is
/// skipped with `"Could not re-check rule"`. Each item ends up in the log as one line. One item failing never
/// stops the others.
public actor Cleaner {
    /// The rule ID Large Files gives its items. Large Files is not a catalog rule.
    static let largeFilesRuleID = "largeFiles"

    private let env: CoreEnvironment
    private let rules: [CleanupRule]
    private let log: CleanLog
    private let safetyGuard: SafetyGuard
    /// The components of `env.home`, for the walk in step 7.
    private let homeComponents: [String]
    /// Set before the first suspension point of `clean` and cleared on every way out of it.
    private var isRunning = false

    public init(env: CoreEnvironment, rules: [CleanupRule] = Catalog.all(), log: CleanLog) {
        self.env = env
        self.rules = rules
        self.log = log
        safetyGuard = SafetyGuard(home: env.home)
        homeComponents = Self.lexicalComponents(of: env.home.path)
    }

    /// Cleans `items` one after the other.
    ///
    /// Throws, without touching anything, `CleanerError.alreadyRunning` when another clean on this cleaner has
    /// not finished yet, and `CleanerError.logUnavailable` when the clean log cannot be written.
    public func clean(
        _ items: [ScanItem], onEvent: @Sendable (CleanEvent) -> Void = { _ in }
    ) async throws -> CleanReport {
        guard !isRunning else { throw CleanerError.alreadyRunning }
        isRunning = true
        defer { isRunning = false }

        // Nothing is cleaned unless what is done can be written down.
        do {
            try log.prepare()
        } catch {
            throw CleanerError.logUnavailable(error.localizedDescription)
        }

        var report = CleanReport()
        var rechecks = RecheckCache()
        var seen = Set<String>()
        for item in items where seen.insert(item.id).inserted {
            onEvent(.started(item))
            switch await clean(item, rechecks: &rechecks) {
            case .done:
                switch item.method {
                case .delete: report.deletedBytes += item.size.bytes
                case .trash: report.trashedBytes += item.size.bytes
                case .simctl: report.simctlBytes += item.size.bytes
                }
                write(item, action: item.method.rawValue, result: "ok", message: nil, into: &report)
                onEvent(.finished(item, bytes: item.size.bytes))
            case .skipped(let reason, let logMessage):
                report.skipped[item.id] = reason
                write(item, action: "skip", result: "skipped", message: logMessage, into: &report)
                onEvent(.skipped(item, reason: reason))
            case .failed(let message):
                report.failed[item.id] = message
                write(item, action: item.method.rawValue, result: "failed", message: message, into: &report)
                onEvent(.failed(item, message: message))
            }
        }
        return report
    }

    // MARK: - One item

    private enum Outcome {
        case done
        /// `logMessage` is what goes into the log; it differs from `reason` for `SafetyGuard` denials.
        case skipped(reason: String, logMessage: String)
        case failed(String)

        static func skip(_ reason: String) -> Outcome { .skipped(reason: reason, logMessage: reason) }
    }

    private func clean(_ item: ScanItem, rechecks: inout RecheckCache) async -> Outcome {
        let url = item.url
        let path = url.path

        // 1. A plain path.
        guard url.isFileURL, !path.split(separator: "/").contains("..") else { return .skip("Outside home folder") }
        guard !path.contains("\0") else { return .skip("Invalid path") }

        // 2. Still there.
        if let reason = Self.missingReason(at: path) { return .skip(reason) }

        // 3. Rule and locks, evaluated now.
        let rule = rules.first { $0.id == item.ruleID }
        if let rule {
            guard rule.method == item.method else { return .skip("Clean method does not match its rule") }
            if let lock = currentLock(of: rule) { return .skip(lock.label) }
        } else if !(item.method == .trash && item.ruleID == Self.largeFilesRuleID) {
            return .skip("Unknown rule")
        }

        switch item.method {
        case .simctl:
            guard let rule else { return .skip("Unknown rule") } // handled above; keeps the rule non-optional
            return await deleteSimulator(item, rule: rule, rechecks: &rechecks)
        case .delete, .trash:
            // 5. A permanent deletion must still be something its rule finds.
            var isCatalogItem = false
            if item.method == .delete {
                guard let rule else { return .skip("Unknown rule") } // handled above
                guard case .found(let paths, _) = await rechecks.result(of: rule, in: env) else {
                    return .skip("Could not re-check rule")
                }
                isCatalogItem = paths.contains(Self.lexicalComponents(of: path))
            }

            // 6. Locks again: one may have appeared while `discover` ran.
            if let rule, let lock = currentLock(of: rule) { return .skip(lock.label) }

            // 7. Every folder from home down to the item's parent is a real folder.
            if let reason = linkedAncestorReason(for: path) { return .skip(reason) }

            // 8. SafetyGuard on exactly this URL, then act on it with no suspension point in between.
            if case .denied(let reason) = safetyGuard.check(url, method: item.method, isCatalogItem: isCatalogItem) {
                return .skipped(reason: reason, logMessage: "SafetyGuard: \(reason)")
            }
            do {
                if item.method == .delete {
                    try FileManager.default.removeItem(at: url)
                } else {
                    try env.trasher.trash(url)
                }
                return .done
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Gone as a whole: it vanished since step 2. Still there: only part of it went, which is a failure.
                if let reason = Self.missingReason(at: path) { return .skip(reason) }
                return .failed(error.localizedDescription)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    /// Step 4: a simulator is deleted by UDID, and only one that `simctl` still lists.
    private func deleteSimulator(_ item: ScanItem, rule: CleanupRule, rechecks: inout RecheckCache) async -> Outcome {
        guard let udid = item.simulatorUDID else { return .skip("Missing simulator UDID") }
        // Only a real UDID: `simctl delete` also accepts `all` and `unavailable`.
        guard UUID(uuidString: udid) != nil else { return .skip("Invalid simulator UDID") }
        guard case .found(_, let udids) = await rechecks.result(of: rule, in: env) else {
            return .skip("Could not re-check rule")
        }
        guard udids.contains(udid) else { return .skip("Not found by a cleanup rule") }
        if let lock = currentLock(of: rule) { return .skip(lock.label) } // may have appeared during `discover`
        do {
            try await env.simulators.delete(udid: udid)
            return .done
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Checks

    private func currentLock(of rule: CleanupRule) -> LockReason? {
        let processes = env.processes
        return rule.locks.lazy.compactMap { $0.evaluate(processes) }.first
    }

    /// `"No longer exists"` when nothing is at `path` (not even a link), another reason when `lstat` fails for
    /// some other cause, and `nil` when something is there.
    private static func missingReason(at path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) != 0 else { return nil }
        let code = errno
        if code == ENOENT || code == ENOTDIR { return "No longer exists" }
        return "Cannot inspect item: \(String(cString: strerror(code)))"
    }

    /// Why the item must be skipped when a folder between home and the item cannot be trusted, or `nil`.
    ///
    /// Only the folders strictly below home are looked at (Ruling R14): the item itself is `SafetyGuard`'s to
    /// judge, and a path outside home is denied by it.
    private func linkedAncestorReason(for path: String) -> String? {
        let parts = Self.lexicalComponents(of: path)
        guard !homeComponents.isEmpty, parts.count > homeComponents.count, parts.starts(with: homeComponents) else {
            return nil
        }
        var ancestor = "/" + homeComponents.joined(separator: "/")
        for part in parts[homeComponents.count ..< parts.count - 1] {
            ancestor += "/" + part
            var info = stat()
            guard lstat(ancestor, &info) == 0 else {
                let code = errno
                if code == ENOENT || code == ENOTDIR { return "No longer exists" }
                return "Cannot inspect folder: \(String(cString: strerror(code)))"
            }
            if info.st_mode & S_IFMT == S_IFLNK { return "Path goes through a symbolic link" }
        }
        return nil
    }

    // MARK: - Log

    /// Logs one item. A line that cannot be written does not change what happened to the item (the action is
    /// already done); the first such failure is kept in `report.logError`.
    private func write(
        _ item: ScanItem, action: String, result: String, message: String?, into report: inout CleanReport
    ) {
        let entry = CleanLogEntry(
            timestamp: env.now(), action: action, ruleID: item.ruleID, path: item.url.path,
            bytes: item.size.bytes, result: result, message: message
        )
        do {
            try log.append(entry)
        } catch {
            if report.logError == nil { report.logError = error.localizedDescription }
        }
    }

    /// A path split into components with `.` and empty components dropped. `..` is kept as it is: paths
    /// containing it are rejected before this is used on them.
    fileprivate static func lexicalComponents(of path: String) -> [String] {
        path.split(separator: "/").map(String.init).filter { $0 != "." }
    }
}

/// What a rule's `discover` finds when run again during a clean.
private enum Recheck {
    /// The items' paths (by component) and simulator UDIDs.
    case found(paths: Set<[String]>, udids: Set<String>)
    /// `discover` threw.
    case failed
}

/// Runs each rule's `discover` at most once per clean. A failure is remembered too.
private struct RecheckCache {
    private var results: [String: Recheck] = [:]

    mutating func result(of rule: CleanupRule, in env: CoreEnvironment) async -> Recheck {
        if let cached = results[rule.id] { return cached }
        let result: Recheck
        do {
            let found = try await rule.discover(env)
            result = .found(
                paths: Set(found.map { Cleaner.lexicalComponents(of: $0.url.path) }),
                udids: Set(found.compactMap(\.simulatorUDID))
            )
        } catch {
            result = .failed
        }
        results[rule.id] = result
        return result
    }
}
