// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PoemDesktop",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PoemCore", targets: ["PoemCore"]),
        .executable(name: "PoemDesktop", targets: ["PoemDesktop"])
    ],
    targets: [
        .target(name: "PoemCore"),
        .executableTarget(name: "PoemDesktop", dependencies: ["PoemCore"]),
        .testTarget(name: "PoemCoreTests", dependencies: ["PoemCore"])
    ]
)
