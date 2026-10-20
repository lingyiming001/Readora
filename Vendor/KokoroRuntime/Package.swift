// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReadoraKokoroRuntime",
    platforms: [.iOS(.v17)],
    products: [.library(name: "ReadoraKokoroRuntime", targets: ["ReadoraKokoroRuntime"])],
    targets: [
        .binaryTarget(name: "SherpaOnnxIOS",
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.8-ios-static.xcframework.zip",
            checksum: "6b8e769cb153343270fdccbe92e3b3db0d1c421d67fa0989ab01fdf5b2fcf2de"),
        .binaryTarget(name: "OnnxruntimeIOS",
            url: "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.28.2/onnxruntime-ios-static-xcframework-1.28.2.xcframework.zip",
            checksum: "2c2299acbb461d26d4bac4bc85985d40e7c7177ed6072703ae0846d88b0b4599"),
        .target(name: "ReadoraKokoroRuntime", dependencies: ["SherpaOnnxIOS", "OnnxruntimeIOS"], path: "Sources",
            linkerSettings: [.linkedLibrary("c++"), .linkedFramework("CoreML"), .linkedFramework("Accelerate")])
    ])
