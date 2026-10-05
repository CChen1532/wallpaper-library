import SwiftUI
import WebKit

@MainActor final class WorkshopSubscriptionBrowser: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published private(set) var reading = false
    @Published private(set) var page = 1
    @Published private(set) var error: String?
    var completed: (([String]) -> Void)?
    private var collected: [String] = []
    private var seen = Set<String>()
    private var profilePath: String?
    private var expectedTotal: Int?
    private var generation = UUID()
    private var timeout: Task<Void, Never>?

    override init() {
        let configuration = WKWebViewConfiguration()
        // WebKit owns the persistent Steam session under the stable app bundle
        // identifier. Never copy cookies or passwords into app settings.
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }
    func open() {
        if webView.url == nil { webView.load(URLRequest(url: WorkshopSubscriptionPage.startURL)) }
    }
    func readSubscriptions() {
        guard !reading else { return }
        reading = true; error = nil; page = 1; collected = []; seen = []; profilePath = nil; expectedTotal = nil; generation = UUID()
        load(WorkshopSubscriptionPage.startURL)
    }
    func cancel() { generation = UUID(); reading = false; timeout?.cancel(); timeout = nil; webView.stopLoading() }
    private func load(_ url: URL) {
        timeout?.cancel()
        let current = generation
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            guard let self, self.reading, self.generation == current else { return }
            self.fail(WorkshopFailure.timedOut)
        }
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    }
    private func fail(_ failure: Error) {
        error = (failure as? WorkshopFailure)?.localizedDescription ?? WorkshopFailure.network.localizedDescription
        cancel()
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, url.scheme == "https",
              let host = url.host, ["steamcommunity.com", "store.steampowered.com", "login.steampowered.com", "help.steampowered.com"].contains(host) else {
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if reading { fail(error) } }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if reading, (error as NSError).code != NSURLErrorCancelled { fail(error) } }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard reading, let url = webView.url else { return }
        guard WorkshopSubscriptionPage.validURL(url), profilePath == nil || profilePath == url.path else { fail(WorkshopFailure.subscriptionLogin); return }
        let current = generation
        // Fixed read-only DOM extraction. Only result cards and pagination are returned, never form fields/cookies.
        let script = """
        (() => {
          if (!window.g_steamID || window.g_steamID === '0') return null;
          const nodes = document.querySelectorAll('.workshopItem, #no_items, .workshopBrowsePaging, .workshopBrowsePagingControls');
          return Array.from(nodes).map(n => n.outerHTML).join('');
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] value, failure in
            guard let self, self.reading, self.generation == current else { return }
            self.timeout?.cancel()
            guard failure == nil, let html = value as? String else { self.fail(WorkshopFailure.subscriptionLogin); return }
            do {
                let result = try WorkshopSubscriptionPage.decode(html, url: url, page: self.page)
                guard self.expectedTotal == nil || self.expectedTotal == result.total else { throw WorkshopFailure.pageChanged }
                self.expectedTotal = result.total
                let newIDs = result.ids.filter { self.seen.insert($0).inserted }
                guard self.page <= 1000, self.collected.count + newIDs.count <= 30_000,
                      !result.hasNext || !newIDs.isEmpty else { throw WorkshopFailure.subscriptionLimit }
                self.profilePath = url.path
                self.collected += newIDs
                if result.hasNext {
                    self.page += 1
                    var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                    var items = parts.queryItems ?? []
                    items.removeAll { $0.name == "p" }; items.append(.init(name: "p", value: String(self.page)))
                    parts.queryItems = items
                    self.load(parts.url!)
                } else {
                    guard self.collected.count == result.total else { throw WorkshopFailure.pageChanged }
                    let ids = self.collected
                    self.cancel(); self.completed?(ids)
                }
            } catch { self.fail(error) }
        }
    }
}

private struct WorkshopSteamWebView: NSViewRepresentable {
    let browser: WorkshopSubscriptionBrowser
    func makeNSView(context: Context) -> WKWebView { browser.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct WorkshopSubscriptionSheet: View {
    @ObservedObject var browser: WorkshopSubscriptionBrowser
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let completed: ([String]) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Steam 订阅").font(.headline)
                Spacer()
                Button("完成") { browser.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("在 Steam 页面登录后，点击读取订阅。这里只读取列表，不会订阅、退订或删除 Steam 中的项目。")
                .font(.callout).foregroundStyle(.secondary)
            WorkshopSteamWebView(browser: browser)
            if let error = browser.error { Text(AppStrings.text(error, locale: locale)).foregroundStyle(.orange).font(.callout) }
            HStack {
                if browser.reading {
                    WorkshopStageProgressView(title: LocalizedStringKey(String(format: AppStrings.text("正在读取第 %d 页…", locale: locale), browser.page)))
                }
                Spacer()
                Button("读取订阅") { browser.readSubscriptions() }.buttonStyle(.borderedProminent).disabled(browser.reading)
            }
        }.padding(18).frame(minWidth: 820, minHeight: 640)
            .onAppear { browser.completed = { ids in completed(ids); dismiss() }; browser.open() }
            .onDisappear { browser.cancel(); browser.completed = nil }
    }
}
