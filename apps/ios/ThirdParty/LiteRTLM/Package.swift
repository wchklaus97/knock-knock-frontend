// swift-tools-version: 5.9
//
// This package intentionally exposes only LiteRT-LM's public C framework.
// The upstream Swift wrapper adds an unsafe `-all_load` linker flag, which
// Xcode refuses to consume from an application target. The C API is stable,
// has no unsafe SwiftPM settings, and keeps the iOS 15 deployment floor.

import PackageDescription

let package = Package(
    name: "LiteRTLMRuntime",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(
            name: "LiteRTLM",
            targets: ["CLiteRTLM"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "CLiteRTLM",
            url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.16.0/CLiteRTLM.xcframework.zip",
            checksum: "4e0f683da07566ee79c143d2d58d387f77052b0e6a41562c969e5d2728fc9f4b"
        ),
    ]
)
