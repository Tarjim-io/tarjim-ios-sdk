// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Tarjim",
    // macOS is listed only so `swift test` runs on a Mac host (the lowest host CI runs); iOS is the
    // supported platform.
    platforms: [.iOS(.v15), .macOS(.v15)],
    products: [
        .library(name: "Tarjim", targets: ["Tarjim"]),
    ],
    targets: [
        .target(name: "Tarjim", resources: [.copy("Resources/PrivacyInfo.xcprivacy")]),
        .testTarget(
            name: "TarjimTests",
            dependencies: ["Tarjim"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
