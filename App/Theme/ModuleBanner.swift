import SwiftUI

/// The thin gradient banner at the top of a screen (spec §6.1): the module's symbol, a result title, a subtitle
/// and, at the trailing end, a secondary action such as Rescan or Choose folder… (style it with `BannerButtonStyle`).
struct ModuleBanner<Trailing: View>: View {
    let module: Module
    let title: String
    let subtitle: String
    let trailing: Trailing

    init(module: Module, title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) {
        self.module = module
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.white.opacity(0.2))
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: module.systemImage)
                        .font(.system(size: 17, weight: .semibold))
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .opacity(0.85)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            trailing
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 54)
        .background(module.bannerGradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

extension ModuleBanner where Trailing == EmptyView {
    init(module: Module, title: String, subtitle: String) {
        self.init(module: module, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// The capsule button that sits on a banner: an outline by default, with a faint fill when `isProminent`.
struct BannerButtonStyle: ButtonStyle {
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: isProminent ? .semibold : .regular))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(.white.opacity(isProminent ? 0.22 : 0), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.55), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .modifier(DimWhenDisabled())
    }

    private struct DimWhenDisabled: ViewModifier {
        @Environment(\.isEnabled) private var isEnabled

        func body(content: Content) -> some View {
            content.opacity(isEnabled ? 1 : 0.5)
        }
    }
}
