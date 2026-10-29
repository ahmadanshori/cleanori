import AppKit
import Foundation
import Observation
import CleanoriCore

/// The state of the Large Files screen (spec §6.2): what it is doing, the files the last scan found, the filters
/// and which files the user ticked. It never touches the disk itself: finding files is `LargeFileFinder`'s job
/// and every move to the Trash goes through `Cleaner`.
///
/// Two kinds of filter:
/// - "Larger than" and "Not opened in" change what the finder looks for, so changing one scans again.
/// - The kind chip only narrows the list that is shown.
///
/// Whatever a filter hides is never acted on: "Selected" and Move to Trash only ever count the ticked files that
/// are showing. And what the confirmation sheet showed is what is acted on (ruling R28): the sheet captures the
/// IDs, and `moveSelectedToTrash(ids:)` checks each one again against the list as it is then.
@MainActor @Observable
final class LargeFilesModel {
    enum Phase {
        /// Nothing scanned yet.
        case idle
        case scanning(ScanProgress)
        /// The table of the last scan.
        case results
        /// A move to the Trash is running.
        case cleaning(done: Int, total: Int)
        /// The table again, with what the last move did above it.
        case report(CleanReport)
    }

    /// The rule ID Large Files gives its items. It is not a catalog rule; `Cleaner` knows it by name.
    private static let ruleID = "largeFiles"

    private(set) var phase: Phase = .idle

    /// The size of each file being moved to the Trash, for the bubbles that pop as they are done.
    private(set) var cleaningSizes: [Int64] = []

    /// What the last scan found (every kind, before the chip), oldest-opened first; `nil` until a scan has
    /// finished. The shell (`AppModel`, sidebar, Overview) reads it.
    private(set) var files: [LargeFile]?

    /// The kind the list is narrowed to; `nil` shows every kind.
    var kindFilter: FileKind?

    /// What the finder is asked for.
    struct Filters: Equatable {
        var minBytes: Int64
        var notOpenedInDays: Int?

        /// Whether the finder would leave `file` out under these filters, going by what is known of it. The same
        /// rules as `LargeFileFinder`: too small, or opened within the last `notOpenedInDays` days (a file without a
        /// date counts as old).
        func hides(_ file: LargeFile, now: Date) -> Bool {
            if file.bytes < minBytes { return true }
            if let days = notOpenedInDays, let opened = file.lastOpened,
               opened >= now.addingTimeInterval(-Double(days) * 86_400) { return true }
            return false
        }
    }

    /// The smallest file to list. It is the setting `AppSettings.largeFilesMinBytes`, so a choice here is kept.
    /// Changing it, here or in Settings, scans again when the screen has results and is not busy. While it is busy
    /// the list stays as it is, and the next scan uses the new value; `listedMinBytes` says what the list was found with.
    var minBytes: Int64 {
        get { settings.largeFilesMinBytes }
        set {
            guard newValue != settings.largeFilesMinBytes else { return }
            noteChangeMadeHere()
            settings.largeFilesMinBytes = newValue
            rescanIfFiltersDiffer()
        }
    }

    /// Only files last opened more than this many days ago; `nil` is any time. Changing it scans again.
    var notOpenedInDays: Int? {
        didSet {
            guard notOpenedInDays != oldValue else { return }
            noteChangeMadeHere()
            rescanIfFiltersDiffer()
        }
    }

    /// The filters the list on screen was found with; `nil` until a scan has finished. The menus show these, so
    /// they always agree with the list.
    private(set) var applied: Filters?
    var listedMinBytes: Int64 { applied?.minBytes ?? minBytes }
    var listedNotOpenedInDays: Int? { applied?.notOpenedInDays ?? notOpenedInDays }

    /// The IDs (paths) of the files the user ticked. Nothing is ticked at first, and a locked file never is.
    /// It can hold the ID of a file that a filter hides right now (the chip, or a threshold or age that leaves it
    /// out of the scan); that file is not counted and not touched. A file that is neither listed nor hidden by a
    /// filter (it shrank, was changed or is gone) is not kept.
    private(set) var selected: Set<String> = []

    /// The home folder of the last scan, to show paths as `~/Downloads`.
    private(set) var homePath = ""

    /// Set when a scan or a move to the Trash could not run; the screen shows it as an alert.
    var problem: CleanProblem?
    /// What the report banner needs besides the `CleanReport` itself.
    private(set) var reportContext = CleanReportContext()
    /// The report banner's title: how many files and how much went to the Trash.
    private(set) var reportHeadline = ""

    let settings: AppSettings

    /// The environment of the last scan. The move to the Trash uses the same one, so what `Cleaner` re-checks is
    /// what the user was shown, even if the settings changed in between.
    @ObservationIgnored private var environment: CoreEnvironment?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// What each ticked file looked like when it was last listed, to tell whether a filter hides it.
    @ObservationIgnored private var lastSeen: [String: LargeFile] = [:]
    /// The filters to go back to if the scan that a change made on this screen starts is cancelled.
    @ObservationIgnored private var revertTo: Filters?
    /// True while a cancelled scan puts the filters back, which must not start another scan.
    @ObservationIgnored private var isRestoringFilters = false

    init(settings: AppSettings) {
        self.settings = settings
        watchSettings()
    }

    /// A change of "Larger than" made in Settings: scan again, if the screen is idle.
    private func watchSettings() {
        withObservationTracking {
            _ = settings.largeFilesMinBytes
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.watchSettings()
                self?.rescanIfFiltersDiffer()
            }
        }
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

    /// The files showing: the scan's files narrowed to the chip. The table lists exactly these.
    var visibleFiles: [LargeFile] {
        guard let files else { return [] }
        guard let kindFilter else { return files }
        return files.filter { $0.kind == kindFilter }
    }

    /// What the banner counts, and the sidebar and Overview with it: the files that can be moved to the Trash.
    /// A locked file frees nothing (ruling R20).
    var movable: [LargeFile] { (files ?? []).filter { $0.lock == nil } }
    /// What a lock holds back.
    var lockedCount: Int { (files ?? []).count { $0.lock != nil } }
    var lockedBytes: Int64 { (files ?? []).filter { $0.lock != nil }.reduce(0) { $0 + $1.bytes } }

    /// The ticked files that are showing and not locked: the only ones "Selected" counts and Move to Trash moves.
    var selectedVisible: [LargeFile] {
        visibleFiles.filter { $0.lock == nil && selected.contains($0.id) }
    }

    var selectedBytes: Int64 { selectedVisible.reduce(0) { $0 + $1.bytes } }

    /// How many ticked files a filter is hiding right now.
    var hiddenSelectedCount: Int { max(0, selected.count - selectedVisible.count) }

    /// Move to Trash is available when a table is showing and a showing file is ticked. Not while scanning or moving.
    var canMoveToTrash: Bool {
        switch phase {
        case .results, .report: !selectedVisible.isEmpty
        case .idle, .scanning, .cleaning: false
        }
    }

    // MARK: - Scanning

    /// Looks for large files with the current filters. A scan that is already running is joined rather than
    /// started twice, and nothing starts while files are being moved. Cancelling the calling task cancels the scan.
    func scan() async {
        if let scanTask {
            await scanTask.value
            return
        }
        guard !isCleaning else { return }
        // Set before the task starts: between here and the task's first line nothing else may begin a move.
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
        let requested = Filters(minBytes: minBytes, notOpenedInDays: notOpenedInDays)
        let revert = revertTo
        revertTo = nil

        // `LargeFileFinder` calls `progress` from its own thread. It only leaves the latest value in `relay`; the
        // main actor picks it up a few times a second.
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
            let found = try await LargeFileFinder(env: env).find(
                minBytes: requested.minBytes,
                notOpenedInDays: requested.notOpenedInDays,
                progress: { relay.store($0) }
            )
            environment = env
            homePath = env.home.path
            files = found
            applied = requested
            pruneSelection()
            phase = .results
        } catch {
            // Cancelled (the usual way out), or the home folder could not be walked at all. Either way the screen
            // returns to where it was.
            putFiltersBack(revert, requested: requested)
            phase = files == nil ? .idle : .results
            if !(error is CancellationError) {
                problem = CleanProblem(title: "Couldn't scan for large files", message: error.localizedDescription)
            }
        }
    }

    private func show(_ progress: ScanProgress) {
        if case .scanning = phase {
            phase = .scanning(progress)
        }
    }

    private var filtersDiffer: Bool {
        guard let applied else { return false }
        return applied != Filters(minBytes: minBytes, notOpenedInDays: notOpenedInDays)
    }

    /// The filters no longer match the list: find again. Only when there is a list, which the first scan (started
    /// by the user) makes, and the screen is neither scanning nor moving files; when it is busy the list stays, and
    /// the next scan picks the new filters up.
    private func rescanIfFiltersDiffer() {
        guard !isRestoringFilters, files != nil, filtersDiffer, !isScanning, !isCleaning else { return }
        Task { [weak self] in
            // Checked again: the change may already have been dealt with by the time this runs.
            guard let self, self.filtersDiffer, !self.isScanning, !self.isCleaning else { return }
            await self.scan()
        }
    }

    /// A menu on this screen is changing a filter: if that scan is cancelled, the filters go back.
    private func noteChangeMadeHere() {
        guard !isRestoringFilters, revertTo == nil else { return }
        revertTo = applied
    }

    /// After a scan caused by a change on this screen is cancelled, the old list is back, so the filters go back to
    /// the ones it was found with. A filter that was changed by someone else meanwhile (Settings) is left alone.
    private func putFiltersBack(_ revert: Filters?, requested: Filters) {
        guard files != nil, let revert else { return }
        isRestoringFilters = true
        defer { isRestoringFilters = false }
        if minBytes == requested.minBytes { minBytes = revert.minBytes }
        if notOpenedInDays == requested.notOpenedInDays { notOpenedInDays = revert.notOpenedInDays }
    }

    // MARK: - Selection

    /// Ticks or unticks a file. A locked file, or one that is not showing, cannot be ticked.
    func toggle(_ file: LargeFile) {
        guard file.lock == nil, visibleFiles.contains(where: { $0.id == file.id }) else { return }
        if selected.insert(file.id).inserted {
            lastSeen[file.id] = file
        } else {
            selected.remove(file.id)
            lastSeen[file.id] = nil
        }
    }

    func isSelected(_ file: LargeFile) -> Bool {
        file.lock == nil && selected.contains(file.id)
    }

    /// Keeps the ticks of files that are listed and unlocked, and of files that are not listed because a filter
    /// leaves them out (and are still on disk). Anything else is locked, gone, or no longer a match (it shrank
    /// below the threshold, say), and its tick goes, so "hidden by filters" counts only what a filter hides.
    private func pruneSelection() {
        let listed = Dictionary((files ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let now = environment?.now() ?? Date()
        var kept = Set<String>()
        for id in selected {
            if let file = listed[id] {
                if file.lock == nil {
                    kept.insert(id)
                    lastSeen[id] = file
                }
            } else if let seen = lastSeen[id], applied?.hides(seen, now: now) == true, Self.exists(atPath: id) {
                kept.insert(id)
            }
        }
        selected = kept
        lastSeen = lastSeen.filter { kept.contains($0.key) }
    }

    /// Whether something (even a broken link) is at `path`. Looks only.
    private nonisolated static func exists(atPath path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    // MARK: - Finder

    /// Shows a file in Finder. It only looks, so it works for a locked file too.
    func reveal(_ file: LargeFile) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    /// Shows the ticked files that are showing in Finder.
    func revealSelected() {
        let urls = selectedVisible.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: - Moving to the Trash

    /// What the confirmation sheet shows, and what is acted on if the user confirms (ruling R28): the IDs of the
    /// ticked files that are showing when the sheet opens, with their total size.
    struct TrashRequest: Identifiable {
        let id = UUID()
        let ids: [String]
        let bytes: Int64

        var count: Int { ids.count }
    }

    /// The request for the sheet, from the ticked files that are showing right now; `nil` when there are none.
    func makeTrashRequest() -> TrashRequest? {
        guard canMoveToTrash else { return nil }
        let chosen = selectedVisible
        return TrashRequest(ids: chosen.map(\.id), bytes: chosen.reduce(0) { $0 + $1.bytes })
    }

    /// Moves the files of `ids`, the ones the confirmation sheet showed, to the Trash with `Cleaner`, then takes
    /// those that left the disk out of the list.
    ///
    /// The list is not worked out again from the ticks: a scan that finished while the sheet was open could have
    /// changed which files are ticked and showing, under the same "3 files". Each ID is checked against the list as
    /// it is now. One that is no longer listed, or is locked now, is left alone and the report says so.
    func moveSelectedToTrash(ids: [String]) async {
        // A scan that started while the sheet was open (from Settings, say) finishes first, so the check below is
        // against the list as it will be shown.
        if let scanTask { await scanTask.value }
        let previous = phase
        switch previous {
        case .results, .report: break
        case .idle, .scanning, .cleaning: return
        }
        guard let env = environment, !ids.isEmpty else { return }

        let listed = Dictionary((files ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var chosen: [LargeFile] = []
        var changed: [String] = []
        var seen = Set<String>()
        for id in ids where seen.insert(id).inserted {
            // Never a locked file (the finder already locks what `SafetyGuard` would refuse).
            if let file = listed[id], file.lock == nil { chosen.append(file) } else { changed.append(id) }
        }

        var report = CleanReport()
        var names = Dictionary(chosen.map { (Self.itemID(of: $0.id), displayPath(of: $0)) }, uniquingKeysWith: { first, _ in first })
        if !chosen.isEmpty {
            let items = chosen.map { file in
                ScanItem(
                    ruleID: Self.ruleID,
                    url: file.url,
                    displayName: file.url.lastPathComponent,
                    size: SizeResult(bytes: file.bytes, fileCount: 1, isApproximate: false),
                    method: .trash
                )
            }

            let total = items.count
            cleaningSizes = chosen.map(\.bytes)
            phase = .cleaning(done: 0, total: total)
            let counter = EventCounter()
            let cleaner = Cleaner(env: env, log: settings.makeCleanLog())
            do {
                report = try await cleaner.clean(items) { event in
                    if case .started = event { return }
                    let done = counter.next()
                    Task { @MainActor [weak self] in self?.noteMoved(done, of: total) }
                }
            } catch CleanerError.alreadyRunning {
                // Move to Trash is disabled while files are being moved, so this is not expected; nothing was done.
                phase = previous
                return
            } catch CleanerError.logUnavailable(let message) {
                // Nothing was touched (ruling R13).
                phase = previous
                problem = CleanProblem(title: "Can't write the cleanup log", message: "\(message)\n\nNothing was moved.")
                return
            } catch {
                // `Cleaner` throws nothing else today. Do not blame the log for an error that is not about it.
                phase = previous
                problem = CleanProblem(title: "Couldn't move to the Trash", message: error.localizedDescription)
                return
            }
        }

        let moved = chosen.count { report.skipped[Self.itemID(of: $0.id)] == nil && report.failed[Self.itemID(of: $0.id)] == nil }
        // What changed since the sheet was shown is not hidden in the counts: each one is listed as skipped, and
        // the banner says how many.
        for id in changed {
            report.skipped[Self.itemID(of: id)] = "Changed since you confirmed"
            names[Self.itemID(of: id)] = tildePath(id)
        }
        reportContext = CleanReportContext(
            names: names,
            note: changed.isEmpty ? nil : (changed.count == 1 ? "1 file changed and was skipped" : "\(changed.count) files changed and were skipped")
        )
        reportHeadline = moved == 0
            ? "Nothing was moved to Trash"
            : "\(moved == 1 ? "1 file" : "\(moved) files") · \(report.trashedBytes.fileSizeText) moved to Trash"

        removeFromList(chosen)
        phase = .report(report)
    }

    /// The ID `Cleaner` reports an item under (`ScanItem.id`).
    private static func itemID(of path: String) -> String { "\(ruleID)|\(path)" }

    private func noteMoved(_ done: Int, of total: Int) {
        if case .cleaning(let shown, _) = phase, done > shown {
            phase = .cleaning(done: done, total: total)
        }
    }

    func dismissReport() {
        if case .report = phase { phase = .results }
    }

    /// Takes the files that `files` listed and that are no longer on disk out of the list, and their ticks with
    /// them. A file that was skipped or failed is still there, so it stays listed and ticked, and the report says
    /// why. This is cheaper than finding everything again; Rescan does that.
    private func removeFromList(_ attempted: [LargeFile]) {
        let tried = Set(attempted.map(\.id))
        files = files?.filter { !tried.contains($0.id) || Self.exists(atPath: $0.id) }
        pruneSelection()
    }

    // MARK: - Showing a file

    /// `path` with the home folder written as `~`.
    func tildePath(_ path: String) -> String {
        if path == homePath { return "~" }
        if !homePath.isEmpty, path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }

    /// "~/Downloads": the folder a file is in.
    func folderText(of file: LargeFile) -> String {
        tildePath(file.url.deletingLastPathComponent().path)
    }

    /// "~/Downloads/Installer.dmg": the whole path, for the lists in the report where two files can share a name.
    func displayPath(of file: LargeFile) -> String {
        tildePath(file.url.path)
    }

    /// When a file was last opened, in English whatever the system language: `Today`, `Yesterday`, `Oct 10`,
    /// `Oct 10, 2024` for another year, and `—` when it is not known.
    nonisolated static func lastOpenedText(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "—" }
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let style = Date.FormatStyle(locale: Locale(identifier: "en_US"), calendar: calendar, timeZone: calendar.timeZone)
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(sameYear ? style.month(.abbreviated).day() : style.month(.abbreviated).day().year())
    }
}
