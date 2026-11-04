// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Baby",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "BabyUpdate"),
    .target(name: "BabyControl"),
    .executableTarget(name: "Baby", dependencies: ["BabyUpdate", "BabyControl"]),
    .executableTarget(name: "BabyCLI", dependencies: ["BabyControl"]),
    .executableTarget(name: "baby-update-tool", dependencies: ["BabyUpdate"]),
    .testTarget(name: "BabyTests", dependencies: ["Baby"]),
    .testTarget(name: "BabyControlTests", dependencies: ["BabyControl"]),
    .testTarget(name: "BabyCLITests", dependencies: ["BabyCLI"]),
    .testTarget(name: "BabyUpdateTests", dependencies: ["BabyUpdate", "baby-update-tool"]),
  ]
)
