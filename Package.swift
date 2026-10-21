// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "notch-island",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Island", path: "Sources/Island")
    ]
)
