// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BarPilot",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "BarPilot", targets: ["BarPilot"])
    ],
    targets: [
        .executableTarget(
            name: "BarPilot",
            path: "Sources/BarPilot",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
