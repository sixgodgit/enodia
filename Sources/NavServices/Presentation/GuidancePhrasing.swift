import Foundation
import NavCore

/// 把 DriveDisplayState 变成屏幕上的文字（中文提示 + 荷兰路名/出口原文）。
///
/// 只放在 CarPlay 卡片和横幅上的几个词：开车时扫一眼就要看懂，所以短。
public enum GuidancePhrasing {
    public static func instruction(_ m: ManeuverDisplay) -> String {
        let action: String
        switch m.kind {
        case .depart: action = "出发"
        case .straight: action = "直行"
        case .slightLeft: action = "向左前方"
        case .left: action = "左转"
        case .sharpLeft: action = "向左后方"
        case .slightRight: action = "向右前方"
        case .right: action = "右转"
        case .sharpRight: action = "向右后方"
        case .uTurn: action = "掉头"
        case .keepLeft: action = "靠左行驶"
        case .keepRight: action = "靠右行驶"
        case .exitLeft: action = "左侧驶出"
        case .exitRight: action = "右侧驶出"
        case .merge: action = "并入"
        case .roundabout: action = m.roundaboutExit.map { "环岛第 \($0) 出口" } ?? "进入环岛"
        case .ferry: action = "乘渡轮"
        case .waypoint: action = "到达途经点"
        case .arrive: action = "到达目的地"
        }
        var parts = [action]
        if let exit = m.exitNumber, m.kind == .exitLeft || m.kind == .exitRight { parts.append(exit) }
        if let sign = m.signpost ?? m.roadName { parts.append(sign) }
        return parts.joined(separator: " · ")
    }

    /// 300 米 / 1.2 公里 / 15 公里
    public static func distance(_ meters: Double) -> String {
        if meters < 1000 { return "\(Int(meters)) 米" }
        if meters < 10_000 { return String(format: "%.1f 公里", meters / 1000) }
        return "\(Int((meters / 1000).rounded())) 公里"
    }

    public static func hazard(_ h: HazardDisplay) -> String {
        let what: String
        switch h.kind {
        case .accident: what = "事故"
        case .roadworks: what = "施工"
        case .closure: what = "封路"
        case .laneClosure: what = "车道封闭"
        case .congestion: what = "拥堵"
        case .hazard: what = "路面障碍"
        case .bridgeOpening: what = "开桥"
        case .weather: what = "恶劣天气"
        case .other: what = "交通事件"
        }
        var s = h.inside ? "正在通过\(what)路段" : "前方 \(distance(h.distance)) \(what)"
        let lanes = h.closedLanes.map(laneName)
        if !lanes.isEmpty { s += " · \(lanes.joined(separator: "、"))封闭" }
        if !h.directionVerified { s += "（方向未确认）" }
        return s
    }

    /// DATEX II 车道标识 → 中文。数字车道的左右编号约定还没在真实数据上核实，所以只说"第 N 车道"。
    public static func laneName(_ datex: String) -> String {
        switch datex {
        case "hardShoulder": return "应急车道"
        case "rushHourLane": return "高峰车道"
        case "busLane": return "公交车道"
        case "allLanesCompleteCarriageway": return "全部车道"
        default:
            if datex.hasPrefix("lane"), let n = Int(datex.dropFirst(4)) { return "第 \(n) 车道" }
            return datex
        }
    }

    /// "向右变道 1 条（1.2 公里内）"
    public static func laneChange(_ a: LaneChangeAdvice) -> String {
        "向\(a.direction == .right ? "右" : "左")变道 \(a.lanes) 条（\(distance(DisplayDistance.round(a.within)))内）"
    }

    /// "左起第 2 条，共 3 条"
    public static func currentLane(_ e: LaneEstimate) -> String {
        "左起第 \(e.lane + 1) 条，共 \(e.laneCount) 条"
    }

    /// "19:00 起 130"
    public static func upcomingLimit(_ s: FusedSpeedLimit, calendar: Calendar = DutchRoadRules.amsterdamCalendar) -> String? {
        guard let c = s.upcomingChange else { return nil }
        let t = calendar.dateComponents([.hour, .minute], from: c.at)
        return String(format: "%02d:%02d 起 %d", t.hour ?? 0, t.minute ?? 0, c.kmh)
    }
}
