// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HAPiPCam",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HAPiPCam", targets: ["HAPiPCam"]),
    ],
    targets: [
        .executableTarget(name: "HAPiPCam"),
        .testTarget(name: "HAPiPCamTests", dependencies: ["HAPiPCam"]),
    ]
)
