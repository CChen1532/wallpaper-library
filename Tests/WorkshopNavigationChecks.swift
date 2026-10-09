import AppKit
import WebKit

/// Supplies navigation identities without loading a website or reading cookies.
@MainActor private final class NavigationFixtureView: WKWebView {
    private(set) var navigation: WKNavigation?
    var fixtureURL = URL(string: "https://steamcommunity.com/login")!
    override var url: URL? { fixtureURL }
    override func load(_ request: URLRequest) -> WKNavigation? {
        navigation = super.loadHTMLString("<html></html>", baseURL: nil)
        return navigation
    }
    override func stopLoading() {}
}

@main struct WorkshopNavigationChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = NavigationFixtureView(frame: .zero, configuration: configuration)
        let browser = WorkshopSubscriptionBrowser(webView: view)
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label); checks += 1; print("PASS: " + label)
        }
        browser.readSubscriptions()
        let obsolete = view.navigation!
        browser.cancel()
        browser.readSubscriptions()
        let current = view.navigation!
        browser.webView(view, didFail: obsolete, withError: URLError(.cannotConnectToHost))
        check(browser.reading && browser.error == nil, "旧导航错误不终止重新开始的订阅读取")
        browser.webView(view, didFailProvisionalNavigation: obsolete, withError: URLError(.timedOut))
        check(browser.reading && browser.error == nil, "旧导航预加载错误不覆盖当前读取状态")
        browser.webView(view, didFinish: obsolete)
        check(browser.reading && browser.error == nil, "旧导航完成事件不按新页面解析登录状态")
        browser.webView(view, didFail: current, withError: URLError(.cancelled))
        check(browser.reading && browser.error == nil, "取消回调不误报网络故障")
        browser.webView(view, didFail: current, withError: URLError(.cannotConnectToHost))
        check(!browser.reading && browser.error == WorkshopFailure.network.localizedDescription,
              "当前导航的真实网络失败仍停止读取并显示原因")
        browser.readSubscriptions()
        browser.webView(view, didFinish: view.navigation)
        check(!browser.reading && browser.error == WorkshopFailure.subscriptionLogin.localizedDescription,
              "当前登录页面仍提示先登录，不替换已有订阅")
        browser.readSubscriptions()
        browser.webView(view, didFailProvisionalNavigation: view.navigation, withError: URLError(.timedOut))
        check(!browser.reading && browser.error == WorkshopFailure.network.localizedDescription,
              "当前预加载失败不会被导航隔离吞掉")
        browser.cancel()
        print("\(checks) subscription navigation checks passed; no network requests or cookies used")
    }
}
