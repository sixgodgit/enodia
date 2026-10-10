import Foundation

/// 实时交通事件（事故 / 施工 / 封路 / 车道关闭 …）。
///
/// JSON 形状即 NDW 中继的 v1 契约，样例见 `contracts/ndw-events.v1.example.json`；
/// Swift 与 Python 两边的测试读同一份样例。
public struct TrafficEvent: Sendable, Equatable, Identifiable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case accident
        case roadworks
        /// 整条道路/行车道封闭 —— 路线上出现它就该重算。
        case closure
        case laneClosure = "lane_closure"
        case congestion
        case hazard
        /// 开合桥（brugopening）—— 荷兰特有的"临时封路"。
        case bridgeOpening = "bridge_opening"
        case weather
        case other
    }

    public enum Severity: String, Sendable, Codable, Comparable {
        case unknown, low, medium, high

        private var rank: Int {
            switch self { case .unknown: 0; case .low: 1; case .medium: 2; case .high: 3 }
        }
        public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
    }

    public var id: String
    public var kind: Kind
    public var severity: Severity
    /// 道路编号（"A2"、"N201"）。
    public var road: String?
    /// 按行驶方向排列（DATEX II 线性位置的 from → to）；点事件只有一个点。
    public var geometry: [Coordinate]
    /// DATEX II 车道标识原样保留："lane1"、"hardShoulder"、"rushHourLane" …
    /// 怎么对到屏幕上的第几条车道由 LaneClosureFusion 决定，这里不猜。
    public var closedLanes: [String]
    public var lanesRestricted: Int?
    public var start: Date?
    public var end: Date?
    public var updated: Date?
    public var text: String?
    public var source: String

    public init(id: String, kind: Kind, severity: Severity = .unknown, road: String? = nil,
                geometry: [Coordinate], closedLanes: [String] = [], lanesRestricted: Int? = nil,
                start: Date? = nil, end: Date? = nil, updated: Date? = nil, text: String? = nil,
                source: String = "ndw") {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.road = road
        self.geometry = geometry
        self.closedLanes = closedLanes
        self.lanesRestricted = lanesRestricted
        self.start = start
        self.end = end
        self.updated = updated
        self.text = text
        self.source = source
    }

    /// 路线经过它就必须换路。
    public var blocksRoute: Bool { kind == .closure || kind == .bridgeOpening }

    public func isActive(at date: Date) -> Bool {
        if let s = start, s > date { return false }
        if let e = end, e < date { return false }
        return true
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, severity, road, geometry, start, end, updated, text, source
        case closedLanes = "closed_lanes"
        case lanesRestricted = "lanes_restricted"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        // 未知类型不报错：中继先升级、App 后升级时，新类型按 other 显示。
        kind = Kind(rawValue: try c.decode(String.self, forKey: .kind)) ?? .other
        severity = Severity(rawValue: try c.decodeIfPresent(String.self, forKey: .severity) ?? "") ?? .unknown
        road = try c.decodeIfPresent(String.self, forKey: .road)
        let pairs = try c.decode([[Double]].self, forKey: .geometry)
        geometry = try pairs.map { p in
            guard p.count == 2 else {
                throw DecodingError.dataCorruptedError(forKey: .geometry, in: c,
                                                       debugDescription: "geometry point must be [lat, lon]")
            }
            return Coordinate(p[0], p[1])
        }
        closedLanes = try c.decodeIfPresent([String].self, forKey: .closedLanes) ?? []
        lanesRestricted = try c.decodeIfPresent(Int.self, forKey: .lanesRestricted)
        start = try ISO8601.decode(c, .start)
        end = try ISO8601.decode(c, .end)
        updated = try ISO8601.decode(c, .updated)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "ndw"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind.rawValue, forKey: .kind)
        try c.encode(severity.rawValue, forKey: .severity)
        try c.encodeIfPresent(road, forKey: .road)
        try c.encode(geometry.map { [$0.latitude, $0.longitude] }, forKey: .geometry)
        try c.encode(closedLanes, forKey: .closedLanes)
        try c.encodeIfPresent(lanesRestricted, forKey: .lanesRestricted)
        try c.encodeIfPresent(start.map(ISO8601.string), forKey: .start)
        try c.encodeIfPresent(end.map(ISO8601.string), forKey: .end)
        try c.encodeIfPresent(updated.map(ISO8601.string), forKey: .updated)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encode(source, forKey: .source)
    }
}

/// ISO-8601 解析：带不带小数秒都接受（NDW 两种都出现过）。
public enum ISO8601 {
    public static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    public static func string(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    static func decode<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> Date? {
        guard let s = try c.decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let d = parse(s) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "bad ISO-8601 date: \(s)")
        }
        return d
    }
}
