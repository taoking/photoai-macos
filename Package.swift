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
        .executableTarget(
            name: "PhotoAIMac",
            resources: [.process("Resources")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "PhotoAIMacTests", dependencies: ["PhotoAIMac"])
    ]
)
