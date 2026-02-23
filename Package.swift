// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PortlessMenu",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "PortlessMenu", targets: ["PortlessMenu"])
    ],
    targets: [
        .executableTarget(
            name: "PortlessMenu",
            path: "Sources/PortlessMenu"
        )
    ]
)
