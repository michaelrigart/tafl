// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "TaflCore",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "TaflCore", targets: ["TaflCore"]),
        // For the packages' tests only: the app links TaflCore and TaflPlatform27, never this.
        .library(name: "TaflTestSupport", targets: ["TaflTestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder", exact: "0.4.5"),
    ],
    targets: [
        .target(name: "TaflCore", dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder")]),
        .target(name: "TaflTestSupport"),
        .testTarget(name: "TaflCoreTests", dependencies: [
            "TaflCore",
            "TaflTestSupport",
            .product(name: "TOMLDecoder", package: "TOMLDecoder"),
        ]),
    ]
)
