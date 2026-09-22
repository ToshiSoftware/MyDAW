// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyDAW",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "MyDAW",
            targets: ["MyDAW"]
        )
    ],
    targets: [
        .executableTarget(
            name: "MyDAW",
            path: "Sources"
        )
    ]
)

