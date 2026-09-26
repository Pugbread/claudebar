// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Claudebar",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Claudebar",
            path: "Sources/Claudebar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
