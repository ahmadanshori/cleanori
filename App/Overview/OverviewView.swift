import CleanoriCore
import SwiftUI

/// The first screen (spec §6.2): the disk's capacity, one card for each module with what its last scan found,
/// and the Scan All button.
struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ModuleBanner(
                    module: .overview,
                    title: "Overview",
                    subtitle: "Scan your Mac for space you can get back"
                ) {
                    Button {
                        Task { await model.scanAll() }
                    } label: {
                        HStack(spacing: 6) {
                            if model.isScanningAll {
                                ProgressView().controlSize(.small).tint(.white)
                            }
                            Text(model.isScanningAll ? "Scanning…" : "Scan All")
                        }
                    }
                    .buttonStyle(BannerButtonStyle(isProminent: true))
                    .disabled(model.isScanningAll)
                }

                if model.showsFullDiskAccessBanner {
                    FullDiskAccessBanner { model.dismissFullDiskAccessBanner() }
                }

                CapacityCard(capacity: model.capacity, volumeName: model.volumeName)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Modules")
                        .font(.system(size: 10, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 12) {
                        ForEach([Module.developerJunk, .largeFiles, .diskMap]) { module in
                            ModuleCard(module: module)
                        }
                    }
                }
            }
            // The window has no title bar, so the scroll view already starts 38 pt down, below the traffic
            // lights, which is where the mockup puts the banner. No extra padding on top.
            .padding(EdgeInsets(top: 0, leading: 16, bottom: 16, trailing: 16))
        }
    }
}

/// Free space as a number, the usage bar, and how much is used.
private struct CapacityCard: View {
    let capacity: DiskCapacity?
    let volumeName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let capacity {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(capacity.available.fileSizeText)
                        .font(.system(size: 26, weight: .bold))
                        .monospacedDigit()
                    Text("free of \(capacity.total.fileSizeText)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(volumeName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                CapacityBar(capacity: capacity, height: 8)
                Text("\((capacity.total - capacity.available).fileSizeText) used")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("Disk space unavailable")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardStyle())
    }
}

/// One module: its icon and what it is for, then either its last result or "Not scanned yet". Clicking it opens
/// the module.
private struct ModuleCard: View {
    @Environment(AppModel.self) private var model
    let module: Module

    var body: some View {
        Button {
            model.selection = module
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ModuleIcon(module: module, size: 28)
                    Text(module.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                Text(module.tagline)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Divider()
                result
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
            .contentShape(Rectangle())
            .modifier(CardStyle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var result: some View {
        if let scan = model.lastScan(of: module) {
            VStack(alignment: .leading, spacing: 1) {
                Text(scan.bytes.fileSizeText)
                    .font(.system(size: 17, weight: .bold))
                    .monospacedDigit()
                Text(scan.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            Text(model.isScanningAll && module != .diskMap ? "Scanning…" : "Not scanned yet")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

/// The rounded, hairline-bordered panel the Overview uses for its cards.
private struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.cardBorder))
    }
}
