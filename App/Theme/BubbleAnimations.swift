import CleanoriCore
import SwiftUI

// The scan and clean animations: bubbles in the module's colours, as on the Disk Map. Each one follows Reduce
// Motion: the bubbles stand still, fade instead of popping, and the burst is left out.

/// One bubble: a soft highlight at its top left over the module's first two colours. `strength` is how solid the
/// colours are: faint behind a scan, solid for the items of a clean.
private func bubbleGradient(_ colors: [Color], in rect: CGRect, strength: Double) -> GraphicsContext.Shading {
    let first = colors.first ?? .accentColor
    let second = colors.dropFirst().first ?? first
    return .radialGradient(
        Gradient(colors: [.white.opacity(0.6 + 0.15 * strength), first.opacity(0.45 + 0.5 * strength), second.opacity(0.2 + 0.65 * strength)]),
        center: CGPoint(x: rect.minX + rect.width * 0.35, y: rect.minY + rect.height * 0.3),
        startRadius: 0,
        endRadius: rect.width * 0.75
    )
}

/// Bubbles drifting up behind a scan in progress. Drawn in one `Canvas` from the clock, so it costs one cheap
/// redraw per frame and never touches the scan.
struct RisingBubbles: View {
    let colors: [Color]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where a bubble rises across the width (0…1), its diameter, the seconds it takes to cross the page and
    /// how far into that crossing it starts (0…1). Fixed, so the page looks the same every time.
    private static let bubbles: [(x: Double, diameter: Double, period: Double, phase: Double)] = [
        (0.08, 26, 7.5, 0.10), (0.20, 14, 5.5, 0.55), (0.31, 38, 9.0, 0.30), (0.43, 12, 5.0, 0.85),
        (0.55, 30, 8.0, 0.05), (0.64, 18, 6.0, 0.45), (0.74, 44, 10.0, 0.70), (0.84, 16, 5.5, 0.25),
        (0.92, 24, 7.0, 0.90), (0.48, 20, 6.5, 0.60),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                for bubble in Self.bubbles {
                    var progress = (time / bubble.period + bubble.phase).truncatingRemainder(dividingBy: 1)
                    // Standing still: spread over the lower two thirds, where they do not crowd the text.
                    if reduceMotion { progress = 0.15 + bubble.phase * 0.5 }
                    let d = bubble.diameter
                    let y = size.height + d / 2 - progress * (size.height + d)
                    let sway = reduceMotion ? 0 : sin(time * 0.8 + bubble.phase * 6) * 8
                    let rect = CGRect(x: bubble.x * size.width + sway - d / 2, y: y - d / 2, width: d, height: d)
                    // Fade in at the bottom, and out by the time the bubble reaches the top edge, so none is cut off
                    // there.
                    let fadeIn = min(1, progress / 0.15)
                    let fadeOut = min(1, max(0, (y - d / 2) / (size.height * 0.25)))
                    context.opacity = fadeIn * fadeOut
                    context.fill(Path(ellipseIn: rect), with: bubbleGradient(colors, in: rect, strength: 0))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The items being cleaned as a cluster of up to 12 bubbles, packed like the Disk Map so the biggest items are the
/// biggest bubbles. They pop as `done` goes up, the smallest first and the biggest last, and are all gone once
/// `done` reaches `total`.
struct PoppingBubbles: View {
    let colors: [Color]
    let done: Int
    let total: Int
    private let bubbles: [CleanoriCore.Bubble]

    static let size = CGSize(width: 260, height: 170)
    private static let limit = 12

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(sizes: [Int64], done: Int, total: Int, colors: [Color]) {
        self.colors = colors
        self.done = done
        self.total = total
        // Largest first, as `BubbleLayout` places them. Items without a size still get a small bubble.
        let largest = sizes.sorted(by: >).prefix(Self.limit).map { Double(max($0, 1)) }
        bubbles = BubbleLayout.layout(values: largest, in: Self.size, padding: 8)
    }

    /// How many bubbles have popped: an even share of them for each share of the items done.
    private var popped: Int {
        guard total > 0 else { return bubbles.count }
        return min(bubbles.count, bubbles.count * min(done, total) / total)
    }

    var body: some View {
        ZStack {
            // `bubbles` runs from the biggest to the smallest, so the last `popped` of them are the ones gone.
            ForEach(bubbles.prefix(bubbles.count - popped), id: \.index) { bubble in
                Canvas { context, size in
                    let rect = CGRect(origin: .zero, size: size)
                    context.fill(Path(ellipseIn: rect), with: bubbleGradient(colors, in: rect, strength: 1))
                }
                .frame(width: bubble.radius * 2, height: bubble.radius * 2)
                .position(bubble.center)
                .transition(.asymmetric(
                    insertion: .identity,
                    removal: reduceMotion ? .opacity : .scale(scale: 1.35).combined(with: .opacity)
                ))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(.easeOut(duration: 0.3), value: popped)
        .accessibilityHidden(true)
    }
}

/// A four-point star with concave sides, as on the app icon.
struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let rx = rect.width / 2, ry = rect.height / 2
        let kx = rx * 0.32, ky = ry * 0.32
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y - ry))
        p.addCurve(to: CGPoint(x: c.x + rx, y: c.y), control1: CGPoint(x: c.x, y: c.y - ky), control2: CGPoint(x: c.x + kx, y: c.y))
        p.addCurve(to: CGPoint(x: c.x, y: c.y + ry), control1: CGPoint(x: c.x + kx, y: c.y), control2: CGPoint(x: c.x, y: c.y + ky))
        p.addCurve(to: CGPoint(x: c.x - rx, y: c.y), control1: CGPoint(x: c.x, y: c.y + ky), control2: CGPoint(x: c.x - kx, y: c.y))
        p.addCurve(to: CGPoint(x: c.x, y: c.y - ry), control1: CGPoint(x: c.x - kx, y: c.y), control2: CGPoint(x: c.x, y: c.y - ky))
        p.closeSubpath()
        return p
    }
}

/// Eight sparkles flying out from the middle and fading, once, when a clean has finished.
struct SparkleBurst: View {
    let color: Color
    @State private var flying = false
    @State private var faded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if !reduceMotion {
                ForEach(0..<8, id: \.self) { i in
                    let angle = Double(i) / 8 * 2 * .pi
                    let distance: Double = i.isMultiple(of: 2) ? 130 : 95
                    let side: CGFloat = i.isMultiple(of: 2) ? 26 : 17
                    SparkleShape()
                        .fill(color)
                        .frame(width: side, height: side)
                        .scaleEffect(flying ? 1 : 0.2)
                        .offset(x: flying ? cos(angle) * distance : 0, y: flying ? sin(angle) * distance : 0)
                        .opacity(faded ? 0 : 1)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) { flying = true }
            // Bright while they fly out, then gone.
            withAnimation(.easeIn(duration: 0.45).delay(0.5)) { faded = true }
        }
    }
}
