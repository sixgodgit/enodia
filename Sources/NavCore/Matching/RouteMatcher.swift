import Foundation

/// GPS 点在某条路线上的位置。
public struct RouteMatch: Sendable, Equatable {
    public var routeID: RouteID
    public var segment: Int
    /// 距路线起点的里程（米）；在 lead-in 段上为负。
    public var offset: Double
    /// 到路线的横向距离（米）。
    public var lateral: Double
    /// GPS 航向与路段方向的夹角；速度太低（航向不可信）时为 nil。
    public var headingDelta: Double?
    public var cost: Double
}

public struct MatcherConfig: Sendable {
    /// 横向误差的尺度（米）；实际取 max(它, GPS 精度)。
    public var lateralSigma = 10.0
    public var headingSigma = 30.0
    /// 低于这个速度（m/s）不信 GPS 航向。
    public var minSpeedForCourse = 2.5
    /// 允许的"倒退"（GPS 抖动）；超过就加罚分。
    public var backwardTolerance = 20.0
    public var backwardPenaltyPerMeter = 0.05
    /// 窗口向前看的最小距离（米）。
    public var minLookahead = 150.0
    /// 窗口内最好的结果离路线超过它，就去网格里全局找。
    public var lostSearchRadius = 120.0

    public init() {}
}

/// 路线约束的地图匹配：回答"我在这条路线的哪里、贴合得有多好"。
///
/// 不回答"我在哪条路上"—— 那需要完整路网（路线图第二阶段）。偏航判定看 lateral / headingDelta。
/// 每个点的开销：一个窗口（通常 < 30 个线段）的平面投影，微秒级。
public struct RouteMatcher: Sendable {
    public let config: MatcherConfig
    public private(set) var last: RouteMatch?
    private var lastTimestamp: Date?

    public init(config: MatcherConfig = MatcherConfig()) {
        self.config = config
    }

    public mutating func reset() {
        last = nil
        lastTimestamp = nil
    }

    /// - Parameter leadIn: 允许车在路线起点之前多少米（沿第一段反向延长线）。
    ///   用于预算路线：车还在驶向它的起点时就已经采纳了它。
    public mutating func match(_ fix: LocationFix, on route: Route, leadIn: Double = 0) -> RouteMatch? {
        let frame = LocalFrame(anchor: fix.coordinate)
        let course = fix.reliableCourse(minimumSpeed: config.minSpeedForCourse)
        let sigma = max(config.lateralSigma, fix.horizontalAccuracy)
        let previous = (last?.routeID == route.id) ? last : nil

        var best: RouteMatch?
        if let prev = previous {
            let dt = lastTimestamp.map { max(1, fix.timestamp.timeIntervalSince($0)) } ?? 1
            let travel = (fix.speed ?? 30) * dt
            let lookahead = max(config.minLookahead, travel * 2.5 + 50)
            let lo = max(0, prev.segment - 2)
            var hi = prev.segment
            while hi < route.segmentCount - 1 && route.cumulative[hi + 1] < prev.offset + lookahead { hi += 1 }
            for i in lo...hi {
                best = better(best, evaluate(i, route, frame, course, sigma, prev, leadIn))
            }
        }
        if best == nil || best!.lateral > config.lostSearchRadius {
            let radius = max(config.lostSearchRadius, 3 * fix.horizontalAccuracy)
            for i in route.grid.segments(near: fix.coordinate, radius: radius) {
                best = better(best, evaluate(i, route, frame, course, sigma, nil, leadIn))
            }
            // lead-in 段不在网格里（它在路线起点之前），单独算一次第一段。
            if leadIn > 0 {
                best = better(best, evaluate(0, route, frame, course, sigma, nil, leadIn))
            }
        }

        last = best
        lastTimestamp = fix.timestamp
        return best
    }

    private func better(_ a: RouteMatch?, _ b: RouteMatch) -> RouteMatch {
        guard let a else { return b }
        return b.cost < a.cost ? b : a
    }

    @inline(__always)
    private func evaluate(_ i: Int, _ route: Route, _ frame: LocalFrame, _ course: Double?,
                          _ sigma: Double, _ prev: RouteMatch?, _ leadIn: Double) -> RouteMatch {
        let segLen = route.cumulative[i + 1] - route.cumulative[i]
        let minT = (i == 0 && leadIn > 0 && segLen > 0) ? -leadIn / segLen : 0
        let p = frame.projectAnchor(ontoSegment: route.points[i], route.points[i + 1], minT: minT)
        let offset = route.cumulative[i] + p.t * segLen

        var cost = (p.distance / sigma) * (p.distance / sigma)
        var headingDelta: Double?
        if let c = course {
            let d = Geo.angleBetween(c, route.bearing(ofSegment: i))
            headingDelta = d
            cost += min((d / config.headingSigma) * (d / config.headingSigma), 16)
        }
        if let prev {
            let back = prev.offset - offset
            if back > config.backwardTolerance {
                cost += (back - config.backwardTolerance) * config.backwardPenaltyPerMeter
            }
        }
        return RouteMatch(routeID: route.id, segment: i, offset: offset, lateral: p.distance,
                          headingDelta: headingDelta, cost: cost)
    }
}
