// Draws Cleanori's app icon as vectors and writes App/Assets.xcassets/AppIcon.appiconset.
// Run from the repository root: swift scripts/make-app-icon.swift

import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// The Overview gradient (Theme.swift), stretched a little at both ends so it holds up on a full tile.
/// For the Developer Junk teal instead: 0x1FC7AA, 0x0D6F80, 0x123C5C.
let palette = [Color(hex: 0xB28CFF), Color(hex: 0x5B5BF0), Color(hex: 0x2E2A8C)]

/// A four-point star with concave sides.
struct Sparkle: Shape {
    var waist: CGFloat = 0.32

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let rx = rect.width / 2, ry = rect.height / 2
        let kx = rx * waist, ky = ry * waist
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

/// The icon on Apple's 1024 pt macOS grid: an 824 pt rounded tile with its drop shadow, an "O" ring with a
/// sparkle in its middle, and a small sparkle at the top right.
struct AppIcon: View {
    var body: some View {
        let tile = RoundedRectangle(cornerRadius: 185.4, style: .continuous)
        ZStack {
            tile.fill(LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing))
            // Light from above.
            tile.fill(LinearGradient(colors: [.white.opacity(0.20), .white.opacity(0)], startPoint: .top, endPoint: .center))
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 104).frame(width: 520, height: 520)
                Sparkle().fill(.white).frame(width: 250, height: 250)
                Sparkle().fill(.white.opacity(0.9)).frame(width: 120, height: 120).offset(x: 248, y: -248)
            }
            .shadow(color: Color(hex: 0x0A1E33).opacity(0.35), radius: 18, y: 12)
            tile.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.30), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                lineWidth: 4
            )
        }
        .frame(width: 824, height: 824)
        .clipShape(tile)
        .shadow(color: .black.opacity(0.32), radius: 16, y: 10)
        .frame(width: 1024, height: 1024)
    }
}

@MainActor
func writeIcon(pixels: Int, to url: URL) {
    let renderer = ImageRenderer(content: AppIcon())
    renderer.scale = CGFloat(pixels) / 1024
    renderer.isOpaque = false
    guard let image = renderer.cgImage,
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("could not render \(url.lastPathComponent)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(url.path)") }
}

@MainActor
func main() throws {
    let catalog = URL(fileURLWithPath: "App/Assets.xcassets")
    let iconSet = catalog.appendingPathComponent("AppIcon.appiconset")
    try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

    let info = #""info" : { "author" : "xcode", "version" : 1 }"#
    try "{\n  \(info)\n}\n".write(to: catalog.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

    var images: [String] = []
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
            writeIcon(pixels: size * scale, to: iconSet.appendingPathComponent(name))
            images.append(#"    { "filename" : "\#(name)", "idiom" : "mac", "scale" : "\#(scale)x", "size" : "\#(size)x\#(size)" }"#)
        }
    }
    let contents = "{\n  \"images\" : [\n\(images.joined(separator: ",\n"))\n  ],\n  \(info)\n}\n"
    try contents.write(to: iconSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    print("Wrote \(images.count) images to \(iconSet.path)")
}

try MainActor.assumeIsolated { try main() }
