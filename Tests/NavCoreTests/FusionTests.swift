import XCTest
@testable import NavCore

final class SpeedLimitFusionTests: XCTestCase {
    let fuser = SpeedLimitFuser()
    /// 本地时间（Europe/Amsterdam）→ Date。
    func local(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Amsterdam")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    func obs(_ source: SpeedLimitSource, _ kmh: Int, conf: Double = 1, binding: Bool = true,
             schedule: TimeWindow? = nil, at: Date? = nil, maxAge: TimeInterval? = nil) -> SpeedLimitObservation {
        SpeedLimitObservation(source: source, kmh: kmh, binding: binding, schedule: schedule,
                              observedAt: at ?? World.t0, maxAge: maxAge, matchConfidence: conf)
    }

    func testAmsterdamTimeZoneAvailable() {
        XCTAssertNotNil(TimeZone(identifier: "Europe/Amsterdam"), "tzdata missing: time-dependent limits would be wrong")
        XCTAssertEqual(DutchRoadRules.amsterdamCalendar.component(.hour, from: World.t0), 10)
    }

    func testBindingMatrixSignWins() {
        let r = fuser.fuse([obs(.officialStatic, 100), obs(.provider, 100), obs(.dynamicSign, 70, maxAge: 120),
                            obs(.dynamicSign, 50, binding: false, maxAge: 120)],
                           roadClass: .motorway, now: World.t0)!
        XCTAssertEqual(r.kmh, 70)
        XCTAssertEqual(r.source, .dynamicSign)
        XCTAssertEqual(r.confidence, .high)
        XCTAssertEqual(r.advisoryKmh, 50, "no red ring = advisory, shown separately")
    }

    func testExpiredMatrixSignIgnored() {
        let r = fuser.fuse([obs(.officialStatic, 100), obs(.dynamicSign, 70, at: World.t0.addingTimeInterval(-300), maxAge: 120)],
                           roadClass: .motorway, now: World.t0)!
        XCTAssertEqual(r.kmh, 100)
        XCTAssertEqual(r.source, .officialStatic)
    }

    func testConfidentOfficialBeatsProviderButFlagsConflict() {
        let r = fuser.fuse([obs(.officialStatic, 80, conf: 0.9), obs(.provider, 100)], roadClass: .rural, now: World.t0)!
        XCTAssertEqual(r.kmh, 80)
        XCTAssertEqual(r.confidence, .high)
        XCTAssertTrue(r.conflict)
    }

    func testUncertainDisagreementTakesLowerValue() {
        let r = fuser.fuse([obs(.officialStatic, 80, conf: 0.6), obs(.provider, 60)], roadClass: .rural, now: World.t0)!
        XCTAssertEqual(r.kmh, 60)
        XCTAssertEqual(r.source, .provider)
        XCTAssertEqual(r.confidence, .medium)
        XCTAssertTrue(r.conflict)
    }

    func testAgreementRaisesConfidence() {
        let r = fuser.fuse([obs(.officialStatic, 50, conf: 0.6), obs(.provider, 50)], roadClass: .urban, now: World.t0)!
        XCTAssertEqual(r.confidence, .high)
        XCTAssertFalse(r.conflict)
    }

    func testPoorlyMatchedObservationDropped() {
        let r = fuser.fuse([obs(.officialStatic, 30, conf: 0.3), obs(.provider, 50)], roadClass: .urban, now: World.t0)!
        XCTAssertEqual(r.kmh, 50)
    }

    func testProviderVersusCache() {
        let r = fuser.fuse([obs(.provider, 50), obs(.cache, 30)], roadClass: .urban, now: World.t0)!
        XCTAssertEqual(r.kmh, 30, "Amsterdam went 30 in late 2023; stale map data says 50")
        XCTAssertTrue(r.conflict)
    }

    func testRoadClassDefaults() {
        XCTAssertEqual(fuser.fuse([], roadClass: .rural, now: World.t0)?.kmh, 80)
        XCTAssertEqual(fuser.fuse([], roadClass: .woonerf, now: World.t0)?.kmh, 15)
        XCTAssertEqual(fuser.fuse([], roadClass: .rural, now: World.t0)?.confidence, .low)
        XCTAssertNil(fuser.fuse([], roadClass: .unknown, now: World.t0))
        XCTAssertNil(fuser.fuse([], roadClass: nil, now: World.t0))
    }

    func testMotorwayDaytimeCapAndUpcomingChange() {
        // 官方：06–19 100，其余 130（两条带时段的观测）。
        let day = TimeWindow(from: (6, 0), to: (19, 0))
        let night = TimeWindow(from: (19, 0), to: (6, 0))
        let signs = [obs(.officialStatic, 100, schedule: day), obs(.officialStatic, 130, schedule: night)]

        let afternoon = fuser.fuse(signs, roadClass: .motorway, now: local("2026-10-12 18:30"))!
        XCTAssertEqual(afternoon.kmh, 100)
        XCTAssertEqual(afternoon.upcomingChange?.kmh, 130)
        XCTAssertEqual(afternoon.upcomingChange?.at, local("2026-10-12 19:00"))

        let evening = fuser.fuse(signs, roadClass: .motorway, now: local("2026-10-12 21:00"))!
        XCTAssertEqual(evening.kmh, 130)
        XCTAssertNil(evening.upcomingChange, "06:00 is more than an hour away")

        // 高德只给一个 130、不分时段：白天被全国规则压到 100。
        let provider130 = fuser.fuse([obs(.provider, 130)], roadClass: .motorway, now: local("2026-10-12 08:00"))!
        XCTAssertEqual(provider130.kmh, 100)
        XCTAssertTrue(provider130.daytimeCapApplied)
        let provider130Night = fuser.fuse([obs(.provider, 130)], roadClass: .motorway, now: local("2026-10-12 05:30"))!
        XCTAssertEqual(provider130Night.kmh, 130)
        XCTAssertEqual(provider130Night.upcomingChange?.kmh, 100)
        XCTAssertEqual(provider130Night.upcomingChange?.at, local("2026-10-12 06:00"))
    }

    func testTimeWindowAcrossDstAndMidnight() {
        let cal = DutchRoadRules.amsterdamCalendar
        let night = TimeWindow(from: (19, 0), to: (6, 0))
        XCTAssertTrue(night.contains(local("2026-03-29 03:30"), calendar: cal))   // 夏令时切换当晚
        XCTAssertFalse(night.contains(local("2026-03-29 06:00"), calendar: cal))
        XCTAssertEqual(night.nextTransition(after: local("2026-03-29 01:00"), calendar: cal), local("2026-03-29 06:00"))
        XCTAssertEqual(night.nextTransition(after: local("2026-10-25 12:00"), calendar: cal), local("2026-10-25 19:00"))

        // 只在工作日的时段（例如学校区域 30）：周五晚跨午夜，周六 01:00 仍属于周五的时段。
        let weekdayNights = TimeWindow(from: (22, 0), to: (2, 0), weekdays: [2, 3, 4, 5, 6])
        XCTAssertTrue(weekdayNights.contains(local("2026-10-17 01:00"), calendar: cal))   // 周六凌晨
        XCTAssertFalse(weekdayNights.contains(local("2026-10-18 01:00"), calendar: cal))  // 周日凌晨（属于周六）
        XCTAssertEqual(weekdayNights.nextTransition(after: local("2026-10-17 03:00"), calendar: cal),
                       local("2026-10-19 22:00"), "next window opens Monday night")
    }
}

final class LaneTests: XCTestCase {
    func testAmapDecode() {
        let g = AmapLaneDecoder.decode(background: "1|0|0|4", selection: "255|0|0|255")!
        XCTAssertEqual(g.lanes.map(\.directions), [[.left], [.straight], [.straight], [.straight, .right]])
        XCTAssertEqual(g.recommendedIndices, [1, 2])
        XCTAssertEqual(g.lanes[1].preferred, .straight)

        // 多箭头车道上高亮其中一个箭头。
        let h = AmapLaneDecoder.decode(background: "2|4", selection: "255|3")!
        XCTAssertEqual(h.lanes[1].preferred, .right)
    }

    func testAmapDecodeIsDefensive() {
        XCTAssertNil(AmapLaneDecoder.decode(background: "", selection: nil))
        XCTAssertNil(AmapLaneDecoder.decode(background: "255|255", selection: nil))
        XCTAssertNil(AmapLaneDecoder.decode(background: "0|x", selection: nil))
        let g = AmapLaneDecoder.decode(background: "0|99", selection: nil)!
        XCTAssertEqual(g.lanes[1].directions, [.unknown], "unknown code: plain lane, never a guessed arrow")
        XCTAssertTrue(g.recommendedIndices.isEmpty)
        // 十六进制单字符编码。
        XCTAssertEqual(AmapLaneDecoder.decode(background: "a|c", selection: nil)!.lanes.map(\.directions),
                       [[.straight, .uTurnRight], [.right, .uTurnRight]])
    }

    func testClosureMovesRecommendation() {
        let g = AmapLaneDecoder.decode(background: "0|0|4", selection: "255|255|4")!
        XCTAssertEqual(g.recommendedIndices, [2])
        let gantry = SignalGantry(id: "g", location: World.anchor, bearing: 90, laneCount: 3,
                                  signals: [LaneSignal(laneFromLeft: 2, aspect: .closed)], observedAt: World.t0)
        let fused = LaneClosureFusion.apply(gantry, to: g)
        XCTAssertEqual(fused.lanes[2].status, .closed)
        // 原推荐车道"直行+右转"被关：改推荐还开着、能直行或右转的车道。
        XCTAssertEqual(fused.recommendedIndices, [0, 1])
    }

    func testLaneCountMismatchLeavesGuidanceAlone() {
        let g = AmapLaneDecoder.decode(background: "0|0|0|3", selection: "255|255|255|3")!
        let gantry = SignalGantry(id: "g", location: World.anchor, bearing: 90, laneCount: 3,
                                  signals: [LaneSignal(laneFromLeft: 2, aspect: .closed)], observedAt: World.t0)
        XCTAssertEqual(LaneClosureFusion.apply(gantry, to: g), g)
    }

    func testAdvisorySpeedNotAppliedToLane() {
        let g = AmapLaneDecoder.decode(background: "0|0", selection: nil)!
        let gantry = SignalGantry(id: "g", location: World.anchor, bearing: 90, laneCount: 2,
                                  signals: [LaneSignal(laneFromLeft: 0, aspect: .speedLimit, speedLimit: 50, binding: false),
                                            LaneSignal(laneFromLeft: 1, aspect: .speedLimit, speedLimit: 70)],
                                  observedAt: World.t0)
        let fused = LaneClosureFusion.apply(gantry, to: g)
        XCTAssertNil(fused.lanes[0].dynamicSpeedLimit)
        XCTAssertEqual(fused.lanes[1].dynamicSpeedLimit, 70)
    }
}

final class AnnotatorTests: XCTestCase {
    let route = Scenario.exitRoute()
    let annotator = RouteAnnotator()

    func testLinearEventDirection() {
        let same = TrafficEvent(id: "s", kind: .roadworks, geometry: [World.c(-2000, 5), World.c(-1000, 5)])
        let opposite = TrafficEvent(id: "o", kind: .roadworks, geometry: [World.c(-1000, -5), World.c(-2000, -5)])
        let a = annotator.annotate(route: route, events: [same, opposite], now: World.t0)
        XCTAssertEqual(a.events.map(\.event.id), ["s"])
        XCTAssertEqual(a.events[0].startOffset, 1000, accuracy: 2)
        XCTAssertEqual(a.events[0].endOffset, 2000, accuracy: 2)
        XCTAssertTrue(a.events[0].directionVerified)
    }

    func testEventPartiallyOnRoute() {
        // 事件从路线上开始，延伸到路线不走的高速东段。
        let ev = TrafficEvent(id: "p", kind: .congestion, geometry: [World.c(-500, 0), World.c(2000, 0)])
        let a = annotator.annotate(route: route, events: [ev], now: World.t0)
        XCTAssertEqual(a.events.first?.startOffset ?? 0, 2500, accuracy: 2)
        // 只有 1 个顶点落在路线上、方向一致。
        let wrongWay = TrafficEvent(id: "w", kind: .congestion, geometry: [World.c(2000, 0), World.c(-500, 0)])
        XCTAssertTrue(annotator.annotate(route: route, events: [wrongWay], now: World.t0).events.isEmpty)
    }

    func testPointEventNeedsTightRadiusAndIsMarkedUnverified() {
        let near = TrafficEvent(id: "n", kind: .hazard, geometry: [World.c(-1500, 12)])
        let far = TrafficEvent(id: "f", kind: .hazard, geometry: [World.c(-1500, 40)])
        let a = annotator.annotate(route: route, events: [near, far], now: World.t0)
        XCTAssertEqual(a.events.map(\.event.id), ["n"])
        XCTAssertFalse(a.events[0].directionVerified)
    }

    func testInactiveEventsSkipped() {
        let past = TrafficEvent(id: "past", kind: .roadworks, geometry: [World.c(-2000, 0), World.c(-1000, 0)],
                                end: World.t0.addingTimeInterval(-60))
        let future = TrafficEvent(id: "future", kind: .roadworks, geometry: [World.c(-2000, 0), World.c(-1000, 0)],
                                  start: World.t0.addingTimeInterval(3600))
        XCTAssertTrue(annotator.annotate(route: route, events: [past, future], now: World.t0).events.isEmpty)
    }

    func testSpeedLimitSegmentsAndGantries() {
        let seg = SpeedLimitSegment(id: "wkd-1", geometry: [World.c(-3000, 0), World.c(-2000, 0), World.c(-1000, 0)],
                                    kmh: 80, observedAt: World.t0)
        let reversed = SpeedLimitSegment(id: "wkd-2", geometry: [World.c(-1000, 0), World.c(-3000, 0)], kmh: 120,
                                         observedAt: World.t0)
        let ours = SignalGantry(id: "g1", location: World.c(-500, 8), bearing: 92, laneCount: 3, signals: [],
                                observedAt: World.t0)
        let theirs = SignalGantry(id: "g2", location: World.c(-500, -8), bearing: 270, laneCount: 3, signals: [],
                                  observedAt: World.t0)
        let noBearing = SignalGantry(id: "g3", location: World.c(-400, 0), bearing: nil, laneCount: 3, signals: [],
                                     observedAt: World.t0)
        let a = annotator.annotate(route: route, speedLimits: [seg, reversed], gantries: [ours, theirs, noBearing],
                                   now: World.t0)
        XCTAssertEqual(a.speedLimits.map(\.observation.kmh), [80])
        XCTAssertEqual(a.speedLimits[0].start, 0, accuracy: 2)
        XCTAssertEqual(a.speedLimits[0].end, 2000, accuracy: 2)
        XCTAssertEqual(a.speedLimits[0].observation.matchConfidence, 0.95, accuracy: 1e-9)
        XCTAssertEqual(a.gantries.map(\.gantry.id), ["g1"])
    }
}

final class StrategyAndContractTests: XCTestCase {
    func load(_ name: String) throws -> Data {
        try Data(contentsOf: World.dataDir.appendingPathComponent(name))
    }

    func testNdwEventsContract() throws {
        struct Page: Decodable { var version: Int; var events: [TrafficEvent]; var removed: [String] }
        let page = try JSONDecoder().decode(Page.self, from: load("ndw-events.v1.example.json"))
        XCTAssertEqual(page.events.count, 4)
        let accident = page.events[0]
        XCTAssertEqual(accident.kind, .accident)
        XCTAssertEqual(accident.severity, .high)
        XCTAssertEqual(accident.geometry.count, 2)
        XCTAssertEqual(accident.geometry[0].latitude, 52.0901, accuracy: 1e-9)
        XCTAssertEqual(accident.closedLanes, ["lane1", "lane2"])
        XCTAssertNil(accident.end)
        XCTAssertNotNil(page.events[1].start, "fractional seconds accepted")
        XCTAssertEqual(page.events[2].kind, .bridgeOpening)
        XCTAssertTrue(page.events[2].blocksRoute)
        XCTAssertEqual(page.events[3].kind, .other, "unknown kinds degrade, never crash the app")
        XCTAssertEqual(page.removed, ["RWS03_899001_1"])

        // 往返编码不丢字段。
        let again = try JSONDecoder().decode(TrafficEvent.self, from: JSONEncoder().encode(accident))
        XCTAssertEqual(again, accident)
    }

    func testJevAdviceContract() throws {
        let advices = try JSONDecoder().decode([StrategyAdvice].self, from: load("jev-advice.v1.example.json"))
        XCTAssertEqual(advices.count, 3)
        XCTAssertEqual(advices[0].action, .switchToAlternative("amap-1"))
        XCTAssertEqual(advices[0].expectedGain, 1080)
        guard case .reroute(let prefs) = advices[1].action else { return XCTFail() }
        XCTAssertTrue(prefs.avoidEnvironmentalZones)
        XCTAssertEqual(prefs.avoidRoads, ["A10"])
        XCTAssertEqual(prefs.avoidAreas.first?.maxLongitude, 5.14)
        XCTAssertEqual(advices[2].action, .keepCurrent)

        for a in advices {
            XCTAssertEqual(try JSONDecoder().decode(StrategyAdvice.self, from: JSONEncoder().encode(a)), a)
        }
    }

    func testJevTelemetryContract() throws {
        let t = try JSONDecoder().decode(TripTelemetry.self, from: load("jev-telemetry.v1.example.json"))
        XCTAssertEqual(t.activeRoute?.id, "amap-0")
        XCTAssertEqual(t.alternatives.first?.expectedDuration, 2580)
        XCTAssertEqual(t.position.longitude, 4.8402)
        XCTAssertEqual(try JSONDecoder().decode(TripTelemetry.self, from: JSONEncoder().encode(t)), t)
    }

    func testGateRules() {
        let gate = StrategyGate()
        let a = StrategyAdvice(id: "x", tripID: "t", issuedAt: World.t0, validUntil: World.t0.addingTimeInterval(60),
                               action: .switchToAlternative("alt"), reason: "")
        func eval(now: TimeInterval = 0, next: Double? = 5000, since: Double? = nil, speed: Double? = 30,
                  last: TimeInterval? = nil, rerouting: Bool = false) -> StrategyDecision {
            gate.evaluate(a, tripID: "t", now: World.t0.addingTimeInterval(now), distanceToNextManeuver: next,
                          distanceSincePreviousManeuver: since, speed: speed,
                          lastRouteChange: last.map { World.t0.addingTimeInterval($0) }, rerouting: rerouting)
        }
        XCTAssertEqual(eval(), .apply)
        XCTAssertEqual(eval(now: 61), .reject("expired"))
        XCTAssertEqual(eval(rerouting: true), .deferUntilSafe("rerouting"))
        XCTAssertEqual(eval(next: 500), .deferUntilSafe("near maneuver"))
        // 130 km/h × 25 s ≈ 900 m：800 m 不够。
        XCTAssertEqual(eval(next: 800, speed: 36), .deferUntilSafe("near maneuver"))
        XCTAssertEqual(eval(since: 50), .deferUntilSafe("just passed maneuver"))
        XCTAssertEqual(eval(last: -30), .deferUntilSafe("recent route change"))
        XCTAssertEqual(gate.evaluate(a, tripID: "other", now: World.t0, distanceToNextManeuver: nil, speed: nil,
                                     lastRouteChange: nil, rerouting: false), .reject("different trip"))
    }
}
