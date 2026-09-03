// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "WakeOnCueCore",
  platforms: [
    .iOS(.v18),
    .macOS(.v15),
  ],
  products: [
    .library(name: "WakeOnCueCore", targets: ["WakeOnCueCore"])
  ],
  targets: [
    .target(name: "WakeOnCueCore"),
    .testTarget(name: "WakeOnCueCoreTests", dependencies: ["WakeOnCueCore"]),
  ]
)
