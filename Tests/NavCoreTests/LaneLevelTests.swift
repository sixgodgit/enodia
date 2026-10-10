import XCTest
@testable import NavCore

/// 模拟：从单车道匝道并入三车道高速，途中有弯道，按时间表变道。
/// GPS 误差是前后相关的（手机 CoreLocation 输出本身就是滤波过的），陀螺仪带白噪声和零偏。
struct LaneDriveSim {
    struct Change { var at: TimeInterval; var toLane: Int }

    var route: Route
    var speed = 28.0                 // 100 km/h
    var laneWidth = 3.5
    var laneCount = 3
    var rampEnd = 400.0              // 前 400 m 是单车道匝道（与最右车道对齐）
    var changes: [Change] = []
    var changeDuration: TimeInterval = 4
    var gnssSigma = 1.0              // 每轴，AR(1)
    var gnssTau: TimeInterval = 5
    var gyroSigma = 0.1              // 度/秒，10 Hz 白噪声（≈0.03°/√s，比手机 MEMS 典型值悲观约 3 倍）
    var gyroBias = 0.05
    var withMotion = true
    var seed: UInt64 = 1
    var duration: TimeInterval = 200

    /// 路线：东行直道 → 半径 1500 m 的右弯（30°）→ 直道。顶点间距 20 m。
    static func curvedMotorway(laneCounts: Bool = true, rampEnd: Double = 400) -> Route {
        var xy: [(Double, Double)] = [(0, 0)]
        var heading = 90.0, x = 0.0, y = 0.0, s = 0.0
        let step = 20.0
        while s < 9000 {
            if s > 2500 && s < 2500 + 1500 * Double.pi / 6 { heading += step / 1500 * 180 / .pi }
            x += step * sin(Geo.radians(heading))
            y += step * cos(Geo.radians(heading))
            s += step
            xy.append((x, y))
        }
        let pts = World.path(xy)
        let len = Route.cumulativeDistances(pts).last!
        return Route(id: "lanes", points: pts,
                     maneuvers: [Maneuver(offset: 6000, kind: .exitRight, roadClass: .motorway),
                                 Maneuver(offset: len, kind: .arrive)],
                     roadClasses: [ValueSpan(start: 0, end: len + 1, value: .motorway)],
                     laneCounts: laneCounts ? [ValueSpan(start: 0, end: rampEnd, value: 1),
                                               ValueSpan(start: rampEnd, end: len + 1, value: 3)] : [],
                     createdAt: World.t0)
    }

    /// 真实车道（从左数）与相对路线中心线的横向偏移（右正）。
    func truth(at t: TimeInterval) -> (lane: Int, lateral: Double) {
        var lane = laneCount - 1
        var lateral = laneCenter(lane)
        for c in changes {
            if t >= c.at + changeDuration {
                lane = c.toLane
                lateral = laneCenter(lane)
            } else if t > c.at {
                let f = (1 - cos(.pi * (t - c.at) / changeDuration)) / 2
                lateral = laneCenter(lane) + (laneCenter(c.toLane) - laneCenter(lane)) * f
                break
            } else {
                break
            }
        }
        return (lane, lateral)
    }

    func laneCenter(_ i: Int) -> Double { (Double(i) - Double(laneCount - 1) / 2) * laneWidth }

    func pose(at t: TimeInterval) -> (Coordinate, heading: Double) {
        let s = speed * t
        let bearing = route.smoothedBearing(at: s, window: 10)
        let l = truth(at: t).lateral
        let dl = (truth(at: t + 0.05).lateral - truth(at: t - 0.05).lateral) / 0.1
        let (bx, by) = World.frame.project(route.coordinate(at: s))
        let x = bx + l * cos(Geo.radians(bearing)), y = by - l * sin(Geo.radians(bearing))
        return (World.c(x, y), Geo.normalize(bearing + Geo.degrees(atan2(dl, speed))))
    }

    /// (fix, 这一秒内的陀螺仪读数)
    func run() -> [(LocationFix, [MotionSample])] {
        var rng = SeededRandom(seed: seed)
        var ex = 0.0, ey = 0.0
        let a = exp(-1 / gnssTau), q = gnssSigma * (1 - a * a).squareRoot()
        var out: [(LocationFix, [MotionSample])] = []
        var prevHeading = pose(at: 0).heading
        for k in 0...Int(duration) {
            let t = Double(k)
            var motion: [MotionSample] = []
            if withMotion && k > 0 {
                for j in 1...10 {
                    let tt = t - 1 + Double(j) * 0.1
                    let h = pose(at: tt).heading
                    var dh = h - prevHeading
                    if dh > 180 { dh -= 360 }
                    if dh < -180 { dh += 360 }
                    prevHeading = h
                    motion.append(MotionSample(timestamp: World.t0.addingTimeInterval(tt),
                                               headingRate: dh / 0.1 + gyroBias + rng.gaussian(gyroSigma)))
                }
            }
            ex = a * ex + rng.gaussian(q)
            ey = a * ey + rng.gaussian(q)
            let (c, heading) = pose(at: t)
            let (x, y) = World.frame.project(c)
            out.append((LocationFix(coordinate: World.c(x + ex, y + ey), timestamp: World.t0.addingTimeInterval(t),
                                    horizontalAccuracy: 4, speed: speed + rng.gaussian(0.3),
                                    course: Geo.normalize(heading + rng.gaussian(0.8))), motion))
        }
        return out
    }
}

final class LaneChangeDetectorTests: XCTestCase {
    let route = LaneDriveSim.curvedMotorway()

    func events(_ sim: LaneDriveSim) -> [LaneChangeEvent] {
        var detector = LaneChangeDetector()
        var matcher = RouteMatcher()
        var out: [LaneChangeEvent] = []
        for (fix, motion) in sim.run() {
            guard let m = matcher.match(fix, on: sim.route) else { continue }
            if let e = detector.update(fix: fix, signedLateral: m.signedLateral,
                                       roadBearing: sim.route.smoothedBearing(at: m.offset), motion: motion).event {
                out.append(e)
            }
        }
        return out
    }

    func testSignedLateral() {
        var matcher = RouteMatcher()
        let left = matcher.match(LocationFix(coordinate: World.c(500, 3), timestamp: World.t0), on: route)!
        XCTAssertEqual(left.signedLateral, -3, accuracy: 0.1, "east-bound route: north is the left side")
        var m2 = RouteMatcher()
        XCTAssertEqual(m2.match(LocationFix(coordinate: World.c(500, -3), timestamp: World.t0), on: route)!.signedLateral,
                       3, accuracy: 0.1)
    }

    func testNoFalseLaneChangesOnStraightsAndCurves() {
        // 整段 300 s 跨过 1.5 km 半径的弯道，一直在同一车道。
        for seed in UInt64(1)...10 {
            var sim = LaneDriveSim(route: route)
            sim.seed = seed
            sim.duration = 300
            XCTAssertEqual(events(sim).count, 0, "seed \(seed): false lane change")
        }
    }

    /// 统计回归：60 组随机种子，每组 3 次变道（其中一次在弯道里）+ 300 s 平稳驾驶。
    /// 当前实现的实测：检出 176/180、方向全对、无多报；平稳驾驶误报约 0.2 次/小时
    /// （另取 200 组共 16.7 小时测得 3 次，这里的 60 组 5 小时里是 2 次）。
    func testSimulationMetrics() {
        var detected = 0, wrongDirection = 0, missed = 0, extra = 0, quietFalse = 0
        for seed in UInt64(1)...60 {
            var sim = LaneDriveSim(route: route)
            sim.seed = seed
            sim.changes = [.init(at: 40, toLane: 1), .init(at: 70, toLane: 0), .init(at: 100, toLane: 1)]
            let e = events(sim)
            var used = Set<Int>()
            for (t0, dir) in [(40.0, LaneChangeEvent.Direction.left), (70, .left), (100, .right)] {
                let window = t0...(t0 + 10)
                if let i = e.indices.first(where: { !used.contains($0) && window.contains(e[$0].at.timeIntervalSince(World.t0)) }) {
                    used.insert(i)
                    if e[i].direction == dir { detected += 1 } else { wrongDirection += 1 }
                } else {
                    missed += 1
                }
            }
            extra += e.count - used.count

            var quiet = LaneDriveSim(route: route)
            quiet.seed = seed + 1000
            quiet.duration = 300
            quietFalse += events(quiet).count
        }
        print("lane change detection: \(detected)/180, wrong \(wrongDirection), missed \(missed), extra \(extra), "
              + "false in 5 h quiet driving \(quietFalse)")
        XCTAssertGreaterThanOrEqual(detected, 171, "≥ 95% recall")
        XCTAssertEqual(wrongDirection, 0)
        XCTAssertLessThanOrEqual(extra, 1)
        XCTAssertLessThanOrEqual(quietFalse, 3)
    }

    func testGpsOnlyNeverClaimsLaneChangesButRaisesDoubt() {
        var sim = LaneDriveSim(route: route)
        sim.withMotion = false
        sim.changes = [.init(at: 40, toLane: 1), .init(at: 70, toLane: 0)]
        var detector = LaneChangeDetector()
        var matcher = RouteMatcher()
        var events = 0
        var maxAmbiguity = 0.0
        for (fix, motion) in sim.run() {
            let m = matcher.match(fix, on: route)!
            let o = detector.update(fix: fix, signedLateral: m.signedLateral,
                                    roadBearing: route.smoothedBearing(at: m.offset), motion: motion)
            if o.event != nil { events += 1 }
            maxAmbiguity = max(maxAmbiguity, o.ambiguity)
        }
        XCTAssertEqual(events, 0, "without a gyro we can't count lane changes reliably — so we don't")
        XCTAssertGreaterThan(maxAmbiguity, 0.5, "...but the lateral moves must lower confidence")
    }

    func testLaneChangeDuringWarmupOnlyRaisesDoubt() {
        var sim = LaneDriveSim(route: route)
        sim.changes = [.init(at: 8, toLane: 1)]
        sim.duration = 30
        var detector = LaneChangeDetector()
        var matcher = RouteMatcher()
        var events = 0
        var maxAmbiguity = 0.0
        for (fix, motion) in sim.run() {
            let m = matcher.match(fix, on: route)!
            let o = detector.update(fix: fix, signedLateral: m.signedLateral,
                                    roadBearing: route.smoothedBearing(at: m.offset), motion: motion)
            if o.event != nil { events += 1 }
            maxAmbiguity = max(maxAmbiguity, o.ambiguity)
        }
        XCTAssertEqual(events, 0)
        XCTAssertGreaterThan(maxAmbiguity, 0.5)
    }
}

final class LaneEstimatorTests: XCTestCase {
    func testRampMergeAnchorsRightmostLane() {
        var e = LaneEstimator()
        e.setLaneCount(1)
        e.setLaneCount(3)
        XCTAssertEqual(e.estimate, LaneEstimate(lane: 2, laneCount: 3, confidence: 1))
    }

    func testUnknownStartIsUniform() {
        var e = LaneEstimator()
        e.setLaneCount(3)
        XCTAssertEqual(e.estimate!.confidence, 1.0 / 3, accuracy: 1e-9)
    }

    func testLaneChangeShiftsAndEdgesHold() {
        var e = LaneEstimator()
        e.setLaneCount(1)
        e.setLaneCount(3)
        e.apply(LaneChangeEvent(direction: .left, at: World.t0, confidence: 0.9))
        XCTAssertEqual(e.estimate?.lane, 1)
        XCTAssertEqual(e.estimate!.confidence, 0.9, accuracy: 1e-9)
        // 已经在最右车道还"向右变道"：越界的质量留在最右车道，不凭空出现第 4 条车道。
        var r = LaneEstimator()
        r.setLaneCount(1)
        r.setLaneCount(2)
        r.apply(LaneChangeEvent(direction: .right, at: World.t0, confidence: 0.85))
        XCTAssertEqual(r.estimate, LaneEstimate(lane: 1, laneCount: 2, confidence: 1))
    }

    func testRightLaneEndingForcesMerge() {
        var e = LaneEstimator()
        e.setLaneCount(1)
        e.setLaneCount(4)   // 并入时有加速车道
        e.setLaneCount(3)   // 加速车道结束
        XCTAssertEqual(e.estimate, LaneEstimate(lane: 2, laneCount: 3, confidence: 1))
    }

    func testConfidenceDecaysOnlyWithSuspiciousLateralMotion() {
        var steady = LaneEstimator()
        steady.setLaneCount(1)
        steady.setLaneCount(3)
        for _ in 0..<120 { steady.diffuse(seconds: 1, ambiguity: 0) }
        XCTAssertGreaterThan(steady.estimate!.confidence, 0.9, "two quiet minutes in one lane: still sure")

        var wobbly = LaneEstimator()
        wobbly.setLaneCount(1)
        wobbly.setLaneCount(3)
        for _ in 0..<3 { wobbly.diffuse(seconds: 1, ambiguity: 1) }
        XCTAssertEqual(wobbly.estimate?.lane, 2)
        XCTAssertLessThan(wobbly.estimate!.confidence, 0.7, "near-threshold drifts: maybe a missed lane change")
    }

    func testClearRemembersRampForNextMerge() {
        var e = LaneEstimator()
        e.setLaneCount(1)
        e.clear()             // 匝道上有一小段没有车道数据
        e.setLaneCount(3)
        XCTAssertEqual(e.estimate?.lane, 2)
    }
}

final class LaneLevelEngineTests: XCTestCase {
    /// 跑一趟：返回每秒的画面（下标 = 秒）。laneFeedAt 秒时高德给出车道图（3 条车道，推荐最右）。
    private func drive(_ changes: [LaneDriveSim.Change], laneFeedAt: Int? = nil, duration: TimeInterval = 200)
        -> [DriveDisplayState] {
        let route = LaneDriveSim.curvedMotorway()
        var sim = LaneDriveSim(route: route)
        sim.changes = changes
        sim.duration = duration
        let run = sim.run()
        let engine = NavigationEngine()
        engine.startTrip(TripPlan(id: "t", destination: route.destination))
        var out = [engine.process(run[0].0).display]
        engine.offer(RouteOffer(requestID: 1, purpose: .initial, routes: [route]))
        for (k, (fix, motion)) in run.enumerated() where k > 0 {
            if k == laneFeedAt {
                engine.updateLanes(LaneFeed(guidance: AmapLaneDecoder.decode(background: "0|0|4", selection: "255|255|4"),
                                            receivedAt: fix.timestamp))
            }
            out.append(engine.process(fix, motion: motion).display)
        }
        return out
    }

    func testEngineTracksLaneThroughLaneChanges() {
        let d = drive([.init(at: 40, toLane: 1), .init(at: 70, toLane: 0)], duration: 100)
        XCTAssertEqual(d[30].currentLane?.lane, 2, "merged from the ramp: rightmost lane")
        XCTAssertEqual(d[50].currentLane?.lane, 1)
        XCTAssertEqual(d[80].currentLane?.lane, 0)
        XCTAssertGreaterThan(d[80].currentLane?.confidence ?? 0, 0.75)
        XCTAssertTrue(d.dropFirst(2).allSatisfy { $0.phase == .guiding }, "lane offsets never look like going off route")
    }

    func testEngineAdvisesLaneChangeBeforeExit() {
        // 弯道之后从最右车道换到中间车道；出口（6000 m）在右侧，车道图推荐最右。
        let d = drive([.init(at: 125, toLane: 1)], laneFeedAt: 150, duration: 175)
        XCTAssertEqual(d[140].currentLane?.lane, 1)
        XCTAssertNil(d[155].lanes, "1.6 km before the exit: no lane picture yet")
        let advice = d[165].laneChange
        XCTAssertNotNil(d[165].lanes)
        XCTAssertEqual(advice?.direction, .right)
        XCTAssertEqual(advice?.lanes, 1)
        XCTAssertEqual(advice?.within ?? 0, d[165].maneuver?.exactDistance ?? -1, accuracy: 1)
    }

    func testNoAdviceWhenAlreadyInRecommendedLane() {
        let d = drive([], laneFeedAt: 150, duration: 175)
        XCTAssertEqual(d[165].currentLane?.lane, 2)
        XCTAssertNotNil(d[165].lanes)
        XCTAssertNil(d[165].laneChange)
    }

    func testNoLaneCountsMeansNoLaneClaims() {
        let route = LaneDriveSim.curvedMotorway(laneCounts: false)
        let engine = NavigationEngine()
        engine.startTrip(TripPlan(id: "t", destination: route.destination))
        let drive = LaneDriveSim(route: route).run()
        _ = engine.process(drive[0].0)
        engine.offer(RouteOffer(requestID: 1, purpose: .initial, routes: [route]))
        for (fix, motion) in drive.dropFirst().prefix(60) {
            XCTAssertNil(engine.process(fix, motion: motion).display.currentLane)
        }
    }

    func testLaneCountsFromAnnotations() {
        let plain = LaneDriveSim.curvedMotorway(laneCounts: false)
        // OSM 车道段：匝道 1 条，高速 3 条；还有一段对向的（应被忽略）。
        let ramp = LaneCountSegment(id: "osm:1", geometry: [plain.coordinate(at: 0), plain.coordinate(at: 200),
                                                             plain.coordinate(at: 400)], lanes: 1)
        let main = LaneCountSegment(id: "osm:2", geometry: stride(from: 400.0, through: 8000, by: 400).map { plain.coordinate(at: $0) },
                                    lanes: 3)
        let opposite = LaneCountSegment(id: "osm:3", geometry: [plain.coordinate(at: 5000), plain.coordinate(at: 3000)], lanes: 4)
        let a = RouteAnnotator().annotate(route: plain, laneCounts: [ramp, main, opposite], now: World.t0)
        XCTAssertEqual(a.laneCounts.map(\.value), [1, 3])
        XCTAssertEqual(a.laneCounts[0].end, 400, accuracy: 1)
        XCTAssertEqual(a.laneCounts[1].start, 400, accuracy: 1)

        let engine = NavigationEngine()
        engine.startTrip(TripPlan(id: "t", destination: plain.destination))
        let drive = LaneDriveSim(route: plain).run()
        _ = engine.process(drive[0].0)
        engine.offer(RouteOffer(requestID: 1, purpose: .initial, routes: [plain]))
        engine.updateAnnotations(a)
        var last: DriveDisplayState?
        for (fix, motion) in drive.dropFirst().prefix(30) { last = engine.process(fix, motion: motion).display }
        XCTAssertEqual(last?.currentLane?.lane, 2)
    }
}
