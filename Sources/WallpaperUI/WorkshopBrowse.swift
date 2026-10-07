import Foundation

// Steam public SSR strategy informed by Loomscreen (MIT), pinned in Licenses.
// Only JSON is decoded. No scripts from a downloaded page are evaluated here.
enum WorkshopBrowse {
    struct Page: Sendable {
        let items: [WorkshopItem]; let number: Int; let pages: Int; let total: Int
        var candidateCount = false
    }
    struct Request: Equatable, Sendable {
        let query: String
        let tags: [String]
        let excludedTags: [String]
        let ageOptions: [String]
        let kindOptions: [String]
        let sort: String
        let dates: WorkshopFilters.DateRange?
        init(query: String, filters: WorkshopFilters = .init(), now: Date = Date(), calendar: Calendar = .current) {
            self.query = query; tags = filters.requiredTags; excludedTags = filters.excludedTags
            ageOptions = filters.selectedAges.map(\.rawValue); kindOptions = filters.selectedKinds.map(\.rawValue)
            sort = filters.browseSort(query: query)
            dates = filters.dateRange(now: now, calendar: calendar)
        }
        var needsLocalMatch: Bool { ageOptions.count > 1 || kindOptions.count > 1 }
        func matches(_ item: WorkshopItem) -> Bool {
            let values = Set(item.tags.map { $0.lowercased() })
            return (ageOptions.isEmpty || ageOptions.contains { values.contains($0.lowercased()) })
                && (kindOptions.isEmpty || kindOptions.contains { values.contains($0.lowercased()) })
        }
    }
    static func url(query: String, page: Int) -> URL { url(request: Request(query: query), page: page) }
    static func url(request: Request, page: Int) -> URL {
        var parts = URLComponents(string: "https://steamcommunity.com/workshop/browse/")!
        parts.queryItems = [URLQueryItem(name: "appid", value: "431960"), .init(name: "browsesort", value: request.sort),
                           .init(name: "searchtext", value: request.query), .init(name: "search_text_target", value: "0"), .init(name: "days", value: "7"),
                           .init(name: "p", value: String(max(1, page))), .init(name: "l", value: "english")]
        parts.queryItems! += request.tags.map { .init(name: "requiredtags[]", value: $0) }
        parts.queryItems! += request.excludedTags.map { .init(name: "excludedtags[]", value: $0) }
        if let dates = request.dates {
            parts.queryItems! += [.init(name: "created_date_range_filter_start", value: String(dates.start)),
                                 .init(name: "created_date_range_filter_end", value: String(dates.end))]
        }
        return parts.url!
    }
    static func fetch(query: String, page: Int) async throws -> Page {
        try await fetch(request: Request(query: query), page: page)
    }
    static func fetch(request: Request, page: Int) async throws -> Page {
        let data = try await WorkshopNetwork.read(URLRequest(url: url(request: request, page: page)), maximum: 8 * 1024 * 1024)
        return try decode(String(decoding: data, as: UTF8.self), request: request, page: page)
    }
    static func decode(_ html: String, query: String, page: Int) throws -> Page {
        try decode(html, request: Request(query: query), page: page)
    }
    static func decode(_ html: String, request: Request, page: Int) throws -> Page {
        guard html.utf8.count <= 8 * 1024 * 1024, let context = renderContext(html) else { throw WorkshopFailure.pageChanged }
        let root: [String: Any]?
        if let queryData = context["queryData"] as? String {
            root = try? JSONSerialization.jsonObject(with: Data(queryData.utf8)) as? [String: Any]
        } else { root = context["queryData"] as? [String: Any] }
        guard let queries = root?["queries"] as? [[String: Any]] else { throw WorkshopFailure.pageChanged }
        for entry in queries {
            guard let key = entry["queryKey"] as? [Any], key.count > 1, key[0] as? String == "workshop_browse",
                  let identity = key[1] as? [String: Any], identity["appid"] as? Int == 431960,
                  identity["page"] as? Int == page, identity["browse_sort"] as? String == request.sort,
                  (identity["search_text"] as? String ?? "") == request.query,
                  (identity["search_text_target"] as? Int ?? 0) == 0,
                  (identity["section"] as? String ?? "readytouseitems") == "readytouseitems",
                  Set(identity["required_tags"] as? [String] ?? []) == Set(request.tags),
                  Set(identity["excluded_tags"] as? [String] ?? []) == Set(request.excludedTags),
                  (identity["trend_days"] as? Int ?? 7) == 7,
                  matchesDates(identity, request: request),
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
            }.filter { !request.needsLocalMatch || request.matches($0) }
            return Page(items: items, number: page, pages: pages, total: total, candidateCount: request.needsLocalMatch)
        }
        throw WorkshopFailure.pageChanged
    }
    /// Steam embeds the server render state as JSON. Current pages use
    /// `<script type="application/json" id="valve-ssr-data">`; older pages used
    /// `window.SSR.renderContext=JSON.parse("…")`. Both are parsed as data only.
    static func renderContext(_ html: String) -> [String: Any]? {
        if let marker = html.range(of: "id=\"valve-ssr-data\""),
           let tagStart = html[..<marker.lowerBound].range(of: "<script", options: .backwards),
           !html[tagStart.upperBound..<marker.lowerBound].contains(">"),
           html[tagStart.upperBound..<marker.lowerBound].contains("application/json")
            || html[marker.upperBound...].prefix(80).contains("application/json"),
           let open = html[marker.upperBound...].range(of: ">"),
           let close = html[open.upperBound...].range(of: "</script>"),
           let root = try? JSONSerialization.jsonObject(with: Data(html[open.upperBound..<close.lowerBound].utf8)) as? [String: Any],
           let context = root["renderContext"] as? [String: Any] {
            return context
        }
        guard let start = html.range(of: "window.SSR.renderContext=JSON.parse(")?.upperBound, start < html.endIndex,
              html[start] == "\"" else { return nil }
        var end = html.index(after: start)
        while end < html.endIndex {
            if html[end] == "\\" { end = html.index(end, offsetBy: 2, limitedBy: html.endIndex) ?? html.endIndex }
            else if html[end] == "\"" { break }
            else { end = html.index(after: end) }
        }
        guard end < html.endIndex,
              let text = try? JSONSerialization.jsonObject(with: Data(html[start...end].utf8), options: .fragmentsAllowed) as? String else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }
    private static func matchesDates(_ identity: [String: Any], request: Request) -> Bool {
        // A stale or ignored filter must not be presented as a matching search.
        guard identity["date_range_updated"] == nil else { return false }
        guard let dates = request.dates else { return identity["date_range_created"] == nil }
        guard let actual = identity["date_range_created"] as? [String: Any] else { return false }
        return actual["timestamp_start"] as? Int == dates.start && actual["timestamp_end"] as? Int == dates.end
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
        let totals = captures(#"Showing\s+[\d,]+\s*[\-\x{2013}]\s*[\d,]+\s+of\s+([\d,]+)\s+entries"#, in: html)
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
