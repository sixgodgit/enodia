// swift-tools-version:5.9
//
// 荷兰个人导航 —— 实时导航核心（NavCore）+ 异步服务层（NavServices）
//
// 两个库都只依赖 Foundation，Linux 上可编译、可测试（CI 用官方 swift 镜像跑）。
// 高德 SDK 与 CarPlay 只在 iOS App 里出现（见 ios/），不进这个包：
// 实时链路的逻辑必须能脱离手机和网络单独验证。

import PackageDescription

let package = Package(
    name: "DutchNav",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "NavCore", targets: ["NavCore"]),
        .library(name: "NavServices", targets: ["NavServices"]),
    ],
    targets: [
        // 实时链路：GPS → 匹配 → 路线进度 → 车道 → 偏航/重算。纯计算，不做 I/O，不 await。
        .target(name: "NavCore"),
        // 异步链路：地址入口、NDW 中继客户端。可以慢，但永远不阻塞 NavCore。
        .target(name: "NavServices", dependencies: ["NavCore"]),
        // 契约样例（contracts/*.json）由测试按源码路径直接读取：
        // Swift 与 Python 中继读同一份文件，任何一边改了字段都会在测试里炸。
        .testTarget(name: "NavCoreTests", dependencies: ["NavCore"]),
        .testTarget(name: "NavServicesTests", dependencies: ["NavServices", "NavCore"]),
    ]
)
