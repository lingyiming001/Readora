// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Readora",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.executable(name: "Readora", targets: ["ReadoraMac"]), .executable(name: "ReadoraMCP", targets: ["ReadoraMCP"])],
    targets: [
        .systemLibrary(name: "CZlib"),
        .executableTarget(name: "ReadoraMCP", dependencies: ["ReadoraCore"]),
        .target(name: "ReadoraCore", dependencies: ["CZlib"]),
        .target(name: "ReadoraRendering", dependencies: ["ReadoraCore"]),
        .executableTarget(
            name: "ReadoraMac",
            dependencies: ["ReadoraCore", "ReadoraRendering"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(name: "ReadoraMacTests", dependencies: ["ReadoraMac", "ReadoraCore"]),
        .testTarget(name: "ReadoraCoreTests", dependencies: ["ReadoraCore", "ReadoraRendering", "CZlib"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v6]
)
