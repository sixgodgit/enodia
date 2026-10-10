"""车道数（OSM `lanes` 标签）→ 手机端车道定位用的"沿途车道数"。

手机只靠自身传感器判断车道时，必须知道脚下这段路有几条车道（以及从单车道匝道并入的那一刻）。
高德只在路口给车道图，没有沿途车道数；荷兰高速在 OSM 上的 `lanes` 标注很完整（大量导入了官方数据）。

做法：按 0.25° 的瓦片向 Overpass API 查 motorway/trunk（含匝道）上带 `lanes` 的路段，缓存 7 天。
输出的每一段几何按**行驶方向**排列：
- 单行道（高速默认单行）：`lanes` 就是这个方向的车道数；oneway=-1 时几何反转；
- 双向道路：只用 `lanes:forward` / `lanes:backward`（没有就跳过 —— 总车道数无法确定怎么分）。

OSM 数据 © OpenStreetMap contributors，ODbL。

⚠️ 写这段代码的环境访问不到 Overpass，测试用的是按 Overpass `out geom` 格式构造的样例。
"""

from __future__ import annotations

import json
import logging
import math
import os
import threading
import time
import urllib.parse
import urllib.request
from typing import Callable

log = logging.getLogger("ndw_relay")

OVERPASS_URL = os.environ.get("OVERPASS_URL", "https://overpass-api.de/api/interpreter")
TILE = 0.25
TTL_S = 7 * 24 * 3600
MAX_TILES = 200
QUERY = ('[out:json][timeout:60];'
         'way["highway"~"^(motorway|motorway_link|trunk|trunk_link)$"]["lanes"]({s},{w},{n},{e});'
         'out tags geom;')

IMPLIED_ONEWAY = {"motorway", "motorway_link"}


def _lanes(value: str | None) -> int | None:
    """'3' → 3；'2;3'（按时段变化等）→ 取第一个；无效 → None。"""
    if not value:
        return None
    first = value.split(";")[0].strip()
    return int(first) if first.isdigit() and 1 <= int(first) <= 12 else None


def segments_from_overpass(data: dict) -> list[dict]:
    out: list[dict] = []
    for el in data.get("elements", []):
        if el.get("type") != "way" or len(el.get("geometry") or []) < 2:
            continue
        tags = el.get("tags", {})
        geom = [[p["lat"], p["lon"]] for p in el["geometry"]]
        wid = f"osm:way/{el['id']}"
        oneway = tags.get("oneway")
        implied = tags.get("highway") in IMPLIED_ONEWAY or tags.get("junction") == "roundabout"
        if oneway in ("yes", "true", "1") or (implied and oneway not in ("no", "-1")):
            n = _lanes(tags.get("lanes"))
            if n:
                out.append({"id": wid, "geometry": geom, "lanes": n})
        elif oneway == "-1":
            n = _lanes(tags.get("lanes"))
            if n:
                out.append({"id": wid, "geometry": geom[::-1], "lanes": n})
        else:
            f, b = _lanes(tags.get("lanes:forward")), _lanes(tags.get("lanes:backward"))
            if f:
                out.append({"id": wid + ":f", "geometry": geom, "lanes": f})
            if b:
                out.append({"id": wid + ":b", "geometry": geom[::-1], "lanes": b})
    return out


def tiles_for(bbox: tuple[float, float, float, float]) -> list[tuple[int, int]]:
    a, b, c, d = bbox
    rows = range(math.floor(a / TILE), math.floor(c / TILE) + 1)
    cols = range(math.floor(b / TILE), math.floor(d / TILE) + 1)
    return [(r, k) for r in rows for k in cols]


def overpass_fetch(tile: tuple[int, int], user_agent: str = "nyx-nav-relay/0.1 (personal use)") -> dict:
    r, k = tile
    q = QUERY.format(s=r * TILE, w=k * TILE, n=(r + 1) * TILE, e=(k + 1) * TILE)
    req = urllib.request.Request(OVERPASS_URL, data=urllib.parse.urlencode({"data": q}).encode(),
                                 headers={"User-Agent": user_agent})
    with urllib.request.urlopen(req, timeout=90) as resp:
        return json.load(resp)


class LaneService:
    """瓦片缓存。取不到的瓦片：有旧数据就用旧的，没有就跳过并在响应里报告。"""

    def __init__(self, fetch: Callable[[tuple[int, int]], dict] = overpass_fetch,
                 clock: Callable[[], float] = time.time, ttl_s: float = TTL_S) -> None:
        self._fetch = fetch
        self._clock = clock
        self._ttl = ttl_s
        self._tiles: dict[tuple[int, int], tuple[float, list[dict]]] = {}
        self._lock = threading.Lock()

    def query(self, bbox: tuple[float, float, float, float]) -> dict:
        tiles = tiles_for(bbox)
        if len(tiles) > MAX_TILES:
            raise ValueError(f"bbox too large: {len(tiles)} tiles (max {MAX_TILES})")
        segments: dict[str, dict] = {}
        fetched = cached = failed = 0
        for t in tiles:
            with self._lock:
                entry = self._tiles.get(t)
            if entry and self._clock() - entry[0] < self._ttl:
                cached += 1
            else:
                try:
                    entry = (self._clock(), segments_from_overpass(self._fetch(t)))
                    with self._lock:
                        self._tiles[t] = entry
                    fetched += 1
                except Exception as e:  # noqa: BLE001 —— 一个瓦片失败不影响其他瓦片
                    log.warning("lanes tile %s: %s", t, e)
                    failed += 1
                    if not entry:
                        continue
            for seg in entry[1]:
                segments[seg["id"]] = seg   # 跨瓦片的同一条路只出现一次
        return {
            "schema": "lane-counts/v1",
            "segments": sorted(segments.values(), key=lambda s: s["id"]),
            "tiles": {"cached": cached, "fetched": fetched, "failed": failed},
        }
