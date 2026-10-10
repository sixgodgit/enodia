import XCTest
import NavCore
@testable import NavServices

private let contracts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("contracts")

/// 假 HTTP：按 URL 里的关键字返回预设响应，记录请求。
final class FakeHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URL] = []
    let respond: @Sendable (URL) -> (Data, Int)
    init(_ respond: @escaping @Sendable (URL) -> (Data, Int)) { self.respond = respond }
    var requests: [URL] { lock.lock(); defer { lock.unlock() }; return _requests }
    private func record(_ url: URL) { lock.lock(); _requests.append(url); lock.unlock() }
    func get(_ url: URL, timeout: TimeInterval) async throws -> (data: Data, status: Int) {
        record(url)
        return respond(url)
    }
}

struct StubProvider: PlaceProvider {
    var name: String
    var timeout: TimeInterval
    var delay: TimeInterval
    var results: [PlaceCandidate]
    func search(_ query: PlaceQuery, parsed: DutchAddressQuery) async throws -> [PlaceCandidate] {
        try await Task.sleep(nanoseconds: UInt64(delay * 1e9))
        return results
    }
}

final class DutchAddressQueryTests: XCTestCase {
    func testPostcodeForms() {
        XCTAssertEqual(DutchAddressQuery("3511 ab").kind, .postcode("3511AB"))
        XCTAssertEqual(DutchAddressQuery("3511AB 12").kind, .postcodeHouseNumber(postcode: "3511AB", number: 12, addition: nil))
        XCTAssertEqual(DutchAddressQuery("3511AB12").kind, .postcodeHouseNumber(postcode: "3511AB", number: 12, addition: nil))
        XCTAssertEqual(DutchAddressQuery("3511 AB, 12-bis").kind, .postcodeHouseNumber(postcode: "3511AB", number: 12, addition: "BIS"))
        XCTAssertEqual(DutchAddressQuery("1012 lg 1a").houseNumberKey, "1A")
        // 不存在的邮编字母组合 SA/SD/SS，首位 0 也不是邮编。
        XCTAssertEqual(DutchAddressQuery("1234 SS").kind, .freeText)
        XCTAssertEqual(DutchAddressQuery("0123 AB").kind, .freeText)
    }

    func testStreetAndFreeText() {
        XCTAssertEqual(DutchAddressQuery("Oudegracht 12A, Utrecht").kind,
                       .streetHouseNumber(street: "Oudegracht", number: 12, addition: "A", city: "Utrecht"))
        XCTAssertEqual(DutchAddressQuery("Laan van Meerdervoort 50-H").kind,
                       .streetHouseNumber(street: "Laan van Meerdervoort", number: 50, addition: "H", city: nil))
        XCTAssertEqual(DutchAddressQuery("Albert Heijn Utrecht").kind, .freeText)
        XCTAssertEqual(DutchAddressQuery("A2").kind, .freeText)
    }

    func testNormalization() {
        XCTAssertEqual(DutchAddressQuery.normalize("'s-Gravenhage"), "den haag")
        XCTAssertEqual(DutchAddressQuery.normalize("  Café  ’t Hoekje! "), "cafe t hoekje")
        XCTAssertEqual(DutchAddressQuery.normalize("'s-Hertogenbosch Centraal"), "den bosch centraal")
    }
}

final class PDOKTests: XCTestCase {
    static let sample = #"""
    {"response":{"numFound":2,"start":0,"maxScore":14.2,"docs":[
      {"id":"adr-1a2b","type":"adres","weergavenaam":"Oudegracht 12A, 3511AB Utrecht","straatnaam":"Oudegracht",
       "huisnummer":12,"huisletter":"A","postcode":"3511AB","woonplaatsnaam":"Utrecht",
       "centroide_ll":"POINT(5.12006 52.09091)","score":14.2},
      {"id":"wgd-9","type":"weg","weergavenaam":"Oudegracht, Utrecht","straatnaam":"Oudegracht",
       "woonplaatsnaam":"Utrecht","centroide_ll":"POINT(5.1201 52.0901)","score":7.1}
    ]}}
    """#

    func testParse() throws {
        let r = try PDOKLocatieserver.parse(Data(PDOKTests.sample.utf8))
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].title, "Oudegracht 12A")
        XCTAssertEqual(r[0].subtitle, "3511AB Utrecht")
        XCTAssertEqual(r[0].kind, .address)
        XCTAssertEqual(r[0].postcode, "3511AB")
        XCTAssertEqual(r[0].houseNumber, "12A")
        XCTAssertEqual(r[0].coordinate!.latitude, 52.09091, accuracy: 1e-9)
        XCTAssertEqual(r[0].coordinate!.longitude, 5.12006, accuracy: 1e-9)
        XCTAssertEqual(r[0].relevance, 1)
        XCTAssertEqual(r[1].kind, .street)
        XCTAssertEqual(r[1].relevance, 0.5, accuracy: 1e-9)
        XCTAssertNil(PDOKLocatieserver.parseWKTPoint("POINT(abc)"))
    }

    func testURLFiltersByIntent() {
        let pdok = PDOKLocatieserver(http: FakeHTTP { _ in (Data(), 200) })
        func fq(_ text: String) -> String? {
            let url = pdok.searchURL(for: PlaceQuery(text: text), parsed: DutchAddressQuery(text), proximity: false)
            return URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "fq" }?.value
        }
        XCTAssertEqual(fq("3511AB 12"), "type:adres")
        XCTAssertEqual(fq("3511AB"), "type:(postcode OR adres)")
        XCTAssertEqual(fq("utrecht centraal"), "type:(adres OR postcode OR weg OR woonplaats)")
    }

    func testProximityDroppedWhenServerRejectsIt() async throws {
        let http = FakeHTTP { url in
            url.query!.contains("lat=") ? (Data(), 400) : (Data(PDOKTests.sample.utf8), 200)
        }
        let pdok = PDOKLocatieserver(http: http)
        let q = PlaceQuery(text: "Oudegracht 12A", near: Coordinate(52.09, 5.12))
        let r = try await pdok.search(q, parsed: DutchAddressQuery(q.text))
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(http.requests.count, 2)
    }
}

final class PlaceSearchTests: XCTestCase {
    let address = PlaceCandidate(id: "pdok:adr-1a2b", title: "Oudegracht 12A", subtitle: "3511AB Utrecht",
                                 coordinate: Coordinate(52.09091, 5.12006), kind: .address, provider: "pdok",
                                 relevance: 1, postcode: "3511AB", houseNumber: "12A")

    func testFastSourcesShowFirstAndSlowSourceNeverBlocks() async {
        var home = address
        home.id = "local:home"
        let local = StubProvider(name: "local", timeout: 0.25, delay: 0, results: [home])
        let pdok = StubProvider(name: "pdok", timeout: 2.5, delay: 0.05, results: [address])
        let amap = StubProvider(name: "amap", timeout: 0.3, delay: 5, results: [])   // 高德：慢到超时
        let search = PlaceSearch(providers: [local, pdok, amap])

        let started = Date()
        var snapshots: [PlaceSearchSnapshot] = []
        for await s in search.search(PlaceQuery(text: "3511AB 12a")) { snapshots.append(s) }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(snapshots.first?.results.first?.id, "local:home", "local answer arrives first")
        XCTAssertEqual(snapshots.first?.pending.sorted(), ["amap", "pdok"])
        let last = snapshots.last!
        XCTAssertTrue(last.done)
        XCTAssertEqual(last.failed, ["amap"])
        XCTAssertEqual(last.results.count, 1, "same postcode + house number from two sources = one result")
        XCTAssertLessThan(elapsed, 1.5, "bounded by the slow provider's timeout, not its latency")
    }

    func testRankingPrefersExactPostcodeAndNearby() {
        let ranker = PlaceRanker()
        let poi = PlaceCandidate(id: "amap:1", title: "Oudegracht Café", coordinate: Coordinate(52.0909, 5.1201),
                                 kind: .poi, provider: "amap", relevance: 1)
        let otherNumber = PlaceCandidate(id: "pdok:2", title: "Oudegracht 14", coordinate: Coordinate(52.0910, 5.1202),
                                         kind: .address, provider: "pdok", relevance: 1, postcode: "3511AB", houseNumber: "14")
        let q = PlaceQuery(text: "3511AB 12A")
        let ranked = ranker.rank([poi, otherNumber, address], query: q, parsed: DutchAddressQuery(q.text))
        XCTAssertEqual(ranked.map(\.id), ["pdok:adr-1a2b", "pdok:2", "amap:1"])

        let utrecht = PlaceCandidate(id: "a", title: "Albert Heijn", coordinate: Coordinate(52.09, 5.12), kind: .poi, provider: "amap")
        let groningen = PlaceCandidate(id: "b", title: "Albert Heijn", coordinate: Coordinate(53.21, 6.56), kind: .poi, provider: "amap")
        let near = PlaceQuery(text: "albert heijn", near: Coordinate(52.08, 5.11))
        XCTAssertEqual(ranker.rank([groningen, utrecht], query: near, parsed: DutchAddressQuery(near.text)).first?.id, "a")
    }

    func testLocalStoreRemembersAndMatches() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("places-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = LocalPlaceStore(fileURL: file)
        await store.remember(address)
        await store.setFavorite(PlaceCandidate(id: "home", title: "Thuis", subtitle: "Lange Nieuwstraat 1",
                                               coordinate: Coordinate(52.08, 5.12), kind: .address, provider: "pdok"),
                                aliases: ["thuis", "huis"])

        func find(_ text: String) async throws -> [String] {
            try await store.search(PlaceQuery(text: text), parsed: DutchAddressQuery(text)).map(\.id)
        }
        let byPrefix = try await find("oudegr 12")
        XCTAssertEqual(byPrefix, ["pdok:adr-1a2b"])
        let byPostcode = try await find("3511 AB 12A")
        XCTAssertEqual(byPostcode, ["pdok:adr-1a2b"])
        let byWrongNumber = try await find("3511AB 99")
        XCTAssertEqual(byWrongNumber, [])
        let byAlias = try await find("huis")
        XCTAssertEqual(byAlias, ["home"])

        // 持久化：重新打开还在，并且收藏标记保留。
        let reopened = LocalPlaceStore(fileURL: file)
        let hit = try await reopened.search(PlaceQuery(text: "thuis"), parsed: DutchAddressQuery("thuis"))
        XCTAssertEqual(hit.first?.kind, .favorite)
    }
}

final class NDWClientTests: XCTestCase {
    func testContractAndDeltaMerge() async throws {
        let data = try Data(contentsOf: contracts.appendingPathComponent("ndw-events.v1.example.json"))
        let page = try JSONDecoder().decode(EventsPage.self, from: data)
        XCTAssertEqual(page.version, 1842)
        XCTAssertFalse(page.full)
        XCTAssertEqual(page.feeds["incidents"]?.stale, false)
        XCTAssertEqual(page.feeds["roadworks"]?.ageSeconds, 305)

        let http = FakeHTTP { _ in (data, 200) }
        let client = NDWRelayClient(baseURL: URL(string: "https://relay.example/")!, http: http)
        let feed = NDWEventFeed(client: client)
        let box = BoundingBox(minLatitude: 51.9, minLongitude: 4.9, maxLatitude: 52.2, maxLongitude: 5.3)
        try await feed.refresh(bbox: box)
        try await feed.refresh(bbox: box)
        let urls = http.requests.map(\.absoluteString)
        XCTAssertEqual(urls[0], "https://relay.example/v1/events?bbox=51.90000,4.90000,52.20000,5.30000")
        XCTAssertTrue(urls[1].hasSuffix("&since=1842"), "second call asks for a delta")

        let events = await feed.events
        XCTAssertEqual(events.count, 4)
        await feed.apply(try JSONDecoder().decode(EventsPage.self, from: Data(#"""
            {"version": 1900, "full": false, "events": [], "removed": ["RWS03_900123_1"]}
            """#.utf8)))
        let afterDelta = await feed.events
        XCTAssertNil(afterDelta["RWS03_900123_1"])
        XCTAssertEqual(afterDelta.count, 3)
        await feed.apply(try JSONDecoder().decode(EventsPage.self, from: Data(#"""
            {"version": 2000, "full": true, "events": [], "removed": []}
            """#.utf8)))
        let afterFull = await feed.events
        XCTAssertTrue(afterFull.isEmpty)
    }

    func testFailureKeepsLastGoodData() async throws {
        let data = try Data(contentsOf: contracts.appendingPathComponent("ndw-events.v1.example.json"))
        let fail = FakeHTTP { url in url.query!.contains("since") ? (Data(), 503) : (data, 200) }
        let feed = NDWEventFeed(client: NDWRelayClient(baseURL: URL(string: "https://relay.example/")!, http: fail))
        let box = BoundingBox(minLatitude: 51.9, minLongitude: 4.9, maxLatitude: 52.2, maxLongitude: 5.3)
        try await feed.refresh(bbox: box)
        do {
            try await feed.refresh(bbox: box)
            XCTFail("expected 503")
        } catch let e as HTTPStatusError {
            XCTAssertEqual(e.status, 503)
        }
        let count = await feed.events.count
        XCTAssertEqual(count, 4)
    }
}

final class OSRMTests: XCTestCase {
    static let sample = #"""
    {"code":"Ok","routes":[
      {"distance":2480.0,"duration":130.0,
       "geometry":{"type":"LineString","coordinates":[[5.10,52.09],[5.11,52.09],[5.12,52.09],[5.12,52.08]]},
       "legs":[{"distance":2480.0,"duration":130.0,
         "annotation":{"duration":[25,25,80],
                       "maxspeed":[{"speed":100,"unit":"km/h"},{"speed":100,"unit":"km/h"},{"speed":80,"unit":"km/h"}]},
         "steps":[
           {"distance":684,"name":"","ref":"A12","maneuver":{"type":"depart","modifier":"right"},
            "intersections":[{"classes":["motorway"]}]},
           {"distance":684,"name":"A12","maneuver":{"type":"new name","modifier":"straight"},
            "intersections":[{"classes":["motorway"]}]},
           {"distance":1112,"name":"Rijksstraatweg","ref":"N228","exits":"14","destinations":"Woerden",
            "maneuver":{"type":"off ramp","modifier":"slight right"}},
           {"distance":0,"name":"","maneuver":{"type":"arrive"}}
         ]}]},
      {"distance":3000.0,"duration":160.0,
       "geometry":{"type":"LineString","coordinates":[[5.10,52.09],[5.10,52.08],[5.12,52.08]]},
       "legs":[{"steps":[{"distance":3000,"name":"x","maneuver":{"type":"roundabout","modifier":"right","exit":2}}]}]}
    ]}
    """#

    func request(_ purpose: RoutePurpose = .reroute, heading: Double? = 92.4,
                 prefs: RoutingPreferences = RoutingPreferences()) -> RouteRequest {
        RouteRequest(id: 7, purpose: purpose, origin: Coordinate(52.09, 5.10), originHeading: heading,
                     destination: Coordinate(52.08, 5.12), waypoints: [Coordinate(52.085, 5.11)],
                     preferences: prefs, issuedAt: Date(timeIntervalSince1970: 0))
    }

    func testURL() {
        let osrm = OSRMRouteProvider(baseURL: URL(string: "http://osrm.local:5000/")!)
        let url = osrm.url(for: request(prefs: RoutingPreferences(avoidTolls: true, avoidFerries: true)))
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(c.path, "/route/v1/driving/5.100000,52.090000;5.110000,52.085000;5.120000,52.080000")
        let q = Dictionary(uniqueKeysWithValues: c.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["bearings"], "92,45;;", "heading constraint on the origin only")
        XCTAssertEqual(q["exclude"], "toll,ferry")
        XCTAssertEqual(q["alternatives"], "true")
        let spec = osrm.url(for: request(.speculative(maneuverOffset: 3000, baseRouteID: "main"), heading: nil))
        let sq = URLComponents(url: spec, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(sq.first { $0.name == "alternatives" }?.value, "false")
        XCTAssertNil(sq.first { $0.name == "bearings" })
    }

    func testParse() throws {
        let routes = try OSRMRouteProvider.parse(Data(OSRMTests.sample.utf8), requestID: 7, origin: .provider,
                                                 createdAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(routes.map(\.id), ["osrm-7-0", "osrm-7-1"])
        XCTAssertEqual(routes[1].origin, .alternative)
        let r = routes[0]
        XCTAssertEqual(r.maneuvers.map(\.kind), [.depart, .exitRight, .arrive], "'new name' is not a maneuver")
        let exit = r.maneuvers[1]
        XCTAssertEqual(exit.offset, r.length * 1368 / 2480, accuracy: 1)
        XCTAssertEqual(exit.roadName, "N228")
        XCTAssertEqual(exit.exitNumber, "14")
        XCTAssertEqual(exit.signpost, "Woerden")
        XCTAssertEqual(r.roadClass(at: 100), .motorway)
        XCTAssertEqual(r.roadClass(at: r.length - 10), .rural)
        XCTAssertEqual(r.remainingTime(from: 0), 130, accuracy: 0.01)
        XCTAssertEqual(r.providerSpeedLimits.map(\.value), [100, 80], "adjacent equal limits merged")
        XCTAssertEqual(r.providerSpeedLimit(at: r.length - 10), 80)
        XCTAssertEqual(routes[1].maneuvers.first?.roundaboutExit, 2)
    }

    func testRouterSendsSpeculativeOnlyToBackgroundCapableProvider() {
        struct Fake: RouteProvider {
            var name: String
            var supportsBackgroundCalculation: Bool
            func routes(for request: RouteRequest) async throws -> [Route] { [] }
        }
        let amapOnly = RouteProviderRouter(primary: Fake(name: "amap", supportsBackgroundCalculation: false))
        XCTAssertNil(amapOnly.provider(for: request(.speculative(maneuverOffset: 1, baseRouteID: "r"))))
        XCTAssertEqual(amapOnly.provider(for: request(.reroute))?.name, "amap")
        let both = RouteProviderRouter(primary: Fake(name: "amap", supportsBackgroundCalculation: false),
                                       secondary: OSRMRouteProvider(baseURL: URL(string: "http://osrm.local/")!))
        XCTAssertEqual(both.provider(for: request(.speculative(maneuverOffset: 1, baseRouteID: "r")))?.name, "osrm")
        XCTAssertEqual(both.provider(for: request(.initial))?.name, "amap")
    }
}

final class GuidancePhrasingTests: XCTestCase {
    func testInstructionAndHazardText() {
        let exit = ManeuverDisplay(kind: .exitRight, distance: 300, exactDistance: 312, roadName: "N228",
                                   exitNumber: "14", signpost: "Woerden", roundaboutExit: nil)
        XCTAssertEqual(GuidancePhrasing.instruction(exit), "右侧驶出 · 14 · Woerden")
        let rb = ManeuverDisplay(kind: .roundabout, distance: 50, exactDistance: 50, roadName: "Kanaalweg",
                                 exitNumber: nil, signpost: nil, roundaboutExit: 2)
        XCTAssertEqual(GuidancePhrasing.instruction(rb), "环岛第 2 出口 · Kanaalweg")
        XCTAssertEqual(GuidancePhrasing.distance(300), "300 米")
        XCTAssertEqual(GuidancePhrasing.distance(1_200), "1.2 公里")
        XCTAssertEqual(GuidancePhrasing.distance(15_000), "15 公里")

        let h = HazardDisplay(eventID: "e", kind: .accident, severity: .high, distance: 600, inside: false, road: "A12",
                              closedLanes: ["lane1", "rushHourLane"], text: nil, directionVerified: true)
        XCTAssertEqual(GuidancePhrasing.hazard(h), "前方 600 米 事故 · 第 1 车道、高峰车道封闭")
    }

    func testUpcomingLimitUsesAmsterdamTime() {
        let at = ISO8601.parse("2026-10-12T17:00:00Z")!   // 19:00 CEST
        let s = FusedSpeedLimit(kmh: 100, source: .officialStatic, confidence: .high, conflict: false, advisoryKmh: nil,
                                daytimeCapApplied: false, upcomingChange: .init(kmh: 130, at: at))
        XCTAssertEqual(GuidancePhrasing.upcomingLimit(s), "19:00 起 130")
    }
}
