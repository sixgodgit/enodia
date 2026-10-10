import Foundation
@testable import NavCore

/// 测试用的"平面世界"：以乌得勒支附近为原点，用米来摆路线，再换算成经纬度。
enum World {
    static let anchor = Coordinate(52.0907, 5.1214)
    static let frame = LocalFrame(anchor: anchor)

    static func c(_ x: Double, _ y: Double) -> Coordinate { frame.unproject(x: x, y: y) }
    static func path(_ xy: [(Double, Double)]) -> [Coordinate] { xy.map { c($0.0, $0.1) } }

    /// 2026-10-12（周一）10:00 阿姆斯特丹时间（夏令时，UTC+2）。
    static let t0 = ISO8601.parse("2026-10-12T08:00:00Z")!

    static var dataDir: URL {
        // Tests/NavCoreTests/Support.swift → contracts/
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("contracts")
    }
}

/// 可复现的伪随机数（SplitMix64）+ 正态分布。
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func gaussian(_ sigma: Double) -> Double {
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        return sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// 沿一条米制折线开车，1 Hz 出 GPS 点。
struct Drive {
    var path: [(Double, Double)]
    var speed: Double            // m/s
    var hz: Double = 1
    var noise: Double = 0        // 每个轴的高斯噪声（米）
    var accuracy: Double = 5
    var start: Date = World.t0
    var seed: UInt64 = 42

    func fixes() -> [LocationFix] {
        var rng = SeededRandom(seed: seed)
        var out: [LocationFix] = []
        var seg = 0, along = 0.0, t = 0.0
        let step = speed / hz
        while seg < path.count - 1 {
            let (ax, ay) = path[seg], (bx, by) = path[seg + 1]
            let len = hypot(bx - ax, by - ay)
            if along > len { along -= len; seg += 1; continue }
            let f = len > 0 ? along / len : 0
            let x = ax + (bx - ax) * f + rng.gaussian(noise)
            let y = ay + (by - ay) * f + rng.gaussian(noise)
            let course = Geo.normalize(Geo.degrees(atan2(bx - ax, by - ay)) + rng.gaussian(noise > 0 ? 3 : 0))
            out.append(LocationFix(coordinate: World.c(x, y), timestamp: start.addingTimeInterval(t),
                                   horizontalAccuracy: accuracy, speed: speed, course: course))
            along += step
            t += 1 / hz
        }
        return out
    }
}

/// 典型场景：东西向高速，x = 0 处右侧出口（afrit），出口匝道向东南然后向南。
enum Scenario {
    static let motorwayWest: [(Double, Double)] = [(-3000, 0), (0, 0)]
    static let ramp: [(Double, Double)] = [(0, 0), (150, -20), (300, -60), (500, -150), (700, -300), (700, -2000)]
    static let motorwayEast: [(Double, Double)] = [(0, 0), (5000, 0)]

    /// 走出口的主路线：高速 3 km → 出口 → 南下。
    static func exitRoute(id: RouteID = "main", classes: Bool = true, speedLimit: Int? = nil) -> Route {
        let xy = motorwayWest + ramp.dropFirst()
        let pts = World.path(xy)
        let cum = Route.cumulativeDistances(pts)
        let rampStart = cum[1]
        return Route(id: id, points: pts, cumulative: cum,
                     maneuvers: [
                        Maneuver(offset: 0, kind: .depart, roadName: "A12"),
                        Maneuver(offset: rampStart, kind: .exitRight, roadName: "N228", exitNumber: "14",
                                 signpost: "Woerden", roadClass: .motorway),
                        Maneuver(offset: cum[cum.count - 1], kind: .arrive),
                     ],
                     expectedDuration: 300,
                     providerSpeedLimits: speedLimit.map { [ValueSpan(start: 0, end: rampStart, value: $0)] } ?? [],
                     roadClasses: classes ? [ValueSpan(start: 0, end: rampStart, value: .motorway),
                                             ValueSpan(start: rampStart, end: cum[cum.count - 1] + 1, value: .rural)] : [],
                     createdAt: World.t0)
    }

    /// 同起点、出口不下、继续沿高速往东的备选路线。
    static func straightAlternative(id: RouteID = "alt") -> Route {
        let pts = World.path(motorwayWest + motorwayEast.dropFirst())
        return Route(id: id, origin: .alternative, points: pts,
                     maneuvers: [Maneuver(offset: Route.cumulativeDistances(pts).last!, kind: .arrive)],
                     expectedDuration: 330, createdAt: World.t0)
    }

    /// 错过出口后的预算路线：从"错过"点（出口后 350 m）继续往东。
    static func speculativeAfterMiss(id: RouteID = "spec") -> Route {
        let pts = World.path([(350, 0), (5000, 0)])
        return Route(id: id, origin: .speculative, points: pts,
                     maneuvers: [Maneuver(offset: Route.cumulativeDistances(pts).last!, kind: .arrive)],
                     expectedDuration: 200, createdAt: World.t0)
    }

    /// 错过出口的那趟车：一直在高速上往东开。
    static let missedExitDrive: [(Double, Double)] = [(-1500, 0), (3000, 0)]
    /// 正常走出口。
    static let takeExitDrive: [(Double, Double)] = [(-1500, 0)] + ramp + [(700, -2040)]
}

extension NavigationEngine {
    /// 把 intents 里的路线请求拿出来。
    static func requests(_ outputs: [EngineOutput]) -> [RouteRequest] {
        outputs.flatMap(\.intents).compactMap { if case .requestRoute(let r) = $0 { return r } else { return nil } }
    }

    static func changes(_ outputs: [EngineOutput]) -> [RouteChange] {
        outputs.flatMap(\.intents).compactMap { if case .activeRouteChanged(let c) = $0 { return c } else { return nil } }
    }
}

extension EngineOutput {
    var requests: [RouteRequest] { NavigationEngine.requests([self]) }
}
