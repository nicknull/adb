// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ADBKernel",
    platforms: [
        .macOS(.v13),
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "ADBKernel",
            targets: ["ADBKernel"]
        )
    ],
    targets: [
        .target(
            name: "ADBKernel"
        ),
        .testTarget(
            name: "ADBKernelTests",
            dependencies: ["ADBKernel"]
        )
    ]
)
