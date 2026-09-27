import Foundation

@main struct WorkshopFilterChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); count += 1; print("PASS: " + message) }
        func rejects(_ message: String, _ block: () throws -> Void) {
            do { try block(); fatalError(message) } catch { check(true, message) }
        }
        func html(_ request: WorkshopBrowse.Request, page: Int = 1, tags: [String]? = nil, sort: String? = nil, dates: WorkshopFilters.DateRange? = nil) throws -> String {
            var key: [String: Any] = ["appid": 431960, "page": page, "search_text": request.query, "browse_sort": sort ?? request.sort,
                                      "required_tags": tags ?? request.tags, "trend_days": 7]
            if let range = dates ?? request.dates { key["date_range_created"] = ["timestamp_start": range.start, "timestamp_end": range.end] }
            let data: [String: Any] = ["eresult": 1, "current_page": page, "total_count": 0, "total_pages": 0, "results": []]
            let q = String(decoding: try JSONSerialization.data(withJSONObject: ["queries": [["queryKey": ["workshop_browse", key], "state": ["data": data]]]]), as: UTF8.self)
            let context = String(decoding: try JSONSerialization.data(withJSONObject: ["queryData": q]), as: UTF8.self)
            let literal = String(decoding: try JSONSerialization.data(withJSONObject: context, options: .fragmentsAllowed), as: UTF8.self)
            return "window.SSR.renderContext=JSON.parse(\(literal))"
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        var filters = WorkshopFilters(age: .everyone, kind: .scene, genre: .nature, sort: .subscribers, period: .custom, startDate: date, endDate: date)
        let request = WorkshopBrowse.Request(query: "雪 & p=5", filters: filters, now: date, calendar: calendar)
        let url = WorkshopBrowse.url(request: request, page: 2)
        let args = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        check(args.filter { $0.name == "requiredtags[]" }.compactMap(\.value) == ["Everyone", "Scene", "Nature"], "independent categories combined as three required tags")
        check(args.filter { $0.name == "p" }.map(\.value) == ["2"], "query input cannot inject page or filters")
        check(args.first { $0.name == "browsesort" }?.value == "totaluniquesubscribers", "most subscribed uses Steam global sort")
        check(args.first { $0.name == "created_date_range_filter_start" }?.value == String(request.dates!.start), "date bounds sent to server")
        check(request.dates!.end - request.dates!.start + 1 == 23 * 3600, "custom date includes entire DST-short day")
        check(try WorkshopBrowse.decode(html(request, tags: request.tags.reversed()), request: request, page: 1).total == 0, "tag ordering irrelevant when validating response")
        rejects("ignored age filter cannot pass as filtered result") { _ = try WorkshopBrowse.decode(html(request, tags: ["Scene", "Nature"]), request: request, page: 1) }
        rejects("stale sort rejected") { _ = try WorkshopBrowse.decode(html(request, sort: "mostrecent"), request: request, page: 1) }
        rejects("stale dates rejected") { _ = try WorkshopBrowse.decode(html(request, dates: .init(start: 1, end: 2)), request: request, page: 1) }
        rejects("unexpected date restriction rejected") { _ = try WorkshopBrowse.decode(html(request), request: .init(query: request.query, filters: .init(age: .everyone, kind: .scene, genre: .nature, sort: .subscribers)), page: 1) }
        for sort in WorkshopFilters.Sort.allCases {
            filters.sort = sort
            let current = WorkshopBrowse.Request(query: "mountain", filters: filters)
            check(current.sort == sort.rawValue, "keyword remains compatible with sort " + sort.rawValue)
        }
        check(WorkshopBrowse.Request(query: "").sort == "trend", "empty default search browses popular wallpapers")
        filters.period = .week
        check(filters.dateRange(now: date, calendar: calendar)!.start == Int(calendar.date(byAdding: .day, value: -6, to: date)!.timeIntervalSince1970), "last week includes today plus six calendar days")
        filters.period = .all
        check(filters.dateRange(now: date) == nil, "unlimited date emits no date restriction")
        filters.period = .custom; filters.startDate = date.addingTimeInterval(86400)
        check(!filters.validDates, "inverted date interval rejected")
        check(WorkshopFilters.classification(tags: ["everyone", "Mature", "Scene"]) == ["成人内容", "场景"], "author's stricter declared age wins")
        check(WorkshopFilters.classification(tags: []) == ["年龄未标注", "类型未标注"], "missing tags are not inferred as safe for all ages")
        check(!WorkshopFilters.supportsPlayback(tags: ["Web"]) && !WorkshopFilters.supportsPlayback(tags: ["application"]), "unsupported types can browse without claiming playback")

        let suite = "WorkshopFilters-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls: [(WorkshopBrowse.Request, Int)] = []
        var delay = false, fail = false
        let model = WorkshopModel(defaults: defaults, browse: { request, page in
            calls.append((request, page))
            if delay { try? await Task.sleep(for: .milliseconds(80)) }
            if fail { throw WorkshopFailure.network }
            return .init(items: [], number: page, pages: 3, total: 70)
        })
        func idle() async throws {
            let deadline = Date().addingTimeInterval(3)
            while model.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            precondition(!model.busy, "bounded search completion")
        }
        model.searchText = " mountain "; model.search(); try await idle()
        model.searchText = "unsubmitted edit"; model.search(page: 2); try await idle(); model.search(page: 1); try await idle()
        check(calls.map { $0.0.query } == ["mountain", "mountain", "mountain"], "both next and previous pages preserve submitted text")
        check(calls.map { $0.1 } == [1, 2, 1], "paging supports return to first page")
        var selected = WorkshopFilters(age: .everyone, kind: .scene, genre: .nature, sort: .latest, period: .week)
        model.setFilters(selected)
        check(model.searchPage == nil && model.busy, "new filters immediately remove stale results")
        try await idle()
        check(calls.last!.1 == 1 && calls.last!.0.tags == selected.requiredTags, "filter changes restart at page one")
        let snapshot = calls.last!.0; model.search(page: 2); try await idle()
        check(calls.last!.0 == snapshot, "pagination retains exact date snapshot and filters")
        check(WorkshopModel(defaults: defaults).filters == selected, "filters persist across model restart")
        selected.period = .custom; selected.startDate = date; selected.endDate = date
        model.setFilters(selected)
        check(!model.busy && model.searchPage == nil, "custom dates wait for explicit apply")
        selected.startDate = date.addingTimeInterval(86400); model.setFilters(selected); model.search()
        check(!model.busy, "invalid date range never starts a request")
        selected.startDate = date; model.setFilters(selected); delay = true; model.search()
        model.setFilters(.init())
        check(model.filters == selected, "busy request cannot mutate filters underneath result")
        model.cancel(); try await idle()
        check(model.searchPage == nil && model.error == nil, "late response from cancelled request cannot publish")
        delay = false; fail = true; model.search(); try await idle()
        check(model.searchPage == nil && model.error != nil, "failed new search cannot show old filter results")
        fail = false; model.setFilters(.init()); try await idle()
        check(model.filters.isDefault && calls.last!.0.tags.isEmpty && calls.last!.0.dates == nil, "reset clears categories and dates")
        let previousCalls = calls.count; model.search(page: 0); model.search(page: 4)
        check(calls.count == previousCalls, "out-of-range pages blocked")
        defaults.set(Data("{broken}".utf8), forKey: "workshopBrowseFilters")
        check(WorkshopModel(defaults: defaults).filters.isDefault, "invalid stored filters recover to defaults")

        if CommandLine.arguments.contains("--live") {
            var live = WorkshopFilters(age: .everyone, kind: .scene, genre: .nature)
            for sort in [WorkshopFilters.Sort.latest, .popular, .subscribers] {
                live.sort = sort
                let query = WorkshopBrowse.Request(query: "mountain", filters: live)
                let first = try await WorkshopBrowse.fetch(request: query, page: 1)
                check(!first.items.isEmpty && first.pages > 1, "live combined tags and " + sort.rawValue)
                check(first.items.allSatisfy { Set($0.tags).isSuperset(of: Set(live.requiredTags)) }, "live result tags satisfy all three selections")
                if sort == .subscribers {
                    let second = try await WorkshopBrowse.fetch(request: query, page: 2)
                    check(second.number == 2 && Set(first.items.map(\.id)) != Set(second.items.map(\.id)), "live sorted filters survive pagination")
                }
            }
            live.period = .custom; live.sort = .latest
            live.startDate = ISO8601DateFormatter().date(from: "2025-01-01T00:00:00Z")!
            live.endDate = ISO8601DateFormatter().date(from: "2025-12-31T00:00:00Z")!
            let dated = try await WorkshopBrowse.fetch(request: .init(query: "mountain", filters: live), page: 1)
            check(!dated.items.isEmpty, "live Steam acknowledges exact custom creation bounds")
        }
        print("\(count) Workshop filter checks passed")
    }
}
