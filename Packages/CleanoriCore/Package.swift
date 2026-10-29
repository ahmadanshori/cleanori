// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CleanoriCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CleanoriCore", targets: ["CleanoriCore"]),
    ],
    targets: [
        .target(name: "CleanoriCore"),
        .testTarget(
            name: "CleanoriCoreTests",
            dependencies: ["CleanoriCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
