import Foundation
import NavCore

/// OSRM 路线服务（建议自建：Geofabrik 的荷兰 OSM 数据，单机即可，荷兰全境算路 10–50 ms）。
///
/// 用途：预算路线（高德导航 SDK 做不了后台计算）、高德迟迟不回时的快速重算。
/// OSM 在荷兰的质量很高（大量导入了 BAG/NWB 官方数据），maxspeed 覆盖也好。
/// API：http://project-osrm.org/docs/v5.24.0/api/
public struct OSRMRouteProvider: RouteProvider {
    public let name = "osrm"
    public let supportsBackgroundCalculation = true
    public var baseURL: URL
    public var profile: String
    public var timeout: TimeInterval
    private let http: any HTTPClient

    public init(baseURL: URL, profile: String = "driving", http: any HTTPClient = URLSessionHTTPClient(),
                timeout: TimeInterval = 4) {
        self.baseURL = baseURL
        self.profile = profile
        self.http = http
        self.timeout = timeout
    }

    public func url(for request: RouteRequest) -> URL {
        let coords = ([request.origin] + request.waypoints + [request.destination])
            .map { String(format: "%.6f,%.6f", $0.longitude, $0.latitude) }.joined(separator: ";")
        var c = URLComponents(url: baseURL.appendingPathComponent("route/v1/\(profile)/\(coords)"),
                              resolvingAgainstBaseURL: false)!
        let speculative: Bool = { if case .speculative = request.purpose { return true } else { return false } }()
        var items = [
            URLQueryItem(name: "overview", value: "full"),
            URLQueryItem(name: "geometries", value: "geojson"),
            URLQueryItem(name: "steps", value: "true"),
            URLQueryItem(name: "annotations", value: "duration,maxspeed"),
            URLQueryItem(name: "alternatives", value: speculative ? "false" : "true"),
        ]
        // 起点方向：± 45° —— "不要让我掉头"。
        if let h = request.originHeading {
            let rest = Array(repeating: "", count: request.waypoints.count + 1)
            items.append(URLQueryItem(name: "bearings", value: (["\(Int(h.rounded()) % 360),45"] + rest).joined(separator: ";")))
        }
        var exclude: [String] = []
        if request.preferences.avoidTolls { exclude.append("toll") }
        if request.preferences.avoidMotorways { exclude.append("motorway") }
        if request.preferences.avoidFerries { exclude.append("ferry") }
        if !exclude.isEmpty { items.append(URLQueryItem(name: "exclude", value: exclude.joined(separator: ","))) }
        c.queryItems = items
        return c.url!
    }

    public func routes(for request: RouteRequest) async throws -> [Route] {
        let (data, status) = try await http.get(url(for: request), timeout: timeout)
        guard status == 200 else { throw HTTPStatusError(status: status) }
        let origin: RouteOrigin = { if case .speculative = request.purpose { return .speculative } else { return .provider } }()
        return try OSRMRouteProvider.parse(data, requestID: request.id, origin: origin, createdAt: request.issuedAt)
    }

    // MARK: - 解析

    struct Response: Decodable {
        struct Geometry: Decodable { var coordinates: [[Double]] }
        struct MaxSpeed: Decodable { var speed: Double?; var unit: String?; var unknown: Bool?; var none: Bool? }
        struct Annotation: Decodable { var duration: [Double]?; var maxspeed: [MaxSpeed]? }
        struct StepManeuver: Decodable { var type: String; var modifier: String?; var exit: Int? }
        struct Intersection: Decodable { var classes: [String]? }
        struct Step: Decodable {
            var distance: Double
            var name: String?
            var ref: String?
            var destinations: String?
            var exits: String?
            var maneuver: StepManeuver
            var intersections: [Intersection]?
        }
        struct Leg: Decodable { var steps: [Step]; var annotation: Annotation? }
        struct RouteBody: Decodable { var geometry: Geometry; var legs: [Leg]; var distance: Double; var duration: Double }
        var code: String
        var routes: [RouteBody]?
    }

    public static func parse(_ data: Data, requestID: UInt64, origin: RouteOrigin, createdAt: Date) throws -> [Route] {
        let r = try JSONDecoder().decode(Response.self, from: data)
        guard r.code == "Ok", let bodies = r.routes else { throw HTTPStatusError(status: 422) }
        return bodies.enumerated().compactMap { i, body in
            let points = body.geometry.coordinates.compactMap { $0.count >= 2 ? Coordinate($0[1], $0[0]) : nil }
            guard points.count >= 2 else { return nil }
            let cumulative = Route.cumulativeDistances(points)
            let scale = body.distance > 0 && cumulative.last! > 0 ? cumulative.last! / body.distance : 1

            var maneuvers: [Maneuver] = []
            var classes: [ValueSpan<RoadClass>] = []
            var along = 0.0
            for step in body.legs.flatMap(\.steps) {
                let start = along * scale
                along += step.distance
                let end = along * scale
                let rc = roadClass(step)
                if end > start { classes.append(ValueSpan(start: start, end: end, value: rc)) }
                guard let kind = maneuverKind(step.maneuver) else { continue }
                maneuvers.append(Maneuver(offset: start, kind: kind,
                                          roadName: step.ref ?? step.name.flatMap { $0.isEmpty ? nil : $0 },
                                          exitNumber: step.exits, signpost: step.destinations,
                                          roundaboutExit: kind == .roundabout ? step.maneuver.exit : nil, roadClass: rc))
            }

            // 逐段注释（多个 leg 首尾相接）。
            let durations = body.legs.flatMap { $0.annotation?.duration ?? [] }
            var cumulativeTime: [Double]?
            if durations.count == points.count - 1 {
                var t = [0.0]
                for d in durations { t.append(t.last! + d) }
                cumulativeTime = t
            }
            let speeds = body.legs.flatMap { $0.annotation?.maxspeed ?? [] }
            var limits: [ValueSpan<Int>] = []
            if speeds.count == points.count - 1 {
                for (k, s) in speeds.enumerated() {
                    guard let v = s.speed, s.unknown != true, s.none != true else { continue }
                    let kmh = Int((s.unit == "mph" ? v * 1.609 : v).rounded())
                    if let last = limits.last, last.value == kmh, last.end == cumulative[k] {
                        limits[limits.count - 1].end = cumulative[k + 1]
                    } else {
                        limits.append(ValueSpan(start: cumulative[k], end: cumulative[k + 1], value: kmh))
                    }
                }
            }

            return Route(id: RouteID("osrm-\(requestID)-\(i)"), origin: i == 0 ? origin : .alternative,
                         points: points, cumulative: cumulative, maneuvers: maneuvers,
                         expectedDuration: body.duration, cumulativeTime: cumulativeTime,
                         providerSpeedLimits: limits, roadClasses: merge(classes), createdAt: createdAt)
        }
    }

    static func maneuverKind(_ m: Response.StepManeuver) -> ManeuverKind? {
        let mod = m.modifier ?? "straight"
        let isLeft = mod.contains("left")
        func turn() -> ManeuverKind {
            switch mod {
            case "uturn": return .uTurn
            case "sharp left": return .sharpLeft
            case "left": return .left
            case "slight left": return .slightLeft
            case "sharp right": return .sharpRight
            case "right": return .right
            case "slight right": return .slightRight
            default: return .straight
            }
        }
        switch m.type {
        case "depart": return .depart
        case "arrive": return .arrive
        case "off ramp": return isLeft ? .exitLeft : .exitRight
        case "fork": return mod == "straight" ? .straight : (isLeft ? .keepLeft : .keepRight)
        case "merge": return .merge
        case "roundabout", "rotary", "roundabout turn": return .roundabout
        case "exit roundabout", "exit rotary", "notification", "use lane": return nil
        case "new name", "continue":
            return mod == "straight" ? nil : turn()   // 只是换了路名：不算动作
        default: return turn()        // turn, end of road, on ramp
        }
    }

    /// 荷兰：A 号路 = 高速；OSRM 的 intersection classes 也会标 motorway。
    static func roadClass(_ s: Response.Step) -> RoadClass {
        if s.intersections?.contains(where: { $0.classes?.contains("motorway") == true }) == true { return .motorway }
        if let ref = s.ref?.uppercased().split(separator: ";").first {
            if ref.hasPrefix("A") { return .motorway }
            if ref.hasPrefix("N") { return .rural }
        }
        return .unknown
    }

    static func merge(_ spans: [ValueSpan<RoadClass>]) -> [ValueSpan<RoadClass>] {
        var out: [ValueSpan<RoadClass>] = []
        for s in spans {
            if let last = out.last, last.value == s.value, abs(last.end - s.start) < 0.01 {
                out[out.count - 1].end = s.end
            } else {
                out.append(s)
            }
        }
        return out
    }
}
