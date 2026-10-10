import Foundation

/// 实时导航核心。
///
/// 线程模型：
/// - `process(_:)` 只能从**一个串行上下文**调用（iOS 上是专用的 userInteractive 串行队列），
///   每个 GPS 点调用一次，同步返回要显示的画面和要宿主去做的事（intents）。它不做 I/O、不 await、不加锁等人。
/// - 其余入口（offer / updateAnnotations / updateLanes / submit / startTrip / endTrip）任何线程都能调，
///   只是把消息放进收件箱，下一次 `process` 开头一次性取走。
///
/// 所以：高德慢、NDW 慢、JEV 慢，都只是"消息晚到"，永远不会让这一秒的引导卡住。
public final class NavigationEngine: @unchecked Sendable {
    public let config: EngineConfig
    private let fuser: SpeedLimitFuser
    private let gate: StrategyGate

    // MARK: 收件箱（唯一的跨线程状态）

    private enum Message {
        case trip(TripPlan)
        case endTrip
        case routes(RouteOffer)
        case annotations(RouteAnnotations)
        case lanes(LaneFeed)
        case advice(StrategyAdvice)
    }

    private let inboxLock = NSLock()
    private var inbox: [Message] = []
    private let processingLock = NSLock()

    // MARK: 实时状态（只在 process 里读写）

    private struct Speculative {
        var route: Route
        var maneuverOffset: Double
        var baseRouteID: RouteID
    }

    private struct PendingRoute {
        var id: UInt64
        var purpose: RoutePurpose
        var issuedAt: Date
        var attempts: Int
    }

    private struct PendingAdvice {
        var advice: StrategyAdvice
        var requestID: UInt64?
        var routes: [Route]?
    }

    private struct EventAvoidance {
        var requestID: UInt64
        var area: BoundingBox
        var routes: [Route]?
        var done = false
    }

    private var trip: TripPlan?
    private var remainingWaypoints: [Coordinate] = []
    private var active: Route?
    private var activeLeadIn = 0.0
    private var alternatives: [Route] = []
    private var speculative: [Speculative] = []
    private var requestedSpeculative: Set<Int> = []
    private var annotations: [RouteID: RouteAnnotations] = [:]
    private var laneFeed: LaneFeed?
    private var advices: [PendingAdvice] = []
    private var eventAvoidance: [String: EventAvoidance] = [:]
    private var pendingRefresh: [Route]?

    private var matcher: RouteMatcher
    private var detector: OffRouteDetector
    private var currentMatch: RouteMatch?
    private var lastGoodMatch: RouteMatch?
    private var offRouteSince: Date?
    private var pendingRoute: PendingRoute?
    private var nextRequestID: UInt64 = 1
    private var lastRouteChange: Date?
    private var lastTelemetry: Date?
    private var strategyNote: (text: String, until: Date)?
    private var arrived = false

    /// 限速融合要做时区/时段计算（Foundation Calendar 很贵），输入没变就复用几秒。
    private struct SpeedMemo {
        var observations: [SpeedLimitObservation]
        var roadClass: RoadClass?
        var result: FusedSpeedLimit?
        var computedAt: Date
    }
    private var speedMemo: SpeedMemo?

    public init(config: EngineConfig = EngineConfig(), calendar: Calendar = DutchRoadRules.amsterdamCalendar) {
        self.config = config
        self.fuser = SpeedLimitFuser(calendar: calendar)
        self.gate = StrategyGate(config: config.strategy)
        self.matcher = RouteMatcher(config: config.matcher)
        self.detector = OffRouteDetector(config: config.offRoute)
    }

    // MARK: - 异步入口（任何线程）

    public func startTrip(_ plan: TripPlan) { post(.trip(plan)) }
    public func endTrip() { post(.endTrip) }
    public func offer(_ offer: RouteOffer) { post(.routes(offer)) }
    public func updateAnnotations(_ annotations: RouteAnnotations) { post(.annotations(annotations)) }
    public func updateLanes(_ feed: LaneFeed) { post(.lanes(feed)) }
    public func submit(_ advice: StrategyAdvice) { post(.advice(advice)) }

    private func post(_ m: Message) {
        inboxLock.lock()
        inbox.append(m)
        inboxLock.unlock()
    }

    // MARK: - 实时入口

    public func process(_ fix: LocationFix) -> EngineOutput {
        let clock = ContinuousClock()
        let started = clock.now
        precondition(processingLock.try(), "NavigationEngine.process must be called from a single serial context")
        defer { processingLock.unlock() }

        var intents: [EngineIntent] = []
        drainInbox(fix, &intents)
        let display = step(fix, &intents)
        return EngineOutput(display: display, intents: intents, processingTime: clock.now - started)
    }

    // MARK: - 收件箱处理

    private func drainInbox(_ fix: LocationFix, _ intents: inout [EngineIntent]) {
        inboxLock.lock()
        let messages = inbox
        inbox.removeAll(keepingCapacity: true)
        inboxLock.unlock()

        for m in messages {
            switch m {
            case .trip(let plan):
                resetTripState()
                trip = plan
                remainingWaypoints = plan.waypoints
            case .endTrip:
                resetTripState()
                trip = nil
            case .routes(let offer):
                handle(offer, fix, &intents)
            case .annotations(let a):
                annotations[a.routeID] = a
            case .lanes(let feed):
                laneFeed = feed
            case .advice(let a):
                advices.removeAll { $0.advice.id == a.id }
                advices.append(PendingAdvice(advice: a))
            }
        }
    }

    private func resetTripState() {
        active = nil
        activeLeadIn = 0
        alternatives = []
        speculative = []
        requestedSpeculative = []
        annotations = [:]
        laneFeed = nil
        advices = []
        eventAvoidance = [:]
        pendingRefresh = nil
        matcher.reset()
        detector.reset()
        currentMatch = nil
        lastGoodMatch = nil
        offRouteSince = nil
        pendingRoute = nil
        lastRouteChange = nil
        lastTelemetry = nil
        strategyNote = nil
        arrived = false
        speedMemo = nil
    }

    private func handle(_ offer: RouteOffer, _ fix: LocationFix, _ intents: inout [EngineIntent]) {
        guard trip != nil, let primary = offer.routes.first else { return }
        let rest = Array(offer.routes.dropFirst())

        switch offer.purpose {
        case .initial:
            // 已经在导航时迟到的初始路线没有意义。
            guard active == nil else { return }
            adopt(primary, leadIn: 0, reason: .initial, alternatives: rest, fix, &intents)

        case .reroute:
            // 司机已经自己开回原路线了：迟到的重算结果丢掉。
            guard detector.state.isOffRoute || pendingRoute?.purpose == .reroute else { return }
            if vehicleFits(primary, fix) {
                adopt(primary, leadIn: 0, reason: .reroute, alternatives: rest, fix, &intents)
            } else if var p = pendingRoute, p.purpose == .reroute {
                // 结果已经过时（车开远了），立刻允许重发。
                p.issuedAt = .distantPast
                pendingRoute = p
            }

        case .speculative(let maneuverOffset, let base):
            guard active?.id == base, speculative.count < config.maxSpeculative else { return }
            speculative.append(Speculative(route: primary, maneuverOffset: maneuverOffset, baseRouteID: base))

        case .strategy(let adviceID):
            if let i = advices.firstIndex(where: { $0.advice.id == adviceID }) {
                advices[i].routes = offer.routes
            }

        case .avoidEvent(let eventID):
            guard var state = eventAvoidance[eventID], !state.done else { return }
            // 路线服务没有真的绕开（例如避让区域不被支持）：不采纳。
            if primary.points.contains(where: state.area.contains) {
                state.done = true
            } else {
                state.routes = offer.routes
            }
            eventAvoidance[eventID] = state

        case .refresh:
            pendingRefresh = offer.routes
        }
    }

    // MARK: - 每个点的主流程

    private func step(_ fix: LocationFix, _ intents: inout [EngineIntent]) -> DriveDisplayState {
        guard let trip else { return .idle }
        if arrived { return arrivedDisplay(fix) }
        if let next = remainingWaypoints.first,
           Geo.distance(fix.coordinate, next) <= config.waypointReachedRadius {
            remainingWaypoints.removeFirst()
        }

        guard active != nil else {
            requestIfDue(.initial, fix, &intents)
            var d = DriveDisplayState.idle
            d.phase = .planning(attempts: pendingRoute?.attempts ?? 0)
            d.speedKmh = kmh(fix.speed)
            return d
        }

        // 1. 匹配 + 偏航判定
        currentMatch = matcher.match(fix, on: active!, leadIn: activeLeadIn)
        let adherence = detector.update(match: currentMatch, fix: fix)

        switch adherence {
        case .offRoute(let since):
            if offRouteSince == nil { offRouteSince = since }
            // 2. 第一阶段重算：不等路线服务。
            if let c = instantCandidate(fix) {
                adopt(c.route, leadIn: c.leadIn, reason: c.reason, alternatives: nil, fix, &intents)
            } else {
                requestIfDue(.reroute, fix, &intents)
            }
        case .onRoute:
            if let m = currentMatch {
                lastGoodMatch = m
                if activeLeadIn > 0 && m.offset > 0 { activeLeadIn = 0 }
            }
            offRouteSince = nil
            if pendingRoute?.purpose == .reroute { pendingRoute = nil }
        case .suspect:
            break
        }

        let route = active!
        let offRoute = detector.state.isOffRoute
        let offset = (offRoute ? lastGoodMatch?.offset : currentMatch?.offset) ?? lastGoodMatch?.offset ?? 0

        // 3. 在路线上时：预算下一个高速决策点、检查前方封路
        if !offRoute, let m = currentMatch {
            planSpeculative(route, m, fix, &intents)
            speculative.removeAll { $0.maneuverOffset < m.offset - 1500 }
            checkBlockingEvents(route, offset, fix, trip, &intents)
        }

        // 4. 延后执行的换路（JEV 建议、封路避让）
        processDeferred(offset, fix, &intents)

        // 5. 到达
        let r = active!
        let o = (r === route) ? offset : (currentMatch?.offset ?? 0)
        if !detector.state.isOffRoute, r.length - o <= config.arrivalRadius,
           (currentMatch?.lateral ?? .infinity) < max(50, 2 * fix.horizontalAccuracy) {
            arrived = true
            return arrivedDisplay(fix)
        }

        let display = buildDisplay(fix, r, o)
        emitTelemetryIfDue(fix, display, &intents)
        return display
    }

    // MARK: - 第一阶段重算

    private func instantCandidate(_ fix: LocationFix) -> (route: Route, leadIn: Double, reason: RouteChange.Reason)? {
        for alt in alternatives where fitsTightly(alt, fix, leadIn: 0) {
            return (alt, 0, .alternativeInstant)
        }
        let course = fix.reliableCourse(minimumSpeed: config.offRoute.minSpeedForHeading)
        for s in speculative where s.baseRouteID == active?.id {
            if fitsTightly(s.route, fix, leadIn: 0) { return (s.route, 0, .speculativeInstant) }
            // 车还在驶向预算路线起点（"错过"点在出口之后几百米）。
            guard let c = course else { continue }
            let start = s.route.start
            if Geo.distance(fix.coordinate, start) <= config.speculativeLeadIn,
               Geo.angleBetween(c, Geo.bearing(fix.coordinate, start)) <= config.instantSwitchHeading,
               Geo.angleBetween(c, s.route.bearing(ofSegment: 0)) <= config.instantSwitchHeading,
               fitsTightly(s.route, fix, leadIn: config.speculativeLeadIn) {
                return (s.route, config.speculativeLeadIn, .speculativeInstant)
            }
        }
        return nil
    }

    /// 车此刻确实开在这条路线上（偏航阈值以内、方向一致）。
    private func fitsTightly(_ route: Route, _ fix: LocationFix, leadIn: Double) -> Bool {
        var m = RouteMatcher(config: config.matcher)
        guard let rm = m.match(fix, on: route, leadIn: leadIn) else { return false }
        return rm.lateral <= detector.threshold(forAccuracy: fix.horizontalAccuracy)
            && (rm.headingDelta ?? 0) <= config.instantSwitchHeading
            && route.length - rm.offset > config.arrivalRadius
    }

    /// 路线服务回来的新路线是否还"接得上"车现在的位置。
    /// 偏航重算的结果还要求车没开出它的前 acceptWithin 米（否则就是过时结果，该重发）；
    /// 延后采纳的路线（避让/策略/更新版）只看横向和方向。
    private func vehicleFits(_ route: Route, _ fix: LocationFix, maxOffset: Double? = nil) -> Bool {
        var m = RouteMatcher(config: config.matcher)
        guard let rm = m.match(fix, on: route) else { return false }
        return rm.lateral <= max(config.acceptRadius, 2 * fix.horizontalAccuracy)
            && rm.offset <= (maxOffset ?? config.acceptWithin)
            && (rm.headingDelta ?? 0) <= 60
    }

    private func requestIfDue(_ purpose: RoutePurpose, _ fix: LocationFix, _ intents: inout [EngineIntent]) {
        var attempts = 0
        if let p = pendingRoute, p.purpose == purpose {
            let wait = p.attempts >= config.maxRerouteAttempts ? config.slowRetryInterval : config.rerouteTimeout
            if fix.timestamp.timeIntervalSince(p.issuedAt) < wait { return }
            attempts = p.attempts
        }
        let req = makeRequest(purpose, origin: fix.coordinate,
                              heading: fix.reliableCourse(minimumSpeed: config.offRoute.minSpeedForHeading),
                              preferences: trip?.preferences ?? RoutingPreferences(), fix)
        pendingRoute = PendingRoute(id: req.id, purpose: purpose, issuedAt: fix.timestamp, attempts: attempts + 1)
        intents.append(.requestRoute(req))
    }

    private func makeRequest(_ purpose: RoutePurpose, origin: Coordinate, heading: Double?,
                             preferences: RoutingPreferences, _ fix: LocationFix) -> RouteRequest {
        defer { nextRequestID += 1 }
        return RouteRequest(id: nextRequestID, purpose: purpose, origin: origin, originHeading: heading,
                            destination: trip!.destination, waypoints: remainingWaypoints,
                            preferences: preferences, issuedAt: fix.timestamp)
    }

    private func adopt(_ route: Route, leadIn: Double, reason: RouteChange.Reason, alternatives newAlternatives: [Route]?,
                       _ fix: LocationFix, _ intents: inout [EngineIntent]) {
        let old = active
        active = route
        activeLeadIn = leadIn
        if let newAlternatives {
            alternatives = Array(newAlternatives.prefix(config.maxAlternatives))
        } else {
            // 原路线降为备选：司机也许会开回去。
            var alts = alternatives.filter { $0.id != route.id }
            if let old, old.id != route.id { alts.insert(old, at: 0) }
            alternatives = Array(alts.prefix(config.maxAlternatives))
        }
        speculative.removeAll()
        requestedSpeculative.removeAll()
        if laneFeed?.routeID != route.id { laneFeed = nil }
        matcher.reset()
        detector.reset()
        pendingRoute = nil

        let latency = reason == .initial ? nil : offRouteSince.map { fix.timestamp.timeIntervalSince($0) }
        offRouteSince = nil
        if reason != .initial { lastRouteChange = fix.timestamp }
        lastTelemetry = nil

        currentMatch = matcher.match(fix, on: route, leadIn: leadIn)
        lastGoodMatch = currentMatch
        detector.update(match: currentMatch, fix: fix)

        let keep = Set([route.id] + alternatives.map(\.id))
        annotations = annotations.filter { keep.contains($0.key) }

        intents.append(.activeRouteChanged(RouteChange(from: old?.id, to: route.id, reason: reason,
                                                       at: fix.timestamp, deviationToNewRoute: latency)))
    }

    // MARK: - 预算路线

    private func planSpeculative(_ route: Route, _ m: RouteMatch, _ fix: LocationFix, _ intents: inout [EngineIntent]) {
        guard pendingRoute == nil, let idx = route.nextManeuverIndex(after: m.offset) else { return }
        let man = route.maneuvers[idx]
        let distance = man.offset - m.offset
        guard man.kind.isHighwayDecision, !requestedSpeculative.contains(idx),
              distance <= config.speculativeLookahead, distance >= config.speculativeMinDistance else { return }

        // 错过 = 沿进入动作点时的方向继续开。分岔（knooppunt）的另一支会拐弯，这里只是近似；
        // 精确做法需要路网（路线图第二阶段）。
        let approach = route.bearing(ofSegment: route.segmentIndex(at: max(0, man.offset - 20)))
        let miss = Geo.destination(from: route.coordinate(at: man.offset), bearing: approach,
                                   distance: config.speculativeMissDistance)
        requestedSpeculative.insert(idx)
        intents.append(.requestRoute(makeRequest(.speculative(maneuverOffset: man.offset, baseRouteID: route.id),
                                                 origin: miss, heading: approach,
                                                 preferences: trip?.preferences ?? RoutingPreferences(), fix)))
    }

    // MARK: - NDW 封路 → 避让

    private func checkBlockingEvents(_ route: Route, _ offset: Double, _ fix: LocationFix, _ trip: TripPlan,
                                     _ intents: inout [EngineIntent]) {
        guard let ann = annotations[route.id] else { return }
        let speed = max(fix.speed ?? 0, 8)
        for re in ann.events where re.event.blocksRoute && re.startOffset > offset
            && re.startOffset - offset <= config.avoidBlockingEventsWithin
            && eventAvoidance[re.event.id] == nil {
            // 开合桥两个方向都封；其他封路必须确认是我们这个方向。
            guard re.directionVerified || re.event.kind == .bridgeOpening else { continue }
            // 开到那里时已经结束了（例如几分钟的开桥）：不绕。
            let arrival = fix.timestamp.addingTimeInterval((re.startOffset - offset) / speed)
            if let end = re.event.end, end < arrival { continue }
            guard let box = BoundingBox(covering: re.event.geometry) else { continue }

            var prefs = trip.preferences
            let area = box.expanded(byMeters: 150)
            prefs.avoidAreas.append(area)
            let req = makeRequest(.avoidEvent(eventID: re.event.id), origin: fix.coordinate,
                                  heading: fix.reliableCourse(minimumSpeed: config.offRoute.minSpeedForHeading),
                                  preferences: prefs, fix)
            eventAvoidance[re.event.id] = EventAvoidance(requestID: req.id, area: area)
            intents.append(.requestRoute(req))
        }
    }

    // MARK: - 延后执行的换路

    private func processDeferred(_ offset: Double, _ fix: LocationFix, _ intents: inout [EngineIntent]) {
        // 注意：中途可能已经换了路线，每次都按当前路线重新算。
        func distanceToNextManeuver() -> Double? {
            guard let r = active, let i = r.nextManeuverIndex(after: offset) else { return nil }
            return r.maneuvers[i].offset - offset
        }
        func distanceSincePreviousManeuver() -> Double? {
            guard let r = active else { return nil }
            let i = r.nextManeuverIndex(after: offset) ?? r.maneuvers.count
            guard let prev = r.maneuvers[..<i].last(where: { $0.kind != .depart }) else { return nil }
            return offset - prev.offset
        }

        // 更新版路线（例如高德在我们切到预算路线后自己重算出的路线）。
        if let routes = pendingRefresh, let primary = routes.first {
            let decision = gate.safePoint(now: fix.timestamp, distanceToNextManeuver: distanceToNextManeuver(),
                                          distanceSincePreviousManeuver: distanceSincePreviousManeuver(),
                                          speed: fix.speed, lastRouteChange: nil,
                                          rerouting: detector.state.isOffRoute)
            if decision == .apply {
                pendingRefresh = nil
                if vehicleFits(primary, fix, maxOffset: .infinity) {
                    adopt(primary, leadIn: 0, reason: .refresh, alternatives: Array(routes.dropFirst()), fix, &intents)
                }
            }
        }

        // NDW 封路避让：路线到了、且此刻是安全点，就换。
        for (id, var state) in eventAvoidance where !state.done {
            guard let routes = state.routes, let primary = routes.first else { continue }
            let decision = gate.safePoint(now: fix.timestamp, distanceToNextManeuver: distanceToNextManeuver(),
                                          distanceSincePreviousManeuver: distanceSincePreviousManeuver(),
                                          speed: fix.speed, lastRouteChange: lastRouteChange,
                                          rerouting: detector.state.isOffRoute)
            guard decision == .apply else { continue }
            state.done = true
            eventAvoidance[id] = state
            // 等安全点期间车可能已经在新路线上开了好几公里：只看横向和方向，不限里程。
            if vehicleFits(primary, fix, maxOffset: .infinity) {
                adopt(primary, leadIn: 0, reason: .avoidEvent, alternatives: Array(routes.dropFirst()), fix, &intents)
            }
        }

        // JEV 建议
        var keep: [PendingAdvice] = []
        for var p in advices {
            let decision = gate.evaluate(p.advice, tripID: trip?.id, now: fix.timestamp,
                                         distanceToNextManeuver: distanceToNextManeuver(),
                                         distanceSincePreviousManeuver: distanceSincePreviousManeuver(), speed: fix.speed,
                                         lastRouteChange: lastRouteChange, rerouting: detector.state.isOffRoute)
            switch decision {
            case .reject(let why):
                intents.append(.adviceResolved(adviceID: p.advice.id, applied: false, note: why))

            case .deferUntilSafe:
                // 还不能换，但路线可以先算着。
                if case .reroute(let prefs) = p.advice.action, p.requestID == nil, !detector.state.isOffRoute {
                    p.requestID = requestStrategyRoute(p.advice, prefs, fix, &intents)
                }
                keep.append(p)

            case .apply:
                switch p.advice.action {
                case .keepCurrent:
                    intents.append(.adviceResolved(adviceID: p.advice.id, applied: true, note: "kept"))
                case .switchToAlternative(let id):
                    guard let alt = alternatives.first(where: { $0.id == id }) else {
                        intents.append(.adviceResolved(adviceID: p.advice.id, applied: false, note: "unknown route"))
                        continue
                    }
                    guard fitsTightly(alt, fix, leadIn: 0) else {
                        intents.append(.adviceResolved(adviceID: p.advice.id, applied: false, note: "passed divergence"))
                        continue
                    }
                    adopt(alt, leadIn: 0, reason: .strategy, alternatives: nil, fix, &intents)
                    noteStrategy(p.advice, fix)
                    intents.append(.adviceResolved(adviceID: p.advice.id, applied: true, note: "switched"))
                case .reroute(let prefs):
                    if p.requestID == nil {
                        p.requestID = requestStrategyRoute(p.advice, prefs, fix, &intents)
                        keep.append(p)
                    } else if let routes = p.routes, let primary = routes.first {
                        if vehicleFits(primary, fix, maxOffset: .infinity) {
                            adopt(primary, leadIn: 0, reason: .strategy, alternatives: Array(routes.dropFirst()), fix, &intents)
                            noteStrategy(p.advice, fix)
                            intents.append(.adviceResolved(adviceID: p.advice.id, applied: true, note: "rerouted"))
                        } else {
                            intents.append(.adviceResolved(adviceID: p.advice.id, applied: false, note: "route no longer reachable"))
                        }
                    } else {
                        keep.append(p)   // 等路线
                    }
                }
            }
        }
        advices = keep
    }

    private func requestStrategyRoute(_ advice: StrategyAdvice, _ prefs: RoutingPreferences, _ fix: LocationFix,
                                      _ intents: inout [EngineIntent]) -> UInt64 {
        let req = makeRequest(.strategy(adviceID: advice.id), origin: fix.coordinate,
                              heading: fix.reliableCourse(minimumSpeed: config.offRoute.minSpeedForHeading),
                              preferences: prefs, fix)
        intents.append(.requestRoute(req))
        return req.id
    }

    private func noteStrategy(_ advice: StrategyAdvice, _ fix: LocationFix) {
        guard !advice.reason.isEmpty else { return }
        strategyNote = (advice.reason, fix.timestamp.addingTimeInterval(config.strategyNoteDuration))
    }

    // MARK: - 画面

    private func buildDisplay(_ fix: LocationFix, _ route: Route, _ offset: Double) -> DriveDisplayState {
        let now = fix.timestamp
        let offRoute = detector.state.isOffRoute
        var d = DriveDisplayState.idle
        d.activeRouteID = route.id
        d.speedKmh = kmh(fix.speed)
        d.gpsDegraded = fix.horizontalAccuracy > config.offRoute.maxUsableAccuracy
        d.remainingDistance = max(0, route.length - offset)
        d.remainingTime = route.remainingTime(from: offset)
        d.eta = now.addingTimeInterval(d.remainingTime)
        if let note = strategyNote, note.until > now { d.strategyNote = note.text }

        if offRoute {
            d.phase = .rerouting(since: offRouteSince ?? now, attempts: pendingRoute?.attempts ?? 0)
            d.rejoin = rejoinHint(route, fix)
            return d   // 偏航时不显示旧路线的动作、车道、限速（都属于另一条路）
        }

        d.phase = .guiding
        let ann = annotations[route.id]
        if let i = route.nextManeuverIndex(after: offset) {
            let man = route.maneuvers[i]
            d.maneuver = maneuverDisplay(man, offset)
            if i + 1 < route.maneuvers.count, route.maneuvers[i + 1].offset - man.offset <= config.thenManeuverGap {
                d.thenManeuver = maneuverDisplay(route.maneuvers[i + 1], offset)
            }
            d.lanes = lanes(route, man, offset, now, ann)
        }
        d.speedLimit = speedLimit(route, offset, now, ann)
        if let limit = d.speedLimit, let v = d.speedKmh {
            d.isSpeeding = v > limit.kmh + config.speedingToleranceKmh
        }
        d.hazard = hazard(offset, now, ann)
        return d
    }

    private func maneuverDisplay(_ m: Maneuver, _ offset: Double) -> ManeuverDisplay {
        let exact = max(0, m.offset - offset)
        return ManeuverDisplay(kind: m.kind, distance: DisplayDistance.round(exact), exactDistance: exact,
                               roadName: m.roadName, exitNumber: m.exitNumber, signpost: m.signpost,
                               roundaboutExit: m.roundaboutExit)
    }

    private func lanes(_ route: Route, _ man: Maneuver, _ offset: Double, _ now: Date,
                       _ ann: RouteAnnotations?) -> LaneGuidance? {
        guard let feed = laneFeed, let guidance = feed.guidance,
              now.timeIntervalSince(feed.receivedAt) <= config.laneFeedMaxAge,
              feed.routeID == nil || feed.routeID == route.id else { return nil }
        if let mo = feed.maneuverOffset, abs(mo - man.offset) > 60 { return nil }
        let rc = man.roadClass ?? route.roadClass(at: man.offset) ?? .unknown
        let range = (rc == .motorway || rc == .expressway) ? config.laneRangeMotorway : config.laneRangeOther
        guard man.offset - offset <= range else { return nil }
        guard let gantry = relevantGantry(offset, now, ann, ahead: config.gantryLookahead) else { return guidance }
        return LaneClosureFusion.apply(gantry.gantry, to: guidance)
    }

    /// 即将驶过的门架（前方 ahead 米内），否则刚驶过的那个（gantryValidity 内）。
    private func relevantGantry(_ offset: Double, _ now: Date, _ ann: RouteAnnotations?, ahead: Double) -> RouteGantry? {
        guard let ann else { return nil }
        let fresh = ann.gantries.filter { now.timeIntervalSince($0.gantry.observedAt) <= config.gantryMaxAge }
        if ahead > 0, let next = fresh.first(where: { $0.offset > offset && $0.offset - offset <= ahead }) {
            return next
        }
        return fresh.last { $0.offset <= offset && offset - $0.offset <= config.gantryValidity }
    }

    private func speedLimit(_ route: Route, _ offset: Double, _ now: Date, _ ann: RouteAnnotations?) -> FusedSpeedLimit? {
        var obs: [SpeedLimitObservation] = []
        if let p = route.providerSpeedLimit(at: offset) {
            obs.append(SpeedLimitObservation(source: .provider, kmh: p, observedAt: route.createdAt, matchConfidence: 0.9))
        }
        if let ann {
            for s in ann.speedLimits where s.start <= offset && offset < s.end {
                obs.append(s.observation)
            }
            // 矩阵牌只认已经驶过的门架：牌面从门架起生效。
            if let g = relevantGantry(offset, now, ann, ahead: 0) {
                for sig in g.gantry.signals where sig.aspect == .speedLimit {
                    guard let k = sig.speedLimit else { continue }
                    obs.append(SpeedLimitObservation(source: .dynamicSign, kmh: k, binding: sig.binding,
                                                     observedAt: g.gantry.observedAt, maxAge: config.gantryMaxAge,
                                                     matchConfidence: 0.8))
                }
            }
        }
        let roadClass = route.roadClass(at: offset)
        if let m = speedMemo, m.roadClass == roadClass, m.observations == obs, now >= m.computedAt,
           now.timeIntervalSince(m.computedAt) < config.speedLimitRecheck {
            return m.result
        }
        let result = fuser.fuse(obs, roadClass: roadClass, now: now)
        speedMemo = SpeedMemo(observations: obs, roadClass: roadClass, result: result, computedAt: now)
        return result
    }

    private func hazard(_ offset: Double, _ now: Date, _ ann: RouteAnnotations?) -> HazardDisplay? {
        guard let ann else { return nil }
        for re in ann.events where re.endOffset >= offset && re.startOffset - offset <= config.hazardHorizon
            && re.event.isActive(at: now) {
            let inside = re.startOffset <= offset
            return HazardDisplay(eventID: re.event.id, kind: re.event.kind, severity: re.event.severity,
                                 distance: inside ? 0 : DisplayDistance.round(re.startOffset - offset),
                                 inside: inside, road: re.event.road, closedLanes: re.event.closedLanes,
                                 text: re.event.text, directionVerified: re.directionVerified)
        }
        return nil
    }

    private func rejoinHint(_ route: Route, _ fix: LocationFix) -> RejoinHint? {
        let from = lastGoodMatch?.offset ?? 0
        var best: (distance: Double, point: Coordinate)?
        var i = route.segmentIndex(at: from) + 1
        while i < route.points.count && route.cumulative[i] <= from + 3000 {
            let d = Geo.distance(fix.coordinate, route.points[i])
            if best == nil || d < best!.distance { best = (d, route.points[i]) }
            i += 1
        }
        return best.map { RejoinHint(distance: DisplayDistance.round($0.distance),
                                     bearing: Geo.bearing(fix.coordinate, $0.point)) }
    }

    private func arrivedDisplay(_ fix: LocationFix) -> DriveDisplayState {
        var d = DriveDisplayState.idle
        d.phase = .arrived
        d.activeRouteID = active?.id
        d.speedKmh = kmh(fix.speed)
        return d
    }

    private func kmh(_ speed: Double?) -> Int? {
        speed.map { Int(($0 * 3.6).rounded()) }
    }

    // MARK: - 给 JEV 的遥测

    private func emitTelemetryIfDue(_ fix: LocationFix, _ display: DriveDisplayState, _ intents: inout [EngineIntent]) {
        guard let trip else { return }
        if let last = lastTelemetry, fix.timestamp.timeIntervalSince(last) < config.telemetryInterval { return }
        lastTelemetry = fix.timestamp

        func summary(_ r: Route) -> TripTelemetry.RouteSummary {
            TripTelemetry.RouteSummary(id: r.id, length: r.length, expectedDuration: r.expectedDuration)
        }
        let phase: String
        switch display.phase {
        case .idle: phase = "idle"
        case .planning: phase = "planning"
        case .guiding: phase = "guiding"
        case .rerouting: phase = "rerouting"
        case .arrived: phase = "arrived"
        }
        let offset = lastGoodMatch?.offset ?? 0
        let ahead = active.flatMap { annotations[$0.id] }?.events
            .filter { $0.endOffset >= offset }.map(\.event.id) ?? []
        intents.append(.telemetry(TripTelemetry(
            tripID: trip.id, at: fix.timestamp, position: fix.coordinate, speedKmh: display.speedKmh, phase: phase,
            activeRoute: active.map(summary), alternatives: alternatives.map(summary),
            remainingDistance: display.remainingDistance, remainingTime: display.remainingTime,
            eventsAhead: Array(ahead.prefix(10)))))
    }
}
