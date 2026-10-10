import Foundation

/// WGS-84 坐标。NavCore 内部只有这一种坐标系。
///
/// 高德在中国大陆以外不做 GCJ-02 偏移，荷兰境内拿到的就是 WGS-84；
/// 但"以外不偏移"是接入层（ios/AmapAdapter）要守住的边界，核心不关心。
public struct Coordinate: Hashable, Sendable, Codable, CustomStringConvertible {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public init(_ latitude: Double, _ longitude: Double) {
        self.init(latitude: latitude, longitude: longitude)
    }

    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180
    }

    public var description: String {
        String(format: "(%.6f, %.6f)", latitude, longitude)
    }
}

public enum Geo {
    public static let earthRadius = 6_371_008.8

    @inline(__always) public static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    @inline(__always) public static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

    /// 大圆距离（米）。用于路线累计里程等"远距离"量。
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let dLat = radians(b.latitude - a.latitude)
        let dLon = radians(b.longitude - a.longitude)
        let s = sin(dLat / 2) * sin(dLat / 2)
            + cos(radians(a.latitude)) * cos(radians(b.latitude)) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(s)))
    }

    /// 初始方位角，0..<360，正北为 0、顺时针。
    public static func bearing(_ a: Coordinate, _ b: Coordinate) -> Double {
        let lat1 = radians(a.latitude), lat2 = radians(b.latitude)
        let dLon = radians(b.longitude - a.longitude)
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return normalize(degrees(atan2(y, x)))
    }

    /// 两个方位角之间的夹角，0...180。
    public static func angleBetween(_ a: Double, _ b: Double) -> Double {
        let d = abs(normalize(a) - normalize(b))
        return d > 180 ? 360 - d : d
    }

    public static func normalize(_ bearing: Double) -> Double {
        let r = bearing.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// 从某点沿方位角走一段距离后的位置。
    public static func destination(from c: Coordinate, bearing: Double, distance: Double) -> Coordinate {
        let δ = distance / earthRadius
        let θ = radians(bearing)
        let φ1 = radians(c.latitude), λ1 = radians(c.longitude)
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        return Coordinate(degrees(φ2), degrees(λ2))
    }

    /// 线性插值（短距离足够准确）。
    public static func interpolate(_ a: Coordinate, _ b: Coordinate, _ t: Double) -> Coordinate {
        Coordinate(a.latitude + (b.latitude - a.latitude) * t,
                   a.longitude + (b.longitude - a.longitude) * t)
    }
}

/// 以某点为原点的局部平面（东 x、北 y，单位米）。
///
/// 匹配只关心 GPS 点附近几百米内的几何，每个 GPS 点用自己做原点，
/// 误差远小于 GPS 本身；比每段都算 haversine 便宜一个数量级。
public struct LocalFrame: Sendable {
    public let anchor: Coordinate
    public let metersPerDegreeLatitude: Double
    public let metersPerDegreeLongitude: Double

    public init(anchor: Coordinate) {
        self.anchor = anchor
        let mPerDeg = Geo.earthRadius * .pi / 180
        metersPerDegreeLatitude = mPerDeg
        metersPerDegreeLongitude = mPerDeg * cos(Geo.radians(anchor.latitude))
    }

    @inline(__always)
    public func project(_ c: Coordinate) -> (x: Double, y: Double) {
        ((c.longitude - anchor.longitude) * metersPerDegreeLongitude,
         (c.latitude - anchor.latitude) * metersPerDegreeLatitude)
    }

    public func unproject(x: Double, y: Double) -> Coordinate {
        Coordinate(anchor.latitude + y / metersPerDegreeLatitude,
                   anchor.longitude + x / metersPerDegreeLongitude)
    }
}

/// 点到线段的投影结果（在 frame 的局部平面里算）。
public struct SegmentProjection: Sendable, Equatable {
    /// 线段参数：0 = 起点，1 = 终点；允许 lead-in 时可以小于 0。
    public var t: Double
    /// 点到投影点的距离（米）。
    public var distance: Double
    /// 线段长度（米，局部平面）。
    public var length: Double
}

extension LocalFrame {
    /// 把 frame 原点投影到线段 ab 上。`minT` 小于 0 时允许向起点之前延长（用于"还没开上新路线起点"的情况）。
    @inline(__always)
    public func projectAnchor(ontoSegment a: Coordinate, _ b: Coordinate, minT: Double = 0) -> SegmentProjection {
        let (ax, ay) = project(a)
        let (bx, by) = project(b)
        let dx = bx - ax, dy = by - ay
        let len2 = dx * dx + dy * dy
        guard len2 > 1e-9 else {
            return SegmentProjection(t: 0, distance: (ax * ax + ay * ay).squareRoot(), length: 0)
        }
        var t = -(ax * dx + ay * dy) / len2
        t = min(1, max(minT, t))
        let px = ax + t * dx, py = ay + t * dy
        return SegmentProjection(t: t, distance: (px * px + py * py).squareRoot(), length: len2.squareRoot())
    }
}

public struct BoundingBox: Hashable, Sendable, Codable {
    public var minLatitude: Double
    public var minLongitude: Double
    public var maxLatitude: Double
    public var maxLongitude: Double

    public init(minLatitude: Double, minLongitude: Double, maxLatitude: Double, maxLongitude: Double) {
        self.minLatitude = minLatitude
        self.minLongitude = minLongitude
        self.maxLatitude = maxLatitude
        self.maxLongitude = maxLongitude
    }

    public init?<S: Sequence>(covering points: S) where S.Element == Coordinate {
        var it = points.makeIterator()
        guard let first = it.next() else { return nil }
        var box = BoundingBox(minLatitude: first.latitude, minLongitude: first.longitude,
                              maxLatitude: first.latitude, maxLongitude: first.longitude)
        while let p = it.next() { box.include(p) }
        self = box
    }

    public mutating func include(_ p: Coordinate) {
        minLatitude = min(minLatitude, p.latitude)
        maxLatitude = max(maxLatitude, p.latitude)
        minLongitude = min(minLongitude, p.longitude)
        maxLongitude = max(maxLongitude, p.longitude)
    }

    public func contains(_ p: Coordinate) -> Bool {
        p.latitude >= minLatitude && p.latitude <= maxLatitude
            && p.longitude >= minLongitude && p.longitude <= maxLongitude
    }

    public func intersects(_ o: BoundingBox) -> Bool {
        !(o.minLatitude > maxLatitude || o.maxLatitude < minLatitude
            || o.minLongitude > maxLongitude || o.maxLongitude < minLongitude)
    }

    public func expanded(byMeters m: Double) -> BoundingBox {
        let dLat = m / (Geo.earthRadius * .pi / 180)
        let midLat = (minLatitude + maxLatitude) / 2
        let dLon = dLat / max(0.01, cos(Geo.radians(midLat)))
        return BoundingBox(minLatitude: minLatitude - dLat, minLongitude: minLongitude - dLon,
                           maxLatitude: maxLatitude + dLat, maxLongitude: maxLongitude + dLon)
    }
}
