// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "clock",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "clock",
            path: "Sources/clock",
            resources: [.process("Resources")]
        )
    ]
)
