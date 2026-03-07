// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CleanMacApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CleanMacCore", targets: ["CleanMacCore"]),
        .executable(name: "cleanmacapp-cli", targets: ["CleanMacAppCLI"]),
        .executable(name: "cleanmacapp-desktop", targets: ["CleanMacAppDesktop"])
    ],
    targets: [
        .target(
            name: "CleanMacCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "CleanMacAppCLI",
            dependencies: ["CleanMacCore"]
        ),
        .executableTarget(
            name: "CleanMacAppDesktop",
            dependencies: ["CleanMacCore"]
        )
    ]
)
