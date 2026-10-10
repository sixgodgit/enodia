import Foundation

public struct RouteID: Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public init(stringLiteral value: String) { raw = value }
    public var description: String { raw }

    public init(from decoder: Decoder) throws { raw = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
}

/// 路线从哪来。决定它被采纳时走哪条规则。
public enum RouteOrigin: String, Sendable, Codable {
    /// 路线服务（高德）正式算出来的主路线。
    case provider
    /// 同一次计算里的备选路线（高德多路线）。偏航时如果车正好开在上面，直接切过去，0 网络等待。
    case alternative
    /// 预算的"错过路口后怎么走"。在接近高速出口/分岔时提前请求。
    case speculative
    /// 本地路网算的（第二阶段，见 README 路线图）。
    case local
}

/// 荷兰道路等级 —— 决定默认限速、车道显示距离、预算重算是否值得。
public enum RoadClass: String, Sendable, Codable, CaseIterable {
    /// autosnelweg（A 号路），白天 06–19 全国上限 100。
    case motorway
    /// autoweg（N 号路中带"autoweg"标志的），默认 100。
    case expressway
    /// 建成区外普通道路，默认 80。
    case rural
    /// 建成区内，默认 50。
    case urban
    /// 30 区。阿姆斯特丹等城市大面积改 30。
    case zone30
    /// woonerf（生活街区），步行速度，按 15 计。
    case woonerf
    case unknown
}

/// 沿路线的一段属性：[start, end) 米。
public struct ValueSpan<Value: Sendable & Equatable>: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var value: Value

    public init(start: Double, end: Double, value: Value) {
        self.start = start
        self.end = end
        self.value = value
    }

    public func contains(_ offset: Double) -> Bool { offset >= start && offset < end }
}

extension ValueSpan: Codable where Value: Codable {}

public enum ManeuverKind: String, Sendable, Codable {
    case depart
    case straight
    case slightLeft, left, sharpLeft
    case slightRight, right, sharpRight
    case uTurn
    /// 高速分岔保持左/右（knooppunt 处常见）。
    case keepLeft, keepRight
    /// 驶出（afrit）。
    case exitLeft, exitRight
    case merge
    case roundabout
    case ferry
    case waypoint
    case arrive

    /// "错过了只能去下一个出口"的那类决策点 —— 值得预算重算。
    public var isHighwayDecision: Bool {
        switch self {
        case .keepLeft, .keepRight, .exitLeft, .exitRight: return true
        default: return false
        }
    }
}

public struct Maneuver: Sendable, Equatable, Codable {
    /// 距路线起点的里程（米）。
    public var offset: Double
    public var kind: ManeuverKind
    /// 动作之后进入的道路名。
    public var roadName: String?
    /// 出口编号（afrit 12）。
    public var exitNumber: String?
    /// 指路牌文字（"Utrecht / A12"）。
    public var signpost: String?
    /// 环岛第几个出口。
    public var roundaboutExit: Int?
    /// 该动作所在道路等级（决定车道显示距离等）。
    public var roadClass: RoadClass?

    public init(offset: Double, kind: ManeuverKind, roadName: String? = nil, exitNumber: String? = nil,
                signpost: String? = nil, roundaboutExit: Int? = nil, roadClass: RoadClass? = nil) {
        self.offset = offset
        self.kind = kind
        self.roadName = roadName
        self.exitNumber = exitNumber
        self.signpost = signpost
        self.roundaboutExit = roundaboutExit
        self.roadClass = roadClass
    }
}

/// 一条不可变的路线。构建（累计里程 + 网格索引）是 O(n)，必须在实时链路之外完成；
/// 之后实时链路里所有查询都是二分或窗口扫描。
public final class Route: Sendable, Identifiable {
    public let id: RouteID
    public let origin: RouteOrigin
    public let points: [Coordinate]
    /// 每个点距起点的里程（米）。
    public let cumulative: [Double]
    public let length: Double
    /// 按 offset 升序。
    public let maneuvers: [Maneuver]
    /// 路线服务给的预计用时（秒）。
    public let expectedDuration: TimeInterval?
    /// 每个点的预计累计用时（秒），有就用它算 ETA，比按里程比例准。
    public let cumulativeTime: [Double]?
    /// 路线服务自带的限速（km/h），按 start 升序、互不重叠。只是融合的一个来源。
    public let providerSpeedLimits: [ValueSpan<Int>]
    public let roadClasses: [ValueSpan<RoadClass>]
    public let createdAt: Date
    let grid: SegmentGrid

    public init(id: RouteID,
                origin: RouteOrigin = .provider,
                points: [Coordinate],
                cumulative: [Double]? = nil,
                maneuvers: [Maneuver] = [],
                expectedDuration: TimeInterval? = nil,
                cumulativeTime: [Double]? = nil,
                providerSpeedLimits: [ValueSpan<Int>] = [],
                roadClasses: [ValueSpan<RoadClass>] = [],
                createdAt: Date = Date()) {
        precondition(points.count >= 2, "route needs at least two points")
        let cum = cumulative ?? Route.cumulativeDistances(points)
        precondition(cum.count == points.count, "cumulative must match points")
        if let t = cumulativeTime { precondition(t.count == points.count, "cumulativeTime must match points") }
        self.id = id
        self.origin = origin
        self.points = points
        self.cumulative = cum
        self.length = cum.last ?? 0
        self.maneuvers = maneuvers.sorted { $0.offset < $1.offset }
        self.expectedDuration = expectedDuration
        self.cumulativeTime = cumulativeTime
        self.providerSpeedLimits = providerSpeedLimits.sorted { $0.start < $1.start }
        self.roadClasses = roadClasses.sorted { $0.start < $1.start }
        self.createdAt = createdAt
        self.grid = SegmentGrid(points: points)
    }

    public static func cumulativeDistances(_ points: [Coordinate]) -> [Double] {
        var out = [Double](repeating: 0, count: points.count)
        for i in 1..<max(1, points.count) {
            out[i] = out[i - 1] + Geo.distance(points[i - 1], points[i])
        }
        return out
    }

    public var segmentCount: Int { points.count - 1 }
    public var start: Coordinate { points[0] }
    public var destination: Coordinate { points[points.count - 1] }

    public func bearing(ofSegment i: Int) -> Double {
        Geo.bearing(points[i], points[i + 1])
    }

    /// offset 落在哪个线段上（二分）。offset < 0 返回 0。
    public func segmentIndex(at offset: Double) -> Int {
        if offset <= 0 { return 0 }
        if offset >= length { return segmentCount - 1 }
        var lo = 0, hi = cumulative.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= offset { lo = mid } else { hi = mid }
        }
        return min(lo, segmentCount - 1)
    }

    /// 路线上某里程处的位置；offset < 0 时沿第一段反向延长（lead-in）。
    public func coordinate(at offset: Double) -> Coordinate {
        let i = segmentIndex(at: offset)
        let segLen = cumulative[i + 1] - cumulative[i]
        guard segLen > 0 else { return points[i] }
        let t = (offset - cumulative[i]) / segLen
        return Geo.interpolate(points[i], points[i + 1], offset < 0 ? t : min(1, t))
    }

    /// offset 之后（不含）的第一个动作。
    public func nextManeuverIndex(after offset: Double) -> Int? {
        var lo = 0, hi = maneuvers.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if maneuvers[mid].offset <= offset { lo = mid + 1 } else { hi = mid }
        }
        return lo < maneuvers.count ? lo : nil
    }

    public func remainingTime(from offset: Double) -> TimeInterval {
        let remaining = max(0, length - offset)
        if let t = cumulativeTime, let total = t.last {
            let i = segmentIndex(at: max(0, offset))
            let segLen = cumulative[i + 1] - cumulative[i]
            let frac = segLen > 0 ? min(1, max(0, (offset - cumulative[i]) / segLen)) : 0
            let elapsed = t[i] + (t[i + 1] - t[i]) * frac
            return max(0, total - elapsed)
        }
        if let d = expectedDuration, length > 0 { return d * remaining / length }
        return remaining / 13.9   // 没有任何时间信息时按 50 km/h 估
    }

    public func roadClass(at offset: Double) -> RoadClass? {
        Route.span(in: roadClasses, at: offset)?.value
    }

    public func providerSpeedLimit(at offset: Double) -> Int? {
        Route.span(in: providerSpeedLimits, at: offset)?.value
    }

    /// 在按 start 升序、互不重叠的 spans 里找覆盖 offset 的那段（二分）。
    public static func span<V>(in spans: [ValueSpan<V>], at offset: Double) -> ValueSpan<V>? {
        var lo = 0, hi = spans.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if spans[mid].start <= offset { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return nil }
        let s = spans[lo - 1]
        return s.contains(offset) ? s : nil
    }
}
