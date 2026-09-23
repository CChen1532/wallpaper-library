import SwiftUI

@main struct WallpaperApp: App {
    @StateObject private var model = LibraryModel()
    var body: some Scene {
        WindowGroup("视频壁纸") {
            NativeLibraryView().environmentObject(model).frame(minWidth: 980, minHeight: 680)
        }.defaultSize(width: 1200, height: 800)
    }
}
