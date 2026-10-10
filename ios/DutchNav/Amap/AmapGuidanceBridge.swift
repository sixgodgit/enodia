// ⚠️ 未在本仓库 CI 中编译：需要 iOS SDK + 高德导航 SDK。方法名以你安装的 SDK 版本为准。
//
// 高德导航会话 = 车道信息的来源（⑤：直接用高德已有的车道数据，而不是自建车道库）。
//
// 做法：高德照常跑一个导航会话，但定位喂的是我们自己的 GPS（外部定位模式），
// 它在接近路口时回调车道背景/前景字符串，我们解码后交给引擎。
// 位置、偏航、走哪条路仍然由 NavigationEngine 决定；高德的会话只是"跟着走"。

import AMapNaviKit
import CoreLocation
import Foundation
import NavCore

final class AmapGuidanceBridge: NSObject, AMapNaviDriveDataRepresentable, @unchecked Sendable {
    private let manager = AMapNaviDriveManager.sharedInstance()
    var lanesSink: ((LaneFeed) -> Void)?
    var unsolicitedRoutesSink: (([Route]) -> Void)?
    /// 高德会话当前跟的是哪条路线（我们的 RouteID）；车道信息只对这条路线有效。
    private var followingRouteID: RouteID?

    init(routeProvider: AmapRouteProvider) {
        super.init()
        manager.addDataRepresentative(self)
        manager.enableExternalLocation = true
        routeProvider.onUnsolicitedRoutes = { [weak self] routes in self?.unsolicitedRoutesSink?(routes) }
    }

    func stop() {
        DispatchQueue.main.async { self.manager.stopNavi() }
    }

    /// 我们的 GPS → 高德会话。
    func feed(_ l: CLLocation) {
        let loc = AMapNaviLocation()
        loc.coordinate = AMapNaviPoint.location(withLatitude: CGFloat(l.coordinate.latitude),
                                                longitude: CGFloat(l.coordinate.longitude))
        loc.accuracy = l.horizontalAccuracy
        loc.altitude = l.altitude
        loc.course = l.course
        loc.speed = max(0, l.speed) * 3.6   // 高德 AMapNaviLocation.speed 的单位是 km/h（以 SDK 文档为准）
        loc.timestamp = l.timestamp
        DispatchQueue.main.async {
            // isAMapCoordinate: false = 这是 WGS-84；中国境外高德不做偏移。
            self.manager.setExternalLocation(loc, isAMapCoordinate: false)
        }
    }

    /// 引擎换了路线：如果是高德自己的路线（初始/备选），让高德会话也切过去，车道信息才对得上。
    /// 换到预算路线 / OSRM 路线时高德跟不过去：它会自己判定偏航并重算，结果作为 .refresh 回到引擎。
    func follow(_ change: RouteChange) {
        let raw = change.to.raw
        guard raw.hasPrefix("amap-"), let amapID = Int(raw.dropFirst(5)) else {
            followingRouteID = nil
            return
        }
        DispatchQueue.main.async {
            if change.reason == .initial {
                self.manager.selectNaviRoute(withRouteID: amapID)
                self.manager.startGPSNavi()
            } else {
                self.manager.selectNaviRoute(withRouteID: amapID)
            }
            self.followingRouteID = change.to
        }
    }

    // MARK: AMapNaviDriveDataRepresentable —— 车道

    func driveManager(_ driveManager: AMapNaviDriveManager, showLaneBackInfo laneBackInfo: String,
                      laneSelectInfo: String) {
        guard let routeID = followingRouteID else { return }
        lanesSink?(LaneFeed(guidance: AmapLaneDecoder.decode(background: laneBackInfo, selection: laneSelectInfo),
                            receivedAt: Date(), routeID: routeID))
    }

    func driveManagerHideLaneInfo(_ driveManager: AMapNaviDriveManager) {
        lanesSink?(LaneFeed(guidance: nil, receivedAt: Date(), routeID: followingRouteID))
    }
}
