// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BoothCore",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [.library(name: "BoothCore", targets: ["BoothCore"])],
    targets: [
        .target(name: "BoothCore"),
        .testTarget(name: "BoothCoreTests", dependencies: ["BoothCore"], resources: [.copy("Fixtures")])
    ]
)
