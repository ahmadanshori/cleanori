import CleanoriCore
import SwiftUI

/// The small pill that says how an item is removed, or why it cannot be (spec §6.1): Delete, Move to Trash,
/// simctl, or a lock reason such as "Xcode is running".
struct MethodTag: View {
    private enum Style {
        case delete, trash, simctl, lock

        /// Text colour, then the tint behind it. The dark pair is the one in the approved mockup; the text is
        /// darkened in light mode so it stays readable on a pale window.
        var colors: (text: Color, background: Color) {
            switch self {
            case .delete:
                (Color(light: Color(hex: 0x0B7F6C), dark: Color(hex: 0x4FE0C4)), Color(hex: 0x18B39A, opacity: 0.16))
            case .trash:
                (Color(light: Color(hex: 0x8A5A00), dark: Color(hex: 0xFFCC66)), Color(hex: 0xFEBC2E, opacity: 0.14))
            case .simctl:
                (Color(light: Color(hex: 0x2F55C4), dark: Color(hex: 0xA4C0FF)), Color(hex: 0x6496FF, opacity: 0.16))
            case .lock:
                (Theme.lockText, Color(hex: 0xFF7850, opacity: 0.14))
            }
        }
    }

    private let text: String
    private let style: Style

    init(method: CleanMethod) {
        switch method {
        case .delete:
            text = "Delete"
            style = .delete
        case .trash:
            text = "Move to Trash"
            style = .trash
        case .simctl:
            text = "simctl"
            style = .simctl
        }
    }

    init(lock: LockReason) {
        text = lock.label
        style = .lock
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .lineLimit(1)
            // The longest lock labels ("Android emulator is running") are a little wider than the 140 pt Method
            // column, so they shrink before they would be cut off.
            .minimumScaleFactor(0.85)
            .foregroundStyle(style.colors.text)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(style.colors.background, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
