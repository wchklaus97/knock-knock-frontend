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
            url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.12.0/CLiteRTLM.xcframework.zip",
            checksum: "3c2a11ecc8511d1e74efa7ca308dc7130c95223325c33212337ffb0563b79cde"
        ),
    ]
)
