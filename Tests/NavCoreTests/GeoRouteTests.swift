import XCTest
@testable import NavCore

final class GeoRouteTests: XCTestCase {
    func testDistanceAndBearing() {
        let amsterdam = Coordinate(52.3791, 4.9003)   // Centraal
        let utrecht = Coordinate(52.0894, 5.1101)     // Centraal
        let d = Geo.distance(amsterdam, utrecht)
        XCTAssertEqual(d, 35_200, accuracy: 600)
        let b = Geo.bearing(amsterdam, utrecht)
        XCTAssertEqual(b, 155, accuracy: 3)
        XCTAssertEqual(Geo.angleBetween(350, 10), 20, accuracy: 1e-9)
        XCTAssertEqual(Geo.angleBetween(90, 270), 180, accuracy: 1e-9)
    }

    func testDestinationRoundTrip() {
        let p = Geo.destination(from: World.anchor, bearing: 90, distance: 1000)
        XCTAssertEqual(Geo.distance(World.anchor, p), 1000, accuracy: 0.5)
        XCTAssertEqual(Geo.bearing(World.anchor, p), 90, accuracy: 0.1)
    }

    func testLocalFrameMatchesHaversineAtShortRange() {
        let p = World.c(300, -400)
        XCTAssertEqual(Geo.distance(World.anchor, p), 500, accuracy: 0.5)
        let (x, y) = World.frame.project(p)
        XCTAssertEqual(x, 300, accuracy: 0.01)
        XCTAssertEqual(y, -400, accuracy: 0.01)
    }

    func testProjectionOntoSegment() {
        let frame = LocalFrame(anchor: World.c(50, 10))
        let p = frame.projectAnchor(ontoSegment: World.c(0, 0), World.c(100, 0))
        XCTAssertEqual(p.t, 0.5, accuracy: 1e-6)
        XCTAssertEqual(p.distance, 10, accuracy: 0.01)

        // 起点之前：默认夹到 t = 0；允许 lead-in 时可以为负。
        let before = LocalFrame(anchor: World.c(-50, 0))
        XCTAssertEqual(before.projectAnchor(ontoSegment: World.c(0, 0), World.c(100, 0)).t, 0)
        let leadIn = before.projectAnchor(ontoSegment: World.c(0, 0), World.c(100, 0), minT: -1)
        XCTAssertEqual(leadIn.t, -0.5, accuracy: 1e-6)
        XCTAssertEqual(leadIn.distance, 0, accuracy: 0.01)
    }

    func testSegmentGridFindsNearbySegmentsOnly() {
        let pts = World.path([(0, 0), (1000, 0), (1000, 1000), (5000, 1000)])
        let grid = SegmentGrid(points: pts)
        XCTAssertEqual(grid.segments(near: World.c(500, 30), radius: 50), [0])
        XCTAssertTrue(grid.segments(near: World.c(1000, 500), radius: 50).contains(1))
        XCTAssertTrue(grid.segments(near: World.c(-3000, -3000), radius: 50).isEmpty)
    }

    func testRouteQueries() {
        let route = Scenario.exitRoute(speedLimit: 130)
        XCTAssertEqual(route.length, route.cumulative.last!)
        XCTAssertEqual(route.cumulative[1], 3000, accuracy: 1)
        XCTAssertEqual(route.segmentIndex(at: 10), 0)
        XCTAssertEqual(route.segmentIndex(at: 3010), 1)
        XCTAssertEqual(route.segmentIndex(at: -5), 0)
        XCTAssertEqual(route.segmentIndex(at: route.length + 100), route.segmentCount - 1)

        let mid = route.coordinate(at: 1500)
        XCTAssertEqual(Geo.distance(mid, World.c(-1500, 0)), 0, accuracy: 0.5)
        // lead-in：起点之前 100 m。
        XCTAssertEqual(Geo.distance(route.coordinate(at: -100), World.c(-3100, 0)), 0, accuracy: 0.5)

        XCTAssertEqual(route.maneuvers[route.nextManeuverIndex(after: 0)!].kind, .exitRight)
        XCTAssertEqual(route.maneuvers[route.nextManeuverIndex(after: 2999)!].kind, .exitRight)
        XCTAssertEqual(route.maneuvers[route.nextManeuverIndex(after: 3001)!].kind, .arrive)
        XCTAssertNil(route.nextManeuverIndex(after: route.length + 1))

        XCTAssertEqual(route.providerSpeedLimit(at: 100), 130)
        XCTAssertNil(route.providerSpeedLimit(at: 3100))
        XCTAssertEqual(route.roadClass(at: 100), .motorway)
        XCTAssertEqual(route.roadClass(at: 3100), .rural)
        XCTAssertEqual(route.remainingTime(from: route.length / 2), 150, accuracy: 0.5)
    }

    func testRemainingTimeUsesPerPointTimesWhenAvailable() {
        let pts = World.path([(0, 0), (1000, 0), (2000, 0)])
        // 前 1 km 堵车（300 s），后 1 km 畅通（40 s）。
        let route = Route(id: "t", points: pts, cumulativeTime: [0, 300, 340])
        XCTAssertEqual(route.remainingTime(from: 0), 340, accuracy: 0.5)
        XCTAssertEqual(route.remainingTime(from: 500), 190, accuracy: 1)
        XCTAssertEqual(route.remainingTime(from: 1500), 20, accuracy: 1)
    }

    func testDisplayDistanceRounding() {
        XCTAssertEqual(DisplayDistance.round(-3), 0)
        XCTAssertEqual(DisplayDistance.round(44), 40)
        XCTAssertEqual(DisplayDistance.round(46), 50)
        XCTAssertEqual(DisplayDistance.round(324), 300)
        XCTAssertEqual(DisplayDistance.round(330), 350)
        XCTAssertEqual(DisplayDistance.round(1_249), 1_200)
        XCTAssertEqual(DisplayDistance.round(12_600), 13_000)
    }
}
