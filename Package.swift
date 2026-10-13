// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pathfinder",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/AdguardTeam/SafariConverterLib.git", from: "4.3.0")
    ],
    targets: [
        .executableTarget(
            name: "Pathfinder",
            dependencies: [
                .product(name: "ContentBlockerConverter", package: "SafariConverterLib")
            ],
            path: "Pathfinder",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "PathfinderTests",
            dependencies: ["Pathfinder"],
            path: "Tests"
        )
    ]
)
