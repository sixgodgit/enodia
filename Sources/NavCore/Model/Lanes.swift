import Foundation

public enum LaneDirection: String, Sendable, Codable, CaseIterable {
    case straight
    case slightLeft, left, sharpLeft
    case slightRight, right, sharpRight
    case uTurnLeft, uTurnRight
    /// 数据里有、但我们不认识的箭头 —— 画成无箭头车道，绝不猜方向。
    case unknown
}

public enum LaneStatus: String, Sendable, Codable {
    case open
    /// 矩阵牌红叉（rood kruis）：法律上禁止驶入。
    case closed
}

public struct Lane: Sendable, Equatable, Codable {
    /// 画箭头的顺序即数组顺序。
    public var directions: [LaneDirection]
    /// 推荐行驶的车道（高亮）。
    public var recommended: Bool
    /// 推荐车道上要高亮的那个箭头（多箭头车道时有意义）。
    public var preferred: LaneDirection?
    public var status: LaneStatus
    /// 该车道上方矩阵牌显示的限速（km/h）。
    public var dynamicSpeedLimit: Int?

    public init(directions: [LaneDirection], recommended: Bool = false, preferred: LaneDirection? = nil,
                status: LaneStatus = .open, dynamicSpeedLimit: Int? = nil) {
        self.directions = directions
        self.recommended = recommended
        self.preferred = preferred
        self.status = status
        self.dynamicSpeedLimit = dynamicSpeedLimit
    }
}

/// 一组车道，从左到右。
public struct LaneGuidance: Sendable, Equatable, Codable {
    public var lanes: [Lane]
    public init(lanes: [Lane]) { self.lanes = lanes }

    public var recommendedIndices: [Int] { lanes.indices.filter { lanes[$0].recommended } }
}

/// 车道信息流：来自高德导航会话的回调（显示/隐藏车道图）。
public struct LaneFeed: Sendable, Equatable {
    /// nil = 高德让隐藏车道图。
    public var guidance: LaneGuidance?
    public var receivedAt: Date
    /// 属于哪条路线；nil = 不知道（按当前路线处理）。
    public var routeID: RouteID?
    /// 属于路线上哪个动作（offset）；nil = 当作下一个动作。
    public var maneuverOffset: Double?

    public init(guidance: LaneGuidance?, receivedAt: Date, routeID: RouteID? = nil, maneuverOffset: Double? = nil) {
        self.guidance = guidance
        self.receivedAt = receivedAt
        self.routeID = routeID
        self.maneuverOffset = maneuverOffset
    }
}

// MARK: - 高德车道编码

/// 高德导航 SDK 的车道字符串 → LaneGuidance。
///
/// 高德回调给两串以 `|` 分隔的编码：背景（每条车道有哪些箭头）和前景（推荐车道高亮哪个箭头，255 = 不推荐）。
/// 例：背景 "1|0|0|4"、前景 "255|0|0|255" → 左转 | 直行* | 直行* | 直行+右转，中间两条推荐。
///
/// ⚠️ 下面的编码表按高德文档整理，接入时请用所用 SDK 版本的真机数据核对一遍
///    （`AmapLaneDecoderTests` 锁定了当前假设）。不认识的编码一律解成 `.unknown`：
///    宁可画一条没箭头的车道，也不画错箭头。
public enum AmapLaneDecoder {
    public static let notRecommended = 255

    public static func directions(forCode code: Int) -> [LaneDirection] {
        switch code {
        case 0: return [.straight]
        case 1: return [.left]
        case 2: return [.left, .straight]
        case 3: return [.right]
        case 4: return [.straight, .right]
        case 5: return [.uTurnLeft]
        case 6: return [.left, .right]
        case 7: return [.left, .straight, .right]
        case 8: return [.uTurnRight]
        case 9: return [.straight, .uTurnLeft]
        case 10: return [.straight, .uTurnRight]
        case 11: return [.left, .uTurnLeft]
        case 12: return [.right, .uTurnRight]
        default: return [.unknown]
        }
    }

    public static func decode(background: String, selection: String?) -> LaneGuidance? {
        let back = codes(background)
        guard !back.isEmpty, back.allSatisfy({ $0 != nil && $0 != notRecommended }) else { return nil }
        let select = selection.map(codes) ?? []
        var lanes: [Lane] = []
        for (i, code) in back.enumerated() {
            let dirs = directions(forCode: code!)
            var lane = Lane(directions: dirs)
            if i < select.count, let s = select[i], s != notRecommended {
                lane.recommended = true
                let highlighted = directions(forCode: s)
                if highlighted.count == 1, highlighted[0] != .unknown, dirs.contains(highlighted[0]) {
                    lane.preferred = highlighted[0]
                } else if dirs.count == 1 {
                    lane.preferred = dirs[0]
                }
            }
            lanes.append(lane)
        }
        return LaneGuidance(lanes: lanes)
    }

    /// 十进制为主；个别版本用单个十六进制字符（"a"、"b"），也接受。
    private static func codes(_ s: String) -> [Int?] {
        s.split(separator: "|", omittingEmptySubsequences: false).map { part in
            let t = part.trimmingCharacters(in: .whitespaces)
            return Int(t) ?? Int(t, radix: 16)
        }
    }
}

// MARK: - 矩阵牌（MSI）× 车道

/// 一块门架上某条车道的矩阵牌状态（NDW Matrixsignaalinformatie）。
public struct LaneSignal: Sendable, Equatable, Codable {
    public enum Aspect: String, Sendable, Codable {
        case blank
        case speedLimit
        /// 红叉：车道关闭。
        case closed
        /// 黄色斜箭头：前方车道关闭，请变道。
        case mergeLeft, mergeRight
        case endOfRestrictions
        case unknown
    }

    /// 从左数，0 起。
    public var laneFromLeft: Int
    public var aspect: Aspect
    public var speedLimit: Int?
    /// 限速有红圈 = 强制；没有红圈 = 建议速度。
    public var binding: Bool

    public init(laneFromLeft: Int, aspect: Aspect, speedLimit: Int? = nil, binding: Bool = true) {
        self.laneFromLeft = laneFromLeft
        self.aspect = aspect
        self.speedLimit = speedLimit
        self.binding = binding
    }
}

/// 一个门架：位置 + 车道数 + 每条车道的牌面。
public struct SignalGantry: Sendable, Equatable, Codable {
    public var id: String
    public var location: Coordinate
    /// 行驶方向的方位角，用来排除对向车道上的门架。
    public var bearing: Double?
    public var laneCount: Int
    public var signals: [LaneSignal]
    public var observedAt: Date

    public init(id: String, location: Coordinate, bearing: Double?, laneCount: Int,
                signals: [LaneSignal], observedAt: Date) {
        self.id = id
        self.location = location
        self.bearing = bearing
        self.laneCount = laneCount
        self.signals = signals
        self.observedAt = observedAt
    }
}

public enum LaneClosureFusion {
    /// 把门架红叉/车道限速叠到高德车道图上。
    ///
    /// 只有门架车道数和高德车道数一致时才动推荐车道：数不一样说明车道图包含了出口加速/减速车道，
    /// 这时左右对齐是猜，猜错的后果（把人引到红叉车道）比不叠加严重得多。
    public static func apply(_ gantry: SignalGantry, to guidance: LaneGuidance) -> LaneGuidance {
        guard gantry.laneCount == guidance.lanes.count else { return guidance }
        var out = guidance
        let preferredBefore = Set(guidance.lanes.filter(\.recommended).flatMap { lane in
            lane.preferred.map { [$0] } ?? lane.directions
        })
        let hadRecommendation = !guidance.recommendedIndices.isEmpty

        for s in gantry.signals where s.laneFromLeft >= 0 && s.laneFromLeft < out.lanes.count {
            switch s.aspect {
            case .closed:
                out.lanes[s.laneFromLeft].status = .closed
                out.lanes[s.laneFromLeft].recommended = false
                out.lanes[s.laneFromLeft].preferred = nil
            case .speedLimit where s.binding:
                out.lanes[s.laneFromLeft].dynamicSpeedLimit = s.speedLimit
            default:
                break
            }
        }

        // 推荐车道全被红叉了：在还开着的车道里找能走同一方向的，改推荐它们。
        if hadRecommendation && out.recommendedIndices.isEmpty {
            for i in out.lanes.indices where out.lanes[i].status == .open {
                if let dir = out.lanes[i].directions.first(where: preferredBefore.contains) {
                    out.lanes[i].recommended = true
                    out.lanes[i].preferred = dir
                }
            }
        }
        return out
    }
}
