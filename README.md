# 荷兰个人导航（高德 + NDW + CarPlay）

> 导航实时链路 ≠ AI Agent 链路。
> 实时链路必须毫秒级、永远不等网络；JEV 只负责"该走哪条路"，可以慢、可以挂。

```
                ┌──────────────┐
                │     JEV      │   Strategy/Strategy.swift      StrategyAdvice（带有效期）→ 核心
                │  策略/决策层  │                                核心 → TripTelemetry（30 s 一次）
                └──────┬───────┘
                       │ 非实时 / 异步（收件箱）
┌──────────────────────▼──────────────────────┐
│             Navigation Core  (NavCore)      │   Engine/NavigationEngine.swift
│ GPS → Map Matching → Route → Lane → Reroute │   Matching/  Fusion/  Model/Lanes.swift
│        每个 GPS 点 p50 0.08 ms / p99 0.4 ms   │   （调试构建，2 万点路线，Linux 容器实测）
└──────────────┬──────────────────────────────┘
               │ RouteRequest（意图）/ RouteOffer（结果）
       ┌───────┴────────┐
       ▼                ▼
   Amap SDK          NDW / Traffic                ios/DutchNav/Amap/        relay/（Python 中继）
   路网/导航          交通/事件/限速                Routing/OSRMRouteProvider（可选第二路线源）
       │                │
       └───────┬────────┘
               ▼
          CarPlay UI                              Display/DriveDisplayState.swift → ios/DutchNav/CarPlay/
```

## 核心原则：两条链路之间只有"消息"

`NavigationEngine.process(fix)` 每个 GPS 点同步调用一次，返回 **要显示的画面**（`DriveDisplayState`）
和 **要宿主去做的事**（`EngineIntent`：算路请求、路线变化、给 JEV 的遥测）。它不做 I/O、不 await。

高德算路、NDW 事件、JEV 建议全部是异步结果，只是往引擎的收件箱里放一条消息，
下一个 GPS 点开头一次性取走。所以 **任何外部服务慢或挂掉，都只表现为"某条消息晚到/没到"**，
这一秒的引导永远不会卡住。

```
目录
.
├── Package.swift                 SwiftPM：NavCore + NavServices（只依赖 Foundation，Linux 可测）
├── Sources/NavCore/              实时链路（纯计算）
│   ├── Engine/                   NavigationEngine：收件箱 + 每点主流程 + 重算/预算/安全点
│   ├── Matching/                 路线约束匹配、偏航检测
│   ├── Fusion/                   限速融合、外部数据 → 路线里程投影
│   ├── Model/                    Route、TrafficEvent、车道（含高德车道编码、矩阵牌融合）
│   ├── Strategy/                 JEV 契约 + 安全点闸门
│   └── Display/                  CarPlay 要画的全部内容
├── Sources/NavServices/          异步链路（可以慢）
│   ├── Address/                  地址入口层：本地记忆 + PDOK + 竞速合并
│   ├── Routing/                  RouteProvider 协议、OSRM 路线源
│   ├── Traffic/                  NDW 中继客户端（增量合并）
│   └── Presentation/             中文提示文案
├── Tests/                        78 个测试（场景模拟：错过出口、平行车道、过时结果、封路…）
├── contracts/                    JSON 契约样例：Swift 与 Python 两边的测试读同一份
├── relay/                        NDW 中继（Python 标准库）：DATEX II → 增量 JSON
└── ios/                          iOS App 层：宿主、高德适配、CarPlay（⚠️ 需 Xcode 编译，见 ios/README.md）
```

## 七个问题 → 现在的解法

### ① 高德荷兰地址/POI 慢 → 自己的地址入口层

`PlaceSearch` 让所有来源**同时出发、谁先回来先显示谁**，每个来源有硬超时：

| 来源 | 典型延迟 | 负责什么 |
|---|---|---|
| `LocalPlaceStore` 本地记忆 | < 5 ms | 收藏（"thuis"）、最近去过、选过的结果。个人导航大多数目的地都在这里 |
| `PDOKLocatieserver` 政府地址库 | ~100–300 ms | 荷兰全部地址/邮编/街道（BAG）。免费、无 key，比任何商业地图都准 |
| `MapKitPlaceProvider`（iOS） | ~0.5–1 s | 商家/POI |
| 高德 POI（可选） | 最慢 | 给 1.5 s 硬超时，回不来不影响其他结果 |

`DutchAddressQuery` 识别 **邮编 + 门牌号**（`3511AB 12-bis`）—— 荷兰人最常用、几乎唯一确定地址的输入，
识别出来就走 PDOK 精确查找并排第一。`'s-Gravenhage`/`Den Haag` 等别名互通。
跨来源按"邮编+门牌"或"30 m 内同名"去重。

### ② 高德重新规划慢 → 偏航检测和第一阶段重算不等高德

- **本地偏航检测**（`OffRouteDetector`）：证据累积，不是单点判决。阈值随 GPS 精度伸缩，下限 18 m ——
  专门针对荷兰的 **平行车道（parallelbaan）**：主车道和平行车道只隔 20–40 m，50 m 一刀切的阈值会一直开到
  两条路分开才发现。测试要求平行车道在两路分开后 400 m 内确认（50 m 阈值永远确认不了）；正常行驶 20 组带噪声轨迹、
  城市峡谷（精度 20 m、噪声 12 m）10 组轨迹均零误报。
- **第一阶段重算，零网络等待**：确认偏航的那一刻，依次尝试
  1. **备选路线**：高德多路线结果里的其余路线常驻内存；车正好开在其中一条上就直接切换；
  2. **预算路线**：接近高速出口/分岔（afrit / knooppunt）前 2.5 km，提前请求"错过了怎么走"
     （起点放在出口后 350 m、沿高速方向），错过时立刻切换，车还没到预算路线起点也能接上（lead-in）；
  3. 都没有 → 向路线服务请求，5 秒没回就重发；画面显示"回到原路线"方向箭头。
- **结果校验**：重算结果回来时车已经往前开了，必须"接得上"才采纳；接不上（过时）立刻允许重发；
  司机自己开回原路线了，迟到的结果直接丢掉。
- 高德导航 SDK 是单例，导航中后台算一条预算路线会顶掉当前路线，所以预算请求交给第二个 provider
  （自建 OSRM，荷兰全境 10–50 ms）；没有就不做预算，前两条照样工作。

`RouteChange.deviationToNewRoute` 记录"从第一次偏离迹象到换上新路线"的真实延迟，这是②的核心指标。

### ③ 荷兰限速 → 多来源融合，不盲信一个

`SpeedLimitFuser`，来源按可信度：**矩阵牌（有红圈）> 官方静态（RWS/NDW）> 高德 > 本地缓存 > 道路等级默认值**。

- 来源不一致且把握不足时 **取较低值** 并标记冲突（显示偏高比偏低危险），限速牌画成虚线圈；
- 矩阵牌无红圈 = 建议速度，单独显示，不当限速；
- **2020 年起全国高速 06:00–19:00 最高 100**：任何非矩阵牌来源白天给出 > 100（例如高德不分时段的 130）都压到 100；
- 时段限速按 Europe/Amsterdam 本地时间计算（含夏令时切换、跨午夜、按星期），一小时内的变化提前提示："19:00 起 130"。

### ④ 事故/施工/封路 → NDW 实时事件层

- `relay/`：家里小机器或免费云主机上跑，每分钟拉 NDW 开放数据（DATEX II gzip XML），
  解析成紧凑 JSON，按区域 + 版本号**增量下发**（4G 上每分钟轮询也只是几百字节）。中继挂了 App 照常导航。
- `RouteAnnotator` 在后台把事件投影到路线里程上。**方向是关键**：双向车道中心线只隔几十米，
  线性事件按几何顺序判方向，对向事故不报；点事件判不了方向就标注"方向未确认"。
- 路线前方有确认方向的**封路** → 自动带避让区域请求新路线，在安全点切换；
  **开合桥**两个方向都封，但如果开到时早已合上（几分钟的开桥）就不绕。

### ⑤ 车道级导航 → 直接用高德已有的车道信息

- 高德导航会话照常跑，但定位喂我们自己的 GPS（外部定位），它接近路口时回调车道字符串，
  `AmapLaneDecoder` 解码。不认识的编码画成无箭头车道，**绝不猜方向**。
- 叠加荷兰矩阵牌（MSI）：红叉车道标为关闭，推荐车道被关时改推荐同方向还开着的车道；
  门架车道数与高德车道数不一致时不动（说明包含出口加减速车道，左右对齐是猜）。

### ⑥ JEV → 只负责"该走哪条路"

契约（`contracts/jev-advice.v1.example.json`）：建议是带 `valid_until` 的消息，三种动作：
换到某条备选 / 带约束重新算（避开 A10、环保区 milieuzone…）/ 维持现状。
核心只在**安全点**执行：离下一个动作 ≥ max(600 m, 25 s 车程)、刚过动作点 150 m 外、不在重算中、
距上次换路线 ≥ 90 s。车已经过了分岔点的建议直接拒绝并回执原因（`adviceResolved`）。
JEV 永远碰不到定位、车道、偏航。

### ⑦ CarPlay → 只输出开车时真正要看的

`DriveDisplayState` 是核心唯一的"画面"：下一个动作（取整后的距离，近处 10 m、远处 1 km 一档，不会每秒跳）、
紧接着的动作（只在两个动作挨得很近时）、车道条、融合后的限速 + 时段提示、当前车速/超速、
前方最近事件、剩余里程/ETA；偏航时只显示"回到原路线"方向，不显示属于另一条路的旧动作。
`ios/DutchNav/CarPlay/` 只负责画：系统模板放转向卡片，自绘叠加层放限速牌、车道条、事件。

## 哪些验证过、哪些没有

| 部分 | 状态 |
|---|---|
| NavCore / NavServices | ✅ Linux 上 78 个测试；严格并发检查零警告；改坏关键逻辑（偏航阈值、白天限速规则）测试会失败 |
| relay（Python） | ✅ 12 个测试，Python 3.10 和 3.13；HTTP 输出与 Swift 契约做了字段比对 |
| NDW 真实数据 | ⚠️ 开发环境访问不到 opendata.ndw.nu，DATEX II 样例按结构手工构造。接入后先跑 `python -m ndw_relay inspect` |
| PDOK 真实响应 | ⚠️ 同上，按 v3_1 文档格式写的 |
| ios/（高德、CarPlay） | ⚠️ 没有 iOS SDK 无法编译。高德 API 名按文档写，各版本有改名，以所装版本为准 |
| 高德车道编码表 | ⚠️ 按文档整理，需真机核对（不认识的编码已安全降级） |
| DATEX II 车道编号左右约定 | ⚠️ 未核实，所以事件车道只显示"第 N 车道"，不叠加到车道图 |

## 前置条件和风险

1. **CarPlay 导航权限**：`com.apple.developer.carplay-maps` 需向 Apple 申请批准，否则 CarPlay 上不会出现。
2. **高德海外**：高德在荷兰的路网/车道覆盖和 SDK 海外能力需要真机确认；核心不依赖高德（`RouteProvider` 可替换）。
3. **NDW 文件名**：NDW 偶尔改名或换 DATEX 版本，中继可以用 `NDW_FEEDS` 环境变量覆盖。

## 路线图

- **下一步（真机）**：Xcode 工程跑通 → 高德车道编码表真机核对 → NDW 真实数据 inspect → 在车上记录 GPS 轨迹做回放测试
- **限速数据**：中继加 RWS 道路特征库（WKD）最高限速 + NDW 交通标志库 → `/v1/speed-limits`；本地缓存来源（开过就记住）
- **矩阵牌**：中继解析 NDW Matrixsignaalinformatie → `SignalGantry`（核心的融合逻辑已就绪）
- **第二阶段重算**：本机路网（NWB/OSM 走廊）上的 A*，真正做到偏航后毫秒出新路线，并精确知道分岔的另一支
- **JEV**：接入 Nyx 记忆（例如记住"周五 17 点避开 A12"这类偏好）—— 在 JEV 侧做，核心不变

## 运行测试

```bash
# Swift（需要 Swift 5.9+；没有本地工具链可以用官方镜像）
docker run --rm -v "$PWD":/src -w /src swift:6.1-noble swift test

# 中继
python -m pytest relay/tests -q
```
