import CleanoriCore
import SwiftUI

/// What a cleanup screen shows before its first scan: the module's icon, what it does and a Scan button.
struct StartPage: View {
    let module: Module
    /// The Scan button's colour: the app's teal, or the screen's own.
    var gradient: LinearGradient = Theme.primaryGradient
    let message: String
    /// A second, quieter button under Scan, for a screen that can also start somewhere else (Disk Map: Choose folder…).
    var secondary: (title: String, action: () -> Void)?
    let scan: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ModuleIcon(module: module, size: 56)
            Text(module.title)
                .font(.system(size: 20, weight: .bold))
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Scan", action: scan)
                .buttonStyle(PrimaryButtonStyle(gradient: gradient))
                .padding(.top, 4)
            if let secondary {
                Button(secondary.title, action: secondary.action)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }
}

/// What a cleanup screen shows while it scans: bubbles in the module's colours drifting up behind its icon, how many
/// items were visited, the path in view and Cancel.
struct ScanningPage: View {
    let module: Module
    let progress: ScanProgress
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ModuleIcon(module: module, size: 56)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                .padding(.bottom, 4)
            Text("Scanning…")
                .font(.system(size: 15, weight: .bold))
            Text("\(progress.itemsScanned.formatted(.number.locale(Locale(identifier: "en_US")))) items scanned")
                .font(.system(size: 12.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text((progress.currentPath as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 520)
                .opacity(progress.currentPath.isEmpty ? 0 : 1)
            Button("Cancel", action: cancel)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .background { RisingBubbles(colors: module.gradient) }
    }
}

/// What a cleanup screen shows in place of its table while it cleans: the items as bubbles that pop as they are
/// done, then a line on the progress (`status`) and one on what was selected (`detail`).
struct CleaningPage: View {
    let module: Module
    /// The size of each item being cleaned, in bytes.
    let sizes: [Int64]
    let done: Int
    let total: Int
    let status: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            PoppingBubbles(sizes: sizes, done: done, total: total, colors: module.gradient)
            Text(status)
                .font(.system(size: 15, weight: .bold))
                .monospacedDigit()
            Text(detail)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.cardBorder))
    }
}
