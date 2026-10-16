// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Readora",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Readora", targets: ["ReadoraMac"]), .executable(name: "ReadoraMCP", targets: ["ReadoraMCP"])],
    targets: [
        .systemLibrary(name: "CZlib"),
        .executableTarget(name: "ReadoraMCP", dependencies: ["ReadoraCore"]),
        .target(name: "ReadoraCore", dependencies: ["CZlib"]),
        .target(name: "ReadoraRendering", dependencies: ["ReadoraCore"]),
        .executableTarget(name: "ReadoraMac", dependencies: ["ReadoraCore", "ReadoraRendering"]),
        .testTarget(name: "ReadoraMacTests", dependencies: ["ReadoraMac", "ReadoraCore"]),
        .testTarget(name: "ReadoraCoreTests", dependencies: ["ReadoraCore", "ReadoraRendering", "CZlib"], resources: [.copy("Fixtures")])
    ]
)
