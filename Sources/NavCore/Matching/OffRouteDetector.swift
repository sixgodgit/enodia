import Foundation

public enum RouteAdherence: Sendable, Equatable {
    case onRoute
    /// 有偏离迹象，还没确认。
    case suspect(since: Date)
    /// 已确认偏航；since = 第一次出现偏离迹象的时间（用来算"从偏离到拿到新路线"的真实延迟）。
    case offRoute(since: Date)

    public var isOffRoute: Bool {
        if case .offRoute = self { return true }
        return false
    }
}

public struct OffRouteConfig: Sendable {
    /// 横向阈值 = clamp(精度 × accuracyFactor, minThreshold, maxThreshold)。
    ///
    /// 下限 18 m 是给荷兰的平行车道（parallelbaan，A2/A4/A12/A13/A20/A16 都有）定的：
    /// 主车道和平行车道中心线通常只隔 20–40 m，很多导航用 50 m 一刀切的阈值，
    /// 走错了一直开到两条路分开才发现，出口早过了。
    public var minThreshold = 18.0
    public var accuracyFactor = 2.0
    public var maxThreshold = 60.0
    public var headingThreshold = 50.0
    public var minSpeedForHeading = 3.0
    /// 累计证据到这个分数、并且持续了 confirmMinDuration，才确认偏航。
    public var confirmScore = 3.0
    public var confirmMinDuration: TimeInterval = 1.5
    /// 精度比这差的点既不加证据也不清证据（隧道口、高楼间）。
    public var maxUsableAccuracy = 40.0
    /// 回到路线：横向 < 阈值 × recoverFactor，连续 recoverFixes 个点。
    public var recoverFactor = 0.6
    public var recoverFixes = 2

    public init() {}
}

/// 偏航检测。完全在本地、按每个 GPS 点更新，不等任何路线服务。
///
/// 证据累积而不是单点判决：单个漂移点不会触发，持续的小偏移（平行车道）和
/// 迅速变大的偏移（错过出口）都会在 2–3 秒内确认。
public struct OffRouteDetector: Sendable {
    public let config: OffRouteConfig
    public private(set) var state: RouteAdherence = .onRoute
    private var score = 0.0
    private var suspectSince: Date?
    private var recoverCount = 0

    public init(config: OffRouteConfig = OffRouteConfig()) {
        self.config = config
    }

    public mutating func reset() {
        state = .onRoute
        score = 0
        suspectSince = nil
        recoverCount = 0
    }

    public func threshold(forAccuracy accuracy: Double) -> Double {
        min(config.maxThreshold, max(config.minThreshold, accuracy * config.accuracyFactor))
    }

    @discardableResult
    public mutating func update(match: RouteMatch?, fix: LocationFix) -> RouteAdherence {
        guard fix.horizontalAccuracy <= config.maxUsableAccuracy else { return state }

        let limit = threshold(forAccuracy: fix.horizontalAccuracy)
        let lateral = match?.lateral ?? .infinity
        let heading: Double? = {
            guard let h = match?.headingDelta, let s = fix.speed, s >= config.minSpeedForHeading else { return nil }
            return h
        }()

        if state.isOffRoute {
            if lateral < limit * config.recoverFactor && (heading ?? 0) <= config.headingThreshold {
                recoverCount += 1
                if recoverCount >= config.recoverFixes { reset() }
            } else {
                recoverCount = 0
            }
            return state
        }

        var evidence = 0.0
        if lateral > limit {
            evidence += 1 + min(1, (lateral - limit) / limit)
        }
        if let h = heading, h > config.headingThreshold {
            evidence += lateral > limit * 0.5 ? 1.5 : 0.5
        }

        if evidence > 0 {
            score += evidence
            let since = suspectSince ?? fix.timestamp
            suspectSince = since
            if score >= config.confirmScore && fix.timestamp.timeIntervalSince(since) >= config.confirmMinDuration {
                state = .offRoute(since: since)
                recoverCount = 0
            } else {
                state = .suspect(since: since)
            }
        } else {
            score = max(0, score - 1.5)
            if score == 0 {
                suspectSince = nil
                state = .onRoute
            }
        }
        return state
    }
}
