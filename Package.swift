// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalAudioPlayer",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "LocalAudioPlayer", targets: ["LocalAudioPlayer"])],
    targets: [
        .executableTarget(name: "LocalAudioPlayer")
    ]
)
