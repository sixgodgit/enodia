import Foundation

// 仅用手机传感器的车道定位（不需要外接设备）。
//
// 手机 GPS 的绝对精度（几米）分辨不了 3.5 m 宽的车道，所以这里不靠"绝对位置"判断车道，而是：
//   1. 锚点：从匝道并入高速的那一刻，车一定在最右车道；
//   2. 数变道：陀螺仪测到"先转一点再转回来"、同时 GPS 测到横向移动约一个车道宽 → 一次变道；
//      手机 GPS 的误差在几秒内高度相关，所以"几秒内横向挪了多少"比"绝对在哪"准得多；
//   3. 车道数变化（右侧加车道/减车道）时按荷兰的常规（加减都在右侧）搬运概率；
//   4. 每条车道一个概率，随时间缓慢扩散（承认会漏检变道），最大概率不到阈值就不显示。
//
// 只在高速/快速路上工作（车速 ≥ 12 m/s 且知道车道数）。市区做不了，也不假装能做。

/// 一次陀螺仪读数（宿主从 CoreMotion 取，已换算成绕竖直轴的角速度，与手机怎么摆放无关）。
public struct MotionSample: Sendable, Equatable {
    public var timestamp: Date
    /// 航向角速度（度/秒），右转为正（与方位角同向）。
    public var headingRate: Double

    public init(timestamp: Date, headingRate: Double) {
        self.timestamp = timestamp
        self.headingRate = headingRate
    }
}

public struct LaneChangeEvent: Sendable, Equatable {
    public enum Direction: Int, Sendable {
        case left = -1
        case right = 1
    }

    public var direction: Direction
    public var at: Date
    /// 这次检测有多可信（0–1）：陀螺仪和 GPS 一致时高，只有一方时低。
    public var confidence: Double

    public init(direction: Direction, at: Date, confidence: Double) {
        self.direction = direction
        self.at = at
        self.confidence = confidence
    }
}

/// 一次更新的结果：要么检测到一次变道，要么给出"有多可疑"（挪动了但没到变道阈值）。
public struct LaneChangeObservation: Sendable, Equatable {
    public var event: LaneChangeEvent?
    /// 0 = 横向稳稳不动；1 = 挪动已接近变道阈值（可能漏检了一次变道）。
    public var ambiguity: Double

    public static let quiet = LaneChangeObservation(event: nil, ambiguity: 0)
}

public struct LaneChangeDetectorConfig: Sendable {
    public var laneWidth = 3.5
    /// 一个窗口内的侧向位移达到车道宽的这个比例、且航向已回正，算一次变道。
    public var trigger = 0.6
    /// 没有陀螺仪时 GPS 侧向位移达到这个比例只算"可疑"（降低把握），不报变道：
    /// 模拟里只靠 GPS 的检出率约 75%、误报多，不足以支撑"你在第几车道"。
    public var gnssOnlyTrigger = 0.8
    /// 滤波器预热（秒）：第一次启动要估出陀螺仪零偏；之后零偏沿用，只需短预热。
    public var warmup: TimeInterval = 30
    public var shortWarmup: TimeInterval = 5
    /// 另一路信号达到车道宽的这个比例算"同意"。
    public var agreement = 0.3
    /// 侧向位移超过车道宽的这个比例（但没判定为变道）才算"可疑"。
    /// 合成后的噪声约 0.65 m，门槛放在约 2.4 倍噪声处，避免正常抖动不断蚕食把握。
    public var doubtFloor = 0.45
    /// 两路侧向位移在 10 秒窗口里的典型误差（米），用来加权合成。
    public var imuMoveSigma = 0.8
    public var gnssMoveSigma = 1.2
    /// 看最近这么多秒的侧向位移（要盖住一次 4–8 秒的变道）。
    public var window: TimeInterval = 10
    /// 航向偏差小于它（度）算"已回正"，变道做完了才判定。
    public var settledHeading = 0.6
    /// 窗口内航向偏差的峰值至少这么大（度），才像一次变道（100 km/h 下 4 秒变道约 2.8°、8 秒约 1.4°）；
    /// 漂移造成的假横移，航向偏差一直只有零点几度。
    public var minPeakHeading = 1.0
    /// GPS 航向的噪声（度），卡尔曼滤波用它和陀螺仪加权。
    public var courseSigma = 0.8
    /// 陀螺仪角速度噪声（度/√秒）与零偏漂移（度/秒/√秒）。手机 MEMS 陀螺仪典型值约 0.01，这里留了余量。
    public var gyroNoise = 0.03
    public var biasDrift = 0.001
    /// GPS 横向值的平滑时间（秒）。
    public var gnssSmoothing: TimeInterval = 2.5
    public var minSpeed = 12.0
    public var maxGnssAccuracy = 12.0

    public init() {}
}

/// 变道检测。每个 GPS 点调用一次，带上这段时间里的陀螺仪读数。
///
/// 1. 航向偏差 ψ（车头相对道路的角度）与陀螺仪零偏用一个两状态卡尔曼滤波估计：
///    陀螺仪给高频（10 Hz），GPS 航向给绝对参考（1 Hz），道路弯道的转角先减掉。
///    不估零偏的话，0.05°/s 的零偏经两次积分半分钟就是两米的假横移。
/// 2. 侧向位移只在最近 `window` 秒里累计：陀螺仪一路（∫v·sinψ），GPS 一路（平滑后横向值之差）。
/// 3. 航向回正（变道做完）且位移够大才判定；判定后窗口从这一刻重新开始，同一次变道不会算两次。
public struct LaneChangeDetector: Sendable {
    public let config: LaneChangeDetectorConfig

    private var lastFixTime: Date?
    private var lastMotionTime: Date?
    private var lastRoadBearing: Double?
    // 卡尔曼状态：ψ（度）、零偏 b（度/秒）及协方差
    private var psi = 0.0
    private var bias = 0.0
    private var p00 = 4.0, p01 = 0.0, p11 = 0.01
    // 每个 GPS 点：时间、这一段陀螺仪侧向增量、平滑后的 GPS 横向值
    private var history: [(t: Date, imu: Double, gnss: Double?, psiMax: Double, psiMin: Double)] = []
    private var gnssSmoothed: Double?
    private var windowStart: Date?
    private var lastMotionSeen: Date?
    private var warmupUntil: Date?
    private var biasKnown = false
    /// 已经上报过的可疑程度（同一次横移只上报一次，随窗口滑走而衰减）。
    private var reportedSuspicion = 0.0

    public init(config: LaneChangeDetectorConfig = LaneChangeDetectorConfig()) {
        self.config = config
    }

    /// 重新开始（换路线、离开高速……）。陀螺仪零偏很稳定，默认保留。
    public mutating func reset(keepBias: Bool = true) {
        let (b, pb, known) = (bias, p11, biasKnown)
        self = LaneChangeDetector(config: config)
        if keepBias && known {
            bias = b
            p11 = pb
            biasKnown = true
        }
    }

    /// - Parameters:
    ///   - signedLateral: GPS 点相对路线的带符号横向距离（右正）
    ///   - roadBearing: 当前位置的道路方向（平滑后）
    public mutating func update(fix: LocationFix, signedLateral: Double, roadBearing: Double,
                                motion: [MotionSample]) -> LaneChangeObservation {
        defer {
            lastFixTime = fix.timestamp
            lastRoadBearing = roadBearing
        }
        guard let speed = fix.speed, speed >= config.minSpeed, let prevFix = lastFixTime,
              case let dtFix = fix.timestamp.timeIntervalSince(prevFix), dtFix > 0, dtFix < 5 else {
            // 太慢（不在高速上）、第一个点或断档：重新开始。
            reset()
            lastMotionTime = fix.timestamp
            return .quiet
        }
        if warmupUntil == nil {
            warmupUntil = fix.timestamp.addingTimeInterval(biasKnown ? config.shortWarmup : config.warmup)
        }

        // 道路自身的转弯（弯道）不是变道：从陀螺仪里减掉。
        let roadRate = lastRoadBearing.map { signedAngle(from: $0, to: roadBearing) / dtFix } ?? 0

        // 1. 预测：陀螺仪
        var imuIncrement = 0.0
        var psiMax = psi, psiMin = psi
        var t = lastMotionTime ?? prevFix
        let samples = motion.filter { $0.timestamp > t }.sorted { $0.timestamp < $1.timestamp }
        if samples.isEmpty {
            predict(rate: roadRate, roadRate: roadRate, dt: dtFix, noImu: true)
            imuIncrement = 0
            t = fix.timestamp
        } else {
            for m in samples {
                let dt = min(0.5, m.timestamp.timeIntervalSince(t))
                t = m.timestamp
                predict(rate: m.headingRate, roadRate: roadRate, dt: dt, noImu: false)
                imuIncrement += speed * sin(Geo.radians(psi)) * dt
                psiMax = max(psiMax, psi)
                psiMin = min(psiMin, psi)
            }
            lastMotionSeen = t
        }
        lastMotionTime = t

        // 2. 更新：GPS 航向（相对道路）
        if let course = fix.course {
            correct(observedPsi: signedAngle(from: roadBearing, to: course))
        }

        // 3. GPS 横向值平滑
        var gnss: Double?
        if fix.horizontalAccuracy <= config.maxGnssAccuracy {
            let a = min(1, dtFix / config.gnssSmoothing)
            let smoothed = gnssSmoothed.map { $0 + (signedLateral - $0) * a } ?? signedLateral
            gnssSmoothed = smoothed
            gnss = smoothed
        }
        history.append((fix.timestamp, imuIncrement, gnss, psiMax, psiMin))
        let cutoff = fix.timestamp.addingTimeInterval(-config.window)
        history.removeAll { $0.t < cutoff }
        let start = max(windowStart ?? cutoff, cutoff)

        // 4. 判定
        let w = config.laneWidth
        let imuFresh = lastMotionSeen.map { fix.timestamp.timeIntervalSince($0) < 2 } ?? false
        let m = moves(since: start)
        let settled: Bool
        let primary: Double
        let trigger: Double
        if imuFresh {
            settled = abs(psi) < config.settledHeading
            // 两路误差独立：按方差倒数加权，合成后的误差比任一路都小。
            if let g = m.gnss {
                let wi = 1 / (config.imuMoveSigma * config.imuMoveSigma)
                let wg = 1 / (config.gnssMoveSigma * config.gnssMoveSigma)
                primary = (m.imu * wi + g * wg) / (wi + wg)
            } else {
                primary = m.imu
            }
            trigger = config.trigger * w
        } else {
            // 没有陀螺仪：用最近 2 秒 GPS 横向变化判断"停下来了没有"。
            let recent = history.filter { $0.t >= fix.timestamp.addingTimeInterval(-2.5) }.compactMap(\.gnss)
            settled = recent.count >= 2 && abs(recent.last! - recent.first!) < 0.4
            primary = m.gnss ?? 0
            trigger = config.gnssOnlyTrigger * w
        }

        // 陀螺仪在场时，还要看到像变道的航向峰值（方向与位移一致）。
        let looksLikeLaneChange: Bool = {
            guard imuFresh else { return true }
            let window = history.filter { $0.t > start }
            let peak = primary > 0 ? (window.map(\.psiMax).max() ?? 0) : -(window.map(\.psiMin).min() ?? 0)
            return peak >= config.minPeakHeading
        }()

        let floor = config.doubtFloor * w
        let warmingUp = fix.timestamp < warmupUntil!
        if !warmingUp && imuFresh { biasKnown = true }
        reportedSuspicion *= exp(-dtFix / config.window)
        func doubt(_ suspicion: Double) -> LaneChangeObservation {
            let increment = max(0, suspicion - reportedSuspicion)
            reportedSuspicion = max(reportedSuspicion, suspicion)
            return LaneChangeObservation(event: nil, ambiguity: increment)
        }

        // 预热中或没有陀螺仪：不报变道；GPS 一路（不受滤波器预热影响）看到可疑横移就只降低把握。
        guard imuFresh, !warmingUp else {
            if warmingUp { windowStart = fix.timestamp }   // 预热期间的陀螺仪位移不可信，不带进之后的窗口
            let g = abs(moves(since: cutoff).gnss ?? 0)
            return doubt(min(1, max(0, (g - floor) / (config.gnssOnlyTrigger * w - floor))))
        }
        guard settled, abs(primary) >= trigger, looksLikeLaneChange else {
            return doubt(settled ? min(1, max(0, (abs(primary) - floor) / (trigger - floor))) : 0)
        }

        let dir: LaneChangeEvent.Direction = primary > 0 ? .right : .left
        let gnssAgree = (m.gnss ?? 0) * Double(dir.rawValue)
        let imuAgree = m.imu * Double(dir.rawValue)
        let agree = config.agreement * w
        let confidence = (gnssAgree >= agree && imuAgree >= agree) ? 0.9 : (min(gnssAgree, imuAgree) <= -agree ? 0.35 : 0.6)
        windowStart = fix.timestamp   // 这次位移已经用掉
        reportedSuspicion = 0
        return LaneChangeObservation(event: LaneChangeEvent(direction: dir, at: fix.timestamp, confidence: confidence),
                                     ambiguity: 0)
    }

    /// 窗口内两路的侧向位移。
    private func moves(since start: Date) -> (imu: Double, gnss: Double?) {
        let imu = history.filter { $0.t > start }.reduce(0) { $0 + $1.imu }
        let before = history.last(where: { $0.t <= start })?.gnss ?? history.first?.gnss
        guard let b = before, let e = history.last?.gnss else { return (imu, nil) }
        return (imu, e - b)
    }

    /// 卡尔曼预测。状态 [ψ, b]，ψ' = ψ + (ω − ω_road − b)·dt。
    private mutating func predict(rate: Double, roadRate: Double, dt: Double, noImu: Bool) {
        guard dt > 0 else { return }
        if noImu {
            // 没有陀螺仪：ψ 只能靠 GPS 航向，预测阶段只加大不确定性。
            p00 += 1.0 * dt
            p11 += config.biasDrift * config.biasDrift * dt
            return
        }
        psi += (rate - roadRate - bias) * dt
        // P = F P Fᵀ + Q，F = [[1, -dt], [0, 1]]
        let n00 = p00 - 2 * dt * p01 + dt * dt * p11 + config.gyroNoise * config.gyroNoise * dt
        let n01 = p01 - dt * p11
        p00 = n00
        p01 = n01
        p11 += config.biasDrift * config.biasDrift * dt
    }

    /// 卡尔曼更新：观测 z = ψ（GPS 航向 − 道路方向），H = [1, 0]。
    private mutating func correct(observedPsi z: Double) {
        let s = p00 + config.courseSigma * config.courseSigma
        let k0 = p00 / s, k1 = p01 / s
        let innovation = z - psi
        psi += k0 * innovation
        bias += k1 * innovation
        let n00 = (1 - k0) * p00
        let n01 = (1 - k0) * p01
        let n11 = p11 - k1 * p01
        p00 = n00
        p01 = n01
        p11 = n11
    }

    private func signedAngle(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }
}

// MARK: - 车道估计

public struct LaneEstimate: Sendable, Equatable {
    /// 从左数，0 起（与 LaneGuidance 的车道顺序一致）。
    public var lane: Int
    public var laneCount: Int
    public var confidence: Double

    public init(lane: Int, laneCount: Int, confidence: Double) {
        self.lane = lane
        self.laneCount = laneCount
        self.confidence = confidence
    }
}

public struct LaneEstimatorConfig: Sendable {
    /// 横向完全不动时，每秒仍有这么一点概率"漏检了变道"（兜底）。
    public var diffusionPerSecond = 0.0005
    /// 横向出现可疑挪动（ambiguity = 1）时，一次扩散这么多到相邻车道。
    public var ambiguityDiffusion = 0.15
    public init() {}
}

/// 每条车道一个概率。没有锚点时是均匀分布（= 不知道）。
public struct LaneEstimator: Sendable {
    public let config: LaneEstimatorConfig
    public private(set) var probabilities: [Double] = []
    private var previousLaneCount: Int?

    public init(config: LaneEstimatorConfig = LaneEstimatorConfig()) {
        self.config = config
    }

    public var laneCount: Int? { probabilities.isEmpty ? nil : probabilities.count }

    public var estimate: LaneEstimate? {
        guard let (lane, p) = probabilities.enumerated().max(by: { $0.element < $1.element }).map({ ($0.offset, $0.element) })
        else { return nil }
        return LaneEstimate(lane: lane, laneCount: probabilities.count, confidence: p)
    }

    public mutating func reset() {
        probabilities = []
        previousLaneCount = nil
    }

    /// 车道数变了。荷兰的常规：加车道、减车道都发生在右侧；
    /// 从单车道匝道并入多车道道路 → 一定在最右车道（最可靠的锚点）。
    public mutating func setLaneCount(_ n: Int) {
        guard n >= 1, n != probabilities.count else { return }
        let old = probabilities
        if old.isEmpty {
            if previousLaneCount == 1 && n > 1 {
                probabilities = (0..<n).map { $0 == n - 1 ? 1 : 0 }
            } else {
                probabilities = Array(repeating: 1 / Double(n), count: n)
            }
        } else if n > old.count {
            probabilities = old + Array(repeating: 0, count: n - old.count)
            if old.count == 1 {   // 匝道并入
                probabilities = (0..<n).map { $0 == n - 1 ? 1 : 0 }
            }
        } else {
            // 右侧车道结束：在那几条车道上的车被迫并到新的最右车道。
            var p = Array(old.prefix(n))
            p[n - 1] += old.dropFirst(n).reduce(0, +)
            probabilities = p
        }
        previousLaneCount = n
        normalize()
    }

    /// 道路不再有车道信息（例如离开高速进入市区）：忘掉，但记住最后的车道数（用于判断"从匝道并入"）。
    public mutating func clear(keepingLaneCount: Bool = true) {
        if keepingLaneCount { previousLaneCount = probabilities.isEmpty ? previousLaneCount : probabilities.count }
        probabilities = []
    }

    public mutating func apply(_ event: LaneChangeEvent) {
        let n = probabilities.count
        guard n > 1 else { return }
        let c = event.confidence
        var shifted = Array(repeating: 0.0, count: n)
        for i in 0..<n {
            let j = min(n - 1, max(0, i + event.direction.rawValue))   // 越界的质量留在边上车道
            shifted[j] += probabilities[i]
        }
        probabilities = (0..<n).map { c * shifted[$0] + (1 - c) * probabilities[$0] }
        normalize()
    }

    /// 可能漏检了变道：概率向相邻车道扩散。横向越"可疑"扩散越多；稳稳不动时几乎不扩散。
    public mutating func diffuse(seconds: TimeInterval, ambiguity: Double = 0) {
        let n = probabilities.count
        guard n > 1, seconds > 0 || ambiguity > 0 else { return }
        let q = min(0.5, config.diffusionPerSecond * max(0, seconds) + config.ambiguityDiffusion * ambiguity)
        var p = probabilities.map { $0 * (1 - q) }
        for i in 0..<n {
            let share = probabilities[i] * q
            let neighbors = [i - 1, i + 1].filter { $0 >= 0 && $0 < n }
            for j in neighbors { p[j] += share / Double(neighbors.count) }
        }
        probabilities = p
        normalize()
    }

    private mutating func normalize() {
        let s = probabilities.reduce(0, +)
        guard s > 0 else { return }
        probabilities = probabilities.map { $0 / s }
    }
}

/// "向右变道 1 条"：当前车道不在推荐车道里时才给。
public struct LaneChangeAdvice: Sendable, Equatable {
    public var direction: LaneChangeEvent.Direction
    public var lanes: Int
    /// 要在这么远之内完成（= 到下一个动作的距离）。
    public var within: Double

    public init(direction: LaneChangeEvent.Direction, lanes: Int, within: Double) {
        self.direction = direction
        self.lanes = lanes
        self.within = within
    }
}
