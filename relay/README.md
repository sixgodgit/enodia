# relay/ —— NDW 交通事件中继

只用 Python 标准库（3.10+）。把 NDW（Nationaal Dataportaal Wegverkeer）的开放数据
（整国的 DATEX II gzip XML）变成手机友好的增量 JSON。

**为什么要中继**：施工数据集解压后几十 MB，每分钟在手机上下载、解析既费流量又费电。
中继放在家里的小机器或免费云主机上；手机只按路线区域拿变化的部分。中继挂了，App 照常导航，只是没有事件层。

## 运行

```bash
cd relay
python -m ndw_relay serve --host 0.0.0.0 --port 8787
# NDW 改了文件名时覆盖数据集清单：
NDW_FEEDS="incidents=https://opendata.ndw.nu/incidents.xml.gz@60" python -m ndw_relay serve
```

默认拉取（`ndw_relay/feeds.py`）：incidents（事故，60 s）、actuele_statusberichten（封路/车道关闭，60 s）、
wegwerkzaamheden（施工，300 s，只保留 24 小时内开始的）、brugopeningen（开合桥，60 s）。
请求带 ETag / If-Modified-Since；拉取或解析失败只标记该数据集陈旧，不清空已有数据。

## 接口

```
GET /v1/events?bbox=min_lat,min_lon,max_lat,max_lon[&since=N]   NDW 事件（增量）
GET /v1/lanes?bbox=min_lat,min_lon,max_lat,max_lon              沿途车道数（OSM）
GET /healthz
```

### /v1/lanes

手机端车道定位需要知道每段路有几条车道。中继按 0.25° 瓦片向 Overpass API 查 motorway/trunk（含匝道）上带
`lanes` 标签的路段，缓存 7 天（`OVERPASS_URL` 可换成自建的 Overpass）。几何按行驶方向排列：
高速默认单行；`oneway=-1` 反转；双向道路只用 `lanes:forward` / `lanes:backward`，没有就跳过。
一次最多 200 个瓦片；取不到的瓦片在响应的 `tiles.failed` 里报告。不需要时用 `--no-lanes` 关掉。
形状见 `contracts/lane-counts.v1.example.json`。OSM 数据 © OpenStreetMap contributors（ODbL）。

响应即 `contracts/ndw-events.v1.example.json` 的形状：
- 不带 `since`、`since` 太旧（墓碑已清理）、或比当前版本还大（中继重启过）→ `"full": true` 完整快照；
- 否则 `"full": false`，只给版本号大于 `since` 的事件，和这期间消失的事件 id（`removed`）；
- `feeds` 里每个数据集的新鲜度：三个周期没更新或最近一次出错 → `stale: true`；
- 客户端发 `Accept-Encoding: gzip` 时压缩（iOS 默认会发）。

## 接入真实数据前先做的事

开发这个中继的环境访问不到 opendata.ndw.nu，测试样例是按 DATEX II v2.3 / v3 结构手工构造的。
第一次拿到真实文件时：

```bash
curl -O https://opendata.ndw.nu/incidents.xml.gz
python -m ndw_relay inspect incidents.xml.gz
```

看输出里的 `record_types`（有没有没见过的类型）、`unmapped_types`（被归为 other 的）、
`linear` / `point`（有方向的线性几何占多少 —— 点事件 App 无法区分对向车道）。
需要补的映射都在 `ndw_relay/datex2.py` 开头的几张表里。

## 测试

```bash
python -m pytest relay/tests -q
```
