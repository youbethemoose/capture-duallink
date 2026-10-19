// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CaptureDualLink",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CaptureDualLink", targets: ["CaptureDualLink"])],
    targets: [
        .target(name: "DualLinkCore"),
        .executableTarget(name: "CaptureDualLink", dependencies: ["DualLinkCore"]),
        .testTarget(name: "DualLinkCoreTests", dependencies: ["DualLinkCore"])
    ]
)
