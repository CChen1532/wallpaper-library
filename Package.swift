// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "WallpaperUI", platforms: [.macOS(.v14)], products: [
    .executable(name: "WallpaperUI", targets: ["WallpaperUI"]),
    .executable(name: "WESceneVisibleProbe", targets: ["WESceneVisibleProbe"])
], targets: [
    .executableTarget(name: "WallpaperUI", dependencies: ["WESceneCore"]),
    .executableTarget(name: "WESceneVisibleProbe", dependencies: ["WESceneCore"]),
    .target(name: "WESceneCore")
])
