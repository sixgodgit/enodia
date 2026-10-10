import XCTest
@testable import NavCore

final class EngineTests: XCTestCase {
    let trip = TripPlan(id: "trip-1", destination: World.c(700, -2000))

    /// 开始行程，吃掉初始路线请求并立刻给出路线。
    private func startedEngine(routes: [Route] = [Scenario.exitRoute()],
                               config: EngineConfig = EngineConfig()) -> (NavigationEngine, LocationFix) {
        let engine = NavigationEngine(config: config)
        engine.startTrip(trip)
        let first = LocationFix(coordinate: World.c(-1500, 0), timestamp: World.t0, speed: 30, course: 90)
        let out = engine.process(first)
        XCTAssertEqual(out.display.phase, .planning(attempts: 1))
        guard let req = out.requests.first, req.purpose == .initial else {
            XCTFail("expected initial route request")
            return (engine, first)
        }
        engine.offer(RouteOffer(requestID: req.id, purpose: .initial, routes: routes))
        return (engine, first)
    }

    func testIdleWithoutTrip() {
        let engine = NavigationEngine()
        let out = engine.process(LocationFix(coordinate: World.anchor, timestamp: World.t0))
        XCTAssertEqual(out.display, .idle)
        XCTAssertTrue(out.intents.isEmpty)
    }

    func testInitialRouteThenGuidance() {
        let (engine, _) = startedEngine()
        let fixes = Drive(path: Scenario.takeExitDrive, speed: 30, start: World.t0.addingTimeInterval(1)).fixes()
        var outputs: [EngineOutput] = []
        for f in fixes { outputs.append(engine.process(f)) }

        let changes = NavigationEngine.changes(outputs)
        XCTAssertEqual(changes.first?.reason, .initial)
        XCTAssertEqual(changes.count, 1, "no reroutes on a clean drive")

        let first = outputs[0].display
        XCTAssertEqual(first.phase, .guiding)
        XCTAssertEqual(first.maneuver?.kind, .exitRight)
        XCTAssertEqual(first.maneuver?.exitNumber, "14")
        XCTAssertEqual(first.maneuver?.distance, 1_500)

        // 出口前 300 m 左右：距离按 50 m 取整。
        let near = outputs.first { ($0.display.maneuver?.exactDistance ?? .infinity) < 320 && $0.display.maneuver?.kind == .exitRight }!
        XCTAssertEqual(near.display.maneuver!.distance.truncatingRemainder(dividingBy: 50), 0)

        XCTAssertEqual(outputs.last?.display.phase, .arrived)
        XCTAssertTrue(NavigationEngine.requests(outputs).allSatisfy {
            if case .speculative = $0.purpose { return true } else { return false }
        }, "only speculative requests while on route")
    }

    func testMissedExitWithoutBackupsRequestsReroute() {
        let (engine, _) = startedEngine()
        let fixes = Drive(path: Scenario.missedExitDrive, speed: 30, start: World.t0.addingTimeInterval(1)).fixes()
        var outputs: [EngineOutput] = []
        var rerouteAt: Int?
        for (i, f) in fixes.enumerated() {
            let out = engine.process(f)
            outputs.append(out)
            if rerouteAt == nil, out.requests.contains(where: { $0.purpose == .reroute }) { rerouteAt = i }
            if i > 80 { break }
        }
        guard let i = rerouteAt else { return XCTFail("no reroute request") }
        XCTAssertLessThan(i, 60, "reroute requested at fix \(i); split at fix 50")

        let req = NavigationEngine.requests(outputs).first { $0.purpose == .reroute }!
        XCTAssertEqual(req.originHeading ?? 0, 90, accuracy: 10)
        XCTAssertEqual(req.destination, trip.destination)

        guard case .rerouting(_, let attempts) = outputs[i].display.phase else {
            return XCTFail("expected rerouting phase, got \(outputs[i].display.phase)")
        }
        XCTAssertEqual(attempts, 1)
        XCTAssertNil(outputs[i].display.maneuver, "old maneuvers belong to a road we're no longer on")
        XCTAssertNotNil(outputs[i].display.rejoin)

        // 高德一直不回：5 秒后重发。
        let retries = NavigationEngine.requests(outputs).filter { $0.purpose == .reroute }
        XCTAssertGreaterThanOrEqual(retries.count, 2)
        if retries.count >= 2 {
            XCTAssertEqual(retries[1].issuedAt.timeIntervalSince(retries[0].issuedAt), 5, accuracy: 1.01)
        }
    }

    func testRerouteResultAdoptedWhenStillReachable() {
        let (engine, _) = startedEngine()
        let fixes = Drive(path: Scenario.missedExitDrive, speed: 30, start: World.t0.addingTimeInterval(1)).fixes()
        var req: RouteRequest?
        var adopted: RouteChange?
        for f in fixes {
            let out = engine.process(f)
            if req == nil, let r = out.requests.first(where: { $0.purpose == .reroute }) {
                req = r
                // 高德花了 3 秒；新路线从请求点往东。
                let (x, _) = World.frame.project(r.origin)
                let route = Route(id: "rerouted", points: World.path([(x, 0), (6000, 0)]),
                                  maneuvers: [Maneuver(offset: 6000 - x, kind: .arrive)])
                engine.offer(RouteOffer(requestID: r.id, purpose: .reroute, routes: [route]))
            }
            if let c = NavigationEngine.changes([out]).first(where: { $0.reason == .reroute }) { adopted = c; break }
        }
        XCTAssertEqual(adopted?.to, "rerouted")
        XCTAssertNotNil(adopted?.deviationToNewRoute)
    }

    func testStaleRerouteResultRejectedAndRetried() {
        let (engine, _) = startedEngine()
        let fixes = Drive(path: Scenario.missedExitDrive, speed: 30, start: World.t0.addingTimeInterval(1)).fixes()
        var sentStale = false
        var requestsAfterStale = 0
        for f in fixes.prefix(90) {
            let out = engine.process(f)
            if sentStale { requestsAfterStale += out.requests.filter { $0.purpose == .reroute }.count }
            if !sentStale, let r = out.requests.first(where: { $0.purpose == .reroute }) {
                // 结果对应一个车早就不在的地方（例如南边 2 km）。
                let far = Route(id: "stale", points: World.path([(0, -2000), (3000, -2000)]))
                engine.offer(RouteOffer(requestID: r.id, purpose: .reroute, routes: [far]))
                sentStale = true
            }
            XCTAssertNotEqual(out.display.activeRouteID, "stale")
        }
        XCTAssertGreaterThanOrEqual(requestsAfterStale, 1, "stale result must free the slot for an immediate retry")
    }

    func testAlternativeRouteGivesInstantSwitch() {
        let (engine, _) = startedEngine(routes: [Scenario.exitRoute(), Scenario.straightAlternative()])
        let fixes = Drive(path: Scenario.missedExitDrive, speed: 30, start: World.t0.addingTimeInterval(1)).fixes()
        var outputs: [EngineOutput] = []
        for f in fixes.prefix(80) { outputs.append(engine.process(f)) }

        let change = NavigationEngine.changes(outputs).first { $0.reason != .initial }
        XCTAssertEqual(change?.reason, .alternativeInstant)
        XCTAssertEqual(change?.to, "alt")
        XCTAssertFalse(NavigationEngine.requests(outputs).contains { $0.purpose == .reroute },
                       "no network round trip needed")
        XCTAssertEqual(outputs.last?.display.phase, .guiding)
        XCTAssertEqual(outputs.last?.display.activeRouteID, "alt")
    }

    func testSpeculativeRouteRequestedBeforeExitAndUsedOnMiss() {
        let (engine, _) = startedEngine()
        let fixes = Drive(path: Scenario.missedExitDrive, speed: 30, start: World.t0.addingTimeInterval(1)).fixes()
        var outputs: [EngineOutput] = []
        var specRequest: RouteRequest?
        for f in fixes.prefix(80) {
            let out = engine.process(f)
            outputs.append(out)
            if specRequest == nil, let r = out.requests.first(where: {
                if case .speculative = $0.purpose { return true } else { return false }
            }) {
                specRequest = r
                engine.offer(RouteOffer(requestID: r.id, purpose: r.purpose, routes: [Scenario.speculativeAfterMiss()]))
            }
        }
        guard let r = specRequest else { return XCTFail("no speculative request") }
        // 在出口前 2.5 km 内发出；"错过"点在出口之后 350 m、沿高速方向。
        XCTAssertEqual(Geo.distance(r.origin, World.c(350, 0)), 0, accuracy: 5)
        XCTAssertEqual(r.originHeading ?? 0, 90, accuracy: 1)

        let change = NavigationEngine.changes(outputs).first { $0.reason != .initial }
        XCTAssertEqual(change?.reason, .speculativeInstant)
        XCTAssertFalse(NavigationEngine.requests(outputs).contains { $0.purpose == .reroute })
        // 采纳时车还没到预算路线起点（x = 350）：靠 lead-in 接上。
        let adoptedAt = outputs.firstIndex { $0.display.activeRouteID == "spec" }!
        XCTAssertEqual(outputs[adoptedAt].display.phase, .guiding)
        let x = -1500 + 30 * Double(adoptedAt)
        XCTAssertLessThan(x, 350)
    }

    func testDriverReturnsToRouteAndLateRerouteIsIgnored() {
        let (engine, _) = startedEngine()
        var t = 1.0
        func fix(_ x: Double, _ y: Double) -> LocationFix {
            defer { t += 1 }
            return LocationFix(coordinate: World.c(x, y), timestamp: World.t0.addingTimeInterval(t), speed: 20, course: 90)
        }
        var req: RouteRequest?
        for k in 0..<8 {
            let out = engine.process(fix(-1400 + Double(k) * 20, 90))   // 拐进了旁边的辅路
            req = req ?? out.requests.first { $0.purpose == .reroute }
        }
        XCTAssertNotNil(req)
        _ = engine.process(fix(-1220, 2))
        let back = engine.process(fix(-1200, 1))
        XCTAssertEqual(back.display.phase, .guiding)

        let late = Route(id: "late", points: World.path([(-1300, 90), (2000, 90)]))
        engine.offer(RouteOffer(requestID: req!.id, purpose: .reroute, routes: [late]))
        let after = engine.process(fix(-1180, 1))
        XCTAssertEqual(after.display.activeRouteID, "main")
    }

    func testLaneGuidanceShownInRangeWithGantryClosureFused() {
        let (engine, _) = startedEngine()
        let route = Scenario.exitRoute()
        // 出口前 200 m 的门架：最右车道红叉。
        let gantry = SignalGantry(id: "A12-14.2", location: World.c(-200, 0), bearing: 90, laneCount: 3,
                                  signals: [LaneSignal(laneFromLeft: 2, aspect: .closed),
                                            LaneSignal(laneFromLeft: 0, aspect: .speedLimit, speedLimit: 70),
                                            LaneSignal(laneFromLeft: 1, aspect: .speedLimit, speedLimit: 70)],
                                  observedAt: World.t0)
        engine.updateAnnotations(RouteAnnotator().annotate(route: route, gantries: [gantry], now: World.t0))
        // 高德：三条车道，右边两条可以出口，推荐最右。
        let lanes = AmapLaneDecoder.decode(background: "0|4|3", selection: "255|255|3")!
        engine.updateLanes(LaneFeed(guidance: lanes, receivedAt: World.t0))

        let far = engine.process(LocationFix(coordinate: World.c(-1600, 0), timestamp: World.t0.addingTimeInterval(1),
                                             speed: 30, course: 90))
        XCTAssertEqual(far.display.phase, .guiding)
        XCTAssertNil(far.display.lanes, "beyond 1.5 km the lane picture is noise")

        let near = engine.process(LocationFix(coordinate: World.c(-250, 0), timestamp: World.t0.addingTimeInterval(20),
                                              speed: 30, course: 90))
        let shown = near.display.lanes
        XCTAssertEqual(shown?.lanes.count, 3)
        XCTAssertEqual(shown?.lanes[2].status, .closed)
        XCTAssertEqual(shown?.recommendedIndices, [1], "recommendation moves off the red-cross lane")
        XCTAssertEqual(shown?.lanes[1].preferred, .right)

        // 驶过门架后：矩阵牌 70 生效（压过高速默认值）。
        let past = engine.process(LocationFix(coordinate: World.c(-150, 0), timestamp: World.t0.addingTimeInterval(22),
                                              speed: 30, course: 90))
        XCTAssertEqual(past.display.speedLimit?.kmh, 70)
        XCTAssertEqual(past.display.speedLimit?.source, .dynamicSign)
        XCTAssertTrue(past.display.isSpeeding)
    }

    func testMotorwayDaytimeCapOverridesProvider130() {
        let (engine, _) = startedEngine(routes: [Scenario.exitRoute(speedLimit: 130)])
        let out = engine.process(LocationFix(coordinate: World.c(-1400, 0), timestamp: World.t0.addingTimeInterval(1),
                                             speed: 30, course: 90))
        XCTAssertEqual(out.display.speedLimit?.kmh, 100, "10:00 on a weekday: 100 everywhere on Dutch motorways")
        XCTAssertEqual(out.display.speedLimit?.daytimeCapApplied, true)
        XCTAssertEqual(out.display.speedKmh, 108)
        XCTAssertTrue(out.display.isSpeeding)
    }

    func testHazardAheadOnlyForOurDirection() {
        let (engine, _) = startedEngine()
        let route = Scenario.exitRoute()
        let ours = TrafficEvent(id: "ours", kind: .accident, severity: .high, road: "A12",
                                geometry: [World.c(-800, 0), World.c(-600, 0)], closedLanes: ["lane1"])
        let opposite = TrafficEvent(id: "opposite", kind: .accident, road: "A12",
                                    geometry: [World.c(-1000, 0), World.c(-1200, 0)])
        engine.updateAnnotations(RouteAnnotator().annotate(route: route, events: [ours, opposite], now: World.t0))

        let out = engine.process(LocationFix(coordinate: World.c(-1400, 0), timestamp: World.t0.addingTimeInterval(1),
                                             speed: 30, course: 90))
        XCTAssertEqual(out.display.hazard?.eventID, "ours")
        XCTAssertEqual(out.display.hazard?.distance, 600)
        XCTAssertEqual(out.display.hazard?.closedLanes, ["lane1"])
        XCTAssertEqual(out.display.hazard?.directionVerified, true)

        let inside = engine.process(LocationFix(coordinate: World.c(-700, 0), timestamp: World.t0.addingTimeInterval(25),
                                                speed: 30, course: 90))
        XCTAssertEqual(inside.display.hazard?.inside, true)
    }

    func testClosureAheadTriggersAvoidanceAdoptedAtSafePoint() {
        let (engine, _) = startedEngine()
        let route = Scenario.exitRoute()
        // 匝道上封路（施工全封）。
        let closure = TrafficEvent(id: "closure-1", kind: .closure, severity: .high,
                                   geometry: [World.c(500, -150), World.c(700, -300)])
        engine.updateAnnotations(RouteAnnotator().annotate(route: route, events: [closure], now: World.t0))

        let out = engine.process(LocationFix(coordinate: World.c(-1400, 0), timestamp: World.t0.addingTimeInterval(1),
                                             speed: 30, course: 90))
        guard let req = out.requests.first(where: { $0.purpose == .avoidEvent(eventID: "closure-1") }) else {
            return XCTFail("closure ahead must trigger an avoidance request")
        }
        XCTAssertEqual(req.preferences.avoidAreas.count, 1)
        XCTAssertTrue(req.preferences.avoidAreas[0].contains(World.c(600, -220)))

        // 新路线不走那个匝道（继续直行）。
        let detour = Route(id: "detour", points: World.path([(-1500, 0), (5000, 0)]),
                           maneuvers: [Maneuver(offset: 6500, kind: .arrive)])
        engine.offer(RouteOffer(requestID: req.id, purpose: req.purpose, routes: [detour]))
        // 离出口 1.35 km、远超安全距离：可以换。
        let next = engine.process(LocationFix(coordinate: World.c(-1370, 0), timestamp: World.t0.addingTimeInterval(2),
                                              speed: 30, course: 90))
        XCTAssertEqual(next.display.activeRouteID, "detour")
        XCTAssertEqual(NavigationEngine.changes([next]).first?.reason, .avoidEvent)
    }

    func testShortBridgeOpeningFarAheadIsNotAvoided() {
        let (engine, _) = startedEngine()
        let bridge = TrafficEvent(id: "brug", kind: .bridgeOpening, geometry: [World.c(700, -1000)],
                                  start: World.t0, end: World.t0.addingTimeInterval(60))
        engine.updateAnnotations(RouteAnnotator().annotate(route: Scenario.exitRoute(), events: [bridge], now: World.t0))
        let out = engine.process(LocationFix(coordinate: World.c(-1400, 0), timestamp: World.t0.addingTimeInterval(1),
                                             speed: 30, course: 90))
        XCTAssertFalse(out.requests.contains { $0.purpose == .avoidEvent(eventID: "brug") },
                       "the bridge closes again long before we get there")
    }

    func testRefreshRouteAdoptedAtSafePointOnly() {
        let (engine, _) = startedEngine()
        // 主路线服务给了一条"更新版"（同一几何，路况更新后的用时），在离出口 250 m 时到达。
        let refreshed = Route(id: "main-v2", points: Scenario.exitRoute().points,
                              maneuvers: Scenario.exitRoute().maneuvers, expectedDuration: 420)
        _ = engine.process(LocationFix(coordinate: World.c(-1400, 0), timestamp: World.t0.addingTimeInterval(1), speed: 30, course: 90))
        engine.offer(RouteOffer(requestID: nil, purpose: .refresh, routes: [refreshed]))
        let near = engine.process(LocationFix(coordinate: World.c(-250, 0), timestamp: World.t0.addingTimeInterval(39), speed: 30, course: 90))
        XCTAssertEqual(near.display.activeRouteID, "main", "never swap routes right before a maneuver")
        // 出了匝道、离上一个动作够远：换。
        var adopted = false
        for (k, (x, y)) in [(300.0, -60.0), (500, -150), (700, -300), (700, -500)].enumerated() {
            let out = engine.process(LocationFix(coordinate: World.c(x, y), timestamp: World.t0.addingTimeInterval(50 + Double(k) * 10),
                                                 speed: 20, course: nil))
            if out.display.activeRouteID == "main-v2" {
                XCTAssertEqual(NavigationEngine.changes([out]).first?.reason, .refresh)
                adopted = true
                break
            }
        }
        XCTAssertTrue(adopted)
    }

    // MARK: - JEV

    private func advice(_ action: StrategyAdvice.Action, id: String = "a1", validFor: TimeInterval = 600) -> StrategyAdvice {
        StrategyAdvice(id: id, tripID: trip.id, issuedAt: World.t0, validUntil: World.t0.addingTimeInterval(validFor),
                       action: action, reason: "A12 ongeval, +12 min")
    }

    private func resolutions(_ out: EngineOutput) -> [(String, Bool, String)] {
        out.intents.compactMap {
            if case .adviceResolved(let id, let applied, let note) = $0 { return (id, applied, note) } else { return nil }
        }
    }

    func testStrategySwitchAppliedAtSafePoint() {
        let (engine, _) = startedEngine(routes: [Scenario.exitRoute(), Scenario.straightAlternative()])
        engine.submit(advice(.switchToAlternative("alt")))
        let out = engine.process(LocationFix(coordinate: World.c(-1400, 0), timestamp: World.t0.addingTimeInterval(1),
                                             speed: 30, course: 90))
        XCTAssertEqual(out.display.activeRouteID, "alt")
        XCTAssertEqual(out.display.strategyNote, "A12 ongeval, +12 min")
        XCTAssertEqual(resolutions(out).first?.1, true)
    }

    func testStrategyDeferredNearManeuverThenRejectedAfterDivergence() {
        let (engine, _) = startedEngine(routes: [Scenario.exitRoute(), Scenario.straightAlternative()])
        // 离出口 300 m 才收到建议：不能现在换。
        _ = engine.process(LocationFix(coordinate: World.c(-1400, 0), timestamp: World.t0.addingTimeInterval(1), speed: 30, course: 90))
        engine.submit(advice(.switchToAlternative("alt")))
        let near = engine.process(LocationFix(coordinate: World.c(-300, 0), timestamp: World.t0.addingTimeInterval(38),
                                              speed: 30, course: 90))
        XCTAssertEqual(near.display.activeRouteID, "main")
        XCTAssertTrue(resolutions(near).isEmpty, "deferred, not resolved")

        // 司机按原路线出了高速；建议的备选（继续直行）已经接不上了。
        var t = 39.0
        var last: EngineOutput?
        for (x, y) in [(-270.0, 0.0), (0, 0), (150, -20), (300, -60), (500, -150), (700, -300), (700, -700), (700, -1100)] {
            last = engine.process(LocationFix(coordinate: World.c(x, y), timestamp: World.t0.addingTimeInterval(t), speed: 20,
                                              course: nil))
            t += 10
            if let r = resolutions(last!).first {
                XCTAssertEqual(r.1, false)
                XCTAssertEqual(r.2, "passed divergence")
                return
            }
        }
        XCTFail("advice never resolved; last phase \(String(describing: last?.display.phase))")
    }

    func testExpiredAndForeignAdviceRejected() {
        let (engine, _) = startedEngine()
        engine.submit(advice(.keepCurrent, id: "old", validFor: -1))
        var foreign = advice(.keepCurrent, id: "foreign")
        foreign.tripID = "someone-else"
        engine.submit(foreign)
        let out = engine.process(LocationFix(coordinate: World.c(-1400, 0), timestamp: World.t0.addingTimeInterval(1), speed: 30, course: 90))
        let r = Dictionary(uniqueKeysWithValues: resolutions(out).map { ($0.0, $0.2) })
        XCTAssertEqual(r["old"], "expired")
        XCTAssertEqual(r["foreign"], "different trip")
    }

    func testTelemetryThrottled() {
        let (engine, _) = startedEngine()
        var count = 0
        for f in Drive(path: Scenario.takeExitDrive, speed: 30, start: World.t0.addingTimeInterval(1)).fixes().prefix(70) {
            count += engine.process(f).intents.filter { if case .telemetry = $0 { return true } else { return false } }.count
        }
        // 第一个点 + 30 s + 60 s（路线变化不在这段里）。
        XCTAssertEqual(count, 3)
    }

    // MARK: - 实时预算

    func testProcessingStaysWellUnderBudgetOnLongRoute() {
        // 200 km、2 万个点的路线（高德长途路线的量级），带事件和限速注释。
        var xy: [(Double, Double)] = []
        for i in 0..<20_000 { xy.append((Double(i) * 10, sin(Double(i) / 50) * 30)) }
        let pts = World.path(xy)
        let maneuvers = stride(from: 5_000.0, to: 199_000, by: 5_000).map { Maneuver(offset: $0, kind: .keepRight, roadClass: .motorway) }
        let route = Route(id: "long", points: pts, maneuvers: maneuvers, expectedDuration: 7200,
                          providerSpeedLimits: [ValueSpan(start: 0, end: 200_000, value: 130)],
                          roadClasses: [ValueSpan(start: 0, end: 200_000, value: .motorway)],
                          laneCounts: [ValueSpan(start: 0, end: 200_000, value: 3)])
        let events = stride(from: 1000, to: 19_000, by: 400).map { i in
            TrafficEvent(id: "e\(i)", kind: .roadworks, geometry: [pts[i], pts[i + 5]])
        }
        let engine = NavigationEngine()
        engine.startTrip(TripPlan(id: "long", destination: pts.last!))
        _ = engine.process(LocationFix(coordinate: pts[0], timestamp: World.t0))
        engine.offer(RouteOffer(requestID: 1, purpose: .initial, routes: [route]))
        engine.updateAnnotations(RouteAnnotator().annotate(route: route, events: events, now: World.t0))

        var durations: [Double] = []
        var rng = SeededRandom(seed: 7)
        for k in 0..<3000 {
            let i = min(19_998, k * 6)
            let p = pts[i]
            let fix = LocationFix(coordinate: Coordinate(p.latitude + rng.gaussian(3) / 111_000, p.longitude),
                                  timestamp: World.t0.addingTimeInterval(Double(k + 1)), speed: 30,
                                  course: Geo.bearing(pts[i], pts[i + 1]))
            // 每秒 10 个陀螺仪读数（车道定位路径也算在预算里）。
            let motion = (1...10).map { j in
                MotionSample(timestamp: fix.timestamp.addingTimeInterval(-1 + Double(j) * 0.1), headingRate: rng.gaussian(0.1))
            }
            let out = engine.process(fix, motion: motion)
            durations.append(Double(out.processingTime.components.attoseconds) / 1e15
                             + Double(out.processingTime.components.seconds) * 1000)
        }
        durations.sort()
        let p50 = durations[durations.count / 2], p99 = durations[durations.count * 99 / 100]
        print("NavigationEngine.process: p50 \(String(format: "%.3f", p50)) ms, p99 \(String(format: "%.3f", p99)) ms")
        // 调试构建、CI 机器上也应远低于 1 Hz GPS 的 1000 ms 预算；这里给 20 ms 的宽松上限。
        XCTAssertLessThan(p99, 20)
    }
}
