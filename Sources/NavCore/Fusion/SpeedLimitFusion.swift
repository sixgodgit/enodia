import Foundation

/// 限速来源，按"可信 + 时效"由高到低：
/// 矩阵牌（此刻显示在头顶，有红圈即法定）> 官方静态数据（RWS/NDW）> 路线服务（高德）> 本地缓存 > 道路等级默认值。
public enum SpeedLimitSource: String, Sendable, Codable {
    /// MSI 矩阵牌 —— 动态，过期很快。
    case dynamicSign = "dynamic_sign"
    /// RWS 道路特征库（WKD）/ NDW 交通标志库。
    case officialStatic = "official_static"
    /// 路线服务自带（高德）。
    case provider
    /// 本机以前确认过的值。
    case cache
    case roadClassDefault = "road_class_default"
}

/// 本地时间的时段（Europe/Amsterdam）。荷兰限速常见"06–19 100，其余 130"。
public struct TimeWindow: Sendable, Equatable, Codable {
    /// 当地零点起的分钟数。
    public var startMinute: Int
    /// 不含；小于等于 start 表示跨午夜。
    public var endMinute: Int
    /// Calendar 的 weekday（1 = 周日 … 7 = 周六）；nil = 每天。跨午夜的时段按开始那天算。
    public var weekdays: [Int]?

    public init(startMinute: Int, endMinute: Int, weekdays: [Int]? = nil) {
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.weekdays = weekdays
    }

    public init(from start: (Int, Int), to end: (Int, Int), weekdays: [Int]? = nil) {
        self.init(startMinute: start.0 * 60 + start.1, endMinute: end.0 * 60 + end.1, weekdays: weekdays)
    }

    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        let c = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let wraps = endMinute <= startMinute
        let inTime = wraps ? (m >= startMinute || m < endMinute) : (m >= startMinute && m < endMinute)
        guard inTime else { return false }
        guard let days = weekdays else { return true }
        var day = c.weekday ?? 1
        if wraps && m < endMinute { day = day == 1 ? 7 : day - 1 }
        return days.contains(day)
    }

    /// 下一次"在/不在时段内"翻转的时刻。
    public func nextTransition(after date: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: date)
        var candidates: [Date] = []
        // 每天都生效的时段，今明两天之内一定有翻转；按星期的最多要看一周多。
        for dayOffset in 0...(weekdays == nil ? 1 : 8) {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
            for minute in [startMinute, endMinute] {
                if let t = calendar.date(bySettingHour: minute / 60 % 24, minute: minute % 60, second: 0, of: day),
                   t > date {
                    candidates.append(t)
                }
            }
        }
        candidates.sort()
        return candidates.first { contains($0, calendar: calendar) != contains($0.addingTimeInterval(-1), calendar: calendar) }
    }
}

public struct SpeedLimitObservation: Sendable, Equatable, Codable {
    public var source: SpeedLimitSource
    public var kmh: Int
    /// 矩阵牌没有红圈 = 建议速度，不是限速。
    public var binding: Bool
    /// 只在这个时段内有效。
    public var schedule: TimeWindow?
    public var observedAt: Date
    /// 动态来源必须给；过期即作废。
    public var maxAge: TimeInterval?
    /// 这条观测"确实属于脚下这段路"的把握（0–1），来自几何匹配。
    public var matchConfidence: Double

    public init(source: SpeedLimitSource, kmh: Int, binding: Bool = true, schedule: TimeWindow? = nil,
                observedAt: Date, maxAge: TimeInterval? = nil, matchConfidence: Double = 1) {
        self.source = source
        self.kmh = kmh
        self.binding = binding
        self.schedule = schedule
        self.observedAt = observedAt
        self.maxAge = maxAge
        self.matchConfidence = matchConfidence
    }

    public func isExpired(at now: Date) -> Bool {
        guard let maxAge else { return false }
        return now.timeIntervalSince(observedAt) > maxAge
    }
}

public struct FusedSpeedLimit: Sendable, Equatable {
    public enum Confidence: Int, Sendable, Comparable {
        case low, medium, high
        public static func < (a: Confidence, b: Confidence) -> Bool { a.rawValue < b.rawValue }
    }

    public struct ScheduledChange: Sendable, Equatable {
        public var kmh: Int
        public var at: Date
        public init(kmh: Int, at: Date) {
            self.kmh = kmh
            self.at = at
        }
    }

    public var kmh: Int
    public var source: SpeedLimitSource
    public var confidence: Confidence
    /// 来源之间有分歧（已按"取低"处理）。UI 可以把限速牌画成虚线框。
    public var conflict: Bool
    /// 矩阵牌上的建议速度（无红圈）。
    public var advisoryKmh: Int?
    /// 高速白天 100 的全国规则把更高的值压下来了。
    public var daytimeCapApplied: Bool
    /// 一小时内会因时段变化而变（"100 → 130 om 19:00"）。
    public var upcomingChange: ScheduledChange?

    public init(kmh: Int, source: SpeedLimitSource, confidence: Confidence, conflict: Bool, advisoryKmh: Int?,
                daytimeCapApplied: Bool, upcomingChange: ScheduledChange?) {
        self.kmh = kmh
        self.source = source
        self.confidence = confidence
        self.conflict = conflict
        self.advisoryKmh = advisoryKmh
        self.daytimeCapApplied = daytimeCapApplied
        self.upcomingChange = upcomingChange
    }
}

/// 荷兰本地规则。
public enum DutchRoadRules {
    /// 2020-03-16 起：所有高速 06:00–19:00 最高 100。
    public static let motorwayDaytime = TimeWindow(from: (6, 0), to: (19, 0))
    public static let motorwayDaytimeMax = 100

    public static func defaultLimit(for roadClass: RoadClass) -> Int? {
        switch roadClass {
        case .motorway: return 100
        case .expressway: return 100
        case .rural: return 80
        case .urban: return 50
        case .zone30: return 30
        case .woonerf: return 15
        case .unknown: return nil
        }
    }

    public static var amsterdamCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Amsterdam") ?? TimeZone(secondsFromGMT: 3600)!
        return cal
    }
}

/// 限速融合：不盲信任何一个来源。
///
/// 规则（按顺序）：
/// 1. 丢掉匹配把握 < 0.5、已过期、不在时段内的观测。
/// 2. 有红圈的矩阵牌 → 直接用（多条取最低）。
/// 3. 官方静态把握 ≥ 0.8 → 用官方；与高德不一致只标记冲突。
/// 4. 官方把握一般、且与高德不一致 → 取两者较低值，标记冲突（显示偏高比偏低危险）。
/// 5. 只有高德 → 用高德；与本地缓存不一致 → 取低。
/// 6. 都没有 → 道路等级默认值，低把握。
/// 7. 高速白天 06–19：任何非矩阵牌来源给出 > 100 都压到 100（高德不一定区分时段）。
public struct SpeedLimitFuser: Sendable {
    public var calendar: Calendar
    /// 多久之内的时段变化要提前告诉 UI。
    public var changeHorizon: TimeInterval

    public init(calendar: Calendar = DutchRoadRules.amsterdamCalendar, changeHorizon: TimeInterval = 3600) {
        self.calendar = calendar
        self.changeHorizon = changeHorizon
    }

    public func fuse(_ observations: [SpeedLimitObservation], roadClass: RoadClass?, now: Date) -> FusedSpeedLimit? {
        guard var result = resolve(observations, roadClass: roadClass, at: now) else { return nil }
        guard result.source != .dynamicSign else { return result }

        var transitions = observations.compactMap { $0.schedule?.nextTransition(after: now, calendar: calendar) }
        if roadClass == .motorway,
           let t = DutchRoadRules.motorwayDaytime.nextTransition(after: now, calendar: calendar) {
            transitions.append(t)
        }
        if let t = transitions.filter({ $0.timeIntervalSince(now) <= changeHorizon }).min() {
            let staticOnly = observations.filter { $0.source != .dynamicSign }
            if let later = resolve(staticOnly, roadClass: roadClass, at: t.addingTimeInterval(1)), later.kmh != result.kmh {
                result.upcomingChange = .init(kmh: later.kmh, at: t)
            }
        }
        return result
    }

    private func resolve(_ observations: [SpeedLimitObservation], roadClass: RoadClass?, at now: Date) -> FusedSpeedLimit? {
        let usable = observations.filter {
            $0.matchConfidence >= 0.5 && !$0.isExpired(at: now) && ($0.schedule?.contains(now, calendar: calendar) ?? true)
        }
        let advisory = usable.filter { $0.source == .dynamicSign && !$0.binding }
            .max { $0.observedAt < $1.observedAt }?.kmh

        let dynamic = usable.filter { $0.source == .dynamicSign && $0.binding && $0.matchConfidence >= 0.6 }
        if let lowest = dynamic.map(\.kmh).min() {
            return FusedSpeedLimit(kmh: lowest, source: .dynamicSign, confidence: .high, conflict: false,
                                   advisoryKmh: advisory, daytimeCapApplied: false, upcomingChange: nil)
        }

        let official = usable.filter { $0.source == .officialStatic }
            .max { ($0.matchConfidence, -$0.kmh) < ($1.matchConfidence, -$1.kmh) }
        let provider = usable.first { $0.source == .provider }
        let cache = usable.first { $0.source == .cache }

        var kmh: Int
        var source: SpeedLimitSource
        var confidence: FusedSpeedLimit.Confidence
        var conflict = false

        if let o = official, o.matchConfidence >= 0.8 {
            (kmh, source, confidence) = (o.kmh, .officialStatic, .high)
            conflict = provider.map { $0.kmh != o.kmh } ?? false
        } else if let o = official {
            if let p = provider, p.kmh != o.kmh {
                kmh = min(o.kmh, p.kmh)
                source = kmh == o.kmh ? .officialStatic : .provider
                confidence = .medium
                conflict = true
            } else {
                (kmh, source) = (o.kmh, .officialStatic)
                confidence = provider == nil ? .medium : .high
            }
        } else if let p = provider {
            if let c = cache, c.kmh != p.kmh {
                kmh = min(p.kmh, c.kmh)
                source = kmh == p.kmh ? .provider : .cache
                confidence = .low
                conflict = true
            } else {
                (kmh, source, confidence) = (p.kmh, .provider, .medium)
            }
        } else if let c = cache {
            (kmh, source, confidence) = (c.kmh, .cache, .low)
        } else if let rc = roadClass, let d = DutchRoadRules.defaultLimit(for: rc) {
            (kmh, source, confidence) = (d, .roadClassDefault, .low)
        } else {
            return nil
        }

        var capped = false
        if roadClass == .motorway, kmh > DutchRoadRules.motorwayDaytimeMax,
           DutchRoadRules.motorwayDaytime.contains(now, calendar: calendar) {
            kmh = DutchRoadRules.motorwayDaytimeMax
            capped = true
        }
        return FusedSpeedLimit(kmh: kmh, source: source, confidence: confidence, conflict: conflict,
                               advisoryKmh: advisory, daytimeCapApplied: capped, upcomingChange: nil)
    }
}
