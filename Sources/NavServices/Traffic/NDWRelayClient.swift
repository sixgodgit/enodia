import Foundation
import NavCore

/// NDW 中继的一页事件（契约：contracts/ndw-events.v1.example.json）。
public struct EventsPage: Sendable, Decodable {
    public struct FeedStatus: Sendable, Decodable, Equatable {
        public var fetchedAt: Date?
        public var ageSeconds: Double?
        public var stale: Bool

        enum CodingKeys: String, CodingKey {
            case stale
            case fetchedAt = "fetched_at"
            case ageSeconds = "age_s"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fetchedAt = try ISO8601.decodeIfPresent(c, .fetchedAt)
            ageSeconds = try c.decodeIfPresent(Double.self, forKey: .ageSeconds)
            stale = try c.decodeIfPresent(Bool.self, forKey: .stale) ?? false
        }
    }

    public var version: Int
    /// true = 完整快照，客户端应替换；false = 自 since 以来的增量。
    public var full: Bool
    public var events: [TrafficEvent]
    public var removed: [String]
    public var feeds: [String: FeedStatus]

    enum CodingKeys: String, CodingKey { case version, full, events, removed, feeds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        full = try c.decodeIfPresent(Bool.self, forKey: .full) ?? true
        events = try c.decode([TrafficEvent].self, forKey: .events)
        removed = try c.decodeIfPresent([String].self, forKey: .removed) ?? []
        feeds = try c.decodeIfPresent([String: FeedStatus].self, forKey: .feeds) ?? [:]
    }
}

extension ISO8601 {
    static func decodeIfPresent<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> Date? {
        guard let s = try c.decodeIfPresent(String.self, forKey: key) else { return nil }
        return parse(s)
    }
}

/// 拉中继、维护本地事件集合（增量合并）。拉取失败就保留上一次的数据 —— 旧事件好过没有事件，
/// 但调用方能从 `lastSuccess` 看出数据有多旧。
public actor NDWEventFeed {
    public private(set) var events: [String: TrafficEvent] = [:]
    public private(set) var version: Int?
    public private(set) var lastSuccess: Date?
    public private(set) var feeds: [String: EventsPage.FeedStatus] = [:]

    private let client: NDWRelayClient

    public init(client: NDWRelayClient) {
        self.client = client
    }

    /// 拉一次。bbox 换了（换路线）时传 reset: true，强制完整快照。
    @discardableResult
    public func refresh(bbox: BoundingBox, reset: Bool = false, now: Date = Date()) async throws -> [TrafficEvent] {
        let page = try await client.fetch(bbox: bbox, since: reset ? nil : version)
        apply(page, now: now)
        return Array(events.values)
    }

    public func apply(_ page: EventsPage, now: Date = Date()) {
        if page.full { events = [:] }
        for id in page.removed { events[id] = nil }
        for e in page.events { events[e.id] = e }
        version = page.version
        feeds = page.feeds
        lastSuccess = now
    }
}

public struct NDWRelayClient: Sendable {
    public var baseURL: URL
    public var timeout: TimeInterval
    private let http: any HTTPClient

    public init(baseURL: URL, http: any HTTPClient = URLSessionHTTPClient(), timeout: TimeInterval = 8) {
        self.baseURL = baseURL
        self.http = http
        self.timeout = timeout
    }

    /// GET /v1/events?bbox=min_lat,min_lon,max_lat,max_lon[&since=N]
    public func url(bbox: BoundingBox, since: Int?) -> URL {
        var c = URLComponents(url: baseURL.appendingPathComponent("v1/events"), resolvingAgainstBaseURL: false)!
        let box = [bbox.minLatitude, bbox.minLongitude, bbox.maxLatitude, bbox.maxLongitude]
            .map { String(format: "%.5f", $0) }.joined(separator: ",")
        c.queryItems = [URLQueryItem(name: "bbox", value: box)] + (since.map { [URLQueryItem(name: "since", value: String($0))] } ?? [])
        return c.url!
    }

    public func fetch(bbox: BoundingBox, since: Int?) async throws -> EventsPage {
        let (data, status) = try await http.get(url(bbox: bbox, since: since), timeout: timeout)
        guard status == 200 else { throw HTTPStatusError(status: status) }
        return try JSONDecoder().decode(EventsPage.self, from: data)
    }
}
