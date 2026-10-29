import SwiftUI

/// The gradient capsule of a screen's main action (Clean, Scan, Move to Trash), as in the approved mockup.
struct PrimaryButtonStyle: ButtonStyle {
    /// Teal by default; Large Files passes its own orange.
    var gradient: LinearGradient = Theme.primaryGradient

    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration, gradient: gradient)
    }

    private struct Label: View {
        let configuration: ButtonStyleConfiguration
        let gradient: LinearGradient
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .background(gradient, in: Capsule())
                .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
        }
    }
}
