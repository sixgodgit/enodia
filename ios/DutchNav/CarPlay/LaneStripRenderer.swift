// ⚠️ 未在本仓库 CI 中编译：需要 iOS SDK（UIKit）。
//
// LaneGuidance → 一张车道条图片（用于 CPManeuver.junctionImage 和底图顶部）。
// 推荐车道：白色箭头、高亮推荐方向；其他车道：灰色；红叉关闭的车道：红色 ✕。
// 估计出当前车道时，在那条车道底部画一个车标（只在把握足够、且车道数对得上时由调用方传入）。

import NavCore
import UIKit

enum LaneStripRenderer {
    static func image(_ g: LaneGuidance, height: CGFloat, currentLane: Int? = nil) -> UIImage {
        let laneWidth = height * 0.8
        let size = CGSize(width: laneWidth * CGFloat(g.lanes.count), height: height)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.black.withAlphaComponent(0.75).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6).fill()
            for (i, lane) in g.lanes.enumerated() {
                let cell = CGRect(x: CGFloat(i) * laneWidth, y: 0, width: laneWidth, height: height)
                if i > 0 {   // 车道分隔线
                    UIColor.white.withAlphaComponent(0.4).setFill()
                    ctx.fill(CGRect(x: cell.minX - 0.5, y: height * 0.15, width: 1, height: height * 0.7))
                }
                draw(lane, in: cell.insetBy(dx: laneWidth * 0.15, dy: height * 0.15))
                if i == currentLane {
                    UIColor.systemBlue.setFill()
                    UIBezierPath(roundedRect: CGRect(x: cell.minX + laneWidth * 0.2, y: height - 5,
                                                     width: laneWidth * 0.6, height: 4), cornerRadius: 2).fill()
                }
            }
        }
    }

    private static func draw(_ lane: Lane, in rect: CGRect) {
        if lane.status == .closed {
            symbol("xmark", .systemRed, rect)
            return
        }
        let dirs = lane.directions.filter { $0 != .unknown }
        guard !dirs.isEmpty else { return }   // 不认识的箭头：空车道，绝不猜
        for d in dirs {
            let highlighted = lane.recommended && (lane.preferred == nil || lane.preferred == d)
            symbol(name(for: d), highlighted ? .white : UIColor.white.withAlphaComponent(0.3), rect)
        }
    }

    private static func symbol(_ name: String, _ color: UIColor, _ rect: CGRect) {
        let config = UIImage.SymbolConfiguration(pointSize: rect.height, weight: .bold)
        guard let img = UIImage(systemName: name, withConfiguration: config)?
            .withTintColor(color, renderingMode: .alwaysOriginal) else { return }
        let scale = min(rect.width / img.size.width, rect.height / img.size.height)
        let s = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        img.draw(in: CGRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
    }

    private static func name(for d: LaneDirection) -> String {
        switch d {
        case .straight: return "arrow.up"
        case .slightLeft: return "arrow.up.left"
        case .left, .sharpLeft: return "arrow.turn.up.left"
        case .slightRight: return "arrow.up.right"
        case .right, .sharpRight: return "arrow.turn.up.right"
        case .uTurnLeft: return "arrow.uturn.down"
        case .uTurnRight: return "arrow.uturn.down"
        case .unknown: return "questionmark"
        }
    }
}
