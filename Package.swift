// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Mac-TaskManager",
    platforms: [.macOS(.v13)],
    products: [
        .executable(
            name: "Mac-TaskManager",
            targets: ["MacTaskManager"]
        ),
        .executable(
            name: "MacFanHelper",
            targets: ["MacFanHelper"]
        ),
        .executable(name: "MacSystemHelper", targets: ["MacSystemHelper"]),
        .executable(
            name: "CoolModeAlgorithmChecks",
            targets: ["CoolModeAlgorithmChecks"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(
            name: "MacSMC",
            path: "Sources/MacSMC",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "MacTaskManager",
            dependencies: ["MacSMC", "MacManagement", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/MacTaskManager",
            linkerSettings: [
                .linkedFramework("ServiceManagement"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .executableTarget(
            name: "MacFanHelper",
            dependencies: ["MacSMC"],
            path: "Sources/MacFanHelper"
        ),
        .target(name: "MacManagement", dependencies: ["MacSMC"], path: "Sources/MacManagement"),
        .executableTarget(name: "MacSystemHelper", dependencies: ["MacManagement", "MacSMC"], path: "Sources/MacSystemHelper"),
        .executableTarget(
            name: "CoolModeAlgorithmChecks",
            dependencies: ["MacSMC"],
            path: "Tests/MacSMCTests"
        )
    ]
)
