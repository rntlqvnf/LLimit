// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LLMBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LLMBar", targets: ["LLMBar"])
    ],
    targets: [
        .executableTarget(
            name: "LLMBar",
            path: "Sources/LLMBar"
        )
    ]
)
