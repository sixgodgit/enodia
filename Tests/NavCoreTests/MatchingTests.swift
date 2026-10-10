import XCTest
@testable import NavCore

final class MatchingTests: XCTestCase {
    func testNoisyFixesStayMatchedAndProgressForward() {
        let route = Scenario.exitRoute()
        var matcher = RouteMatcher()
        let fixes = Drive(path: Scenario.takeExitDrive, speed: 25, noise: 5).fixes()
        var lastOffset = -Double.infinity
        for fix in fixes {
            let m = matcher.match(fix, on: route)!
            XCTAssertLessThan(m.lateral, 25)
            XCTAssertGreaterThan(m.offset, lastOffset - 20, "matched position must not jump backwards")
            lastOffset = m.offset
        }
        XCTAssertGreaterThan(lastOffset, route.length - 100)
    }

    func testRecoversViaGridAfterJump() {
        let route = Scenario.exitRoute()
        var matcher = RouteMatcher()
        _ = matcher.match(LocationFix(coordinate: World.c(-2900, 0), timestamp: World.t0), on: route)
        // 隧道出来，一下跳了 2.5 km：窗口里找不到，网格里找回来。
        let m = matcher.match(LocationFix(coordinate: World.c(-400, 3), timestamp: World.t0.addingTimeInterval(5)),
                              on: route)!
        XCTAssertEqual(m.offset, 2600, accuracy: 5)
        XCTAssertLessThan(m.lateral, 5)
    }

    func testHeadingDisambiguatesOppositeDirectionLeg() {
        // 去程东行、回程西行，两条腿相距 15 m（双向车道）。
        let pts = World.path([(0, 0), (2000, 0), (2000, 15), (0, 15)])
        let route = Route(id: "loop", points: pts)
        var matcher = RouteMatcher()
        let westbound = LocationFix(coordinate: World.c(1000, 6), timestamp: World.t0, speed: 25, course: 270)
        let m = matcher.match(westbound, on: route)!
        XCTAssertEqual(m.segment, 2, "westbound car belongs on the return leg even though the outbound leg is closer")
    }

    func testLeadInGivesNegativeOffset() {
        let route = Scenario.speculativeAfterMiss()
        var matcher = RouteMatcher()
        let fix = LocationFix(coordinate: World.c(200, 2), timestamp: World.t0, speed: 30, course: 90)
        let m = matcher.match(fix, on: route, leadIn: 600)!
        XCTAssertEqual(m.offset, -150, accuracy: 2)
        XCTAssertLessThan(m.lateral, 3)
        // 不允许 lead-in 时，同一点离起点 150 m。
        var plain = RouteMatcher()
        XCTAssertEqual(plain.match(fix, on: route)!.lateral, 150, accuracy: 2)
    }

    // MARK: - 偏航

    private func run(_ fixes: [LocationFix], on route: Route) -> (states: [RouteAdherence], fixes: [LocationFix]) {
        var matcher = RouteMatcher()
        var detector = OffRouteDetector()
        return (fixes.map { detector.update(match: matcher.match($0, on: route), fix: $0) }, fixes)
    }

    func testNoFalsePositiveWithGpsNoise() {
        for seed in UInt64(1)...20 {
            let fixes = Drive(path: Scenario.takeExitDrive, speed: 25, noise: 5, seed: seed).fixes()
            let (states, _) = run(fixes, on: Scenario.exitRoute())
            XCTAssertFalse(states.contains(where: \.isOffRoute), "seed \(seed)")
        }
    }

    func testUrbanNoiseWithHonestAccuracyDoesNotTrigger() {
        // 城市峡谷：噪声大，但 GPS 自报精度也大 → 阈值跟着放宽。
        for seed in UInt64(1)...10 {
            let fixes = Drive(path: Scenario.takeExitDrive, speed: 12, noise: 12, accuracy: 20, seed: seed).fixes()
            let (states, _) = run(fixes, on: Scenario.exitRoute())
            XCTAssertFalse(states.contains(where: \.isOffRoute), "seed \(seed)")
        }
    }

    func testMissedExitDetectedWithinSeconds() {
        let fixes = Drive(path: Scenario.missedExitDrive, speed: 30, noise: 3).fixes()
        let (states, _) = run(fixes, on: Scenario.exitRoute())
        guard let i = states.firstIndex(where: \.isOffRoute) else { return XCTFail("never detected") }
        // 车在 x = 0 处与路线分开（第 50 个点：从 -1500 起 30 m/s）。
        let secondsAfterSplit = fixes[i].timestamp.timeIntervalSince(World.t0) - 50
        XCTAssertLessThanOrEqual(secondsAfterSplit, 9, "detected \(secondsAfterSplit)s after split")
        XCTAssertGreaterThan(secondsAfterSplit, 3, "can't be detected before the paths are measurably apart")
    }

    func testParallelCarriagewayDetected() {
        // 路线要走平行车道（y = -25），车留在了主车道（y = 0）上，两条路一直平行。
        let route = Route(id: "parallelbaan", points: World.path([(-2000, 0), (0, 0), (100, -25), (4000, -25)]))
        let fixes = Drive(path: [(-1000, 0), (4000, 0)], speed: 28, noise: 3).fixes()
        let (states, _) = run(fixes, on: route)
        guard let i = states.firstIndex(where: \.isOffRoute) else {
            return XCTFail("50 m threshold navigators miss this; we must not")
        }
        let x = -1000 + 28 * fixes[i].timestamp.timeIntervalSince(World.t0)
        XCTAssertLessThan(x, 400, "detected at x=\(x)")
    }

    func testBadAccuracyFixesAreIgnored() {
        let route = Scenario.exitRoute()
        var detector = OffRouteDetector()
        var matcher = RouteMatcher()
        for k in 0..<10 {
            let fix = LocationFix(coordinate: World.c(-2000 + Double(k) * 20, 150), timestamp: World.t0.addingTimeInterval(Double(k)),
                                  horizontalAccuracy: 80, speed: 20, course: 90)
            XCTAssertEqual(detector.update(match: matcher.match(fix, on: route), fix: fix), .onRoute)
        }
    }

    func testRecoveryAfterReturningToRoute() {
        let route = Scenario.exitRoute()
        var detector = OffRouteDetector()
        var matcher = RouteMatcher()
        var t = 0.0
        func feed(_ x: Double, _ y: Double) -> RouteAdherence {
            t += 1
            let fix = LocationFix(coordinate: World.c(x, y), timestamp: World.t0.addingTimeInterval(t), speed: 20, course: 90)
            return detector.update(match: matcher.match(fix, on: route), fix: fix)
        }
        for k in 0..<6 { _ = feed(-2000 + Double(k) * 20, 80) }
        XCTAssertTrue(detector.state.isOffRoute)
        _ = feed(-1880, 2)
        XCTAssertTrue(detector.state.isOffRoute, "one good fix is not enough")
        XCTAssertEqual(feed(-1860, 1), .onRoute)
    }
}
