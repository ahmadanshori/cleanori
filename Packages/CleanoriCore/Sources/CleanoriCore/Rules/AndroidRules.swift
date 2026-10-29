import Foundation

// MARK: - Rules

extension Discovery {
    /// Every NDK folder in the Android SDK except the newest one (`27.0.12077973` and `27.1.12297006` when
    /// `27.2.12479018` is installed). Versions are compared as numbers, so `27.10.0` is newer than `27.9.1`.
    static func androidNDKs() -> Function {
        allButHighestVersion(in: AndroidSDK.ndk)
    }

    /// Every `system-images/<api>/<tag>` folder of the Android SDK, named `<api> · <tag>`
    /// (`android-36.1 · google_apis_playstore`). An image that no emulator's `config.ini` points at is
    /// badged `unused` and gets the detail `unused`.
    ///
    /// The ABI folder inside a tag (`arm64-v8a`) is not an item of its own: the SDK Manager installs and
    /// removes an image as a whole, and the emulator refers to it by `<api>/<tag>`.
    static func androidSystemImages() -> Function {
        { env in
            let used = AndroidSDK.systemImagePathsUsedByEmulators(in: env)
            var items: [DiscoveredItem] = []
            for api in try await children(of: AndroidSDK.systemImages)(env) {
                for tag in try await children(of: "\(AndroidSDK.systemImages)/\(api.displayName)")(env) {
                    var item = tag
                    item.displayName = "\(api.displayName) · \(tag.displayName)"
                    if !used.contains(where: { $0.contains("/system-images/\(api.displayName)/\(tag.displayName)/") }) {
                        item.badges = [.unused]
                        item.detail = "unused"
                    }
                    items.append(item)
                }
            }
            return items
        }
    }

    /// Every Android Virtual Device (`~/.android/avd/<name>.avd`). The `<name>.ini` file that Android keeps
    /// next to each one is a plain file, so it is never an item.
    static func androidEmulators() -> Function {
        children(of: AndroidSDK.avds) { $0.pathExtension == "avd" }
    }
}

// MARK: - Android SDK

/// Where Android Studio keeps things below the home folder.
private enum AndroidSDK {
    static let ndk = "Library/Android/sdk/ndk"
    static let systemImages = "Library/Android/sdk/system-images"
    static let avds = ".android/avd"

    /// The system image locations that the emulators (`.android/avd/*.avd/config.ini`) point at, one entry
    /// per emulator and shaped for matching `/system-images/<api>/<tag>/`: the value of `image.sysdir.1`
    /// (`system-images/android-36.1/google_apis_playstore/arm64-v8a/`) with a `/` on both ends, so it matches
    /// whether the path is relative, absolute or has no trailing slash. Matching whole folder names is what
    /// keeps `google_apis_playstore` from matching `google_apis_playstore_ps16k`.
    ///
    /// This is only reading, so a link to an emulator folder or to a `config.ini` is followed on purpose: an
    /// emulator kept on another disk still uses its image, and "unused" must never be claimed wrongly.
    static func systemImagePathsUsedByEmulators(in env: CoreEnvironment) -> [String] {
        let avdFolder = env.home.appending(path: avds, directoryHint: .isDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: avdFolder.path)) ?? []
        return names.sorted().filter { $0.hasSuffix(".avd") }.compactMap { name in
            let config = avdFolder
                .appending(path: name, directoryHint: .isDirectory)
                .appending(path: "config.ini", directoryHint: .notDirectory)
            guard let data = try? Data(contentsOf: config) else { return nil }
            return systemImagePath(inConfig: String(decoding: data, as: UTF8.self))
        }
    }

    /// The `image.sysdir.1` value of an AVD `config.ini` (`key=value` lines), wrapped in `/`; `nil` when absent.
    static func systemImagePath(inConfig config: String) -> String? {
        for line in config.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard key == "image.sysdir.1" else { continue }
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            return "/\(value)/"
        }
        return nil
    }
}
