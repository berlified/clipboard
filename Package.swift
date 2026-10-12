// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Aura",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Aura",
            path: "Sources/Aura"
        )
    ]
)
