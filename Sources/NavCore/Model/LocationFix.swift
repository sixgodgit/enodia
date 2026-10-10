import Foundation

/// 一次定位。字段语义对齐 CoreLocation（CLLocation），但不依赖它。
public struct LocationFix: Sendable, Equatable {
    public var coordinate: Coordinate
    public var timestamp: Date
    /// 水平精度（米）。越大越不可信；超过阈值的点不参与偏航判定。
    public var horizontalAccuracy: Double
    /// 米/秒；nil 表示无效。
    public var speed: Double?
    /// 航向，0..<360；nil 表示无效（低速时 GPS 航向不可信）。
    public var course: Double?

    public init(coordinate: Coordinate, timestamp: Date, horizontalAccuracy: Double = 5,
                speed: Double? = nil, course: Double? = nil) {
        self.coordinate = coordinate
        self.timestamp = timestamp
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed.flatMap { $0 >= 0 ? $0 : nil }
        self.course = course.flatMap { $0 >= 0 ? Geo.normalize($0) : nil }
    }

    /// 速度够快时航向才有意义。
    public func reliableCourse(minimumSpeed: Double) -> Double? {
        guard let c = course, let s = speed, s >= minimumSpeed else { return nil }
        return c
    }
}
