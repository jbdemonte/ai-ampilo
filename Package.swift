// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUsage", defaultLocalization: "fr", platforms: [.macOS(.v14)],
    products: [.library(name: "AIUsageCore", targets: ["AIUsageCore"]),
               .executable(name: "AIUsage", targets: ["AIUsage"]),
               .executable(name: "aiusage-cli", targets: ["AIUsageCLI"])],
    targets: [
        .target(name: "PTYBridge"),
        .target(name: "AIUsageCore", dependencies: ["PTYBridge"], resources: [.process("Resources")]),
        .executableTarget(name: "AIUsage", dependencies: ["AIUsageCore"], exclude: ["Resources"]),
        .executableTarget(name: "AIUsageCLI", dependencies: ["AIUsageCore"]),
        .testTarget(name: "AIUsageCoreTests", dependencies: ["AIUsageCore"], resources: [.copy("Fixtures")])
    ])
