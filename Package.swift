// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NativTranslationKit", platforms: [.macOS(.v14)],
    products: [.library(name: "NativTranslationKit", targets: ["NativTranslationKit"])],
    targets: [
        .target(name: "NativTranslationKit"),
        .testTarget(name: "NativTranslationKitTests", dependencies: ["NativTranslationKit"]),
    ], swiftLanguageModes: [.v6])
