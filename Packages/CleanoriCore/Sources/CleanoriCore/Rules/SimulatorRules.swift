import Foundation

extension Discovery {
    /// Every iOS Simulator device that `xcrun simctl` lists, named `<name> (<runtime>)` (`iPhone 16 (iOS 26.3)`).
    /// The item's folder is the device's data folder, and its `simulatorUDID` is what `.simctl` deletes by.
    /// A device whose runtime has been removed is marked unavailable.
    ///
    /// When `simctl` fails (Xcode is not installed, say) there are no simulators to offer, so the result is
    /// empty and the scan goes on. Cancellation is not a failure of `simctl` and is passed on.
    static func simulators() -> Function {
        { env in
            let devices: [SimulatorDevice]
            do {
                devices = try await env.simulators.listDevices()
            } catch let cancellation as CancellationError {
                throw cancellation
            } catch {
                return []
            }
            return devices.map { device in
                DiscoveredItem(
                    url: device.dataURL,
                    displayName: "\(device.name) (\(device.runtime))",
                    simulatorUDID: device.udid,
                    isUnavailable: !device.isAvailable
                )
            }
        }
    }
}
