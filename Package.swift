// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalAudioPlayer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "LocalAudioPlayer", targets: ["LocalAudioPlayer"]),
        .executable(name: "ncm-restore", targets: ["NCMRestoreTool"])
    ],
    targets: [
        .executableTarget(name: "LocalAudioPlayer"),
        .executableTarget(name: "NCMRestoreTool", path: "Sources/NCMRestoreTool")
    ]
)
