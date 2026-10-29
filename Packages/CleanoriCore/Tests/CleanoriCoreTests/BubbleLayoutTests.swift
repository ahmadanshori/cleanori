import CoreGraphics
import Foundation
import Testing
import CleanoriCore

/// The smallest gap between two bubbles (negative when they overlap).
private func minimumGap(_ bubbles: [Bubble]) -> CGFloat {
    var gap = CGFloat.infinity
    for i in bubbles.indices {
        for j in bubbles.indices where j > i {
            let distance = hypot(bubbles[i].center.x - bubbles[j].center.x, bubbles[i].center.y - bubbles[j].center.y)
            gap = min(gap, distance - bubbles[i].radius - bubbles[j].radius)
        }
    }
    return gap
}

/// The box around every circle: (minX, minY, maxX, maxY).
private func extent(_ bubbles: [Bubble]) -> (minX: CGFloat, minY: CGFloat, maxX: CGFloat, maxY: CGFloat) {
    (
        bubbles.map { $0.center.x - $0.radius }.min() ?? 0,
        bubbles.map { $0.center.y - $0.radius }.min() ?? 0,
        bubbles.map { $0.center.x + $0.radius }.max() ?? 0,
        bubbles.map { $0.center.y + $0.radius }.max() ?? 0
    )
}

@Test func bubblesDoNotOverlapAndFit() {
    let size = CGSize(width: 440, height: 310)
    let bubbles = BubbleLayout.layout(values: [140, 102, 19, 13, 11, 5.7, 5.4, 15], in: size)
    #expect(bubbles.count == 8)
    for i in bubbles.indices {
        for j in bubbles.indices where j > i {
            let a = bubbles[i], b = bubbles[j]
            let distance = hypot(a.center.x - b.center.x, a.center.y - b.center.y)
            #expect(distance >= a.radius + b.radius - 0.5)
        }
        let bubble = bubbles[i]
        #expect(bubble.center.x - bubble.radius >= 0)
        #expect(bubble.center.y - bubble.radius >= 0)
        #expect(bubble.center.x + bubble.radius <= size.width)
        #expect(bubble.center.y + bubble.radius <= size.height)
    }
}

@Test func bubbleRadiusFollowsSqrt() {
    let bubbles = BubbleLayout.layout(values: [4, 1], in: CGSize(width: 300, height: 300))
    #expect(abs(bubbles[0].radius / bubbles[1].radius - 2) < 0.01)
}

@Test func emptyValuesGiveNoBubbles() {
    #expect(BubbleLayout.layout(values: [], in: CGSize(width: 440, height: 310)).isEmpty)
}

@Test func bubblesComeBackInInputOrder() {
    // The values are not sorted, and a bubble's index is its position in `values`.
    let values: [Double] = [3, 50, 8, 20]
    let bubbles = BubbleLayout.layout(values: values, in: CGSize(width: 400, height: 300))
    #expect(bubbles.map(\.index) == [0, 1, 2, 3])
    let radii = bubbles.map(\.radius)
    #expect(radii[1] > radii[3] && radii[3] > radii[2] && radii[2] > radii[0])
}

@Test func theTwoLargestBubblesTouch() {
    // The second bubble placed is tangent to the first, and scaling keeps tangent circles tangent.
    let bubbles = BubbleLayout.layout(values: [10, 140, 20, 100, 5], in: CGSize(width: 440, height: 310))
    let (first, second) = (bubbles[1], bubbles[3]) // 140 and 100
    let distance = hypot(first.center.x - second.center.x, first.center.y - second.center.y)
    #expect(abs(distance - (first.radius + second.radius)) < 1e-6)
}

@Test func everyBubbleTouchesAnotherOne() {
    // Each bubble after the first is placed tangent to a pair of earlier ones, so the arrangement is one
    // connected cluster with no bubble floating on its own.
    let bubbles = BubbleLayout.layout(values: [140, 102, 19, 13, 11, 5.7, 5.4, 15], in: CGSize(width: 440, height: 310))
    for bubble in bubbles {
        let touchesAnother = bubbles.contains { other in
            other.index != bubble.index
                && abs(hypot(bubble.center.x - other.center.x, bubble.center.y - other.center.y)
                    - (bubble.radius + other.radius)) < 1e-6
        }
        #expect(touchesAnother)
    }
}

@Test func singleBubbleFillsTheArea() {
    let size = CGSize(width: 440, height: 310)
    let bubbles = BubbleLayout.layout(values: [42], in: size, padding: 4)
    #expect(bubbles.count == 1)
    #expect(abs(bubbles[0].center.x - 220) < 1e-9)
    #expect(abs(bubbles[0].center.y - 155) < 1e-9)
    #expect(abs(bubbles[0].radius - (155 - 4)) < 1e-9) // limited by the height
}

@Test func arrangementIsScaledToTouchThePaddedArea() {
    let size = CGSize(width: 440, height: 310)
    let padding: CGFloat = 12
    let bubbles = BubbleLayout.layout(values: [140, 102, 19, 13, 11, 5.7, 5.4, 15], in: size, padding: padding)
    let box = extent(bubbles)
    // Nothing sticks out of the padded area, and the tighter of the two directions is used up exactly.
    #expect(box.minX >= padding - 1e-6 && box.minY >= padding - 1e-6)
    #expect(box.maxX <= size.width - padding + 1e-6 && box.maxY <= size.height - padding + 1e-6)
    let widthUsed = (box.maxX - box.minX) / (size.width - 2 * padding)
    let heightUsed = (box.maxY - box.minY) / (size.height - 2 * padding)
    #expect(abs(max(widthUsed, heightUsed) - 1) < 1e-9)
    // And it is centered in `size`.
    #expect(abs((box.minX + box.maxX) / 2 - size.width / 2) < 1e-6)
    #expect(abs((box.minY + box.maxY) / 2 - size.height / 2) < 1e-6)
}

@Test func layoutIsDeterministic() {
    let values: [Double] = [140, 102, 19, 13, 11, 5.7, 5.4, 15, 15, 15]
    let size = CGSize(width: 440, height: 310)
    #expect(BubbleLayout.layout(values: values, in: size) == BubbleLayout.layout(values: values, in: size))
}

@Test func equalValuesGiveEqualRadiiWithoutOverlap() {
    let bubbles = BubbleLayout.layout(values: Array(repeating: 7, count: 13), in: CGSize(width: 500, height: 400))
    #expect(bubbles.count == 13)
    #expect(Set(bubbles.map { ($0.radius * 1e6).rounded() }).count == 1)
    #expect(minimumGap(bubbles) >= -1e-6)
}

@Test func manyDifferentValuesNeverOverlap() {
    // A fixed pseudo-random spread of sizes, from a tiny sliver to a giant.
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    var values: [Double] = []
    for _ in 0..<60 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        values.append(pow(10, Double(state >> 40) / Double(1 << 24) * 4)) // 1 ... 10,000
    }
    let size = CGSize(width: 440, height: 310)
    let bubbles = BubbleLayout.layout(values: values, in: size)
    #expect(bubbles.count == 60)
    #expect(minimumGap(bubbles) >= -1e-6)
    let box = extent(bubbles)
    #expect(box.minX >= 4 - 1e-6 && box.minY >= 4 - 1e-6)
    #expect(box.maxX <= size.width - 4 + 1e-6 && box.maxY <= size.height - 4 + 1e-6)
}

@Test func fitsWideTallAndSquareAreas() {
    let values: [Double] = [100, 90, 80, 70, 60, 50, 40, 30, 20, 10]
    for size in [CGSize(width: 800, height: 300), CGSize(width: 300, height: 800), CGSize(width: 500, height: 500)] {
        let box = extent(BubbleLayout.layout(values: values, in: size, padding: 4))
        // Inside the padded area, centered, and using up the direction that is the tighter one.
        #expect(box.minX >= 4 - 1e-6 && box.minY >= 4 - 1e-6)
        #expect(box.maxX <= size.width - 4 + 1e-6 && box.maxY <= size.height - 4 + 1e-6)
        #expect(abs((box.minX + box.maxX) / 2 - size.width / 2) < 1e-6)
        #expect(abs((box.minY + box.maxY) / 2 - size.height / 2) < 1e-6)
        let widthUsed = (box.maxX - box.minX) / (size.width - 8)
        let heightUsed = (box.maxY - box.minY) / (size.height - 8)
        #expect(abs(max(widthUsed, heightUsed) - 1) < 1e-9)
    }
}

@Test func zeroNegativeAndNonFiniteValuesGetNoArea() {
    let size = CGSize(width: 300, height: 200)
    let bubbles = BubbleLayout.layout(values: [25, 0, -5, .nan, .infinity, 9], in: size)
    #expect(bubbles.map(\.index) == [0, 1, 2, 3, 4, 5])
    #expect(bubbles.map(\.radius).allSatisfy { $0.isFinite })
    #expect(bubbles.allSatisfy { $0.center.x.isFinite && $0.center.y.isFinite })
    #expect([1, 2, 3, 4].allSatisfy { bubbles[$0].radius == 0 })
    #expect(bubbles[0].radius > bubbles[5].radius && bubbles[5].radius > 0)
    #expect(minimumGap([bubbles[0], bubbles[5]]) >= -1e-6)
}

@Test func allZeroValuesStayAtTheMiddle() {
    let bubbles = BubbleLayout.layout(values: [0, 0, 0], in: CGSize(width: 200, height: 100))
    #expect(bubbles.count == 3)
    #expect(bubbles.allSatisfy { $0.radius == 0 && $0.center == CGPoint(x: 100, y: 50) })
}

@Test func tooSmallAreaGivesZeroRadiiNotNaN() {
    for size in [CGSize.zero, CGSize(width: 6, height: 300), CGSize(width: 300, height: -1)] {
        let bubbles = BubbleLayout.layout(values: [5, 3, 1], in: size, padding: 4)
        #expect(bubbles.count == 3)
        #expect(bubbles.allSatisfy { $0.radius == 0 && $0.center.x.isFinite && $0.center.y.isFinite })
    }
}
