// ⚠️ 未在本仓库 CI 中编译：需要 iOS SDK（CarPlay）。
//
// DriveDisplayState → CarPlay。只在内容真的变了时才调用 CarPlay API（CarPlay 对频繁刷新很敏感）。

import CarPlay
import MapKit
import NavCore
import NavServices
import UIKit

@MainActor
final class GuidanceRenderer {
    private let mapTemplate: CPMapTemplate
    private weak var overlay: CarPlayMapViewController?
    private var session: CPNavigationSession?
    private var trip: CPTrip?
    private var current: (key: String, maneuver: CPManeuver)?
    private var lastPhase: DriveDisplayState.Phase = .idle
    private var alertedEvents: Set<String> = []

    init(mapTemplate: CPMapTemplate, overlay: CarPlayMapViewController) {
        self.mapTemplate = mapTemplate
        self.overlay = overlay
    }

    func render(_ s: DriveDisplayState) {
        overlay?.apply(s)

        switch s.phase {
        case .idle, .planning:
            return
        case .arrived:
            session?.finishTrip()
            session = nil
            current = nil
        case .rerouting:
            if case .rerouting = lastPhase {} else {
                session?.pauseTrip(for: .rerouting, description: "正在重新规划…")
                current = nil
            }
        case .guiding:
            ensureSession(s)
            updateManeuvers(s)
            updateTripEstimates(s)
            alertIfNeeded(s)
        }
        lastPhase = s.phase
    }

    func end() {
        session?.cancelTrip()
        session = nil
    }

    private func ensureSession(_ s: DriveDisplayState) {
        guard session == nil else { return }
        let destination = MKMapItem(placemark: MKPlacemark(coordinate: AppEnvironment.shared.destinationCoordinate))
        let choice = CPRouteChoice(summaryVariants: ["推荐路线"], additionalInformationVariants: [],
                                   selectionSummaryVariants: [])
        let trip = CPTrip(origin: MKMapItem.forCurrentLocation(), destination: destination, routeChoices: [choice])
        self.trip = trip
        session = mapTemplate.startNavigationSession(for: trip)
    }

    private func updateManeuvers(_ s: DriveDisplayState) {
        guard let session, let m = s.maneuver else { return }
        // 同一个动作（类型+文字+车道图）只建一次 CPManeuver，之后只刷新距离。
        let marked = CarPlayMapViewController.markedLane(s)
        let advice = s.laneChange.map(GuidancePhrasing.laneChange)
        let key = "\(s.activeRouteID?.raw ?? "")|\(m.kind)|\(GuidancePhrasing.instruction(m))|\(s.lanes.map { "\($0)" } ?? "")|\(marked ?? -1)|\(advice ?? "")"
        let estimates = CPTravelEstimates(distanceRemaining: Measurement(value: m.distance, unit: .meters),
                                          timeRemaining: 0)
        if current?.key != key {
            let maneuver = CPManeuver()
            // 需要变道时把提示放在最前面：卡片上第一眼就看到。
            maneuver.instructionVariants = [(advice.map { "\($0) · " } ?? "") + GuidancePhrasing.instruction(m),
                                            GuidancePhrasing.instruction(m)]
            maneuver.symbolImage = ManeuverSymbols.image(for: m.kind)
            maneuver.initialTravelEstimates = estimates
            if let lanes = s.lanes { maneuver.junctionImage = LaneStripRenderer.image(lanes, height: 44, currentLane: marked) }
            var list = [maneuver]
            if let then = s.thenManeuver {
                let next = CPManeuver()
                next.instructionVariants = ["然后" + GuidancePhrasing.instruction(then)]
                next.symbolImage = ManeuverSymbols.image(for: then.kind)
                list.append(next)
            }
            session.upcomingManeuvers = list
            current = (key, maneuver)
        } else if let maneuver = current?.maneuver {
            session.updateEstimates(estimates, for: maneuver)
        }
    }

    private func updateTripEstimates(_ s: DriveDisplayState) {
        guard let trip else { return }
        mapTemplate.update(CPTravelEstimates(distanceRemaining: Measurement(value: s.remainingDistance, unit: .meters),
                                             timeRemaining: s.remainingTime),
                           for: trip, with: s.hazard?.severity == .high ? .orange : .default)
    }

    /// 前方严重事件（事故/封路）弹一次提示，不重复弹。
    private func alertIfNeeded(_ s: DriveDisplayState) {
        guard let h = s.hazard, !alertedEvents.contains(h.eventID),
              h.severity == .high || h.kind == .closure || h.kind == .accident else { return }
        alertedEvents.insert(h.eventID)
        let alert = CPNavigationAlert(titleVariants: [GuidancePhrasing.hazard(h)],
                                      subtitleVariants: h.text.map { [$0] },
                                      image: UIImage(systemName: "exclamationmark.triangle.fill"),
                                      primaryAction: CPAlertAction(title: "知道了", style: .default) { _ in },
                                      secondaryAction: nil, duration: 8)
        mapTemplate.present(navigationAlert: alert, animated: true)
    }
}

enum ManeuverSymbols {
    static func image(for kind: ManeuverKind) -> UIImage? {
        let name: String
        switch kind {
        case .depart: name = "location.north.fill"
        case .straight: name = "arrow.up"
        case .slightLeft, .keepLeft, .exitLeft: name = "arrow.up.left"
        case .left, .sharpLeft: name = "arrow.turn.up.left"
        case .slightRight, .keepRight, .exitRight: name = "arrow.up.right"
        case .right, .sharpRight: name = "arrow.turn.up.right"
        case .uTurn: name = "arrow.uturn.down"
        case .merge: name = "arrow.merge"
        case .roundabout: name = "arrow.triangle.2.circlepath"
        case .ferry: name = "ferry.fill"
        case .waypoint: name = "mappin"
        case .arrive: name = "flag.checkered"
        }
        return UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .bold))
    }
}
