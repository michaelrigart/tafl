// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "TaflPlatform27",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "TaflPlatform27", targets: ["TaflPlatform27"]),
    ],
    dependencies: [
        .package(path: "../TaflCore"),
    ],
    targets: [
        .target(name: "TaflPlatform27", dependencies: [.product(name: "TaflCore", package: "TaflCore")]),
        .testTarget(name: "TaflPlatform27Tests", dependencies: [
            "TaflPlatform27",
            .product(name: "TaflCore", package: "TaflCore"),
            .product(name: "TaflTestSupport", package: "TaflCore"),
        ]),
    ]
)
