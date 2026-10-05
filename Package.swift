// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tarjim",
    // macOS is listed only so `swift test` runs on a Mac host; iOS is the supported platform.
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "Tarjim", targets: ["Tarjim"]),
    ],
    targets: [
        .target(
            name: "Tarjim",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "TarjimTests",
            dependencies: ["Tarjim"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
    ]
)
