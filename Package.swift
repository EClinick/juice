// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Juice",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "JuiceXPCShared"),
        .executableTarget(
            name: "JuiceHelper",
            dependencies: ["JuiceXPCShared"]
        ),
        .executableTarget(
            name: "Juice",
            dependencies: ["JuiceXPCShared"],
            path: "Sources/Juice"
        )
    ]
)
