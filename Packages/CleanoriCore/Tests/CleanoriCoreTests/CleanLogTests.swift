import Foundation
import Synchronization
import Testing
import CleanoriCore

/// Noon local time on the given day, so the file name does not depend on the time zone the tests run in.
private func localNoon(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
}

private func entry(
    at timestamp: Date,
    action: String = "delete",
    path: String = "/Users/someone/Library/Developer/Xcode/DerivedData/A",
    result: String = "ok",
    message: String? = nil
) -> CleanLogEntry {
    CleanLogEntry(
        timestamp: timestamp, action: action, ruleID: "xcode.derivedData", path: path,
        bytes: 2048, result: result, message: message
    )
}

private func lines(of file: URL) throws -> [Substring] {
    try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
}

private func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

/// A clock a test can move forward.
private final class Clock: Sendable {
    private let current: Mutex<Date>
    init(_ start: Date) { current = Mutex(start) }
    var now: Date { current.withLock { $0 } }
    func set(_ date: Date) { current.withLock { $0 = date } }
}

@Test func writesJSONLinesPerDay() throws {
    let temp = try TempHome(); defer { temp.cleanup() }
    let now = try localNoon(2026, 10, 28)
    let dir = temp.url.appending(path: "Logs/Cleanori", directoryHint: .isDirectory) // made by the first append
    let log = CleanLog(directory: dir, now: { now })
    #expect(log.currentFileURL.path == dir.path + "/clean-2026-10-28.jsonl")

    let first = entry(at: now)
    let second = entry(
        at: now, action: "skip", path: "/Users/someone/Documents/x", result: "skipped",
        message: "SafetyGuard: Protected location"
    )
    try log.append(first)
    try log.append(second)

    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["clean-2026-10-28.jsonl"])
    let text = try lines(of: log.currentFileURL)
    #expect(text.count == 3)
    #expect(text.last == "") // every line, the last one included, ends with a newline

    let objects = try text.dropLast().map {
        try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
    for object in objects {
        #expect(Set(object.keys) == ["timestamp", "action", "ruleID", "path", "bytes", "result", "message"])
    }
    #expect(objects[0]["message"] is NSNull) // present even when there is no message
    #expect(objects[0]["timestamp"] as? String == ISO8601DateFormatter().string(from: now))
    #expect(objects[0]["bytes"] as? Int == 2048)

    let decoded = try text.dropLast().map { try decoder().decode(CleanLogEntry.self, from: Data($0.utf8)) }
    #expect(decoded == [first, second])
}

@Test func appendsToAnExistingFileInsteadOfReplacingIt() throws {
    let temp = try TempHome(); defer { temp.cleanup() }
    let now = try localNoon(2026, 10, 28)
    try CleanLog(directory: temp.url, now: { now }).append(entry(at: now))
    let log = CleanLog(directory: temp.url, now: { now })
    try log.append(entry(at: now, action: "trash"))
    try log.append(entry(at: now, action: "simctl"))
    let actions = try lines(of: log.currentFileURL).dropLast().map {
        try decoder().decode(CleanLogEntry.self, from: Data($0.utf8)).action
    }
    #expect(actions == ["delete", "trash", "simctl"])
}

@Test func startsANewFileEachLocalDay() throws {
    let temp = try TempHome(); defer { temp.cleanup() }
    let clock = Clock(try localNoon(2026, 10, 28))
    let log = CleanLog(directory: temp.url, now: { clock.now })
    try log.append(entry(at: clock.now))
    clock.set(try localNoon(2026, 10, 29))
    #expect(log.currentFileURL.lastPathComponent == "clean-2026-10-29.jsonl")
    try log.append(entry(at: clock.now))
    let files = try FileManager.default.contentsOfDirectory(atPath: temp.url.path).sorted()
    #expect(files == ["clean-2026-10-28.jsonl", "clean-2026-10-29.jsonl"])
    for file in files {
        #expect(try lines(of: temp.url.appending(path: file)).count == 2)
    }
}

@Test func keepsAnyPathOnOneLineAndReadable() throws {
    let temp = try TempHome(); defer { temp.cleanup() }
    let now = try localNoon(2026, 10, 28)
    let log = CleanLog(directory: temp.url, now: { now })
    let path = "/Users/someone/Library/Developer/Xcode/iOS DeviceSupport/iPhone14,5 27.0.1 (24A446)/a\"b\nc"
    try log.append(entry(at: now, path: path))
    let text = try lines(of: log.currentFileURL)
    #expect(text.count == 2)
    #expect(text[0].contains("/iOS DeviceSupport/iPhone14,5 27.0.1 (24A446)/")) // slashes are not escaped
    #expect(try decoder().decode(CleanLogEntry.self, from: Data(text[0].utf8)).path == path)
}

@Test func prepareCreatesTodaysFileOrThrows() throws {
    let temp = try TempHome(); defer { temp.cleanup() }
    let now = try localNoon(2026, 10, 28)
    let log = CleanLog(directory: temp.url.appending(path: "Logs/Cleanori", directoryHint: .isDirectory), now: { now })
    try log.prepare()
    #expect(try Data(contentsOf: log.currentFileURL).isEmpty)
    try log.append(entry(at: now))
    try log.prepare() // keeps what is already there
    #expect(try lines(of: log.currentFileURL).count == 2)

    let blocker = try temp.file("Blocked", bytes: 16) // a file where the folder should be
    #expect(throws: (any Error).self) { try CleanLog(directory: blocker, now: { now }).prepare() }
}

@Test func liveLogIsInLibraryLogsCleanori() throws {
    // Only the location is computed; nothing is written to the real `~/Library/Logs`.
    let file = CleanLog.live().currentFileURL
    let folder = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/Cleanori", directoryHint: .isDirectory)
    #expect(file.deletingLastPathComponent().path == folder.path)
    #expect(file.lastPathComponent.hasPrefix("clean-"))
    #expect(file.pathExtension == "jsonl")
}
