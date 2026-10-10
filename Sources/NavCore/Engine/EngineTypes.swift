import Foundation

public struct TripPlan: Sendable, Equatable {
    public var id: String
    public var destination: Coordinate
    public var waypoints: [Coordinate]
    public var preferences: RoutingPreferences

    public init(id: String, destination: Coordinate, waypoints: [Coordinate] = [],
                preferences: RoutingPreferences = RoutingPreferences()) {
        self.id = id
        self.destination = destination
        self.waypoints = waypoints
        self.preferences = preferences
    }
}

public enum RoutePurpose: Sendable, Equatable {
    case initial
    case reroute
    /// 预算：如果错过了 baseRouteID 上 maneuverOffset 处的动作，接下来怎么走。
    case speculative(maneuverOffset: Double, baseRouteID: RouteID)
    case strategy(adviceID: String)
    /// 路线前方有封路（NDW），带避让区域重新算。
    case avoidEvent(eventID: String)
    /// 同一行程的"更新版"路线（主路线服务自己重算的、定期刷新路况的）。车接得上就在安全点换。
    case refresh
}

/// 核心请宿主去算一条路。核心只发请求、不等结果；结果通过 `NavigationEngine.offer` 回来。
public struct RouteRequest: Sendable, Equatable {
    public var id: UInt64
    public var purpose: RoutePurpose
    public var origin: Coordinate
    /// 起点处的行驶方向 —— 告诉路线服务"别让我掉头"。
    public var originHeading: Double?
    public var destination: Coordinate
    public var waypoints: [Coordinate]
    public var preferences: RoutingPreferences
    public var issuedAt: Date

    public init(id: UInt64, purpose: RoutePurpose, origin: Coordinate, originHeading: Double?, destination: Coordinate,
                waypoints: [Coordinate], preferences: RoutingPreferences, issuedAt: Date) {
        self.id = id
        self.purpose = purpose
        self.origin = origin
        self.originHeading = originHeading
        self.destination = destination
        self.waypoints = waypoints
        self.preferences = preferences
        self.issuedAt = issuedAt
    }
}

public struct RouteOffer: Sendable {
    public var requestID: UInt64?
    public var purpose: RoutePurpose
    /// 第一条是主路线，其余是备选。
    public var routes: [Route]

    public init(requestID: UInt64?, purpose: RoutePurpose, routes: [Route]) {
        self.requestID = requestID
        self.purpose = purpose
        self.routes = routes
    }
}

public struct RouteChange: Sendable, Equatable {
    public enum Reason: String, Sendable {
        case initial
        /// 偏航时车正好在备选路线上：零等待切换。
        case alternativeInstant = "alternative_instant"
        /// 偏航时命中预算路线：零等待切换。
        case speculativeInstant = "speculative_instant"
        /// 等路线服务算出来的。
        case reroute
        case strategy
        case avoidEvent = "avoid_event"
        case refresh
    }

    public var from: RouteID?
    public var to: RouteID
    public var reason: Reason
    public var at: Date
    /// 从第一次出现偏离迹象到换上新路线（秒）—— 衡量②的核心指标。
    public var deviationToNewRoute: TimeInterval?
}

public enum EngineIntent: Sendable, Equatable {
    case requestRoute(RouteRequest)
    case activeRouteChanged(RouteChange)
    case telemetry(TripTelemetry)
    case adviceResolved(adviceID: String, applied: Bool, note: String)
}

public struct EngineOutput: Sendable {
    public var display: DriveDisplayState
    public var intents: [EngineIntent]
    /// 本次 process() 在核心里花的时间。
    public var processingTime: Duration
}

public struct EngineConfig: Sendable {
    public var matcher = MatcherConfig()
    public var offRoute = OffRouteConfig()
    public var strategy = StrategyGateConfig()

    // 重算
    /// 路线服务这么久没回就重发。
    public var rerouteTimeout: TimeInterval = 5
    public var maxRerouteAttempts = 3
    /// 超过次数后放慢重试。
    public var slowRetryInterval: TimeInterval = 30
    /// 新路线回来时，车必须在它附近（米）……
    public var acceptRadius = 60.0
    /// ……且在它的前这么多米之内（车在等待期间已经往前开了）。
    public var acceptWithin = 2000.0
    public var instantSwitchHeading = 35.0
    public var maxAlternatives = 4

    // 预算路线
    public var speculativeLookahead = 2500.0
    public var speculativeMinDistance = 300.0
    /// "错过"点放在动作点之后多远（沿进入方向延长）。
    public var speculativeMissDistance = 350.0
    public var speculativeLeadIn = 600.0
    public var maxSpeculative = 3

    // 显示
    public var arrivalRadius = 30.0
    public var hazardHorizon = 30_000.0
    public var laneFeedMaxAge: TimeInterval = 30
    public var laneRangeMotorway = 1500.0
    public var laneRangeOther = 300.0
    public var thenManeuverGap = 400.0
    public var speedingToleranceKmh = 3
    /// 限速输入不变时多久重算一次（时段切换最多晚这么久显示）。
    public var speedLimitRecheck: TimeInterval = 5
    public var strategyNoteDuration: TimeInterval = 20

    // 矩阵牌：牌面管到下一个门架为止，这里给个上限。
    public var gantryValidity = 1200.0
    public var gantryLookahead = 300.0
    public var gantryMaxAge: TimeInterval = 180

    // NDW 封路
    public var avoidBlockingEventsWithin = 25_000.0

    // 车道定位（仅手机传感器）
    public var laneChange = LaneChangeDetectorConfig()
    public var laneEstimator = LaneEstimatorConfig()
    /// 最大概率达到它才显示"当前车道"、给变道提示。
    public var laneDisplayConfidence = 0.7

    public var telemetryInterval: TimeInterval = 30
    public var waypointReachedRadius = 60.0

    public init() {}
}
