import AppKit
import Foundation
import Observation
import CleanoriCore

/// The state of the Disk Map screen (spec §6.2): what it is doing, the size tree of the last scan and where in
/// that tree the user is looking. The screen is view-only. This model never changes anything on disk: scanning is
/// `DiskMapScanner`'s job, going down into a folder uses the tree that is already in memory (nothing is scanned
/// again), and the only thing that leaves the screen is "Reveal in Finder".
@MainActor @Observable
final class DiskMapModel {
    enum Phase {
        /// Nothing scanned yet.
        case idle
        case scanning(ScanProgress)
        /// The map of the last scan.
        case results
    }

    /// The most bubbles the chart shows besides the grey "Other" one (spec §6.2, global constraints).
    nonisolated static let maxBubbles = 12

    private(set) var phase: Phase = .idle

    /// The size tree of the last scan; `nil` until a scan has finished. The shell (`AppModel`, sidebar, Overview) reads it.
    private(set) var root: DiskNode?

    /// The folders from the scanned root down to the one on screen, for the breadcrumb. Empty until a scan has
    /// finished, and never empty after.
    private(set) var path: [DiskNode] = []

    /// The folder on screen.
    var current: DiskNode? { path.last }

    /// How long the last scan took, in seconds.
    private(set) var scanSeconds: Double = 0

    /// The home folder of the last scan, so the root reads "Home" when it is the home folder.
    private(set) var homePath = ""

    /// Set when a scan could not run; the screen shows it as an alert.
    var problem: CleanProblem?

    /// Tasks 13-15 build their environment from the settings when a scan starts.
    let settings: AppSettings

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// What the running scan was asked for, to tell a call for the same thing (joined) from one for something else.
    @ObservationIgnored private var scanRequest: (path: String, restoringPlace: Bool)?
    /// True while a newer request is waiting for the running scan to stop, so that scan leaves the screen alone.
    @ObservationIgnored private var isReplacingScan = false
    /// True while the folder panel is open, so a second click does not open another.
    @ObservationIgnored private var isChoosingFolder = false

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - State

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    /// What the rows and bubbles of the folder on screen show.
    var entries: [DiskMapEntry] {
        current.map { DiskMapEntry.entries(of: $0) } ?? []
    }

    /// Whether the folder on screen has a group of small items (under 1 MB) with something in it, which the note
    /// under the list explains.
    var hasSmallItemsGroup: Bool {
        current?.children.contains(where: { $0.isOther && $0.bytes > 0 }) == true
    }

    // MARK: - Scanning

    /// Scans the home folder (the one the settings use; in a Debug build `CLEANORI_HOME` replaces it).
    func scan() async {
        await scan(root: settings.makeEnvironment().home)
    }

    /// Scans `root` and shows its top level. A scan that is already running for the same folder is joined rather
    /// than started twice; one that is running for another folder is stopped, and this one starts in its place, so a
    /// request is never answered with a map of something else. Cancelling the calling task cancels the scan.
    func scan(root: URL) async {
        await run(root: root, restoringPlace: false)
    }

    /// Scans the folder that was scanned last again, and goes back to the folder the user was in when it still exists.
    func rescan() async {
        guard let url = root?.url else {
            await scan()
            return
        }
        await run(root: url, restoringPlace: true)
    }

    private func run(root url: URL, restoringPlace: Bool) async {
        while let running = scanTask {
            if let request = scanRequest, request.path == url.path, request.restoringPlace == restoringPlace {
                await running.value
                return
            }
            // A scan for something else is running (a folder was chosen while it ran, say): the newest request wins.
            isReplacingScan = true
            running.cancel()
            await running.value
        }
        isReplacingScan = false
        // Set before the task starts, so a second call right behind this one joins instead of starting another scan.
        phase = .scanning(ScanProgress(itemsScanned: 0, currentPath: ""))
        scanRequest = (url.path, restoringPlace)
        let task = Task { await self.performScan(of: url, restoringPlace: restoringPlace) }
        scanTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Stops the running scan. The screen goes back to the earlier map, or to the start.
    func cancelScan() {
        scanTask?.cancel()
    }

    private func performScan(of url: URL, restoringPlace: Bool) async {
        defer {
            scanTask = nil
            scanRequest = nil
        }
        let home = settings.makeEnvironment().home

        // `DiskMapScanner` calls `progress` from its own thread. It only leaves the latest value in `relay`; the
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

        let clock = ContinuousClock()
        let started = clock.now
        do {
            let tree = try await DiskMapScanner().scan(root: url, progress: { relay.store($0) })
            let elapsed = clock.now - started
            let (seconds, attoseconds) = elapsed.components
            scanSeconds = Double(seconds) + Double(attoseconds) / 1e18
            homePath = home.path
            // The same folder as before: stay where the user was, as far down as the new tree still has it.
            let place = restoringPlace && tree.id == root?.id ? path.dropFirst().map(\.id) : []
            root = tree
            path = Self.path(in: tree, following: place)
            phase = .results
        } catch {
            // Cancelled (the usual way out), or the folder could not be inspected at all. Either way the screen
            // returns to where it was, unless another scan is about to start (the screen goes straight to that).
            if !isReplacingScan { phase = root == nil ? .idle : .results }
            if !(error is CancellationError) {
                problem = CleanProblem(title: "Couldn't scan the folder", message: error.localizedDescription)
            }
        }
    }

    private func show(_ progress: ScanProgress) {
        if case .scanning = phase {
            phase = .scanning(progress)
        }
    }

    /// `tree` and then the folders of `ids`, one below the other, stopping at the first that is not there.
    private static func path(in tree: DiskNode, following ids: [String]) -> [DiskNode] {
        var path = [tree]
        for id in ids {
            guard let next = path[path.count - 1].children.first(where: { $0.id == id && $0.isOpenable }) else { break }
            path.append(next)
        }
        return path
    }

    // MARK: - Moving around

    /// Goes down into `node`, one of the folder on screen's children. A file, an "Other" group, or something that
    /// is not shown here is ignored.
    func open(_ node: DiskNode) {
        guard let current, node.isOpenable, current.children.contains(where: { $0.id == node.id }) else { return }
        path.append(node)
    }

    /// Goes up one folder. Does nothing at the scanned root.
    func goUp() {
        guard path.count > 1 else { return }
        path.removeLast()
    }

    /// Goes back to the folder at `depth` of the breadcrumb (0 is the scanned root).
    func goTo(depth: Int) {
        guard path.indices.contains(depth), depth < path.count - 1 else { return }
        path.removeLast(path.count - 1 - depth)
    }

    // MARK: - Choosing a folder

    /// Asks for a folder with the system's open panel (folders only, one at a time) and scans it. The breadcrumb
    /// starts again at that folder. The panel does not block the window, so a scan can start while it is open; the
    /// chosen folder is then scanned in its place rather than dropped.
    func chooseFolder() {
        guard !isScanning, !isChoosingFolder else { return }
        isChoosingFolder = true
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Choose a folder to map"
        panel.prompt = "Scan"
        panel.directoryURL = root?.url
        Task {
            let response = await panel.begin()
            isChoosingFolder = false
            guard response == .OK, let url = panel.url else { return }
            await scan(root: url)
        }
    }

    // MARK: - Showing a node

    /// Shows the file or folder in Finder. It only looks.
    func reveal(_ node: DiskNode) {
        guard let url = node.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// The name the breadcrumb and banner use: "Home" for the home folder, otherwise the folder's own name.
    func displayName(of node: DiskNode) -> String {
        !homePath.isEmpty && node.id == homePath ? "Home" : node.name
    }

    /// "Scanned 1,204,311 items in 48 s".
    var scanSummary: String {
        guard let root else { return "" }
        let count = root.itemCount.formatted(.number.locale(Locale(identifier: "en_US")))
        let time = switch scanSeconds {
        case ..<1: "< 1"
        case ..<10: String(format: "%.1f", scanSeconds)
        default: String(format: "%.0f", scanSeconds)
        }
        return "Scanned \(count) \(root.itemCount == 1 ? "item" : "items") in \(time) s"
    }
}

// MARK: - What is shown

extension DiskNode {
    /// Whether the user can go down into it: a folder (even an empty one), not the "Other" group.
    var isOpenable: Bool { !isOther && (isDirectory || !children.isEmpty) }
}

/// One row of the list and one bubble of the chart: a child of the folder on screen, or the grey "Other" group
/// that sums up the rest.
struct DiskMapEntry: Identifiable {
    let id: String
    let name: String
    let bytes: Int64
    let isApproximate: Bool
    /// The file or folder behind it; `nil` for the "Other" group, which stands for several items.
    let node: DiskNode?

    var isOther: Bool { node == nil }
    var isOpenable: Bool { node?.isOpenable ?? false }

    /// `≈` in front when something inside could not be read, so the figure may be low (ruling R19).
    var sizeText: String { bytes.sizeText(approximate: isApproximate) }

    /// What VoiceOver reads for the row and the bubble.
    var spokenLabel: String { "\(name), \(sizeText)" }

    /// The entries for `folder`: its twelve largest children, then, when there is more, one "Other" entry that sums
    /// all the rest, including the folder's own "N other items" group (everything under 1 MB).
    static func entries(of folder: DiskNode, maxShown: Int = DiskMapModel.maxBubbles) -> [DiskMapEntry] {
        // The scanner sorts the children largest first and puts its own "other" group last.
        let real = folder.children.filter { !$0.isOther }
        var result = real.prefix(maxShown).map {
            DiskMapEntry(id: $0.id, name: $0.name, bytes: $0.bytes, isApproximate: $0.isApproximate, node: $0)
        }
        let rest = Array(real.dropFirst(maxShown)) + folder.children.filter(\.isOther)
        let restBytes = rest.reduce(0) { $0 + $1.bytes }
        // A group with nothing in it (an unreadable folder folds into it with 0 bytes) is left out: it has no bubble
        // and a row of "0 bytes" says nothing. The folder's own `≈` still says something could not be read.
        if restBytes > 0 {
            result.append(DiskMapEntry(
                id: folder.id + "|rest",
                name: "Other",
                bytes: restBytes,
                isApproximate: rest.contains(where: \.isApproximate),
                node: nil
            ))
        }
        return result
    }
}
