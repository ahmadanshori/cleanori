import CleanoriCore
import SwiftUI

/// The Disk Map screen (spec §6.2): the start page, the scan in progress, then the banner, the breadcrumb, the list
/// of the largest items on the left and the bubble chart on the right. It is view-only: nothing on this screen
/// deletes, moves or renames anything.
struct DiskMapView: View {
    @Environment(AppModel.self) private var app

    private var model: DiskMapModel { app.diskMap }

    var body: some View {
        content
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
                module: .diskMap,
                gradient: Theme.diskMapPrimaryGradient,
                message: "Maps where your space goes: the biggest folders in your home folder as bubbles. Click a bubble to look inside it. This screen only shows sizes and never deletes anything.",
                secondary: (title: "Choose folder…", action: { model.chooseFolder() })
            ) { Task { await model.scan() } }
        case .scanning(let progress):
            ScanningPage(module: .diskMap, progress: progress) { model.cancelScan() }
        case .results:
            ResultsPage(model: model)
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
    let model: DiskMapModel
    /// The entry the pointer is on, in the list or the chart.
    @State private var hovered: String?
    /// The entry last clicked that cannot be opened (a file, or "Other").
    @State private var selected: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var bannerTitle: String {
        guard let root = model.root else { return "" }
        return "\(root.bytes.sizeText(approximate: root.isApproximate)) in \(model.displayName(of: root))"
    }

    var body: some View {
        let entries = model.entries
        let highlighted = highlightedID(in: entries)
        VStack(spacing: 10) {
            ModuleBanner(module: .diskMap, title: bannerTitle, subtitle: model.scanSummary) {
                HStack(spacing: 8) {
                    Button("Rescan") { Task { await model.rescan() } }
                        .buttonStyle(BannerButtonStyle())
                    Button("Choose folder…") { model.chooseFolder() }
                        .buttonStyle(BannerButtonStyle())
                }
            }

            Breadcrumb(model: model, goTo: goTo, goUp: goUp)

            HStack(alignment: .top, spacing: 12) {
                FolderList(
                    entries: entries,
                    highlighted: highlighted,
                    hovered: $hovered,
                    selected: $selected,
                    showsOtherNote: model.hasSmallItemsGroup,
                    open: open,
                    reveal: model.reveal
                )
                BubbleChartView(
                    folderID: model.current?.id ?? "",
                    entries: entries,
                    highlighted: highlighted,
                    hovered: $hovered,
                    selected: $selected,
                    emptyMessage: emptyMessage,
                    open: open,
                    reveal: model.reveal
                )
            }
        }
        // The window has no title bar, so the screen already starts 38 pt down, below the traffic lights.
        .padding(EdgeInsets(top: 0, leading: 16, bottom: 16, trailing: 16))
        .onChange(of: model.current?.id) {
            hovered = nil
            selected = nil
        }
    }

    /// What is highlighted: what the pointer is on, else what was clicked, else the largest. An ID that is not on
    /// screen any more counts for nothing.
    private func highlightedID(in entries: [DiskMapEntry]) -> String? {
        let ids = Set(entries.map(\.id))
        return [hovered, selected].lazy.compactMap { $0 }.first(where: ids.contains) ?? entries.first?.id
    }

    private var emptyMessage: String {
        model.current?.isApproximate == true ? "This folder could not be read" : "This folder is empty"
    }

    // Moving around fades the bubbles; with Reduce Motion on they just change.
    private func open(_ node: DiskNode) { animated { model.open(node) } }
    private func goUp() { animated { model.goUp() } }
    private func goTo(_ depth: Int) { animated { model.goTo(depth: depth) } }

    private func animated(_ change: () -> Void) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2), change)
    }
}

// MARK: - Breadcrumb

/// "‹ Home › Library › Caches" and the size of the folder on screen. Every part but the last goes back to that folder.
private struct Breadcrumb: View {
    let model: DiskMapModel
    let goTo: (Int) -> Void
    let goUp: () -> Void

    var body: some View {
        let path = model.path
        HStack(spacing: 6) {
            Button(action: goUp) {
                Text("‹")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Self.border))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(path.count < 2)
            .opacity(path.count < 2 ? 0.4 : 1)
            .accessibilityLabel("Up one folder")

            ForEach(path.indices, id: \.self) { depth in
                if depth > 0 {
                    Text("›")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                crumb(path[depth], depth: depth, isLast: depth == path.count - 1)
            }

            Spacer(minLength: 12)

            if let current = model.current {
                Text(current.bytes.sizeText(approximate: current.isApproximate))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityLabel("Size of this folder: \(current.bytes.sizeText(approximate: current.isApproximate))")
            }
        }
        .font(.system(size: 12))
        .frame(height: 22)
        .padding(.horizontal, 2)
    }

    @ViewBuilder private func crumb(_ node: DiskNode, depth: Int, isLast: Bool) -> some View {
        let name = model.displayName(of: node)
        if isLast {
            // The folder on screen: stays readable when the ones above it are cut short.
            Text(name)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
        } else {
            Button { goTo(depth) } label: {
                Text(name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Go to \(name)")
        }
    }

    private static let border = Color(light: Color(hex: 0x000000, opacity: 0.18), dark: Color(hex: 0xFFFFFF, opacity: 0.2))
}

// MARK: - List

/// The 210 pt list on the left: a colour dot, the name and the size of each entry, in the order of the chart.
private struct FolderList: View {
    let entries: [DiskMapEntry]
    let highlighted: String?
    @Binding var hovered: String?
    @Binding var selected: String?
    /// Whether the folder has an "Other" group of its own (items under 1 MB), which the note explains.
    let showsOtherNote: Bool
    let open: (DiskNode) -> Void
    let reveal: (DiskNode) -> Void

    private static let width: CGFloat = 210
    private static let rowHeight: CGFloat = 27
    private static let rule = Color(light: Color(hex: 0x000000, opacity: 0.07), dark: Color(hex: 0xFFFFFF, opacity: 0.06))

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !entries.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            row(entry, at: index)
                                .overlay(alignment: .top) {
                                    if index > 0 { Rectangle().fill(Self.rule).frame(height: 1) }
                                }
                        }
                    }
                }
                // As tall as its rows, or as tall as there is room for (then it scrolls).
                .frame(maxHeight: CGFloat(entries.count) * Self.rowHeight)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.cardBorder))
            }

            if showsOtherNote {
                Text("Items under 1 MB are grouped into “Other”.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
        .frame(width: Self.width)
    }

    private func row(_ entry: DiskMapEntry, at index: Int) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(DiskMapPalette.color(at: index, of: entry))
                .frame(width: 8, height: 8)
            Text(entry.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.sizeText)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background(entry.id == highlighted ? Self.highlight : Color.clear)
        .contentShape(Rectangle())
        .diskMapEntry(entry, hovered: $hovered, selected: $selected, open: open, reveal: reveal)
    }

    private static let highlight = Color(light: Color(hex: 0x000000, opacity: 0.06), dark: Color(hex: 0xFFFFFF, opacity: 0.08))
}
