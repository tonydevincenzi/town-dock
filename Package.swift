// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TownDock",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "TownDockCore", targets: ["TownDockCore"]),
        .executable(name: "TownDock", targets: ["TownDock"]),
        .executable(name: "TownDockProbe", targets: ["TownDockProbe"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.6"
        ),
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm.git",
            exact: "1.20.0"
        ),
    ],
    targets: [
        .target(
            name: "TownDockCore",
            path: "Sources/TownDockCore"
        ),
        .executableTarget(
            name: "TownDock",
            dependencies: [
                "TownDockCore",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/TownDock"
        ),
        .executableTarget(
            name: "TownDockProbe",
            dependencies: ["TownDockCore"],
            path: "Sources/TownDockProbe"
        ),
        .testTarget(
            name: "TownDockCoreTests",
            dependencies: ["TownDockCore"],
            path: "Tests/TownDockCoreTests"
        ),
    ]
)
