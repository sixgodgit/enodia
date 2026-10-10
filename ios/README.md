# ios/ —— iOS App 层（宿主 + 高德适配 + CarPlay）

> ⚠️ 这里的代码**没有在本仓库 CI 中编译过**：需要 Xcode、iOS SDK 和高德导航 SDK。
> 实时逻辑全在 `Sources/NavCore`（Linux 上有测试），这一层刻意做薄，只负责接线和画图。
> 高德 API 名称按其 iOS 导航 SDK 文档书写，各版本之间有改名，**以你安装的版本头文件为准**；
> 所有高德相关代码集中在 `DutchNav/Amap/` 两个文件里。

```
DutchNav/
├── App/
│   ├── AppEnvironment.swift      读配置、组装 provider 和宿主
│   └── NavigationHost.swift      GPS → engine.process（专用串行队列）；执行 intents；NDW 轮询与注释
├── Amap/
│   ├── AmapRouteProvider.swift   calculateDriveRoute → NavCore.Route（多路线：第一条主路线，其余备选）
│   └── AmapGuidanceBridge.swift  外部定位喂给高德会话；车道回调 → LaneFeed；高德自发重算 → .refresh
├── Places/
│   └── MapKitPlaceProvider.swift Apple 地图 POI，作为地址入口层的一个来源
└── CarPlay/
    ├── CarPlaySceneDelegate.swift
    ├── GuidanceRenderer.swift    DriveDisplayState → CPNavigationSession（只在内容变化时调用）
    ├── CarPlayMapViewController.swift  底图（MAMapView）+ 限速牌 / 车速 / 车道条 / 事件
    └── LaneStripRenderer.swift
```

## 建工程

1. Xcode 新建 iOS App（iOS 16+），把本目录的 `DutchNav/` 拖进工程。
2. **File → Add Package Dependencies → Add Local…** 选本仓库根目录，勾选 `NavCore`、`NavServices`。
3. 高德 SDK（CocoaPods）：
   ```ruby
   platform :ios, '16.0'
   target 'DutchNav' do
     use_frameworks!
     pod 'AMapNavi'      # 含 3D 地图与基础 SDK
   end
   ```
   在高德开放平台创建 iOS key 并绑定 bundle id。高德 SDK 8.x 起使用前必须完成**隐私合规**调用
   （`updatePrivacyShow` / `updatePrivacyAgree`，地图与导航各一组），按所装版本文档加在 `AppEnvironment` 初始化最前面。
4. `Info.plist`：
   - `AMapApiKey`、`NDWRelayURL`（可选）、`OSRMURL`（可选）
   - `NSLocationWhenInUseUsageDescription`、`NSLocationAlwaysAndWhenInUseUsageDescription`
   - `UIBackgroundModes`: `location`, `audio`（以后加语音提示时）
   - CarPlay 场景：
     ```xml
     <key>UIApplicationSceneManifest</key>
     <dict>
       <key>UISceneConfigurations</key>
       <dict>
         <key>CPTemplateApplicationSceneSessionRoleApplication</key>
         <array><dict>
           <key>UISceneConfigurationName</key><string>CarPlay</string>
           <key>UISceneDelegateClassName</key><string>$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate</string>
         </dict></array>
       </dict>
     </dict>
     ```
5. **CarPlay 导航权限** `com.apple.developer.carplay-maps`：要在 developer.apple.com 的 CarPlay 页面申请，
   Apple 批准后才会出现在描述文件里。没有它，App 不会出现在 CarPlay 上（包括 Xcode 的 CarPlay 模拟器）。

## 接线要点

- `NavigationHost` 收到 `CLLocation` 后：先 `amapGuidance.feed`（让高德会话跟着走，才有车道回调），
  再在 `nav.realtime` 串行队列上 `engine.process`。**不要**在主线程调 `process`。
- `RouteProviderRouter`：预算请求只发给能后台计算的 provider（OSRM）。高德导航 SDK 是单例，
  导航中再算一条会顶掉当前路线。
- 引擎切到非高德路线（预算/OSRM）后，高德会话会自己判定偏航并重算；那条结果以 `.refresh` 交回引擎，
  引擎在安全点采纳，之后车道信息恢复。
- 高德在中国大陆以外不做 GCJ-02 偏移；`AmapRouteProvider` 对落在中国境内的坐标直接拒绝。

## 第一次真机要核对的

- [ ] `AmapLaneDecoder` 的编码表：在几个熟悉的路口录下高德回调的原始字符串，和实际车道对比
- [ ] `AMapNaviLocation.speed` 的单位（文档为 km/h）
- [ ] `AmapRouteProvider.maneuverKind`：高速出口在高德里是哪种 `iconType`
- [ ] 高德海外数据的道路等级口径（`roadClass`）
- [ ] 高德是否给出逐段限速；给的话填进 `providerSpeedLimits`，它会自动参与融合
