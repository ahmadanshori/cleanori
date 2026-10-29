import Foundation
import UniformTypeIdentifiers

/// What a large file is, for the Large Files screen (spec §5.6).
public enum FileKind: String, CaseIterable, Sendable {
    case diskImage = "Disk images"
    case archive = "Archives"
    case video = "Videos"
    case other = "Other"

    /// The label for one file of this kind, as shown in its row (`"Disk image"`).
    public var singular: String {
        switch self {
        case .diskImage: "Disk image"
        case .archive: "Archive"
        case .video: "Video"
        case .other: "Other"
        }
    }

    private static let diskImageExtensions: Set<String> = ["dmg", "iso", "img"]
    private static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "xip", "tpz", "7z", "rar"]

    /// The kind of the file at `url`, from its extension (any letter case).
    ///
    /// Disk images and archives are named outright, because the system has no single type for either. A video
    /// is anything whose type conforms to `public.movie`, so `mov`, `mp4`, `m4v` and the rest are found without a list.
    public static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if diskImageExtensions.contains(ext) { return .diskImage }
        if archiveExtensions.contains(ext) { return .archive }
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), type.conforms(to: .movie) { return .video }
        return .other
    }
}
