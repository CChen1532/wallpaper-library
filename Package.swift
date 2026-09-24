// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "WallpaperUI", platforms: [.macOS(.v14)], products: [
    .executable(name: "WallpaperUI", targets: ["WallpaperUI"]),
    .executable(name: "WESceneVisibleProbe", targets: ["WESceneVisibleProbe"]),
    .executable(name: "WESceneDesktopProbe", targets: ["WESceneDesktopProbe"])
], targets: [
    .executableTarget(name: "WallpaperUI", dependencies: ["WESceneCore"]),
    .executableTarget(name: "WESceneVisibleProbe", dependencies: ["WESceneCore"]),
    .executableTarget(name: "WESceneDesktopProbe", dependencies: ["WESceneCore"]),
    .target(name: "WESceneCore")
])
