import AppKit
import SwiftUI

@main
struct CleanoriApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Cleanori", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 540)
        }
        .defaultSize(width: 980, height: 640)
        .windowStyle(.hiddenTitleBar)

        // Cleanori > Settings… (⌘,)
        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// The sidebar and the screen it has selected.
private struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            detail
        }
        .task {
            model.refreshCapacity()
            #if DEBUG
            // A manual check without clicking. It only ever scans, never cleans or moves anything:
            // CLEANORI_AUTOSCAN=1 opens Developer Junk and scans, CLEANORI_AUTOSCAN=largefiles does the same for Large Files
            // and CLEANORI_AUTOSCAN=diskmap for Disk Map (which scans CLEANORI_HOME, or the real home when that is unset).
            switch ProcessInfo.processInfo.environment["CLEANORI_AUTOSCAN"]?.lowercased() {
            case "1":
                model.selection = .developerJunk
                await model.junk.scan()
            case "largefiles":
                model.selection = .largeFiles
                await model.largeFiles.scan()
            case "diskmap":
                model.selection = .diskMap
                await model.diskMap.scan()
            default:
                break
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshCapacity()
            model.refreshFullDiskAccess()
        }
    }

    @ViewBuilder private var detail: some View {
        let module = model.selection
        switch module {
        case .overview: OverviewView()
        case .developerJunk: DeveloperJunkView()
        case .largeFiles: LargeFilesView()
        case .diskMap: DiskMapView()
        }
    }
}
