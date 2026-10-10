// ⚠️ 未在本仓库 CI 中编译：需要 iOS SDK（CarPlay）。
//    CarPlay 导航类 App 需要 Apple 批准的 com.apple.developer.carplay-maps 权限，见 ios/README.md。
//
// CarPlay 只做两件事：
//   1. 系统模板（CPMapTemplate + CPNavigationSession）显示转向卡片、距离、ETA —— 这是 CarPlay 规定的方式；
//   2. 我们自己的底图视图上叠加系统模板不提供的东西：限速牌、当前车速、车道条、前方事件。
// 所有判断都在 NavCore 里做完了，这里只把 DriveDisplayState 画出来。

import CarPlay
import MapKit
import NavCore
import UIKit

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var window: CPWindow?
    private var renderer: GuidanceRenderer?
    private let mapViewController = CarPlayMapViewController()

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController, to window: CPWindow) {
        self.interfaceController = interfaceController
        self.window = window
        window.rootViewController = mapViewController

        let mapTemplate = CPMapTemplate()
        mapTemplate.automaticallyHidesNavigationBar = true
        interfaceController.setRootTemplate(mapTemplate, animated: false, completion: nil)

        let renderer = GuidanceRenderer(mapTemplate: mapTemplate, overlay: mapViewController)
        self.renderer = renderer
        AppEnvironment.shared.host.onDisplay = { state in renderer.render(state) }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnect interfaceController: CPInterfaceController, from window: CPWindow) {
        AppEnvironment.shared.host.onDisplay = nil
        renderer?.end()
        renderer = nil
        self.interfaceController = nil
        self.window = nil
    }
}
