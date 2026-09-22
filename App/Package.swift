// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UMounter",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "UMounter", targets: ["UMounter"]),
    ],
    dependencies: [
        .package(path: "../Packages/DiskKit"),
    ],
    targets: [
        // UI-free state and logic, unit-tested.
        .target(name: "UMounterCore", dependencies: [.product(name: "DiskKit", package: "DiskKit")]),
        // SwiftUI menu bar app. Bundle it with scripts/build-app.sh.
        .executableTarget(name: "UMounter", dependencies: ["UMounterCore"]),
        .testTarget(name: "UMounterCoreTests", dependencies: ["UMounterCore"]),
    ],
    swiftLanguageModes: [.v6]
)
