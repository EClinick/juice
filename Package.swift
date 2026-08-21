// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Juice",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0")
    ],
    targets: [
        .target(name: "JuiceXPCShared"),
        // Minimal C shim for the private coalition_info syscall and its struct,
        // which the public SDK does not expose. Only JuiceHelper depends on it.
        .target(name: "JuiceHelperCoalition"),
        // Dynamic Objective-C bridge to the private smart-charging client used
        // by Control Center. It carries no private headers or static linkage;
        // unsupported or changed interfaces fail closed in the app.
        .target(name: "JuiceSmartChargingBridge"),
        // Pure app logic (insights engine, store schema/queries) - kept out of
        // the executable so tests can import it.
        .target(
            name: "JuiceCore",
            dependencies: [
                "JuiceXPCShared",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .executableTarget(
            name: "JuiceHelper",
            dependencies: ["JuiceXPCShared", "JuiceHelperCoalition"]
        ),
        .executableTarget(
            name: "Juice",
            dependencies: [
                "JuiceXPCShared",
                "JuiceCore",
                "JuiceSmartChargingBridge",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Juice"
        ),
        .executableTarget(
            name: "JuiceXPCProbe",
            dependencies: ["JuiceXPCShared", "JuiceCore"]
        ),
        .testTarget(
            name: "JuiceTests",
            dependencies: [
                "JuiceCore",
                "JuiceXPCShared",
                "JuiceSmartChargingBridge",
                "Juice",
                "JuiceHelper"
            ]
        )
    ]
)
