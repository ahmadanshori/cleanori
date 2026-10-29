import Foundation

/// An iOS Simulator device as reported by `xcrun simctl`.
public struct SimulatorDevice: Sendable, Equatable {
    public var udid: String
    public var name: String
    public var runtime: String
    public var isAvailable: Bool
    public var dataURL: URL

    public init(udid: String, name: String, runtime: String, isAvailable: Bool, dataURL: URL) {
        self.udid = udid
        self.name = name
        self.runtime = runtime
        self.isAvailable = isAvailable
        self.dataURL = dataURL
    }
}

/// Wrapper around `xcrun simctl`.
public protocol SimulatorControl: Sendable {
    func listDevices() async throws -> [SimulatorDevice]
    func delete(udid: String) async throws
}
