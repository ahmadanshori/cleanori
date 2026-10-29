import CleanoriCore
import SwiftUI

/// The Large Files screen (spec §6.2): the start page, the scan in progress, then the filter bar, the table and
/// the bottom bar. Files only ever leave through the confirmation sheet and
/// `LargeFilesModel.moveSelectedToTrash(ids:)`, with the IDs the sheet showed (ruling R28).
struct LargeFilesView: View {
    @Environment(AppModel.self) private var app
    /// What the sheet shows and what is moved if it is confirmed, fixed when the sheet opens. It is not read from
    /// the model again: a scan that finishes while the sheet is open must not change what the user agreed to.
    @State private var request: LargeFilesModel.TrashRequest?

    private var model: LargeFilesModel { app.largeFiles }

    var body: some View {
        content
            .sheet(item: $request) { request in
                ConfirmCleanSheet(
                    title: request.count == 1 ? "Move 1 file to Trash?" : "Move \(request.count) files to Trash?",
                    lines: [
                        ConfirmCleanSheet.Line(symbol: "trash", text: "Moved to Trash", size: request.bytes.fileSizeText),
                    ],
                    confirmTitle: "Move to Trash",
                    confirmGradient: Theme.largeFilesPrimaryGradient,
                    onCancel: { self.request = nil },
                    onConfirm: {
                        self.request = nil
                        Task { await model.moveSelectedToTrash(ids: request.ids) }
                    }
                )
            }
            .alert(model.problem?.title ?? "", isPresented: problemShown) {
                Button("OK") {}
            } message: {
                Text(model.problem?.message ?? "")
            }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            StartPage(
                module: .largeFiles,
                gradient: Theme.largeFilesPrimaryGradient,
                message: "Finds big files in your home folder, oldest-opened first, outside Library and node_modules. Nothing is selected until you choose it, and what you choose goes to the Trash."
            ) { Task { await model.scan() } }
        case .scanning(let progress):
            ScanningPage(module: .largeFiles, progress: progress) { model.cancelScan() }
        case .results, .cleaning, .report:
            ResultsPage(model: model) { request = model.makeTrashRequest() }
        }
    }

    private var problemShown: Binding<Bool> {
        Binding(
            get: { model.problem != nil },
            set: { if !$0 { model.problem = nil } }
        )
    }
}

// MARK: - Results

private struct ResultsPage: View {
    let model: LargeFilesModel
    let confirm: () -> Void
    /// Goes up each time a move to the Trash ends with a report, to play the sparkle burst once.
    @State private var burst = 0

    /// "3 large files · 11.4 GB": what can be moved to the Trash now. What a lock holds back is named in the
    /// subtitle (ruling R20). When only locked files remain, the title says so rather than "No large files" above a
    /// table that still lists them.
    private var title: String {
        let movable = model.movable
        guard !movable.isEmpty else {
            let locked = model.lockedCount
            return locked == 0 ? "No large files" : "Nothing to move · \(locked) locked"
        }
        let size = movable.reduce(Int64(0)) { $0 + $1.bytes }.fileSizeText
        return "\(movable.count == 1 ? "1 large file" : "\(movable.count) large files") · \(size)"
    }

    private var subtitle: String {
        let base = "Outside Library and node_modules"
        guard model.lockedBytes > 0 else { return base }
        return "\(base) · \(model.lockedBytes.fileSizeText) locked"
    }

    var body: some View {
        VStack(spacing: 10) {
            ModuleBanner(module: .largeFiles, title: title, subtitle: subtitle) {
                Button("Rescan") { Task { await model.scan() } }
                    .buttonStyle(BannerButtonStyle())
                    .disabled(model.isCleaning)
            }

            FilterBar(model: model)

            if case .report(let report) = model.phase {
                CleanReportBanner(report: report, context: model.reportContext, headline: model.reportHeadline) {
                    model.dismissReport()
                }
            }

            if case .cleaning(let done, let total) = model.phase {
                CleaningPage(
                    module: .largeFiles,
                    sizes: model.cleaningSizes,
                    done: done,
                    total: total,
                    status: "Moving \(done) of \(total) to Trash…",
                    detail: "\(model.cleaningSizes.reduce(0, +).fileSizeText) selected"
                )
            } else {
                FileTable(model: model)
                    .overlay {
                        if burst > 0 { SparkleBurst(color: Theme.largeFilesAccent).id(burst) }
                    }
            }

            SelectionBar(model: model, confirm: confirm)
        }
        .onChange(of: model.isCleaning) { wasCleaning, isCleaning in
            if wasCleaning, !isCleaning, case .report = model.phase { burst += 1 }
        }
        // The window has no title bar, so the screen already starts 38 pt down, below the traffic lights.
        .padding(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }
}

// MARK: - Filters

/// The kind chips (they only narrow the list) and the two menus (they search again).
private struct FilterBar: View {
    let model: LargeFilesModel

    private static let sizes = AppSettings.largeFilesMinBytesChoices
    private static let days: [Int?] = [nil, 30, 90, 180, 365]

    var body: some View {
        // Wraps onto a second line when the window is narrow, as the mockup's chip row does.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                chips
                Spacer(minLength: 12)
                menus
            }
            VStack(alignment: .leading, spacing: 8) {
                chips
                menus
            }
        }
        .disabled(model.isCleaning)
    }

    private var chips: some View {
        HStack(spacing: 6) {
            KindChip(title: "All", isOn: model.kindFilter == nil) { model.kindFilter = nil }
            ForEach(FileKind.allCases, id: \.self) { kind in
                KindChip(title: kind.rawValue, isOn: model.kindFilter == kind) { model.kindFilter = kind }
            }
        }
    }

    private var menus: some View {
        HStack(spacing: 14) {
            FilterMenu(title: "Larger than", value: model.listedMinBytes.fileSizeText) {
                Picker("Larger than", selection: minBytes) {
                    ForEach(sizeChoices, id: \.self) { Text($0.fileSizeText).tag($0) }
                }
            }
            FilterMenu(title: "Not opened in", value: Self.dayText(model.listedNotOpenedInDays)) {
                Picker("Not opened in", selection: days) {
                    ForEach(Self.days, id: \.self) { Text(Self.dayText($0)).tag($0) }
                }
            }
        }
    }

    /// The four sizes, plus the one the list was found with when it is none of them (set in Settings).
    private var sizeChoices: [Int64] {
        Self.sizes.contains(model.listedMinBytes) ? Self.sizes : (Self.sizes + [model.listedMinBytes]).sorted()
    }

    // The menus show what the list on screen was found with and write what the user picks; the model scans again.
    private var minBytes: Binding<Int64> {
        Binding(get: { model.listedMinBytes }, set: { model.minBytes = $0 })
    }

    private var days: Binding<Int?> {
        Binding(get: { model.listedNotOpenedInDays }, set: { model.notOpenedInDays = $0 })
    }

    private static func dayText(_ days: Int?) -> String {
        days.map { "\($0) days" } ?? "Any time"
    }
}

/// A pill that narrows the list to one kind of file.
private struct KindChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(isOn ? Color.white : Self.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(isOn ? Theme.largeFilesAccent : Self.fill, in: Capsule())
                .overlay(Capsule().strokeBorder(isOn ? Theme.largeFilesAccent : Self.border))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private static let fill = Color(light: Color(hex: 0x000000, opacity: 0.04), dark: Color(hex: 0xFFFFFF, opacity: 0.07))
    private static let border = Color(light: Color(hex: 0x000000, opacity: 0.14), dark: Color(hex: 0xFFFFFF, opacity: 0.12))
    private static let text = Color(light: Color(hex: 0x3A3A3C), dark: Color(hex: 0xCFCFD3))
}

/// "Larger than [100 MB ▾]": a caption and a menu button that shows the current choice.
private struct FilterMenu<Choices: View>: View {
    let title: String
    let value: String
    @ViewBuilder let choices: () -> Choices

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Menu {
                choices().pickerStyle(.inline).labelsHidden()
            } label: {
                HStack(spacing: 4) {
                    Text(value)
                        .font(.system(size: 11.5, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 1.5)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.filterMenuBorder))
            }
            // A plain button menu draws the label as given; the pop-up style would move the chevron and drop the outline.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(title)
            .accessibilityValue(value)
        }
    }
}

private extension Color {
    /// The outline of a filter menu button.
    static let filterMenuBorder = Color(light: Color(hex: 0x000000, opacity: 0.18), dark: Color(hex: 0xFFFFFF, opacity: 0.2))
}

// MARK: - Table

/// The fixed-column table (spec §6.1): checkbox 18 · Name (name and folder) · Kind 140 · Last opened 84 · Size 66,
/// rows 34 pt, as in the approved mockup. Kind is wide enough for the lock tags ("Managed in Developer Junk").
private struct FileTable: View {
    let model: LargeFilesModel

    private enum Layout {
        static let checkbox: CGFloat = 18
        static let kind: CGFloat = 140
        static let lastOpened: CGFloat = 84
        static let size: CGFloat = 66
        static let gap: CGFloat = 8
        static let inset: CGFloat = 12
        static let row: CGFloat = 34
        static let header: CGFloat = 24
    }

    private static let rule = Color(light: Color(hex: 0x000000, opacity: 0.07), dark: Color(hex: 0xFFFFFF, opacity: 0.06))

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            ScrollView {
                let visible = model.visibleFiles
                LazyVStack(spacing: 0) {
                    ForEach(visible) { file in
                        row(file)
                            .overlay(alignment: .top) {
                                if file.id != visible.first?.id { Rectangle().fill(Self.rule).frame(height: 1) }
                            }
                    }
                    if visible.isEmpty {
                        emptyState
                    }
                }
            }
        }
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.cardBorder))
    }

    private var headerRow: some View {
        HStack(spacing: Layout.gap) {
            Color.clear.frame(width: Layout.checkbox)
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Kind").frame(width: Layout.kind, alignment: .leading)
            Text("Last opened").frame(width: Layout.lastOpened, alignment: .leading)
            Text("Size").frame(width: Layout.size, alignment: .trailing)
        }
        .padding(.horizontal, Layout.inset)
        .frame(height: Layout.header)
        .font(.system(size: 10.5, weight: .semibold))
        .textCase(.uppercase)
        .tracking(0.5)
        .lineLimit(1)
        .foregroundStyle(.secondary)
        .background(Color(light: Color(hex: 0x000000, opacity: 0.03), dark: Color(hex: 0xFFFFFF, opacity: 0.03)))
        .overlay(alignment: .bottom) { Rectangle().fill(Self.rule).frame(height: 1) }
        .accessibilityHidden(true)
    }

    /// A chip with nothing behind it, as opposed to a scan that found nothing.
    private var emptyKind: FileKind? {
        guard let kind = model.kindFilter, !(model.files ?? []).isEmpty else { return nil }
        return kind
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text(emptyKind.map { "No \($0.rawValue.lowercased())" } ?? "No large files")
                .font(.system(size: 13, weight: .semibold))
            Text(emptyDetail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 20)
    }

    private var emptyDetail: String {
        if emptyKind != nil { return "None of the large files found are of this kind. Choose another kind." }
        var text = "No file of \(model.listedMinBytes.fileSizeText) or more"
        if let days = model.listedNotOpenedInDays { text += " that was not opened in \(days) days" }
        return text + " was found outside Library and node_modules."
    }

    // MARK: One row

    private func row(_ file: LargeFile) -> some View {
        let isLocked = file.lock != nil
        let name = file.url.lastPathComponent
        return HStack(spacing: Layout.gap) {
            TriStateCheckbox(state: model.isSelected(file) ? .on : .off, label: name, tint: Theme.largeFilesAccent) {
                model.toggle(file)
            }
            .disabled(isLocked)
            .frame(width: Layout.checkbox, alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.folderText(of: file))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isLocked ? 0.45 : 1)

            kindCell(file)
                .frame(width: Layout.kind, alignment: .leading)

            Text(LargeFilesModel.lastOpenedText(file.lastOpened))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Layout.lastOpened, alignment: .leading)
                .opacity(isLocked ? 0.45 : 1)

            Text(file.bytes.fileSizeText)
                .font(.system(size: 12.5, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: Layout.size, alignment: .trailing)
                .opacity(isLocked ? 0.45 : 1)
        }
        .padding(.horizontal, Layout.inset)
        .frame(height: Layout.row)
        // Only the checkbox ticks a file: a stray click on the row must never mark a file for the Trash.
        .help(file.url.path)
        .contextMenu {
            Button("Reveal in Finder") { model.reveal(file) }
        }
    }

    /// The kind, or in place of it why the file cannot be ticked. The tag is not dimmed with the rest of its row.
    @ViewBuilder private func kindCell(_ file: LargeFile) -> some View {
        if let lock = file.lock {
            MethodTag(lock: lock)
        } else {
            Text(file.kind.singular)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Bottom bar

/// "Selected 208 MB · moved to Trash", Reveal in Finder and Move to Trash.
private struct SelectionBar: View {
    let model: LargeFilesModel
    let confirm: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            status
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 10)
            Button("Reveal in Finder") { model.revealSelected() }
                .buttonStyle(OutlineButtonStyle())
                .disabled(model.isCleaning || model.selectedVisible.isEmpty)
            Button("Move to Trash", action: confirm)
                .buttonStyle(PrimaryButtonStyle(gradient: Theme.largeFilesPrimaryGradient))
                .disabled(!model.canMoveToTrash)
        }
        .frame(height: 46)
    }

    @ViewBuilder private var status: some View {
        if case .cleaning = model.phase {
            // The cleaning page above shows the progress.
            EmptyView()
        } else {
            let hidden = model.hiddenSelectedCount
            let hiddenNote = hidden > 0
                ? Text(verbatim: " · \(hidden) hidden by filters").foregroundStyle(Theme.lockText)
                : Text(verbatim: "")
            if model.selectedVisible.isEmpty {
                Text("Nothing selected\(hiddenNote)")
            } else {
                let size = Text(verbatim: model.selectedBytes.fileSizeText)
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(.primary)
                Text("Selected \(size) · moved to Trash\(hiddenNote)")
            }
        }
    }
}

/// The outlined capsule of a secondary action in the bottom bar.
private struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration)
    }

    private struct Label: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .overlay(Capsule().strokeBorder(Color(light: Color(hex: 0x000000, opacity: 0.25), dark: Color(hex: 0xFFFFFF, opacity: 0.25))))
                .contentShape(Capsule())
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
        }
    }
}
