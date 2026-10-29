import CoreGraphics
import Foundation

/// One circle of the Disk Map's bubble chart.
public struct Bubble: Sendable, Equatable {
    /// The position of the value this bubble stands for in the `values` given to `BubbleLayout.layout`.
    public let index: Int
    public let center: CGPoint
    public let radius: CGFloat

    public init(index: Int, center: CGPoint, radius: CGFloat) {
        self.index = index
        self.center = center
        self.radius = radius
    }
}

/// Packs circles whose areas are proportional to a list of values, like CleanMyMac's Space Lens.
///
/// This is pure geometry (no AppKit or SwiftUI), so it is cheap to test. It is meant for a dozen or so values:
/// finding each place looks at every pair of circles already placed, so the work grows with the cube of the count.
public enum BubbleLayout {
    /// Lays out one circle per value, with radius proportional to the square root of the value (so area follows
    /// the value), and fits the arrangement into `size`.
    ///
    /// The circles are placed from the largest to the smallest (equal values keep their input order). The largest
    /// goes at the origin. Each next one goes at the spot where it touches two circles already placed, does not
    /// overlap any, and is closest to the origin. The second circle has only one neighbour, so it simply touches
    /// the first, on its right. The whole arrangement is then scaled uniformly (the circles keep their proportions
    /// and stay tangent, never overlap) until it fills `size` minus `padding` on every side, in whichever direction
    /// is the tighter, and centered in `size`.
    ///
    /// The result has one bubble for each value, **in the order of `values`**, so `bubbles[i]` is the bubble of
    /// `values[i]` and `index` is `i`. A value that is zero, negative or not finite gets no area: its bubble has
    /// radius 0 and sits at the middle of the arrangement. When `size` leaves no room (it is not larger than twice
    /// `padding` in some direction), every radius is 0 and every bubble sits at the middle of `size`.
    public static func layout(values: [Double], in size: CGSize, padding: CGFloat = 4) -> [Bubble] {
        guard !values.isEmpty else { return [] }

        let radii = values.map { $0.isFinite && $0 > 0 ? $0.squareRoot() : 0 }
        let placed = pack(radii)

        // Fit: translate the arrangement's bounding box to the middle of `size`, and scale it to the room left.
        let middle = CGPoint(x: finite(size.width) / 2, y: finite(size.height) / 2)
        let inset = 2 * max(0, finite(padding))
        let room = (width: max(0, finite(size.width) - inset), height: max(0, finite(size.height) - inset))
        guard let box = boundingBox(of: placed) else {
            return values.indices.map { Bubble(index: $0, center: middle, radius: 0) }
        }
        let scale = min(room.width / box.width, room.height / box.height)
        let boxMiddle = (x: (box.minX + box.maxX) / 2, y: (box.minY + box.maxY) / 2)

        return values.indices.map { index in
            // A circle without area was not placed; it goes to the middle with the rest.
            guard let circle = placed[index] else { return Bubble(index: index, center: middle, radius: 0) }
            return Bubble(
                index: index,
                center: CGPoint(
                    x: middle.x + CGFloat((circle.x - boxMiddle.x) * scale),
                    y: middle.y + CGFloat((circle.y - boxMiddle.y) * scale)
                ),
                radius: CGFloat(circle.r * scale)
            )
        }
    }

    // MARK: - Packing

    private struct Circle {
        var x: Double
        var y: Double
        var r: Double
    }

    /// Places every circle that has a radius, returning where each one went (`nil` for a radius of 0).
    /// The result is in the order of `radii`, and in the units of `radii`.
    private static func pack(_ radii: [Double]) -> [Circle?] {
        // Largest first; equal radii keep their input order, so the result never depends on a sort's whims.
        let order = radii.indices.filter { radii[$0] > 0 }.sorted {
            radii[$0] != radii[$1] ? radii[$0] > radii[$1] : $0 < $1
        }
        guard let largest = order.first.map({ radii[$0] }) else { return radii.map { _ in nil } }
        // Two circles closer than this (relative to the largest) count as touching, not overlapping, so
        // rounding in the geometry below cannot reject a spot that is exactly tangent.
        let tolerance = largest * 1e-9

        var result = [Circle?](repeating: nil, count: radii.count)
        var placed: [Circle] = []
        for index in order {
            let r = radii[index]
            let circle: Circle
            switch placed.count {
            case 0:
                circle = Circle(x: 0, y: 0, r: r)
            case 1:
                circle = Circle(x: placed[0].r + r, y: 0, r: r)
            default:
                circle = closestFreeSpot(forRadius: r, among: placed, tolerance: tolerance)
            }
            placed.append(circle)
            result[index] = circle
        }
        return result
    }

    /// The spot closest to the origin where a circle of radius `r` touches two of `placed` and overlaps none.
    private static func closestFreeSpot(forRadius r: Double, among placed: [Circle], tolerance: Double) -> Circle {
        var best: Circle?
        var bestDistance = Double.infinity

        for i in placed.indices {
            for j in placed.indices where j > i {
                for spot in tangentSpots(r, to: placed[i], and: placed[j]) {
                    let distance = hypot(spot.x, spot.y)
                    // On a tie (within rounding) the spot found first stays, which keeps the result stable.
                    guard distance < bestDistance - tolerance else { continue }
                    let overlaps = placed.contains { hypot($0.x - spot.x, $0.y - spot.y) < $0.r + r - tolerance }
                    if !overlaps {
                        best = Circle(x: spot.x, y: spot.y, r: r)
                        bestDistance = distance
                    }
                }
            }
        }
        if let best { return best }

        // Not expected: some pair always leaves a free spot on the outside. If rounding ever hides it, go
        // just outside everything placed so far, which cannot overlap.
        let reach = placed.map { hypot($0.x, $0.y) + $0.r }.max() ?? 0
        return Circle(x: reach + r, y: 0, r: r)
    }

    /// The (up to two) centers where a circle of radius `r` touches both `a` and `b` from the outside.
    private static func tangentSpots(_ r: Double, to a: Circle, and b: Circle) -> [(x: Double, y: Double)] {
        let dx = b.x - a.x, dy = b.y - a.y
        let d = hypot(dx, dy)
        guard d > 0 else { return [] }
        // The center is `ra` from a's center and `rb` from b's: the intersection of two circles.
        let ra = a.r + r, rb = b.r + r
        let along = (d * d + ra * ra - rb * rb) / (2 * d) // from a's center towards b's
        let heightSquared = ra * ra - along * along
        guard heightSquared >= 0 else { return [] } // too far apart for one circle to touch both
        let height = heightSquared.squareRoot()
        let base = (x: a.x + along * dx / d, y: a.y + along * dy / d)
        let normal = (x: -dy / d, y: dx / d)
        return [
            (base.x + height * normal.x, base.y + height * normal.y),
            (base.x - height * normal.x, base.y - height * normal.y),
        ]
    }

    // MARK: - Fitting

    private static func boundingBox(
        of circles: [Circle?]
    ) -> (minX: Double, minY: Double, maxX: Double, maxY: Double, width: Double, height: Double)? {
        let placed = circles.compactMap { $0 }
        guard !placed.isEmpty else { return nil }
        let minX = placed.map { $0.x - $0.r }.min()!, maxX = placed.map { $0.x + $0.r }.max()!
        let minY = placed.map { $0.y - $0.r }.min()!, maxY = placed.map { $0.y + $0.r }.max()!
        return (minX, minY, maxX, maxY, maxX - minX, maxY - minY)
    }

    /// `value` as a `Double`, or 0 when it is NaN or infinite.
    private static func finite(_ value: CGFloat) -> Double {
        value.isFinite ? Double(value) : 0
    }
}
