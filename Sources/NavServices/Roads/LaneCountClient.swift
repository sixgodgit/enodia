import Foundation
import NavCore

/// 中继 `/v1/lanes` 的一页（契约：contracts/lane-counts.v1.example.json）。
public struct LaneCountsPage: Sendable, Decodable {
    public struct Tiles: Sendable, Decodable, Equatable {
        public var cached: Int
        public var fetched: Int
        public var failed: Int
    }

    public var segments: [LaneCountSegment]
    public var tiles: Tiles?
}

/// 取沿途车道数（OSM `lanes`，经中继按瓦片缓存）。车道定位只在知道车道数的路段工作。
/// 一条路线取一次就够：车道数几乎不变，中继那边缓存 7 天。
public struct LaneCountClient: Sendable {
    public var baseURL: URL
    public var timeout: TimeInterval
    private let http: any HTTPClient

    public init(baseURL: URL, http: any HTTPClient = URLSessionHTTPClient(), timeout: TimeInterval = 60) {
        self.baseURL = baseURL
        self.http = http
        self.timeout = timeout
    }

    /// GET /v1/lanes?bbox=min_lat,min_lon,max_lat,max_lon
    public func url(bbox: BoundingBox) -> URL {
        var c = URLComponents(url: baseURL.appendingPathComponent("v1/lanes"), resolvingAgainstBaseURL: false)!
        let box = [bbox.minLatitude, bbox.minLongitude, bbox.maxLatitude, bbox.maxLongitude]
            .map { String(format: "%.5f", $0) }.joined(separator: ",")
        c.queryItems = [URLQueryItem(name: "bbox", value: box)]
        return c.url!
    }

    public func fetch(bbox: BoundingBox) async throws -> LaneCountsPage {
        let (data, status) = try await http.get(url(bbox: bbox), timeout: timeout)
        guard status == 200 else { throw HTTPStatusError(status: status) }
        return try JSONDecoder().decode(LaneCountsPage.self, from: data)
    }
}
