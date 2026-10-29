import CleanoriCore
import SwiftUI

/// The colours of the Disk Map: the same dot in the list and the same fill in the chart, by position.
enum DiskMapPalette {
    /// Cycled by position (the approved mockup's colours).
    private static let cycle: [Color] = [0xB44CF0, 0x5B5BF0, 0x18B39A, 0xF0742F, 0xFFB35C, 0xFF7AC6, 0x4FA3FF].map { Color(hex: $0) }
    /// The "Other" group.
    private static let other = Color(hex: 0x6B6B70)

    static func color(at index: Int, of entry: DiskMapEntry) -> Color {
        entry.isOther ? other : cycle[index % cycle.count]
    }
}

// MARK: - Chart

/// The bubble chart (like Space Lens): one circle per entry, its area following its size, packed by
/// `BubbleLayout` into whatever room the view has. The layout is worked out again whenever the size changes.
///
/// A bubble of a folder goes down into it when clicked. A file and the grey "Other" bubble are not clickable.
struct BubbleChartView: View {
    /// The folder on screen. A new folder fades the bubbles in rather than moving them.
    let folderID: String
    let entries: [DiskMapEntry]
    let highlighted: String?
    @Binding var hovered: String?
    @Binding var selected: String?
    /// What to say when there is nothing to draw.
    let emptyMessage: String
    let open: (DiskNode) -> Void
    let reveal: (DiskNode) -> Void

    private static let padding: CGFloat = 10
    /// A bubble smaller than this is not drawn: it could not be seen or hit.
    private static let smallest: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            // The container is as big as the panel and each bubble is placed in it with `.position`, so every
            // bubble's layout frame is where it is drawn (and where it is hit, hovered and gets its tooltip and menu).
            ZStack {
                if entries.isEmpty {
                    Text(emptyMessage)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                } else {
                    bubbles(in: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .id(folderID)
            .transition(.opacity)
        }
        .background(Self.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.cardBorder))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bubble chart")
    }

    @ViewBuilder private func bubbles(in size: CGSize) -> some View {
        let layout = BubbleLayout.layout(values: entries.map { Double($0.bytes) }, in: size, padding: Self.padding)
        ForEach(layout, id: \.index) { bubble in
            if bubble.radius >= Self.smallest, entries.indices.contains(bubble.index) {
                let entry = entries[bubble.index]
                BubbleView(
                    entry: entry,
                    radius: bubble.radius,
                    color: DiskMapPalette.color(at: bubble.index, of: entry),
                    isHighlighted: entry.id == highlighted
                )
                .diskMapEntry(entry, hovered: $hovered, selected: $selected, open: open, reveal: reveal)
                .position(x: bubble.center.x, y: bubble.center.y)
                // The highlighted one is drawn last so its outline is not cut by a neighbour.
                .zIndex(entry.id == highlighted ? 1 : 0)
            }
        }
    }

    /// The chart's backdrop: darker than the window in dark mode, as in the mockup.
    private static let panel = Color(light: Color(hex: 0xF7F7F8), dark: Color(hex: 0x19191B))
}

/// One circle with its label: name and size when it is big enough, only the name when it is smaller, nothing when
/// it is tiny.
private struct BubbleView: View {
    let entry: DiskMapEntry
    let radius: CGFloat
    let color: Color
    let isHighlighted: Bool

    /// The outline of the highlighted bubble: light on the dark panel, dark on the light one.
    private static let ring = Color(light: Color(hex: 0x000000, opacity: 0.55), dark: Color(hex: 0xFFFFFF, opacity: 0.85))

    /// A label needs this much radius for the name, and this much for the size under it.
    private static let nameFromRadius: CGFloat = 14
    private static let sizeFromRadius: CGFloat = 24

    var body: some View {
        Circle()
            .fill(color.opacity(isHighlighted ? 1 : 0.85))
            .overlay {
                Circle().strokeBorder(isHighlighted ? Self.ring : .clear, lineWidth: 2)
            }
            .overlay { label }
            .frame(width: radius * 2, height: radius * 2)
            .contentShape(Circle())
    }

    @ViewBuilder private var label: some View {
        if radius >= Self.nameFromRadius {
            // Grows with the bubble: about 10 pt on a small one and 15 pt on a big one.
            let nameSize = min(16, 8.5 + 0.06 * radius)
            VStack(spacing: 1) {
                Text(entry.name)
                    .font(.system(size: nameSize, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if radius >= Self.sizeFromRadius {
                    Text(entry.sizeText)
                        .font(.system(size: nameSize - 2.5))
                        .opacity(0.85)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            // Inside the circle, so a long name is cut rather than spilling out of it.
            .frame(width: radius * 1.7)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Clicking and pointing

extension View {
    /// What a row or bubble of an entry does: a folder goes down when clicked, a file or the "Other" group does
    /// nothing but become the selected one. Pointing at it makes it the highlighted one, in the list and the chart
    /// alike. A right click offers "Reveal in Finder" (only for something that is a real item). Read aloud as
    /// "name, size", and as a button when it is a folder.
    func diskMapEntry(
        _ entry: DiskMapEntry,
        hovered: Binding<String?>,
        selected: Binding<String?>,
        open: @escaping (DiskNode) -> Void,
        reveal: @escaping (DiskNode) -> Void
    ) -> some View {
        modifier(EntryInteraction(entry: entry, hovered: hovered, selected: selected, open: open, reveal: reveal))
    }
}

private struct EntryInteraction: ViewModifier {
    let entry: DiskMapEntry
    @Binding var hovered: String?
    @Binding var selected: String?
    let open: (DiskNode) -> Void
    let reveal: (DiskNode) -> Void

    @ViewBuilder func body(content: Content) -> some View {
        let element = control(content)
            .onHover { inside in
                if inside {
                    hovered = entry.id
                } else if hovered == entry.id {
                    hovered = nil
                }
            }
            .contextMenu {
                if let node = entry.node {
                    Button("Reveal in Finder") { reveal(node) }
                }
            }
            .help(helpText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.spokenLabel)
            .accessibilityAddTraits(entry.isOpenable ? .isButton : [])
            .accessibilityRemoveTraits(entry.isOpenable ? [] : .isButton)
        if let node = entry.node, entry.isOpenable {
            // `accessibilityElement` replaces the button's own element, so the press is given again here (what
            // VoiceOver's "activate" and the Accessibility Inspector's press do). A file and "Other" get none.
            element.accessibilityAction { open(node) }
        } else {
            element
        }
    }

    @ViewBuilder private func control(_ content: Content) -> some View {
        if let node = entry.node, entry.isOpenable {
            Button { open(node) } label: { content }
                .buttonStyle(.plain)
        } else {
            content.onTapGesture { selected = entry.id }
        }
    }

    private var helpText: String {
        guard let url = entry.node?.url else { return "Everything else in this folder" }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }
}
