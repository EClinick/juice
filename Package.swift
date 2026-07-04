// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Juice",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Juice", path: "Sources/Juice")
    ]
)
