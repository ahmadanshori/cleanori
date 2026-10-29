import CleanoriCore
import SwiftUI

/// The 14 pt checkbox of a result row. A group shows all / some / none of its items, so it has a third,
/// dashed state. Disabling it (a locked row) dims it.
///
/// It draws no text, so `label` is what VoiceOver reads: the name of what the box selects ("node_modules").
struct TriStateCheckbox: View {
    let state: TriState
    let label: String
    /// The colour of a ticked box: the app's teal, or a module's own (Large Files is orange).
    var tint: Color = Theme.accent
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(state == .off ? Color.clear : tint)
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(state == .off ? Theme.checkboxBorder : tint, lineWidth: 1.5)
                }
                .overlay {
                    switch state {
                    case .on:
                        Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    case .mixed:
                        Image(systemName: "minus").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    case .off:
                        EmptyView()
                    }
                }
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.isToggle)
    }

    private var accessibilityValue: String {
        switch state {
        case .on: "Selected"
        case .off: "Not selected"
        case .mixed: "Partly selected"
        }
    }
}
