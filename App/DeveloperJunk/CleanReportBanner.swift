import CleanoriCore
import SwiftUI

/// What a clean did (spec §6.2): how much it freed (what was deleted or removed; what went to the Trash is
/// named separately, because the Trash still holds it), how many items were skipped or failed with a list to
/// open, a warning when the log could not be written, and a note on APFS snapshots when something was freed.
///
/// A screen that only moves files to the Trash (Large Files) has nothing "freed" to say, so it passes its own
/// `headline`; everything below it works as before.
struct CleanReportBanner: View {
    let report: CleanReport
    /// The names for the skipped and failed lists, and which sizes are approximate.
    let context: CleanReportContext
    /// Replaces "Freed X · Y moved to Trash" when set.
    var headline: String? = nil
    let onDismiss: () -> Void

    @State private var showsDetails = false

    private var freedBytes: Int64 { report.deletedBytes + report.simctlBytes }

    /// "Freed 12.3 GB", or "Freed 12.3 GB · 1.1 GB moved to Trash".
    private var title: String {
        if let headline { return headline }
        var text = "Freed \(freedBytes.sizeText(approximate: context.freedIsApproximate))"
        if report.trashedBytes > 0 {
            text += " · \(report.trashedBytes.sizeText(approximate: context.trashedIsApproximate)) moved to Trash"
        }
        return text
    }
    private var hasProblems: Bool { !report.skipped.isEmpty || !report.failed.isEmpty }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: report.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(report.failed.isEmpty ? Theme.accent : .orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))

                if let note = context.note {
                    Text(note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                if hasProblems {
                    HStack(spacing: 6) {
                        Text(counts)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Button(showsDetails ? "Hide details" : "Show details") {
                            showsDetails.toggle()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11.5))
                    }
                    if showsDetails {
                        details
                    }
                }

                if let logError = report.logError {
                    Label("Some actions could not be logged: \(logError)", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                }

                if freedBytes > 0 {
                    Text("The free space shown may not grow right away: APFS local snapshots (Time Machine) can keep deleted data for a while.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        // Not `fixedSize`: that makes the window's minimum height follow the text wrapped to
                        // one word per line.
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss report")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.accent.opacity(0.35)))
    }

    /// "2 skipped · 1 failed"
    private var counts: String {
        var parts: [String] = []
        if !report.skipped.isEmpty { parts.append("\(report.skipped.count) skipped") }
        if !report.failed.isEmpty { parts.append("\(report.failed.count) failed") }
        return parts.joined(separator: " · ")
    }

    /// Each skipped and failed item with the reason, failures first.
    private var details: some View {
        let entries = report.failed.map { Entry(id: $0.key, name: name(of: $0.key), reason: $0.value, failed: true) }
            .sorted { $0.name < $1.name }
            + report.skipped.map { Entry(id: $0.key, name: name(of: $0.key), reason: $0.value, failed: false) }
            .sorted { $0.name < $1.name }
        return ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(entries) { entry in
                    Text("\(entry.failed ? "Failed" : "Skipped"): \(entry.name) — \(entry.reason)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxHeight: 120)
    }

    private struct Entry: Identifiable {
        let id: String
        let name: String
        let reason: String
        let failed: Bool
    }

    /// The item's name, or the path part of its ID when the name is not known.
    private func name(of id: String) -> String {
        context.names[id] ?? String(id.split(separator: "|", maxSplits: 1).last ?? Substring(id))
    }
}
