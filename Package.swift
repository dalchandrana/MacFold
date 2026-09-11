// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MacFold", platforms: [.macOS(.v13)], products: [
    .executable(name: "MacFold", targets: ["MacFold"])
], targets: [
    .target(name: "FoldCore"),
    .executableTarget(name: "MacFold", dependencies: ["FoldCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "FoldCoreTests", dependencies: ["FoldCore"])
])
