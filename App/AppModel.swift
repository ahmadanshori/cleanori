import Foundation
import Observation
import CleanoriCore

/// What the sidebar and the Overview show for a module's last scan.
struct ScanSummary: Equatable {
    var bytes: Int64
    /// What was counted, for the Overview card ("12 items", "7 files").
    var detail: String
}

/// The state every screen shares: the settings, which screen is open, the disk capacity and one model per module.
@MainActor @Observable
final class AppModel {
    let settings: AppSettings
    var selection: Module = .overview

    /// The startup disk; `nil` when it could not be read.
    private(set) var capacity: DiskCapacity?
    private(set) var volumeName = "Startup disk"
    private(set) var isScanningAll = false

    /// `false` when macOS refused the Full Disk Access probe (spec §6.3). Only a permission error counts, so a Mac
    /// where the probe folder is missing never shows the banner (ruling R32).
    private(set) var isFullDiskAccessGranted = true
    /// The banner was dismissed in this session. It is not remembered: it comes back at the next launch while access
    /// is still missing, which is the only place the owner is reminded that sizes are approximate.
    private(set) var isFullDiskAccessBannerDismissed = false

    let junk: DeveloperJunkModel
    let largeFiles: LargeFilesModel
    let diskMap: DiskMapModel

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
        junk = DeveloperJunkModel(settings: settings)
        largeFiles = LargeFilesModel(settings: settings)
        diskMap = DiskMapModel(settings: settings)
        refreshFullDiskAccess()
    }

    /// Whether the Overview shows the Full Disk Access banner.
    var showsFullDiskAccessBanner: Bool {
        !isFullDiskAccessGranted && !isFullDiskAccessBannerDismissed
    }

    /// Probes Full Disk Access again. Called at launch and whenever the app becomes active, so granting it in
    /// System Settings and switching back takes the banner away without a relaunch (when macOS lets the running
    /// app see the change).
    func refreshFullDiskAccess() {
        isFullDiskAccessGranted = FullDiskAccess.isGranted(home: settings.home)
    }

    func dismissFullDiskAccessBanner() {
        isFullDiskAccessBannerDismissed = true
    }

    /// Reads the free and total space of the startup disk again.
    func refreshCapacity() {
        let root = URL(fileURLWithPath: "/")
        capacity = try? DiskCapacity.current(for: root)
        if let name = (try? root.resourceValues(forKeys: [.volumeNameKey]))?.volumeName {
            volumeName = name
        }
    }

    /// Runs Developer Junk and Large Files together. Does nothing while a Scan All is already running.
    func scanAll() async {
        guard !isScanningAll else { return }
        isScanningAll = true
        defer { isScanningAll = false }
        async let junkScan: Void = junk.scan()
        async let largeFilesScan: Void = largeFiles.scan()
        _ = await (junkScan, largeFilesScan)
        refreshCapacity()
    }

    /// The last scan of a module, or `nil` when it has none yet (and always for Overview).
    func lastScan(of module: Module) -> ScanSummary? {
        switch module {
        case .overview:
            return nil
        case .developerJunk:
            guard let result = junk.result else { return nil }
            // Only what can be cleaned now counts; an item held back by a running app frees nothing (ruling R25).
            let cleanable = result.cleanable
            return ScanSummary(bytes: cleanable.bytes, detail: cleanable.count == 1 ? "1 item" : "\(cleanable.count) items")
        case .largeFiles:
            guard let files = largeFiles.files else { return nil }
            // Only the files the user can actually move to the Trash count; a locked one frees nothing.
            let cleanable = files.filter { $0.lock == nil }
            return ScanSummary(
                bytes: cleanable.reduce(0) { $0 + $1.bytes },
                detail: cleanable.count == 1 ? "1 file" : "\(cleanable.count) files"
            )
        case .diskMap:
            guard let root = diskMap.root else { return nil }
            return ScanSummary(bytes: root.bytes, detail: diskMap.displayName(of: root))
        }
    }
}
