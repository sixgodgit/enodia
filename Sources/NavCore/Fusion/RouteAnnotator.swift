import Foundation

/// 官方静态限速的一段（RWS 道路特征库 / NDW 交通标志库，经中继下发）。几何按行驶方向排列。
public struct SpeedLimitSegment: Sendable, Equatable, Codable {
    public var id: String
    public var geometry: [Coordinate]
    public var kmh: Int
    public var schedule: TimeWindow?
    public var observedAt: Date

    public init(id: String, geometry: [Coordinate], kmh: Int, schedule: TimeWindow? = nil, observedAt: Date) {
        self.id = id
        self.geometry = geometry
        self.kmh = kmh
        self.schedule = schedule
        self.observedAt = observedAt
    }
}

/// 一段路在行驶方向上的车道数（OSM `lanes` / RWS 道路特征库，经中继下发）。几何按行驶方向排列。
public struct LaneCountSegment: Sendable, Equatable, Codable {
    public var id: String
    public var geometry: [Coordinate]
    public var lanes: Int

    public init(id: String, geometry: [Coordinate], lanes: Int) {
        self.id = id
        self.geometry = geometry
        self.lanes = lanes
    }

    enum CodingKeys: String, CodingKey { case id, geometry, lanes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        lanes = try c.decode(Int.self, forKey: .lanes)
        geometry = try c.decode([[Double]].self, forKey: .geometry).compactMap { $0.count == 2 ? Coordinate($0[0], $0[1]) : nil }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(lanes, forKey: .lanes)
        try c.encode(geometry.map { [$0.latitude, $0.longitude] }, forKey: .geometry)
    }
}

public struct RouteEvent: Sendable, Equatable {
    public var event: TrafficEvent
    public var startOffset: Double
    public var endOffset: Double
    public var confidence: Double
    /// 方向核实过（线性事件，几何顺序与路线一致）。点事件无法区分双向车道，为 false。
    public var directionVerified: Bool
}

public struct RouteSpeedLimit: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var observation: SpeedLimitObservation
}

public struct RouteGantry: Sendable, Equatable {
    public var offset: Double
    public var gantry: SignalGantry
}

/// 某条路线上的"沿途信息"。由 RouteAnnotator 在实时链路之外算好，实时链路只按里程查。
public struct RouteAnnotations: Sendable {
    public var routeID: RouteID
    /// 按 startOffset 升序。
    public var events: [RouteEvent]
    public var speedLimits: [RouteSpeedLimit]
    /// 按 offset 升序。
    public var gantries: [RouteGantry]
    /// 沿路线的车道数，按 start 升序、互不重叠。
    public var laneCounts: [ValueSpan<Int>]
    public var generatedAt: Date

    public init(routeID: RouteID, events: [RouteEvent] = [], speedLimits: [RouteSpeedLimit] = [],
                gantries: [RouteGantry] = [], laneCounts: [ValueSpan<Int>] = [], generatedAt: Date) {
        self.routeID = routeID
        self.events = events.sorted { $0.startOffset < $1.startOffset }
        self.speedLimits = speedLimits.sorted { $0.start < $1.start }
        self.gantries = gantries.sorted { $0.offset < $1.offset }
        self.laneCounts = laneCounts.sorted { $0.start < $1.start }
        self.generatedAt = generatedAt
    }
}

/// 把带地理坐标的外部数据（NDW 事件、官方限速、矩阵牌门架）投影到路线里程上。
///
/// 这是重活（每条数据都要找最近线段），所以只在"路线变了"或"数据更新了"时在后台跑一遍；
/// 结果交给 NavigationEngine.updateAnnotations。
///
/// 方向是关键：高速双向车道中心线只隔几十米，对向的事故不能报给你。
/// 线性数据用几何顺序判方向；门架必须带方位角；点事件判不了方向，只给中等把握并标注。
public struct RouteAnnotator: Sendable {
    public var pointRadius = 20.0
    public var linearRadius = 35.0
    public var gantryRadius = 30.0
    public var maxHeadingDelta = 45.0

    public init() {}

    public func annotate(route: Route, events: [TrafficEvent] = [], speedLimits: [SpeedLimitSegment] = [],
                         gantries: [SignalGantry] = [], laneCounts: [LaneCountSegment] = [],
                         now: Date) -> RouteAnnotations {
        RouteAnnotations(
            routeID: route.id,
            events: events.filter { $0.isActive(at: now) }.compactMap { project($0, onto: route) },
            speedLimits: speedLimits.compactMap { project($0, onto: route) },
            gantries: gantries.compactMap { project($0, onto: route) },
            laneCounts: project(laneCounts, onto: route),
            generatedAt: now)
    }

    /// 车道数段 → 路线上互不重叠的区间（方向必须一致；重叠时后开始的覆盖先开始的）。
    func project(_ segments: [LaneCountSegment], onto route: Route) -> [ValueSpan<Int>] {
        let spans = segments.compactMap { seg -> ValueSpan<Int>? in
            guard seg.lanes >= 1, seg.geometry.count >= 2, let span = projectLinear(seg.geometry, onto: route),
                  span.end > span.start else { return nil }
            return ValueSpan(start: span.start, end: span.end, value: seg.lanes)
        }.sorted { $0.start < $1.start }
        var out: [ValueSpan<Int>] = []
        for s in spans {
            if var last = out.last, last.end > s.start {
                last.end = s.start
                out[out.count - 1] = last
                if last.end <= last.start { out.removeLast() }
            }
            if let last = out.last, last.value == s.value, abs(last.end - s.start) < 1 {
                out[out.count - 1].end = max(last.end, s.end)
            } else {
                out.append(s)
            }
        }
        return out
    }

    func project(_ event: TrafficEvent, onto route: Route) -> RouteEvent? {
        guard !event.geometry.isEmpty else { return nil }
        if event.geometry.count == 1 {
            guard let m = nearest(on: route, to: event.geometry[0], radius: pointRadius) else { return nil }
            return RouteEvent(event: event, startOffset: m.offset, endOffset: m.offset, confidence: 0.6,
                              directionVerified: false)
        }
        guard let span = projectLinear(event.geometry, onto: route) else { return nil }
        return RouteEvent(event: event, startOffset: span.start, endOffset: span.end, confidence: span.confidence,
                          directionVerified: true)
    }

    func project(_ segment: SpeedLimitSegment, onto route: Route) -> RouteSpeedLimit? {
        guard segment.geometry.count >= 2, let span = projectLinear(segment.geometry, onto: route),
              span.end > span.start else { return nil }
        let obs = SpeedLimitObservation(source: .officialStatic, kmh: segment.kmh, schedule: segment.schedule,
                                        observedAt: segment.observedAt, matchConfidence: span.confidence)
        return RouteSpeedLimit(start: span.start, end: span.end, observation: obs)
    }

    func project(_ gantry: SignalGantry, onto route: Route) -> RouteGantry? {
        guard let bearing = gantry.bearing,
              let m = nearest(on: route, to: gantry.location, radius: gantryRadius),
              Geo.angleBetween(bearing, route.bearing(ofSegment: m.segment)) <= maxHeadingDelta
        else { return nil }
        return RouteGantry(offset: m.offset, gantry: gantry)
    }

    /// 线性几何 → 路线上的 [start, end]。顶点按行驶方向排列；匹配上的顶点里程必须递增，否则是对向。
    private func projectLinear(_ geometry: [Coordinate], onto route: Route)
        -> (start: Double, end: Double, confidence: Double)? {
        var matched: [(index: Int, offset: Double, segment: Int)] = []
        for (i, p) in geometry.enumerated() {
            if let m = nearest(on: route, to: p, radius: linearRadius) {
                matched.append((i, m.offset, m.segment))
            }
        }
        guard let first = matched.first else { return nil }
        let coverage = Double(matched.count) / Double(geometry.count)

        if matched.count >= 2 {
            let last = matched[matched.count - 1]
            guard last.offset > first.offset else { return nil }   // 顺序反了：对向车道
            return (first.offset, last.offset, 0.6 + 0.35 * coverage)
        }

        // 只有一个顶点落在路线上：用相邻顶点连线的方向核对。
        let i = first.index
        let (a, b) = i + 1 < geometry.count ? (geometry[i], geometry[i + 1]) : (geometry[i - 1], geometry[i])
        guard Geo.angleBetween(Geo.bearing(a, b), route.bearing(ofSegment: first.segment)) <= 60 else { return nil }
        return (first.offset, first.offset, 0.55)
    }

    private func nearest(on route: Route, to p: Coordinate, radius: Double) -> (segment: Int, offset: Double)? {
        let frame = LocalFrame(anchor: p)
        var best: (segment: Int, offset: Double, distance: Double)?
        for i in route.grid.segments(near: p, radius: radius) {
            let proj = frame.projectAnchor(ontoSegment: route.points[i], route.points[i + 1])
            guard proj.distance <= radius else { continue }
            if best == nil || proj.distance < best!.distance {
                let segLen = route.cumulative[i + 1] - route.cumulative[i]
                best = (i, route.cumulative[i] + proj.t * segLen, proj.distance)
            }
        }
        return best.map { ($0.segment, $0.offset) }
    }
}
