// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RufusMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "RufusCore", targets: ["RufusCore"]),
        .executable(name: "RufusMac", targets: ["RufusMac"]),
        .executable(name: "rufusmac-helper", targets: ["rufusmac-helper"]),
        .executable(name: "rufusmac-selftest", targets: ["rufusmac-selftest"])
    ],
    targets: [
        .target(
            name: "RufusCore",
            path: "Sources/RufusCore",
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "rufusmac-helper",
            dependencies: ["RufusCore"],
            path: "Sources/rufusmac-helper"
        ),
        .executableTarget(
            name: "RufusMac",
            dependencies: ["RufusCore"],
            path: "Sources/RufusMac",
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "rufusmac-selftest",
            dependencies: ["RufusCore"],
            path: "Tests/SelfTest"
        )
    ]
)
