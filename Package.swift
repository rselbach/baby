// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Baby",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "BabyUpdate"),
    .executableTarget(name: "Baby", dependencies: ["BabyUpdate"]),
    .executableTarget(name: "baby-update-tool", dependencies: ["BabyUpdate"]),
    .testTarget(name: "BabyTests", dependencies: ["Baby"]),
    .testTarget(name: "BabyUpdateTests", dependencies: ["BabyUpdate", "baby-update-tool"]),
  ]
)
