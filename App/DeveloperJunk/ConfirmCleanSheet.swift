import CleanoriCore
import SwiftUI

/// The last question before anything is removed (spec §6.2): the total, how much goes each way, where the log
/// is, and Cancel / the confirm button. There is a line for every way that at least one ticked item goes, whatever
/// its size: a ticked item of 0 bytes that is deleted still brings up "Deleted permanently (cannot be undone)".
///
/// Developer Junk asks "Clean 12.3 GB?" with one line per way (`init(preview:…)`); Large Files asks "Move 3 files
/// to Trash?" with its own title and button (`init(title:…)`).
///
/// Cancel is the default button: Return and Esc both cancel. Nothing here can be confirmed with a key press, so a
/// permanent deletion always takes a click on the confirm button.
struct ConfirmCleanSheet: View {
    /// One way the items leave the disk, with how much goes that way.
    struct Line: Identifiable {
        let symbol: String
        let text: String
        let size: String

        var id: String { text }
    }

    let title: String
    let lines: [Line]
    let confirmTitle: String
    /// The confirm button's colour: the app's teal, or the screen's own.
    let confirmGradient: LinearGradient
    let onCancel: () -> Void
    let onConfirm: () -> Void

    init(
        title: String,
        lines: [Line],
        confirmTitle: String,
        confirmGradient: LinearGradient = Theme.primaryGradient,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        self.title = title
        self.lines = lines
        self.confirmTitle = confirmTitle
        self.confirmGradient = confirmGradient
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    /// The Developer Junk sheet: "Clean 12.3 GB?" and a line for each way that at least one ticked item goes.
    init(preview: DeveloperJunkModel.CleanPreview, onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void) {
        let totals = preview.totals
        let ways: [(method: CleanMethod, symbol: String, text: String)] = [
            (.delete, "xmark.bin", "Deleted permanently (cannot be undone)"),
            (.trash, "trash", "Moved to Trash"),
            (.simctl, "iphone", "Removed via simctl"),
        ]
        let lines = ways.filter { totals.count(of: $0.method) > 0 }.map { way in
            Line(
                symbol: way.symbol,
                text: way.text,
                size: totals.bytes(of: way.method).sizeText(approximate: preview.isApproximate(way.method))
            )
        }
        self.init(
            title: "Clean \(totals.totalBytes.sizeText(approximate: preview.isApproximate))?",
            lines: lines,
            confirmTitle: "Clean",
            onCancel: onCancel,
            onConfirm: onConfirm
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 15, weight: .bold))

            VStack(spacing: 8) {
                ForEach(lines) { line in
                    row(line)
                }
            }

            Text("Log: ~/Library/Logs/Cleanori")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.defaultAction)
                Button(confirmTitle, role: .destructive, action: onConfirm)
                    .buttonStyle(PrimaryButtonStyle(gradient: confirmGradient))
            }
        }
        .padding(20)
        .frame(width: 400)
        .onExitCommand(perform: onCancel)
    }

    private func row(_ line: Line) -> some View {
        HStack(spacing: 8) {
            Image(systemName: line.symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(line.text)
                .font(.system(size: 12.5))
            Spacer(minLength: 8)
            Text(line.size)
                .font(.system(size: 12.5, weight: .semibold))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}
