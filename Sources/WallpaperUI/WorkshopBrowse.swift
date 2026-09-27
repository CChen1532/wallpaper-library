import Foundation

// Steam public SSR strategy informed by Loomscreen (MIT), pinned in Licenses.
// Only JSON is decoded. No scripts from a downloaded page are evaluated here.
enum WorkshopBrowse {
    struct Page: Sendable { let items: [WorkshopItem]; let number: Int; let pages: Int; let total: Int }
    static func url(query: String, page: Int) -> URL {
        var parts = URLComponents(string: "https://steamcommunity.com/workshop/browse/")!
        parts.queryItems = [URLQueryItem(name: "appid", value: "431960"), .init(name: "browsesort", value: query.isEmpty ? "trend" : "textsearch"),
                           .init(name: "searchtext", value: query), .init(name: "search_text_target", value: "0"),
                           .init(name: "p", value: String(max(1, page))), .init(name: "l", value: "english")]
        return parts.url!
    }
    static func fetch(query: String, page: Int) async throws -> Page {
        let data = try await WorkshopNetwork.read(URLRequest(url: url(query: query, page: page)), maximum: 8 * 1024 * 1024)
        return try decode(String(decoding: data, as: UTF8.self), query: query, page: page)
    }
    static func decode(_ html: String, query: String, page: Int) throws -> Page {
        guard html.utf8.count <= 8 * 1024 * 1024,
              let start = html.range(of: "window.SSR.renderContext=JSON.parse(")?.upperBound, start < html.endIndex,
              html[start] == "\"" else { throw WorkshopFailure.pageChanged }
        var end = html.index(after: start)
        while end < html.endIndex {
            if html[end] == "\\" { end = html.index(end, offsetBy: 2, limitedBy: html.endIndex) ?? html.endIndex }
            else if html[end] == "\"" { break }
            else { end = html.index(after: end) }
        }
        guard end < html.endIndex,
              let text = try? JSONSerialization.jsonObject(with: Data(html[start...end].utf8), options: .fragmentsAllowed) as? String,
              let context = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let queryData = context["queryData"] as? String,
              let root = try? JSONSerialization.jsonObject(with: Data(queryData.utf8)) as? [String: Any],
              let queries = root["queries"] as? [[String: Any]] else { throw WorkshopFailure.pageChanged }
        for entry in queries {
            guard let key = entry["queryKey"] as? [Any], key.count > 1, key[0] as? String == "workshop_browse",
                  let identity = key[1] as? [String: Any], identity["appid"] as? Int == 431960,
                  identity["page"] as? Int == page, identity["browse_sort"] as? String == (query.isEmpty ? "trend" : "textsearch"),
                  (identity["search_text"] as? String ?? "") == query,
                  (identity["search_text_target"] as? Int ?? 0) == 0,
                  (identity["section"] as? String ?? "readytouseitems") == "readytouseitems",
                  (identity["required_tags"] as? [String] ?? []).isEmpty,
                  (identity["excluded_tags"] as? [String] ?? []).isEmpty,
                  let state = entry["state"] as? [String: Any], let data = state["data"] as? [String: Any],
                  data["eresult"] as? Int == 1, data["current_page"] as? Int == page,
                  let pages = data["total_pages"] as? Int, pages >= 0,
                  let total = data["total_count"] as? Int, total >= 0 else { continue }
            guard let values = data["results"] as? [[String: Any]] ?? (total == 0 || page > pages ? [] : nil) else { throw WorkshopFailure.pageChanged }
            var seen = Set<String>()
            let items = values.compactMap { value -> WorkshopItem? in
                guard let id = value["publishedfileid"] as? String, case .ok = WorkshopURLParser.parse(id),
                      seen.insert(id).inserted, (value["visibility"] as? Int ?? 0) == 0,
                      (value["banned"] as? NSNumber)?.boolValue != true else { return nil }
                var detail = value; detail["consumer_app_id"] = value["consumer_appid"]; detail["result"] = 1
                guard let data = try? JSONSerialization.data(withJSONObject: ["response": ["publishedfiledetails": [detail]]]) else { return nil }
                return try? WorkshopMetadata.decode(data, expectedID: id)
            }
            return Page(items: items, number: page, pages: pages, total: total)
        }
        throw WorkshopFailure.pageChanged
    }
}

enum WorkshopSubscriptionPage {
    struct Page { let ids: [String]; let hasNext: Bool; let total: Int }
    static let startURL = URL(string: "https://steamcommunity.com/my/myworkshopfiles/?appid=431960&browsefilter=mysubscriptions&numperpage=30&p=1&l=english")!
    static func validURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host == "steamcommunity.com", url.user == nil, url.password == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.first(where: { $0.name == "appid" })?.value == "431960",
              components.queryItems?.first(where: { $0.name == "browsefilter" })?.value == "mysubscriptions" else { return false }
        let parts = url.path.split(separator: "/")
        return parts.count == 3 && ["id", "profiles"].contains(String(parts[0])) && parts[2] == "myworkshopfiles"
    }
    static func decode(_ html: String, url: URL, page: Int) throws -> Page {
        guard validURL(url), URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "p" })?.value == String(page) else { throw WorkshopFailure.subscriptionLogin }
        guard html.utf8.count <= 8 * 1024 * 1024 else { throw WorkshopFailure.responseTooLarge }
        let hrefs = captures(#"href\s*=\s*["']([^"']+)["']"#, in: html)
        var seen = Set<String>()
        let ids = hrefs.compactMap { href -> String? in
            if case let .ok(id, _) = WorkshopURLParser.parse(href.replacingOccurrences(of: "&amp;", with: "&")), seen.insert(String(id)).inserted { return String(id) }
            return nil
        }
        // A login/challenge/error page must never replace a valid list with an empty one.
        guard !ids.isEmpty || html.contains("id=\"no_items\"") || html.contains("id='no_items'") else { throw WorkshopFailure.pageChanged }
        let totals = captures(#"Showing\s+[\d,]+\s*[--]\s*[\d,]+\s+of\s+([\d,]+)\s+entries"#, in: html)
        guard let total = totals.first.flatMap({ Int($0.replacingOccurrences(of: ",", with: "")) }) ?? (ids.isEmpty ? 0 : nil) else { throw WorkshopFailure.pageChanged }
        let hasNext = hrefs.contains { href in
            guard let link = URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: url)?.absoluteURL,
                  link.host == url.host, link.path == url.path,
                  let c = URLComponents(url: link, resolvingAgainstBaseURL: false),
                  c.queryItems?.first(where: { $0.name == "browsefilter" })?.value == "mysubscriptions",
                  c.queryItems?.first(where: { $0.name == "appid" })?.value == "431960",
                  let p = c.queryItems?.first(where: { $0.name == "p" })?.value, let n = Int(p) else { return false }
            return n > page
        }
        return Page(ids: ids, hasNext: hasNext, total: total)
    }
    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
    }
}
