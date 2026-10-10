// ⚠️ 未在本仓库 CI 中编译：需要 iOS SDK + 高德导航 SDK（CocoaPods: pod 'AMapNavi'）。
//    方法/属性名按高德 iOS 导航 SDK 文档写的；高德各版本之间有改名，接入时以你装的版本头文件为准。
//    所有和高德打交道的代码都在 ios/DutchNav/Amap/ 这两个文件里，换版本只改这里。
//
// 高德导航 SDK → NavCore.Route。
//
// 坐标：高德只在中国大陆境内用 GCJ-02；荷兰境内拿到的就是 WGS-84，不需要转换。
//       这里仍然守一道：坐标落在中国境内就拒绝（本 App 不处理 GCJ-02）。

import AMapNaviKit
import Foundation
import NavCore
import NavServices

enum AmapError: Error {
    case rejected          // calculateDriveRoute 直接返回 false
    case superseded        // 新请求顶掉了旧请求
    case failed(Error)
    case gcj02Region
}

final class AmapRouteProvider: NSObject, RouteProvider, AMapNaviDriveManagerDelegate, @unchecked Sendable {
    let name = "amap"
    /// 高德导航 SDK 是单例、一次只有一组路线：导航中再算一条会顶掉正在用的路线。所以不做后台计算。
    let supportsBackgroundCalculation = false

    private let manager = AMapNaviDriveManager.sharedInstance()
    private var pending: (request: RouteRequest, continuation: CheckedContinuation<[Route], Error>)?
    /// 不是我们发起的计算（高德自己的偏航重算）完成时回调。
    var onUnsolicitedRoutes: (([Route]) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    func routes(for request: RouteRequest) async throws -> [Route] {
        guard !Self.inChina(request.origin), !Self.inChina(request.destination) else { throw AmapError.gcj02Region }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.main.async {   // 高德 SDK 要求主线程
                self.pending?.continuation.resume(throwing: AmapError.superseded)
                self.pending = (request, cont)
                let ok = self.manager.calculateDriveRoute(
                    withStart: [Self.point(request.origin)],
                    end: [Self.point(request.destination)],
                    wayPoints: request.waypoints.map(Self.point),
                    drivingStrategy: Self.strategy(request.preferences))
                if !ok {
                    self.pending = nil
                    cont.resume(throwing: AmapError.rejected)
                }
            }
        }
    }

    // MARK: AMapNaviDriveManagerDelegate

    func driveManager(_ driveManager: AMapNaviDriveManager, onCalculateRouteSuccessWith type: AMapNaviRoutePlanType) {
        let routes = convertAll(driveManager)
        if let p = pending {
            pending = nil
            p.continuation.resume(returning: routes)
        } else if !routes.isEmpty {
            onUnsolicitedRoutes?(routes)
        }
    }

    func driveManager(_ driveManager: AMapNaviDriveManager, onCalculateRouteFailure error: Error) {
        pending?.continuation.resume(throwing: AmapError.failed(error))
        pending = nil
    }

    // MARK: 转换

    /// 当前选中的路线排第一，其余作为备选（多路线策略时高德一次给 2–3 条）。
    private func convertAll(_ m: AMapNaviDriveManager) -> [Route] {
        guard let all = m.naviRoutes else { return [] }
        let selected = m.naviRouteID
        let ordered = all.sorted { a, b in
            (a.key.intValue == selected ? 0 : 1, a.key.intValue) < (b.key.intValue == selected ? 0 : 1, b.key.intValue)
        }
        return ordered.compactMap { id, r in Self.convert(r, amapID: id.intValue, primary: id.intValue == selected) }
    }

    static func convert(_ r: AMapNaviRoute, amapID: Int, primary: Bool) -> Route? {
        let points = (r.routeCoordinates ?? []).map { Coordinate(Double($0.latitude), Double($0.longitude)) }
        guard points.count >= 2 else { return nil }
        let cumulative = Route.cumulativeDistances(points)

        // 高德 segment：iconType 是"走完这一段之后"的动作；segment.length 是米。
        var maneuvers = [Maneuver(offset: 0, kind: .depart)]
        var classes: [ValueSpan<RoadClass>] = []
        var along = 0.0
        let segments = r.routeSegments ?? []
        let scale = r.routeLength > 0 ? cumulative.last! / Double(r.routeLength) : 1
        for (i, seg) in segments.enumerated() {
            let start = along * scale
            along += Double(seg.length)
            let end = along * scale
            let rc = roadClass(seg)
            if end > start { classes.append(ValueSpan(start: start, end: end, value: rc)) }
            let next = i + 1 < segments.count ? segments[i + 1] : nil
            if let kind = maneuverKind(seg.iconType, onMotorway: rc == .motorway) {
                maneuvers.append(Maneuver(offset: end, kind: kind,
                                          roadName: next?.links?.first?.roadName,
                                          roadClass: rc))
            }
        }

        return Route(id: RouteID("amap-\(amapID)"), origin: primary ? .provider : .alternative,
                     points: points, cumulative: cumulative, maneuvers: maneuvers,
                     expectedDuration: TimeInterval(r.routeTime),
                     // 高德的逐段限速字段随版本而异（有的版本只有电子眼限速），拿不准就不填：
                     // 限速融合会退到 NDW/RWS 官方数据和道路等级默认值，而不是信一个可能错的值。
                     providerSpeedLimits: [],
                     roadClasses: classes, createdAt: Date())
    }

    /// AMapNaviIconType → ManeuverKind。高速上"右前方/左前方"多半是驶出或分岔。
    static func maneuverKind(_ icon: AMapNaviIconType, onMotorway: Bool) -> ManeuverKind? {
        switch icon {
        case .left: return .left
        case .right: return .right
        case .leftFront: return onMotorway ? .keepLeft : .slightLeft
        case .rightFront: return onMotorway ? .exitRight : .slightRight
        case .leftBack: return .sharpLeft
        case .rightBack: return .sharpRight
        case .leftAndAround: return .uTurn
        case .enterRoundabout: return .roundabout
        case .arrivedWayPoint: return .waypoint
        case .arrivedDestination: return .arrive
        case .straight: return nil
        default: return nil
        }
    }

    /// 高德道路等级（AMapNaviRoadClass，0 = 高速）→ 荷兰分类。高德海外数据的等级口径未核实，尽力而为。
    static func roadClass(_ seg: AMapNaviSegment) -> RoadClass {
        guard let raw = seg.links?.first?.roadClass.rawValue else { return .unknown }
        switch raw {
        case 0: return .motorway
        case 6: return .expressway
        case 1, 2, 3, 4: return .rural
        case 5, 7, 8, 9: return .urban
        default: return .unknown
        }
    }

    static func strategy(_ p: RoutingPreferences) -> AMapNaviDrivingStrategy {
        ConvertDrivingPreferenceToDrivingStrategy(true, true, p.avoidMotorways, p.avoidTolls, false)
    }

    static func point(_ c: Coordinate) -> AMapNaviPoint {
        AMapNaviPoint.location(withLatitude: CGFloat(c.latitude), longitude: CGFloat(c.longitude))
    }

    /// 粗略的中国大陆范围（GCJ-02 生效区域），只用来拒绝，不用来转换。
    static func inChina(_ c: Coordinate) -> Bool {
        c.longitude > 73.66 && c.longitude < 135.05 && c.latitude > 3.86 && c.latitude < 53.55
    }
}
