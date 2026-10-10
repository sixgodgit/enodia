import Foundation

// JEV ↔ Navigation Core 的契约。
//
// JEV 是策略层：回答"该走哪条路"。它可以慢（秒级、几十秒级都行），可以离线，可以挂掉；
// 核心永远不等它。JEV 的建议是一条带有效期的消息，核心在"安全点"（离下一个动作足够远、
// 没在重算、近期没换过路线）才执行，过期就丢。
//
// JEV 从不碰定位、车道、偏航 —— 那是核心的事。
// JSON 样例：contracts/jev-advice.v1.example.json、contracts/jev-telemetry.v1.example.json

public struct RoutingPreferences: Sendable, Equatable, Codable {
    public var avoidTolls: Bool
    public var avoidFerries: Bool
    public var avoidMotorways: Bool
    /// 道路编号，例如 ["A10"]。
    public var avoidRoads: [String]
    public var avoidAreas: [BoundingBox]
    /// 避开环保区（milieuzone）—— 柴油车/老车进城前要看。
    public var avoidEnvironmentalZones: Bool

    public init(avoidTolls: Bool = false, avoidFerries: Bool = false, avoidMotorways: Bool = false,
                avoidRoads: [String] = [], avoidAreas: [BoundingBox] = [], avoidEnvironmentalZones: Bool = false) {
        self.avoidTolls = avoidTolls
        self.avoidFerries = avoidFerries
        self.avoidMotorways = avoidMotorways
        self.avoidRoads = avoidRoads
        self.avoidAreas = avoidAreas
        self.avoidEnvironmentalZones = avoidEnvironmentalZones
    }

    enum CodingKeys: String, CodingKey {
        case avoidTolls = "avoid_tolls"
        case avoidFerries = "avoid_ferries"
        case avoidMotorways = "avoid_motorways"
        case avoidRoads = "avoid_roads"
        case avoidAreas = "avoid_areas"
        case avoidEnvironmentalZones = "avoid_environmental_zones"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        avoidTolls = try c.decodeIfPresent(Bool.self, forKey: .avoidTolls) ?? false
        avoidFerries = try c.decodeIfPresent(Bool.self, forKey: .avoidFerries) ?? false
        avoidMotorways = try c.decodeIfPresent(Bool.self, forKey: .avoidMotorways) ?? false
        avoidRoads = try c.decodeIfPresent([String].self, forKey: .avoidRoads) ?? []
        // [min_lat, min_lon, max_lat, max_lon]
        let boxes = try c.decodeIfPresent([[Double]].self, forKey: .avoidAreas) ?? []
        avoidAreas = try boxes.map { b in
            guard b.count == 4 else {
                throw DecodingError.dataCorruptedError(forKey: .avoidAreas, in: c,
                                                       debugDescription: "area must be [min_lat, min_lon, max_lat, max_lon]")
            }
            return BoundingBox(minLatitude: b[0], minLongitude: b[1], maxLatitude: b[2], maxLongitude: b[3])
        }
        avoidEnvironmentalZones = try c.decodeIfPresent(Bool.self, forKey: .avoidEnvironmentalZones) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(avoidTolls, forKey: .avoidTolls)
        try c.encode(avoidFerries, forKey: .avoidFerries)
        try c.encode(avoidMotorways, forKey: .avoidMotorways)
        try c.encode(avoidRoads, forKey: .avoidRoads)
        try c.encode(avoidAreas.map { [$0.minLatitude, $0.minLongitude, $0.maxLatitude, $0.maxLongitude] },
                     forKey: .avoidAreas)
        try c.encode(avoidEnvironmentalZones, forKey: .avoidEnvironmentalZones)
    }
}

public struct StrategyAdvice: Sendable, Equatable, Codable {
    public enum Action: Sendable, Equatable {
        /// 换到当前备选路线中的某一条（必须车还没过分岔点）。
        case switchToAlternative(RouteID)
        /// 带约束重新算路（避开某路段/区域/收费…），结果回来后在安全点采纳。
        case reroute(RoutingPreferences)
        /// 明确表示"维持现状"（也是一种回答，便于 JEV 侧闭环）。
        case keepCurrent
    }

    public var id: String
    public var tripID: String
    public var issuedAt: Date
    public var validUntil: Date
    public var action: Action
    /// 给人看的一句话（"A10 West 事故，+18 分钟"）。
    public var reason: String
    public var expectedGain: TimeInterval?

    public init(id: String, tripID: String, issuedAt: Date, validUntil: Date, action: Action,
                reason: String, expectedGain: TimeInterval? = nil) {
        self.id = id
        self.tripID = tripID
        self.issuedAt = issuedAt
        self.validUntil = validUntil
        self.action = action
        self.reason = reason
        self.expectedGain = expectedGain
    }

    enum CodingKeys: String, CodingKey {
        case id, reason, action
        case tripID = "trip_id"
        case issuedAt = "issued_at"
        case validUntil = "valid_until"
        case expectedGain = "expected_gain_s"
    }

    enum ActionKeys: String, CodingKey {
        case type
        case routeID = "route_id"
        case preferences
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        tripID = try c.decode(String.self, forKey: .tripID)
        guard let issued = try ISO8601.decode(c, .issuedAt), let valid = try ISO8601.decode(c, .validUntil) else {
            throw DecodingError.dataCorruptedError(forKey: .issuedAt, in: c, debugDescription: "missing timestamps")
        }
        issuedAt = issued
        validUntil = valid
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        expectedGain = try c.decodeIfPresent(Double.self, forKey: .expectedGain)
        let a = try c.nestedContainer(keyedBy: ActionKeys.self, forKey: .action)
        switch try a.decode(String.self, forKey: .type) {
        case "switch_to_alternative":
            action = .switchToAlternative(RouteID(try a.decode(String.self, forKey: .routeID)))
        case "reroute":
            action = .reroute(try a.decodeIfPresent(RoutingPreferences.self, forKey: .preferences) ?? RoutingPreferences())
        case "keep_current":
            action = .keepCurrent
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: a, debugDescription: "unknown action \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(tripID, forKey: .tripID)
        try c.encode(ISO8601.string(issuedAt), forKey: .issuedAt)
        try c.encode(ISO8601.string(validUntil), forKey: .validUntil)
        try c.encode(reason, forKey: .reason)
        try c.encodeIfPresent(expectedGain, forKey: .expectedGain)
        var a = c.nestedContainer(keyedBy: ActionKeys.self, forKey: .action)
        switch action {
        case .switchToAlternative(let id):
            try a.encode("switch_to_alternative", forKey: .type)
            try a.encode(id.raw, forKey: .routeID)
        case .reroute(let prefs):
            try a.encode("reroute", forKey: .type)
            try a.encode(prefs, forKey: .preferences)
        case .keepCurrent:
            try a.encode("keep_current", forKey: .type)
        }
    }
}

/// 核心发给 JEV 的行程快照（低频：默认 30 秒一次，或路线变化/偏航时立即）。
public struct TripTelemetry: Sendable, Equatable, Codable {
    public struct RouteSummary: Sendable, Equatable, Codable {
        public var id: RouteID
        public var length: Double
        public var expectedDuration: TimeInterval?
    }

    public var tripID: String
    public var at: Date
    public var position: Coordinate
    public var speedKmh: Int?
    public var phase: String
    public var activeRoute: RouteSummary?
    public var alternatives: [RouteSummary]
    public var remainingDistance: Double
    public var remainingTime: TimeInterval
    /// 路线前方的事件 id（按距离）。
    public var eventsAhead: [String]

    enum CodingKeys: String, CodingKey {
        case at, position, phase, alternatives
        case tripID = "trip_id"
        case speedKmh = "speed_kmh"
        case activeRoute = "active_route"
        case remainingDistance = "remaining_m"
        case remainingTime = "remaining_s"
        case eventsAhead = "events_ahead"
    }

    public init(tripID: String, at: Date, position: Coordinate, speedKmh: Int?, phase: String,
                activeRoute: RouteSummary?, alternatives: [RouteSummary], remainingDistance: Double,
                remainingTime: TimeInterval, eventsAhead: [String]) {
        self.tripID = tripID
        self.at = at
        self.position = position
        self.speedKmh = speedKmh
        self.phase = phase
        self.activeRoute = activeRoute
        self.alternatives = alternatives
        self.remainingDistance = remainingDistance
        self.remainingTime = remainingTime
        self.eventsAhead = eventsAhead
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tripID = try c.decode(String.self, forKey: .tripID)
        guard let t = try ISO8601.decode(c, .at) else {
            throw DecodingError.dataCorruptedError(forKey: .at, in: c, debugDescription: "missing at")
        }
        at = t
        let p = try c.decode([Double].self, forKey: .position)
        guard p.count == 2 else {
            throw DecodingError.dataCorruptedError(forKey: .position, in: c, debugDescription: "position must be [lat, lon]")
        }
        position = Coordinate(p[0], p[1])
        speedKmh = try c.decodeIfPresent(Int.self, forKey: .speedKmh)
        phase = try c.decode(String.self, forKey: .phase)
        activeRoute = try c.decodeIfPresent(RouteSummary.self, forKey: .activeRoute)
        alternatives = try c.decodeIfPresent([RouteSummary].self, forKey: .alternatives) ?? []
        remainingDistance = try c.decode(Double.self, forKey: .remainingDistance)
        remainingTime = try c.decode(Double.self, forKey: .remainingTime)
        eventsAhead = try c.decodeIfPresent([String].self, forKey: .eventsAhead) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tripID, forKey: .tripID)
        try c.encode(ISO8601.string(at), forKey: .at)
        try c.encode([position.latitude, position.longitude], forKey: .position)
        try c.encodeIfPresent(speedKmh, forKey: .speedKmh)
        try c.encode(phase, forKey: .phase)
        try c.encodeIfPresent(activeRoute, forKey: .activeRoute)
        try c.encode(alternatives, forKey: .alternatives)
        try c.encode(remainingDistance, forKey: .remainingDistance)
        try c.encode(remainingTime, forKey: .remainingTime)
        try c.encode(eventsAhead, forKey: .eventsAhead)
    }
}

extension TripTelemetry.RouteSummary {
    enum CodingKeys: String, CodingKey {
        case id
        case length = "length_m"
        case expectedDuration = "expected_duration_s"
    }
}

// MARK: - 安全点

public struct StrategyGateConfig: Sendable {
    /// 离下一个动作至少这么远（米）……
    public var minDistanceToManeuver = 600.0
    /// ……并且按当前车速至少这么多秒，才允许换路线。
    public var minTimeToManeuver: TimeInterval = 25
    /// 刚驶过一个动作点（还在路口/匝道里）这么多米之内，也不换。
    public var minDistanceAfterManeuver = 150.0
    /// 两次换路线之间至少间隔（防止来回横跳）。初始路线不算。
    public var minSwitchInterval: TimeInterval = 90

    public init() {}
}

public enum StrategyDecision: Sendable, Equatable {
    case apply
    case deferUntilSafe(String)
    case reject(String)
}

/// 决定一条 JEV 建议此刻能不能执行。纯函数，便于单测。
public struct StrategyGate: Sendable {
    public var config: StrategyGateConfig

    public init(config: StrategyGateConfig = StrategyGateConfig()) {
        self.config = config
    }

    public func evaluate(_ advice: StrategyAdvice, tripID: String?, now: Date, distanceToNextManeuver: Double?,
                         distanceSincePreviousManeuver: Double? = nil, speed: Double?, lastRouteChange: Date?,
                         rerouting: Bool) -> StrategyDecision {
        if now > advice.validUntil { return .reject("expired") }
        if advice.tripID != tripID { return .reject("different trip") }
        if case .keepCurrent = advice.action { return .apply }
        return safePoint(now: now, distanceToNextManeuver: distanceToNextManeuver,
                         distanceSincePreviousManeuver: distanceSincePreviousManeuver, speed: speed,
                         lastRouteChange: lastRouteChange, rerouting: rerouting)
    }

    /// 此刻换路线安不安全（JEV 建议和 NDW 封路避让共用）。
    public func safePoint(now: Date, distanceToNextManeuver: Double?, distanceSincePreviousManeuver: Double? = nil,
                          speed: Double?, lastRouteChange: Date?, rerouting: Bool) -> StrategyDecision {
        if rerouting { return .deferUntilSafe("rerouting") }
        if let d = distanceSincePreviousManeuver, d < config.minDistanceAfterManeuver {
            return .deferUntilSafe("just passed maneuver")
        }
        if let d = distanceToNextManeuver {
            let needed = max(config.minDistanceToManeuver, (speed ?? 0) * config.minTimeToManeuver)
            if d < needed { return .deferUntilSafe("near maneuver") }
        }
        if let last = lastRouteChange, now.timeIntervalSince(last) < config.minSwitchInterval {
            return .deferUntilSafe("recent route change")
        }
        return .apply
    }
}
