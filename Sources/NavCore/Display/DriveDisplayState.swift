import Foundation

/// CarPlay 屏幕上该出现的全部信息 —— 只有开车时真正要看的东西。
///
/// 这是核心的唯一"输出画面"。CarPlay / 手机 UI 只负责把它画出来，不做任何判断：
/// 距离已经取整好（不会每秒跳一下），限速已经融合好，事件已经按方向过滤好。
public struct DriveDisplayState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        /// 行程已开始，第一条路线还没到。
        case planning(attempts: Int)
        case guiding
        /// 偏航了，新路线还没到。attempts = 已经发出的重算请求次数。
        case rerouting(since: Date, attempts: Int)
        case arrived
    }

    public var phase: Phase
    /// 下一个动作。
    public var maneuver: ManeuverDisplay?
    /// 紧接着的动作（两个动作挨得很近时才给，"然后左转"）。
    public var thenManeuver: ManeuverDisplay?
    public var lanes: LaneGuidance?
    public var speedLimit: FusedSpeedLimit?
    public var speedKmh: Int?
    public var isSpeeding: Bool
    /// 前方最近的交通事件。
    public var hazard: HazardDisplay?
    public var remainingDistance: Double
    public var remainingTime: TimeInterval
    public var eta: Date?
    /// 偏航后、新路线到之前：回到原路线最近点的方向和距离。
    public var rejoin: RejoinHint?
    /// JEV 换路线时给人看的理由。
    public var strategyNote: String?
    public var activeRouteID: RouteID?
    public var gpsDegraded: Bool

    public static let idle = DriveDisplayState(
        phase: .idle, maneuver: nil, thenManeuver: nil, lanes: nil, speedLimit: nil, speedKmh: nil,
        isSpeeding: false, hazard: nil, remainingDistance: 0, remainingTime: 0, eta: nil, rejoin: nil,
        strategyNote: nil, activeRouteID: nil, gpsDegraded: false)
}

public struct ManeuverDisplay: Sendable, Equatable {
    public var kind: ManeuverKind
    /// 显示用（已取整）。
    public var distance: Double
    public var exactDistance: Double
    public var roadName: String?
    public var exitNumber: String?
    public var signpost: String?
    public var roundaboutExit: Int?

    public init(kind: ManeuverKind, distance: Double, exactDistance: Double, roadName: String?, exitNumber: String?,
                signpost: String?, roundaboutExit: Int?) {
        self.kind = kind
        self.distance = distance
        self.exactDistance = exactDistance
        self.roadName = roadName
        self.exitNumber = exitNumber
        self.signpost = signpost
        self.roundaboutExit = roundaboutExit
    }
}

public struct HazardDisplay: Sendable, Equatable {
    public var eventID: String
    public var kind: TrafficEvent.Kind
    public var severity: TrafficEvent.Severity
    /// 显示用（已取整）；0 且 inside = 正在事件路段内。
    public var distance: Double
    public var inside: Bool
    public var road: String?
    public var closedLanes: [String]
    public var text: String?
    public var directionVerified: Bool

    public init(eventID: String, kind: TrafficEvent.Kind, severity: TrafficEvent.Severity, distance: Double,
                inside: Bool, road: String?, closedLanes: [String], text: String?, directionVerified: Bool) {
        self.eventID = eventID
        self.kind = kind
        self.severity = severity
        self.distance = distance
        self.inside = inside
        self.road = road
        self.closedLanes = closedLanes
        self.text = text
        self.directionVerified = directionVerified
    }
}

public struct RejoinHint: Sendable, Equatable {
    public var distance: Double
    /// 绝对方位角；UI 结合当前航向画相对箭头。
    public var bearing: Double
}

/// 距离取整：近处细、远处粗，避免数字每秒跳。
public enum DisplayDistance {
    public static func round(_ meters: Double) -> Double {
        let m = max(0, meters)
        let step: Double
        switch m {
        case ..<100: step = 10
        case ..<1000: step = 50
        case ..<10_000: step = 100
        default: step = 1000
        }
        return (m / step).rounded() * step
    }
}
