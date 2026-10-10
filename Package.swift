// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrossMouse",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CrossMouseMac", targets: ["CrossMouseMac"])
    ],
    targets: [
        .target(name: "CrossMouseCore"),
        .executableTarget(name: "CrossMouseMac", dependencies: ["CrossMouseCore"]),
        .testTarget(name: "CrossMouseCoreTests", dependencies: ["CrossMouseCore"])
    ]
)
