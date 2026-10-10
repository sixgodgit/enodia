import Foundation

/// 折线线段的网格索引：给一个点和半径，O(1) 拿到附近的线段下标。
///
/// 只在"丢失位置"时用（第一次定位、隧道出来、跳变）；正常行驶时匹配器只看上一次匹配附近的窗口。
/// 构建是 O(n)，在拿到路线的那条异步线程上完成，不进实时链路。
public struct SegmentGrid: Sendable {
    /// 约 280 m × 270 m（北纬 52°）。
    static let latStep = 0.0025
    static let lonStep = 0.004

    private let cells: [Int64: [Int32]]

    public init(points: [Coordinate]) {
        var cells: [Int64: [Int32]] = [:]
        if points.count >= 2 {
            for i in 0..<(points.count - 1) {
                let a = points[i], b = points[i + 1]
                let (r0, c0) = SegmentGrid.cell(a)
                let (r1, c1) = SegmentGrid.cell(b)
                for r in min(r0, r1)...max(r0, r1) {
                    for c in min(c0, c1)...max(c0, c1) {
                        cells[SegmentGrid.key(r, c), default: []].append(Int32(i))
                    }
                }
            }
        }
        self.cells = cells
    }

    /// 半径 `radius` 米内可能相交的线段下标（升序、去重；是候选，不保证真的在半径内）。
    public func segments(near p: Coordinate, radius: Double) -> [Int] {
        let dLat = radius / (Geo.earthRadius * .pi / 180)
        let dLon = dLat / max(0.01, cos(Geo.radians(p.latitude)))
        let (r0, c0) = SegmentGrid.cell(Coordinate(p.latitude - dLat, p.longitude - dLon))
        let (r1, c1) = SegmentGrid.cell(Coordinate(p.latitude + dLat, p.longitude + dLon))
        var out: [Int] = []
        for r in r0...r1 {
            for c in c0...c1 {
                if let list = cells[SegmentGrid.key(r, c)] {
                    out.append(contentsOf: list.lazy.map(Int.init))
                }
            }
        }
        out.sort()
        return out.uniqued()
    }

    @inline(__always)
    static func cell(_ p: Coordinate) -> (Int32, Int32) {
        (Int32((p.latitude / latStep).rounded(.down)), Int32((p.longitude / lonStep).rounded(.down)))
    }

    @inline(__always)
    static func key(_ r: Int32, _ c: Int32) -> Int64 {
        (Int64(r) << 32) | Int64(UInt32(bitPattern: c))
    }
}

extension Array where Element: Equatable {
    /// 对已排序数组去重。
    func uniqued() -> [Element] {
        guard var last = first else { return self }
        var out: [Element] = [last]
        out.reserveCapacity(count)
        for e in dropFirst() where e != last {
            out.append(e)
            last = e
        }
        return out
    }
}
