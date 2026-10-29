import AppKit
import CleanoriCore
import SwiftUI

/// The notice on the Overview while macOS refuses the Full Disk Access probe (spec §6.3). The app works without that
/// access; the notice says what the user gains and takes them to the right pane of System Settings.
struct FullDiskAccessBanner: View {
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 18))
                .foregroundStyle(Self.amber)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Full Disk Access gives more accurate results")
                    .font(.system(size: 13, weight: .semibold))
                Text("Without it, folders macOS protects are skipped and their sizes are marked ≈.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Open Settings") {
                NSWorkspace.shared.open(FullDiskAccess.settingsURL)
            }
            .controlSize(.small)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .help("Dismiss until the next launch")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Self.amber.opacity(0.4)))
        .accessibilityElement(children: .contain)
    }

    /// The amber of the Move to Trash tag.
    private static let amber = Color(light: Color(hex: 0xB86E00), dark: Color(hex: 0xFFCC66))
}
