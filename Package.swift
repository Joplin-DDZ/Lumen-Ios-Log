// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Lumen",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Lumen", targets: ["Lumen"])],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .executableTarget(name: "Lumen", dependencies: ["CSQLite"]),
        .testTarget(name: "LumenTests", dependencies: ["Lumen"])
    ]
)
