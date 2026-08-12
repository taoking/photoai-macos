// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "PhotoAIMac",
    platforms: [
        .macOS(.v27)
    ],
    products: [
        .executable(name: "PhotoAIMac", targets: ["PhotoAIMac"])
    ],
    targets: [
        .executableTarget(name: "PhotoAIMac"),
        .testTarget(name: "PhotoAIMacTests", dependencies: ["PhotoAIMac"])
    ]
)
