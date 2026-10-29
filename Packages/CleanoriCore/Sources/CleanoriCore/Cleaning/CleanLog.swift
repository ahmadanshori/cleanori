import Foundation

/// One line of the clean log (spec §5.10): what `Cleaner` did with one item.
public struct CleanLogEntry: Codable, Sendable, Equatable {
    public var timestamp: Date
    /// `delete`, `trash`, `simctl` or `skip`.
    public var action: String
    public var ruleID: String
    public var path: String
    public var bytes: Int64
    /// `ok`, `skipped` or `failed`.
    public var result: String
    public var message: String?

    public init(
        timestamp: Date, action: String, ruleID: String, path: String, bytes: Int64, result: String, message: String?
    ) {
        self.timestamp = timestamp
        self.action = action
        self.ruleID = ruleID
        self.path = path
        self.bytes = bytes
        self.result = result
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, action, ruleID, path, bytes, result, message
    }

    /// Writes every key, `message` included (as `null` when there is none), so each line has the same shape.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(action, forKey: .action)
        try container.encode(ruleID, forKey: .ruleID)
        try container.encode(path, forKey: .path)
        try container.encode(bytes, forKey: .bytes)
        try container.encode(result, forKey: .result)
        try container.encode(message, forKey: .message)
    }
}

/// The clean log: one JSON object per line, one file per local day, `clean-YYYY-MM-DD.jsonl` (spec §5.10).
public struct CleanLog: Sendable {
    public let directory: URL
    private let now: @Sendable () -> Date

    public init(directory: URL, now: @escaping @Sendable () -> Date) {
        self.directory = directory
        self.now = now
    }

    /// The real log folder, `~/Library/Logs/Cleanori`.
    public static func live() -> CleanLog {
        CleanLog(
            directory: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Logs/Cleanori", directoryHint: .isDirectory),
            now: { Date() }
        )
    }

    /// Today's file, named after the local date.
    public var currentFileURL: URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return directory.appending(path: "clean-\(formatter.string(from: now())).jsonl", directoryHint: .notDirectory)
    }

    /// Checks that an entry could be appended now: creates the folder and today's file when needed and opens
    /// the file for appending, without writing anything. Throws what `append` would.
    public func prepare() throws {
        close(try openForAppending())
    }

    /// Adds `entry` as one line at the end of today's file, creating the folder and the file when needed.
    /// A file that is a symbolic link is not written through.
    public func append(_ entry: CleanLogEntry) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var line = try encoder.encode(entry) // never contains a raw newline: JSON escapes them
        line.append(UInt8(ascii: "\n"))

        let fd = try openForAppending()
        defer { close(fd) }
        try line.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let count = write(fd, base + written, buffer.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw Self.posixError()
                }
                written += count
            }
        }
    }

    private func openForAppending() throws -> Int32 {
        let file = currentFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { throw Self.posixError() }
        return fd
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
