// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MacDuo", platforms: [.macOS(.v13)], products: [
    .executable(name: "MacDuo", targets: ["MacDuo"])
], targets: [
    .target(name: "FoldCore"),
    .executableTarget(name: "MacDuo", dependencies: ["FoldCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "FoldCoreTests", dependencies: ["FoldCore"])
])
