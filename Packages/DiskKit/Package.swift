// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiskKit", targets: ["DiskKit"]),
        .executable(name: "diskkit-spike", targets: ["diskkit-spike"]),
    ],
    targets: [
        .target(
            name: "DiskKit",
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(name: "diskkit-spike", dependencies: ["DiskKit"]),
        .testTarget(name: "DiskKitTests", dependencies: ["DiskKit"]),
    ],
    swiftLanguageModes: [.v6]
)
