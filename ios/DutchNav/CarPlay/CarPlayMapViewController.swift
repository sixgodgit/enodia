// ⚠️ 未在本仓库 CI 中编译：需要 iOS SDK + 高德地图 SDK（MAMapView）。
//
// CarPlay 窗口的底图 + 叠加层。叠加层只放系统模板没有的、开车时真正要看的东西：
//   左下：限速牌（荷兰样式：白底红圈黑字）+ 时段提示（"19:00 起 130"）+ 当前车速（超速变红）
//   顶部：车道条（推荐车道白色、其余灰色、红叉车道红色）
//   底部：前方事件一行字

import AMapNaviKit
import NavCore
import NavServices
import UIKit

final class CarPlayMapViewController: UIViewController {
    private let mapView = MAMapView()
    private let speedSign = SpeedLimitSignView()
    private let speedLabel = UILabel()
    private let limitNote = UILabel()
    private let laneStrip = UIImageView()
    private let hazardLabel = PaddedLabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        mapView.frame = view.bounds
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .followWithHeading
        view.addSubview(mapView)

        for v in [speedSign, speedLabel, limitNote, laneStrip, hazardLabel] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        speedLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .bold)
        limitNote.font = .systemFont(ofSize: 12, weight: .semibold)
        limitNote.textColor = .label
        laneStrip.contentMode = .scaleAspectFit
        hazardLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        hazardLabel.textColor = .white
        hazardLabel.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.9)
        hazardLabel.layer.cornerRadius = 8
        hazardLabel.clipsToBounds = true

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            speedSign.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            speedSign.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),
            speedSign.widthAnchor.constraint(equalToConstant: 56),
            speedSign.heightAnchor.constraint(equalToConstant: 56),
            limitNote.leadingAnchor.constraint(equalTo: speedSign.leadingAnchor),
            limitNote.bottomAnchor.constraint(equalTo: speedSign.topAnchor, constant: -4),
            speedLabel.leadingAnchor.constraint(equalTo: speedSign.trailingAnchor, constant: 8),
            speedLabel.centerYAnchor.constraint(equalTo: speedSign.centerYAnchor),
            laneStrip.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            laneStrip.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            laneStrip.heightAnchor.constraint(equalToConstant: 44),
            hazardLabel.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            hazardLabel.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),
            hazardLabel.widthAnchor.constraint(lessThanOrEqualTo: safe.widthAnchor, multiplier: 0.6),
        ])
    }

    func apply(_ s: DriveDisplayState) {
        speedSign.limit = s.speedLimit
        speedSign.isHidden = s.speedLimit == nil
        limitNote.text = s.speedLimit.flatMap { GuidancePhrasing.upcomingLimit($0) }
        speedLabel.text = s.speedKmh.map(String.init)
        speedLabel.textColor = s.isSpeeding ? .systemRed : .label
        laneStrip.image = s.lanes.map { LaneStripRenderer.image($0, height: 44) }
        laneStrip.isHidden = s.lanes == nil
        hazardLabel.text = s.hazard.map(GuidancePhrasing.hazard) ?? s.strategyNote
        hazardLabel.isHidden = hazardLabel.text == nil
    }
}

/// 荷兰限速牌：白底、红圈、黑字。把握低 → 灰圈；来源冲突 → 虚线圈（提醒"以路牌为准"）。
final class SpeedLimitSignView: UIView {
    var limit: FusedSpeedLimit? { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let limit else { return }
        let ring = bounds.width * 0.12
        let circle = UIBezierPath(ovalIn: bounds.insetBy(dx: ring / 2, dy: ring / 2))
        UIColor.white.setFill()
        circle.fill()
        (limit.confidence == .low ? UIColor.systemGray : UIColor.systemRed).setStroke()
        circle.lineWidth = ring
        if limit.conflict { circle.setLineDash([6, 4], count: 2, phase: 0) }
        circle.stroke()
        let text = "\(limit.kmh)" as NSString
        let font = UIFont.systemFont(ofSize: bounds.width * (limit.kmh >= 100 ? 0.36 : 0.44), weight: .heavy)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
    }
}

final class PaddedLabel: UILabel {
    override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 10, dy: 6)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + 20, height: s.height + 12)
    }
}
