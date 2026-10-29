import AppKit
import CleanoriCore
import SwiftUI

// MARK: - Modules

/// A screen of the app. Carries what the sidebar, the banners and the Overview cards need to show it.
enum Module: String, CaseIterable, Identifiable {
    case overview, developerJunk, largeFiles, diskMap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .developerJunk: "Developer Junk"
        case .largeFiles: "Large Files"
        case .diskMap: "Disk Map"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2.fill"
        case .developerJunk: "trash.fill"
        case .largeFiles: "doc.fill"
        case .diskMap: "circle.hexagongrid.fill"
        }
    }

    /// One line on what the module is for, shown on its Overview card.
    var tagline: String {
        switch self {
        case .overview: "Your disk at a glance"
        case .developerJunk: "Caches and builds that can be regenerated"
        case .largeFiles: "Big files you have not opened in a while"
        case .diskMap: "See which folders take the most space"
        }
    }

    /// The sidebar section the module sits in; `nil` for Overview, which stands alone above the sections.
    var sidebarGroup: String? {
        switch self {
        case .overview: nil
        case .developerJunk, .largeFiles: "Cleanup"
        case .diskMap: "Space"
        }
    }

    /// The module's colours, the same in light and dark mode (spec §6.1).
    var gradient: [Color] {
        switch self {
        case .overview: [Color(hex: 0xA77BFF), Color(hex: 0x5B5BF0)]
        case .developerJunk: [Color(hex: 0x18B39A), Color(hex: 0x0D6F80), Color(hex: 0x123C5C)]
        case .largeFiles: [Color(hex: 0xFFB35C), Color(hex: 0xF0742F), Color(hex: 0x7A2E1A)]
        case .diskMap: [Color(hex: 0xD55BC4), Color(hex: 0x8A3FD6), Color(hex: 0x3B2A73)]
        }
    }

    /// The gradient of a banner: a slight diagonal across its width, the middle colour 60 % along.
    var bannerGradient: LinearGradient {
        Theme.gradient(gradient, from: UnitPoint(x: 0, y: 0.25), to: UnitPoint(x: 1, y: 0.75))
    }

    /// The gradient of a small icon tile: just the first two colours, because the last stop is too dark to
    /// read against a dark sidebar.
    var iconGradient: LinearGradient {
        Theme.gradient(Array(gradient.prefix(2)), from: .topLeading, to: .bottomTrailing)
    }
}

// MARK: - Theme

enum Theme {
    /// Teal of the selected checkbox and the start of the primary button.
    static let accent = Color(hex: 0x18B39A)

    /// The capsule behind the primary action of a screen (Clean, Move to Trash).
    static let primaryGradient = LinearGradient(
        colors: [Color(hex: 0x18B39A), Color(hex: 0x0D6F80)],
        startPoint: UnitPoint(x: 0, y: 0.25),
        endPoint: UnitPoint(x: 1, y: 0.75)
    )

    /// Large Files' orange (the approved mockup's `#f0742f`): its selected chip and ticked checkboxes.
    static let largeFilesAccent = Color(hex: 0xF0742F)

    /// The capsule behind Large Files' Move to Trash: the orange of its banner, a little darker at the end so the
    /// white label stays readable.
    static let largeFilesPrimaryGradient = LinearGradient(
        colors: [Color(hex: 0xF0742F), Color(hex: 0xC4501D)],
        startPoint: UnitPoint(x: 0, y: 0.25),
        endPoint: UnitPoint(x: 1, y: 0.75)
    )

    /// The capsule behind Disk Map's Scan: the purple of its banner, a little darker at the end so the white label
    /// stays readable.
    static let diskMapPrimaryGradient = LinearGradient(
        colors: [Color(hex: 0xA845C4), Color(hex: 0x6F34BE)],
        startPoint: UnitPoint(x: 0, y: 0.25),
        endPoint: UnitPoint(x: 1, y: 0.75)
    )

    /// The fill of the disk usage bar, from teal to amber.
    static let meterGradient = LinearGradient(
        colors: [Color(hex: 0x18B39A), Color(hex: 0xFFB35C)], startPoint: .leading, endPoint: .trailing
    )

    static let meterTrack = Color(light: Color(hex: 0x000000, opacity: 0.1), dark: Color(hex: 0xFFFFFF, opacity: 0.16))
    /// A panel sits slightly above the window: white in light mode, and in dark mode a faint white tint over the
    /// window colour (the mockup's #262629 cards on a #1e1e20 window), because `controlBackgroundColor` is
    /// darker than the window there.
    static let cardBackground = Color(light: Color(nsColor: .controlBackgroundColor), dark: Color(hex: 0xFFFFFF, opacity: 0.045))
    static let cardBorder = Color(nsColor: .separatorColor)
    /// Unticked checkbox outline.
    static let checkboxBorder = Color(light: Color(hex: 0xA8A8AD), dark: Color(hex: 0x66666B))
    /// Text that says something is locked ("Xcode is running", "1 locked"). Darker in light mode so it stays readable.
    static let lockText = Color(light: Color(hex: 0xB5421A), dark: Color(hex: 0xFF9A76))

    /// A gradient whose stops are spread evenly, except that the middle one of three sits 60 % along as in the
    /// approved mockup.
    static func gradient(_ colors: [Color], from start: UnitPoint, to end: UnitPoint) -> LinearGradient {
        let locations: [Double] = switch colors.count {
        case 3: [0, 0.6, 1]
        default: colors.indices.map { colors.count > 1 ? Double($0) / Double(colors.count - 1) : 0 }
        }
        let stops = zip(colors, locations).map { Gradient.Stop(color: $0, location: $1) }
        return LinearGradient(stops: stops, startPoint: start, endPoint: end)
    }
}

// MARK: - Colours

extension Color {
    /// An sRGB colour from `0xRRGGBB`.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// A colour that follows the system appearance.
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }
}

// MARK: - Formatting

extension Int64 {
    /// A size as Finder writes it (`43.0 GB`, decimal units), always in English style whatever the system
    /// language (spec §3). Zero reads `0 bytes`, not "Zero bytes".
    var fileSizeText: String {
        formatted(ByteCountFormatStyle(style: .file, spellsOutZero: false, locale: Locale(identifier: "en_US")))
    }
}

extension Int64 {
    /// `fileSizeText`, with `≈` in front when the figure may be off (ruling R11).
    func sizeText(approximate: Bool) -> String {
        (approximate ? "≈" : "") + fileSizeText
    }
}

// MARK: - Shared pieces

/// A rounded tile with the module's symbol on its gradient: the sidebar icon (18 pt) and the Overview card icon.
struct ModuleIcon: View {
    let module: Module
    var size: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(module.iconGradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: module.systemImage)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// How full a disk is: a track with the used share filled from teal to amber. `height` is 4 pt in the sidebar.
struct CapacityBar: View {
    let capacity: DiskCapacity
    var height: CGFloat = 4

    private var usedFraction: Double {
        guard capacity.total > 0 else { return 0 }
        return min(1, max(0, Double(capacity.total - capacity.available) / Double(capacity.total)))
    }

    var body: some View {
        Capsule()
            .fill(Theme.meterTrack)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Theme.meterGradient)
                        .frame(width: proxy.size.width * usedFraction)
                }
            }
            .clipShape(Capsule())
            .frame(height: height)
            .accessibilityElement()
            .accessibilityLabel("Disk usage")
            .accessibilityValue("\(Int((usedFraction * 100).rounded())) percent used")
    }
}
