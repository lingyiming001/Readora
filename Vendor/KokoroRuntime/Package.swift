// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReadoraKokoroRuntime",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ReadoraKokoroRuntime", type: .static, targets: ["ReadoraKokoroRuntime"])],
    targets: [
        .binaryTarget(name: "SherpaOnnxIOS",
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.8-ios-static.xcframework.zip",
            checksum: "6b8e769cb153343270fdccbe92e3b3db0d1c421d67fa0989ab01fdf5b2fcf2de"),
        .binaryTarget(name: "OnnxruntimeIOS",
            url: "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.28.2/onnxruntime-ios-static-xcframework-1.28.2.xcframework.zip",
            checksum: "2c2299acbb461d26d4bac4bc85985d40e7c7177ed6072703ae0846d88b0b4599"),
        .binaryTarget(name: "SherpaOnnxMacOS",
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.8-macos-static.xcframework.zip",
            checksum: "93f7a064abe99e0d6185a88c5b36ce18c4bff35cd0d5e4e81f81151de8e3e7e5"),
        .binaryTarget(name: "OnnxruntimeMacOS",
            url: "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.28.2/onnxruntime-macos-static-xcframework-1.28.2.xcframework.zip",
            checksum: "cb0b0bec912c77229517c463e28a3fac9674c521f9599919efff1ef2b42f3da0"),
        .target(name: "ReadoraKokoroRuntime", dependencies: [
            .target(name: "SherpaOnnxIOS", condition: .when(platforms: [.iOS])),
            .target(name: "OnnxruntimeIOS", condition: .when(platforms: [.iOS])),
            .target(name: "SherpaOnnxMacOS", condition: .when(platforms: [.macOS])),
            .target(name: "OnnxruntimeMacOS", condition: .when(platforms: [.macOS]))], path: "Sources",
            linkerSettings: [.linkedLibrary("c++"), .linkedFramework("CoreML"), .linkedFramework("Accelerate")])
    ])
