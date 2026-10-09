import Foundation

@main struct LocalizationChecks {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ name: String) {
            guard value else { fatalError("FAIL: \(name)") }
            count += 1
            print("PASS: \(name)")
        }

        check(AppStrings.text("关于", language: .english) == "About", "常用界面文案可精确查找")
        check(AppStrings.text("停止所有壁纸", language: .english) == "Stop All Wallpapers", "长句不被「停止」这类短词前缀误匹配")
        check(AppStrings.text("恢复原壁纸失败：磁盘错误", language: .english)
              == "Failed to restore the original wallpaper: 磁盘错误", "前缀 + 运行时内容按前缀翻译并保留动态部分")
        check(AppStrings.text("已自动关闭场景过渡底图：不匹配", language: .english)
              == "Scene transition backdrop was turned off automatically: 不匹配", "冒号结尾的前缀同样生效")
        check(AppStrings.text("5 分钟", language: .english) == "5 min", "轮播间隔的「分钟」按英文单位输出")
        check(AppStrings.text("90 秒", language: .english) == "90 sec", "轮播间隔的「秒」按英文单位输出")
        check(AppStrings.text("关于", language: .chinese) == "关于", "中文界面原样返回")
        check(AppStrings.text("未收录的自定义文案", language: .english) == "未收录的自定义文案", "未收录文案原样返回而不是空串")
        check(AppStrings.text("", language: .english).isEmpty, "空串不触发查找")
        let displayFailure = "此显示器的播放记录不一致，请停止此屏幕后重试"
        let translatedDisplayFailure = "Playback records for this display are inconsistent. Stop playback on this display and try again."
        check(AppStrings.text(displayFailure, language: .english) == translatedDisplayFailure,
              "视频控制脚本的已知错误可翻译")
        check(AppStrings.text(displayFailure + "\n", language: .english) == translatedDisplayFailure,
              "子进程末尾换行不阻断已知错误的精确翻译")
        let ownedLabel = "local.wallpaper.phonto.fixture.a"
        check(AppStrings.text("停止视频任务失败：" + ownedLabel, language: .english)
              == "Could not stop the video task: " + ownedLabel, "错误前缀翻译后保留运行时任务标识")
        check(AppStrings.text("  未收录的作者原文\n", language: .english) == "  未收录的作者原文\n",
              "未知作者内容的原始空白保持不变")

        print("本地化运行时检查通过：\(count) 项")
    }
}
