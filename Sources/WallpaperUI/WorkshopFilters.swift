import Foundation

// These values are Steam's declared Wallpaper Engine tags, not inferred ratings.
protocol WorkshopFilterChoice: RawRepresentable, CaseIterable, Hashable where RawValue == String {
    var label: String { get }
}

struct WorkshopFilters: Codable, Equatable, Sendable {
    enum Age: String, Codable, WorkshopFilterChoice, Sendable {
        case all = "", everyone = "Everyone", questionable = "Questionable", mature = "Mature"
        var label: String {
            switch self { case .all: "全部年龄"; case .everyone: "全年龄"; case .questionable: "有争议内容"; case .mature: "成人内容" }
        }
    }
    enum Kind: String, Codable, WorkshopFilterChoice, Sendable {
        case all = "", scene = "Scene", video = "Video", web = "Web", application = "Application"
        var label: String {
            switch self { case .all: "全部类型"; case .scene: "场景"; case .video: "视频"; case .web: "网页"; case .application: "应用程序" }
        }
    }
    enum Genre: String, Codable, WorkshopFilterChoice, Sendable {
        case all = "", abstract = "Abstract", animal = "Animal", anime = "Anime", cartoon = "Cartoon", cgi = "CGI"
        case cyberpunk = "Cyberpunk", fantasy = "Fantasy", game = "Game", girls = "Girls", guys = "Guys", landscape = "Landscape"
        case medieval = "Medieval", memes = "Memes", mmd = "MMD", music = "Music", nature = "Nature", pixel = "Pixel art"
        case relaxing = "Relaxing", retro = "Retro", sciFi = "Sci-Fi", sports = "Sports", technology = "Technology"
        case television = "Television", vehicle = "Vehicle", unspecified = "Unspecified"
        var label: String {
            switch self {
            case .all: "全部题材"; case .abstract: "抽象"; case .animal: "动物"; case .anime: "动漫"; case .cartoon: "卡通"
            case .cgi: "CGI"; case .cyberpunk: "赛博朋克"; case .fantasy: "奇幻"; case .game: "游戏"; case .girls: "女性角色"
            case .guys: "男性角色"; case .landscape: "风景"; case .medieval: "中世纪"; case .memes: "趣味梗图"; case .mmd: "MMD"
            case .music: "音乐"; case .nature: "自然"; case .pixel: "像素艺术"; case .relaxing: "放松"; case .retro: "复古"
            case .sciFi: "科幻"; case .sports: "运动"; case .technology: "科技"; case .television: "影视"; case .vehicle: "交通工具"
            case .unspecified: "未分类"
            }
        }
    }
    enum Sort: String, Codable, WorkshopFilterChoice, Sendable {
        case relevance = "textsearch", latest = "mostrecent", popular = "trend", subscribers = "totaluniquesubscribers"
        var label: String {
            switch self { case .relevance: "默认排序"; case .latest: "最新发布"; case .popular: "最热门"; case .subscribers: "最多人订阅" }
        }
    }
    enum Period: String, Codable, WorkshopFilterChoice, Sendable {
        case all, week, month, year, custom
        var label: String {
            switch self { case .all: "不限日期"; case .week: "最近一周"; case .month: "最近一个月"; case .year: "最近一年"; case .custom: "自定义日期" }
        }
    }
    var age: Age = .all
    var kind: Kind = .all
    var genres: Set<Genre> = []
    var sort: Sort = .relevance
    var period: Period = .all
    var startDate: Date = Calendar.current.startOfDay(for: Date())
    var endDate: Date = Calendar.current.startOfDay(for: Date())
    var selectedGenres: [Genre] { Genre.allCases.filter { $0 != .all && genres.contains($0) } }
    var requiredTags: [String] { ([age.rawValue, kind.rawValue] + selectedGenres.map(\.rawValue)).filter { !$0.isEmpty } }
    var isDefault: Bool { age == .all && kind == .all && selectedGenres.isEmpty && sort == .relevance && period == .all }
    var validDates: Bool { period != .custom || Calendar.current.startOfDay(for: startDate) <= Calendar.current.startOfDay(for: endDate) }
    func browseSort(query: String) -> String { sort == .relevance && query.isEmpty ? Sort.popular.rawValue : sort.rawValue }

    struct DateRange: Equatable, Sendable { let start: Int; let end: Int }
    func dateRange(now: Date, calendar: Calendar = .current) -> DateRange? {
        guard period != .all else { return nil }
        let start: Date
        let end = calendar.startOfDay(for: period == .custom ? endDate : now)
        switch period {
        case .week: start = calendar.date(byAdding: .day, value: -6, to: end)!
        case .month: start = calendar.date(byAdding: .month, value: -1, to: end)!
        case .year: start = calendar.date(byAdding: .year, value: -1, to: end)!
        case .custom: start = calendar.startOfDay(for: startDate)
        case .all: return nil
        }
        // Calendar arithmetic includes the full end date, including DST transitions.
        return DateRange(start: Int(start.timeIntervalSince1970), end: Int(calendar.date(byAdding: .day, value: 1, to: end)!.timeIntervalSince1970) - 1)
    }

    static func classification(tags: [String]) -> [String] {
        let normalized = Set(tags.map { $0.lowercased() })
        // Preserve the more restrictive declared tag when an author supplies several.
        let age = [Age.mature, .questionable, .everyone].first { normalized.contains($0.rawValue.lowercased()) }
        let kind = Kind.allCases.first { $0 != .all && normalized.contains($0.rawValue.lowercased()) }
        return [age?.label ?? "年龄未标注", kind?.label ?? "类型未标注"]
    }
    static func supportsPlayback(tags: [String]) -> Bool {
        !tags.contains { ["web", "application"].contains($0.lowercased()) }
    }
}

extension WorkshopFilters {
    private enum CodingKeys: String, CodingKey { case age, kind, genre, genres, sort, period, startDate, endDate }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        age = try values.decodeIfPresent(Age.self, forKey: .age) ?? .all
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .all
        sort = try values.decodeIfPresent(Sort.self, forKey: .sort) ?? .relevance
        period = try values.decodeIfPresent(Period.self, forKey: .period) ?? .all
        startDate = try values.decodeIfPresent(Date.self, forKey: .startDate) ?? startDate
        endDate = try values.decodeIfPresent(Date.self, forKey: .endDate) ?? endDate
        // The new empty array deliberately overrides a retained legacy single value.
        let raw = try values.decodeIfPresent([String].self, forKey: .genres)
            ?? values.decodeIfPresent(String.self, forKey: .genre).map { [$0] } ?? []
        genres = Set(raw.compactMap(Genre.init(rawValue:)).filter { $0 != .all })
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(age, forKey: .age); try values.encode(kind, forKey: .kind)
        try values.encode(selectedGenres.map(\.rawValue), forKey: .genres)
        try values.encode(sort, forKey: .sort); try values.encode(period, forKey: .period)
        try values.encode(startDate, forKey: .startDate); try values.encode(endDate, forKey: .endDate)
    }
}
