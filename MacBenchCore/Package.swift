// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacBenchCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MacBenchCore", targets: ["MacBenchCore"]),
        // A second Mac on the command line, for trying the two-machine cases on
        // one. See docs/testing.md.
        .executable(name: "macbench-peer", targets: ["macbench-peer"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "MacBenchCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "macbench-peer",
            dependencies: ["MacBenchCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MacBenchCoreTests",
            dependencies: ["MacBenchCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
