import CleanoriCore
import SwiftUI

/// The 200 pt sidebar (spec §6.1): Overview, then CLEANUP and SPACE, each row with a gradient icon and the size
/// its last scan found, and the disk's free space at the bottom.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: selection) {
            row(.overview)

            section("Cleanup")
            section("Space")
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 26)
        .environment(\.sidebarRowSize, .small)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            DiskFooter(capacity: model.capacity, volumeName: model.volumeName)
        }
        .navigationSplitViewColumnWidth(200)
    }

    /// `List` selects an optional value, the model always has a screen open.
    private var selection: Binding<Module?> {
        Binding(
            get: { model.selection },
            set: { if let module = $0 { model.selection = module } }
        )
    }

    private func section(_ group: String) -> some View {
        Section {
            ForEach(Module.allCases.filter { $0.sidebarGroup == group }) { row($0) }
        } header: {
            Text(group)
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.6)
        }
    }

    private func row(_ module: Module) -> some View {
        SidebarRow(module: module, value: value(for: module))
            .tag(module)
            // The row is 26 pt tall by itself, so the list must not add its own padding around it.
            .listRowInsets(EdgeInsets())
    }

    /// The size on the right of a row. A cleanup module that has not been scanned shows a dash; Overview and
    /// Disk Map show nothing.
    private func value(for module: Module) -> SidebarRow.Value? {
        switch module {
        case .overview, .diskMap:
            nil
        case .developerJunk, .largeFiles:
            if let scan = model.lastScan(of: module) {
                SidebarRow.Value(text: scan.bytes.fileSizeText, spoken: scan.bytes.fileSizeText)
            } else {
                SidebarRow.Value(text: "—", spoken: "Not scanned")
            }
        }
    }
}

private struct SidebarRow: View {
    /// What the row shows on its right, and what VoiceOver reads for it (a dash is read as "Not scanned").
    struct Value {
        let text: String
        let spoken: String
    }

    let module: Module
    let value: Value?

    var body: some View {
        HStack(spacing: 8) {
            ModuleIcon(module: module, size: 18)
            Text(module.title)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let value {
                Text(value.text)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel(value.spoken)
            }
        }
        .frame(height: 26)
    }
}

/// "Macintosh HD", "55 GB free of 460 GB" and a 4 pt usage bar.
private struct DiskFooter: View {
    let capacity: DiskCapacity?
    let volumeName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let capacity {
                Text(volumeName)
                Text("\(Text(verbatim: capacity.available.fileSizeText).fontWeight(.semibold).foregroundStyle(.primary)) free of \(Text(verbatim: capacity.total.fileSizeText))")
                CapacityBar(capacity: capacity, height: 4)
            } else {
                Text("Disk space unavailable")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
