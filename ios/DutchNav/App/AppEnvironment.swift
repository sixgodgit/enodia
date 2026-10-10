// ⚠️ 未在本仓库 CI 中编译：需要 iOS SDK + 高德 SDK。
//
// 组装：读配置 → 建 provider → 建宿主。Info.plist 里的键：
//   AMapApiKey      高德 key（绑定 bundle id）
//   NDWRelayURL     NDW 中继地址，例如 https://nav.example.nl/   （不填 = 没有 NDW 事件层，导航照常）
//   OSRMURL         自建 OSRM，例如 https://osrm.example.nl/    （不填 = 不做预算路线）

import AMapNaviKit
import CoreLocation
import Foundation
import NavCore
import NavServices

final class AppEnvironment: @unchecked Sendable {
    static let shared = AppEnvironment()

    let host: NavigationHost
    let places: PlaceSearch
    let localPlaces: LocalPlaceStore
    private(set) var destinationCoordinate = CLLocationCoordinate2D()

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        AMapServices.shared().apiKey = info["AMapApiKey"] as? String
        AMapServices.shared().enableHTTPS = true
        // 高德 SDK 8.x 起要求在使用前完成隐私合规声明（updatePrivacyShow / updatePrivacyAgree），
        // 具体调用以所装版本的文档为准，见 ios/README.md。

        let amapRoutes = AmapRouteProvider()
        let osrm = (info["OSRMURL"] as? String).flatMap(URL.init(string:)).map { OSRMRouteProvider(baseURL: $0) }
        let ndw = (info["NDWRelayURL"] as? String).flatMap(URL.init(string:))
            .map { NDWEventFeed(client: NDWRelayClient(baseURL: $0)) }

        host = NavigationHost(routing: RouteProviderRouter(primary: amapRoutes, secondary: osrm),
                              amapGuidance: AmapGuidanceBridge(routeProvider: amapRoutes),
                              ndw: ndw, jev: nil)

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        localPlaces = LocalPlaceStore(fileURL: support.appendingPathComponent("places.json"))
        // 本地记忆 < 5 ms，PDOK ~100–300 ms，MapKit ~0.5–1 s；高德 POI 若要接，给它 1.5 s 的硬超时。
        places = PlaceSearch(providers: [localPlaces, PDOKLocatieserver(), MapKitPlaceProvider()])
    }

    func navigate(to place: PlaceCandidate) {
        guard let c = place.coordinate else { return }
        destinationCoordinate = CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
        host.start(TripPlan(id: UUID().uuidString, destination: c))
        Task { await localPlaces.remember(place) }
    }
}
