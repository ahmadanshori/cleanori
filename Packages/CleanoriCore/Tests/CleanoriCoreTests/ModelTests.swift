import Foundation
import Testing
import CleanoriCore

@Test func cleanMethodRawValuesAndCodable() throws {
    #expect(CleanMethod.delete.rawValue == "delete")
    #expect(CleanMethod.trash.rawValue == "trash")
    #expect(CleanMethod.simctl.rawValue == "simctl")
    let data = try JSONEncoder().encode(CleanMethod.simctl)
    #expect(String(decoding: data, as: UTF8.self) == "\"simctl\"")
    #expect(try JSONDecoder().decode(CleanMethod.self, from: data) == .simctl)
}

@Test func sizeResultZero() {
    #expect(SizeResult.zero == SizeResult(bytes: 0, fileCount: 0, isApproximate: false))
}

@Test func sizeResultAddsBytesAndCounts() {
    let sum = SizeResult(bytes: 100, fileCount: 2) + SizeResult(bytes: 50, fileCount: 3)
    #expect(sum.bytes == 150)
    #expect(sum.fileCount == 5)
    #expect(!sum.isApproximate)
}

@Test func sizeResultSumIsApproximateIfEitherIs() {
    let exact = SizeResult(bytes: 1, fileCount: 1)
    let approx = SizeResult(bytes: 1, fileCount: 1, isApproximate: true)
    #expect((exact + approx).isApproximate)
    #expect((approx + exact).isApproximate)
    #expect((approx + approx).isApproximate)
    #expect(!(exact + exact).isApproximate)
}

@Test func scanItemIDIsRuleIDAndPath() {
    let item = ScanItem(
        ruleID: "xcode.derivedData",
        url: URL(filePath: "/Users/me/Library/Developer/Xcode/DerivedData/App-abc"),
        displayName: "App",
        size: .zero,
        method: .delete
    )
    #expect(item.id == "xcode.derivedData|/Users/me/Library/Developer/Xcode/DerivedData/App-abc")
}

@Test func scanItemDefaults() {
    let item = ScanItem(
        ruleID: "r", url: URL(filePath: "/tmp/x"), displayName: "x", size: .zero, method: .trash
    )
    #expect(item.detail == nil)
    #expect(item.lastActivity == nil)
    #expect(item.lock == nil)
    #expect(item.badges.isEmpty)
    #expect(item.simulatorUDID == nil)
    #expect(!item.isSelectedByDefault)
}

@Test func scanItemEqualityConsidersAllFields() {
    let base = ScanItem(
        ruleID: "r", url: URL(filePath: "/tmp/x"), displayName: "x", size: .zero, method: .trash
    )
    var locked = base
    locked.lock = .processRunning(name: "qemu")
    #expect(base == base)
    #expect(base != locked)
    #expect(locked.lock?.label == "qemu is running")
}
