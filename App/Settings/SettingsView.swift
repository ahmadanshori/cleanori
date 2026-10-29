import AppKit
import CleanoriCore
import SwiftUI

/// The Settings window (spec §6.4): the inactive threshold, the folders searched for projects and the smallest file
/// Large Files lists. Each control writes straight to `AppSettings`, which saves it to `UserDefaults`.
///
/// Large Files scans again by itself when its minimum changes (`LargeFilesModel` watches the setting). The other two
/// are read when a Developer Junk scan starts, so they apply to the next one.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// The project folders ticked in the list, for Remove.
    @State private var selectedFolders: Set<URL> = []
    @State private var isChoosingFolders = false
    /// Why the folders chosen in the last Add… were not added, one line each.
    @State private var refusals: [String] = []

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                LabeledContent("Inactive project threshold") {
                    HStack(spacing: 6) {
                        Text("\(settings.inactiveAfterDays) days")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Stepper("Inactive project threshold", value: $settings.inactiveAfterDays, in: AppSettings.inactiveAfterDaysRange)
                            .labelsHidden()
                            .accessibilityValue("\(settings.inactiveAfterDays) days")
                    }
                }
            } footer: {
                note("A project not worked on for this many days is inactive, and its node_modules are ticked by default. It applies to the next Developer Junk scan.")
            }

            Section {
                folderList(settings.projectRoots)
                HStack(spacing: 8) {
                    Button("Add…") { addFolders() }
                        .disabled(isChoosingFolders)
                    Button("Remove") { removeSelectedFolders() }
                        .disabled(selectedFolders.isEmpty)
                    Spacer()
                }
                if !refusals.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(refusals, id: \.self) { line in
                            Label(line, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.lockText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Project folders")
            } footer: {
                note("Developer Junk looks for projects, and their node_modules and builds, in these folders. Choose the folders that hold your projects: your whole home folder, ~/Library and folders outside your home folder are refused. It applies to the next scan.")
            }

            Section {
                Picker("Large Files minimum size", selection: $settings.largeFilesMinBytes) {
                    ForEach(sizeChoices(including: settings.largeFilesMinBytes), id: \.self) {
                        Text($0.fileSizeText).tag($0)
                    }
                }
            } footer: {
                note("Large Files lists files of at least this size. Changing it scans again.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The small grey text under a section.
    private func note(_ text: String) -> some View {
        Text(text)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Project folders

    @ViewBuilder private func folderList(_ folders: [URL]) -> some View {
        if folders.isEmpty {
            Text("No project folders. Developer Junk will find no projects.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            List(folders, id: \.self, selection: $selectedFolders) { folder in
                Text((folder.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(folder.path)
            }
            .listStyle(.bordered)
            .frame(height: max(60, min(CGFloat(folders.count) * 22 + 4, 132)))
            .accessibilityLabel("Project folders")
        }
    }

    /// Asks for folders and adds the ones that are not in the list yet.
    private func addFolders() {
        guard !isChoosingFolders else { return }
        isChoosingFolders = true
        refusals = []
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.message = "Choose the folders that hold your projects"
        panel.prompt = "Add"
        panel.directoryURL = model.settings.home
        // A sheet on the Settings window, so it stays with it and cannot be lost behind other windows.
        let window = NSApp.keyWindow
        Task {
            let response = if let window { await panel.beginSheetModal(for: window) } else { await panel.begin() }
            isChoosingFolders = false
            guard response == .OK else { return }
            refusals = model.settings.addProjectRoots(panel.urls).map { folder, problem in
                "Not added: \((folder.path as NSString).abbreviatingWithTildeInPath). \(problem.message)"
            }
        }
    }

    private func removeSelectedFolders() {
        model.settings.removeProjectRoots(selectedFolders)
        selectedFolders = []
        refusals = []
    }

    // MARK: - Large Files

    /// The four sizes, plus the one saved when it is none of them, so the picker always shows what is in effect.
    private func sizeChoices(including saved: Int64) -> [Int64] {
        let choices = AppSettings.largeFilesMinBytesChoices
        return choices.contains(saved) ? choices : (choices + [saved]).sorted()
    }
}
