// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TetheringCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TetheringCore", targets: ["TetheringCore"]),
    ],
    targets: [
        .target(
            name: "TetheringCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("IOUSBHost"),
            ]
        ),
        .testTarget(
            name: "TetheringCoreTests",
            dependencies: ["TetheringCore"]
        ),
    ]
)
