// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "TaflCore",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "TaflCore", targets: ["TaflCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder", exact: "0.4.5"),
    ],
    targets: [
        .target(name: "TaflCore", dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder")]),
        .testTarget(name: "TaflCoreTests", dependencies: [
            "TaflCore",
            .product(name: "TOMLDecoder", package: "TOMLDecoder"),
        ]),
    ]
)
