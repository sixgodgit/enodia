// ⚠️ 未在本仓库 CI 中编译：需要 iOS SDK（CoreLocation）。NavCore / NavServices 部分已在 Linux 上测试。
//
// 宿主：把 GPS、高德、NDW 中继、JEV 接到 NavigationEngine 上。
//
// 三条队列，各司其职：
//   realtime   (userInteractive, 串行)  —— 只做 engine.process，每个 GPS 点一次，毫秒级
//   annotate   (utility, 串行)          —— 把 NDW 事件/限速/门架投影到路线上（RouteAnnotator），可以慢
//   Swift 并发 (Task)                   —— 网络：高德算路、NDW 轮询、JEV
// 任何网络结果都只是"往引擎收件箱里放一条消息"。

import CoreLocation
import Foundation
import NavCore
import NavServices

/// JEV 侧的接口。实现可以是本机进程、局域网服务或者干脆不接 —— 核心照常工作。
protocol StrategyChannel: AnyObject, Sendable {
    func send(_ telemetry: TripTelemetry)
    func resolved(adviceID: String, applied: Bool, note: String)
    /// JEV 推来的建议，宿主转给引擎。
    var onAdvice: (@Sendable (StrategyAdvice) -> Void)? { get set }
}

final class NavigationHost: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    let engine = NavigationEngine()
    private let realtime = DispatchQueue(label: "nav.realtime", qos: .userInteractive)
    private let annotate = DispatchQueue(label: "nav.annotate", qos: .utility)
    private let location = CLLocationManager()
    private let annotator = RouteAnnotator()

    private let routing: RouteProviderRouter
    private let amapGuidance: AmapGuidanceBridge?
    private let ndw: NDWEventFeed?
    private weak var jev: StrategyChannel?

    /// 画面输出（主线程回调）：CarPlay 和手机 UI 订阅它。
    var onDisplay: (@MainActor (DriveDisplayState) -> Void)?

    // annotate 队列上的状态
    private var routesByID: [RouteID: Route] = [:]
    private var activeRouteID: RouteID?
    private var latestEvents: [TrafficEvent] = []
    private var ndwTask: Task<Void, Never>?

    init(routing: RouteProviderRouter, amapGuidance: AmapGuidanceBridge?, ndw: NDWEventFeed?, jev: StrategyChannel?) {
        self.routing = routing
        self.amapGuidance = amapGuidance
        self.ndw = ndw
        self.jev = jev
        super.init()
        location.delegate = self
        location.activityType = .automotiveNavigation
        location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        location.distanceFilter = kCLDistanceFilterNone
        location.pausesLocationUpdatesAutomatically = false
        jev?.onAdvice = { [engine] advice in engine.submit(advice) }
        amapGuidance?.lanesSink = { [engine] feed in engine.updateLanes(feed) }
        amapGuidance?.unsolicitedRoutesSink = { [weak self] routes in
            // 高德自己重算出来的（偏航后/路况刷新）：作为"更新版"，由引擎在安全点决定要不要。
            self?.remember(routes)
            self?.engine.offer(RouteOffer(requestID: nil, purpose: .refresh, routes: routes))
        }
    }

    // MARK: - 行程

    func start(_ trip: TripPlan) {
        engine.startTrip(trip)
        location.requestWhenInUseAuthorization()
        location.allowsBackgroundLocationUpdates = true
        location.startUpdatingLocation()
    }

    func stop() {
        engine.endTrip()
        location.stopUpdatingLocation()
        amapGuidance?.stop()
        ndwTask?.cancel()
    }

    // MARK: - GPS → 实时链路

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for l in locations {
            amapGuidance?.feed(l)   // 高德会话跟着我们的定位走（车道信息来自它）
            realtime.async { [weak self] in self?.tick(l) }
        }
    }

    private func tick(_ l: CLLocation) {
        let fix = LocationFix(
            coordinate: Coordinate(l.coordinate.latitude, l.coordinate.longitude),
            timestamp: l.timestamp,
            horizontalAccuracy: l.horizontalAccuracy,
            speed: l.speed >= 0 ? l.speed : nil,
            course: l.course >= 0 && (l.courseAccuracy < 0 || l.courseAccuracy < 30) ? l.course : nil)
        let out = engine.process(fix)
        for intent in out.intents { perform(intent) }
        let display = out.display
        Task { @MainActor [weak self] in self?.onDisplay?(display) }
    }

    // MARK: - 引擎要求的事（全部异步，结果回收件箱）

    private func perform(_ intent: EngineIntent) {
        switch intent {
        case .requestRoute(let request):
            guard let provider = routing.provider(for: request) else { return }   // 没有能做预算的 provider：跳过
            Task { [weak self] in
                // 失败不用处理：引擎在超时后会自己重发。
                guard let self, let routes = try? await provider.routes(for: request), !routes.isEmpty else { return }
                self.remember(routes)   // 先登记（annotate 队列串行，保证早于 activeRouteChanged）
                self.engine.offer(RouteOffer(requestID: request.id, purpose: request.purpose, routes: routes))
            }

        case .activeRouteChanged(let change):
            amapGuidance?.follow(change)
            annotate.async { [weak self] in
                guard let self else { return }
                self.activeRouteID = change.to
                self.reannotate()
                self.restartNDWPolling()
            }

        case .telemetry(let t):
            jev?.send(t)

        case .adviceResolved(let id, let applied, let note):
            jev?.resolved(adviceID: id, applied: applied, note: note)
        }
    }

    // MARK: - NDW → 注释（annotate 队列）

    private func remember(_ routes: [Route]) {
        annotate.async { [weak self] in routes.forEach { self?.routesByID[$0.id] = $0 } }
    }

    private func restartNDWPolling() {
        guard let ndw, let id = activeRouteID, let route = routesByID[id],
              let box = BoundingBox(covering: route.points)?.expanded(byMeters: 2000) else { return }
        ndwTask?.cancel()
        ndwTask = Task { [weak self] in
            var reset = true
            while !Task.isCancelled {
                if let events = try? await ndw.refresh(bbox: box, reset: reset) {
                    reset = false
                    self?.annotate.async {
                        self?.latestEvents = events
                        self?.reannotate()
                    }
                }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    private func reannotate() {
        guard let id = activeRouteID, let route = routesByID[id] else { return }
        let a = annotator.annotate(route: route, events: latestEvents, now: Date())
        engine.updateAnnotations(a)
    }
}
