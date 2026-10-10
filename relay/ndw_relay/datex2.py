"""DATEX II 情况发布（SituationPublication）→ 中继 v1 事件。

NDW 的开放数据是 DATEX II XML（gzip）。不同数据集用的版本不同（v2.3 和 v3 都有），
而且同一种信息在两个版本里的元素名不一样。这里的做法是**忽略命名空间、按本地元素名取值**，
两个版本走同一套逻辑；认不出的类型归为 other，而不是丢掉或报错。

几何是最关键的字段：
- v3 的 gmlLineString/posList 给的是整条线（首选）；
- v2 的 NDW 扩展 linearCoordinatesStartPoint/EndPoint 给起止点；
- 都没有时退回 locationForDisplay / coordinatesForDisplay 单点。
线性几何的顶点顺序就是行驶方向 —— App 靠它区分对向车道，所以绝不重排。

⚠️ 写这段代码的环境访问不到 opendata.ndw.nu，测试样例是按 DATEX II 结构手工构造的。
   接入真实数据时先跑 `python -m ndw_relay inspect <下载的 .xml.gz>`，看类型分布和几何覆盖率。
"""

from __future__ import annotations

import gzip
import io
import re
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from typing import IO, Iterable, Iterator

XSI_TYPE = "{http://www.w3.org/2001/XMLSchema-instance}type"

# 记录类型（xsi:type，去掉前缀）→ 事件类型
RECORD_KIND = {
    "Accident": "accident",
    "VehicleObstruction": "hazard",
    "AnimalPresenceObstruction": "hazard",
    "GeneralObstruction": "hazard",
    "EnvironmentalObstruction": "hazard",
    "InfrastructureDamageObstruction": "hazard",
    "NonWeatherRelatedRoadConditions": "hazard",
    "PoorEnvironmentConditions": "weather",
    "WeatherRelatedRoadConditions": "weather",
    "MaintenanceWorks": "roadworks",
    "ConstructionWorks": "roadworks",
    "Roadworks": "roadworks",
    "AbnormalTraffic": "congestion",
}

# RoadOrCarriagewayOrLaneManagement 的具体类型
CLOSURE_TYPES = {"roadClosed", "carriagewayClosures"}
LANE_TYPES = {"laneClosures", "narrowLanes", "singleAlternateLineTraffic", "contraflow", "hardShoulderRunningNotAvailable"}

SEVERITY = {"highest": "high", "high": "high", "medium": "medium", "low": "low", "lowest": "low", "none": "low"}

_POSLIST_SPLIT = re.compile(r"[\s,]+")


def local(tag: str) -> str:
    """'{ns}name' → 'name'"""
    return tag.rsplit("}", 1)[-1]


def parse_time(text: str | None) -> datetime | None:
    """ISO-8601 → aware datetime（Python 3.10 的 fromisoformat 不认 'Z' 和非 3/6 位小数秒）。"""
    if not text:
        return None
    s = text.strip().replace("Z", "+00:00")
    m = re.match(r"^(.*?T\d{2}:\d{2}:\d{2})(\.\d+)?(.*)$", s)
    if m:
        frac = (m.group(2) or "")[1:7]
        s = m.group(1) + ("." + frac.ljust(6, "0") if frac else "") + m.group(3)
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def format_time(dt: datetime | None) -> str | None:
    if dt is None:
        return None
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _children(el: ET.Element, name: str) -> Iterator[ET.Element]:
    return (c for c in el if local(c.tag) == name)


def _first(el: ET.Element, name: str) -> ET.Element | None:
    for d in el.iter():
        if local(d.tag) == name:
            return d
    return None


def _first_text(el: ET.Element, name: str) -> str | None:
    d = _first(el, name)
    return d.text.strip() if d is not None and d.text and d.text.strip() else None


def _latlon(el: ET.Element) -> tuple[float, float] | None:
    lat = lon = None
    for c in el:
        n = local(c.tag)
        if n == "latitude" and c.text:
            lat = float(c.text)
        elif n == "longitude" and c.text:
            lon = float(c.text)
    if lat is None or lon is None or not (-90 <= lat <= 90 and -180 <= lon <= 180):
        return None
    return (lat, lon)


DISPLAY_ELEMENTS = {"locationForDisplay", "coordinatesForDisplay"}


def geometry(record: ET.Element) -> list[list[float]]:
    """按行驶方向排列的 [[lat, lon], ...]。"""
    # 1. v3 gmlLineString：DATEX II 里 posList 是"纬度 经度"成对排列。
    for d in record.iter():
        if local(d.tag) == "posList" and d.text:
            nums = [float(x) for x in _POSLIST_SPLIT.split(d.text.strip()) if x]
            pts = [[nums[i], nums[i + 1]] for i in range(0, len(nums) - 1, 2)]
            if pts:
                return _dedupe(pts)

    # 2. 所有"带经纬度子元素"的元素（不含显示用的点），文档顺序即起点 → 终点。
    display: list[list[float]] = []
    points: list[list[float]] = []

    def walk(el: ET.Element, in_display: bool) -> None:
        for c in el:
            name = local(c.tag)
            ll = _latlon(c)
            if ll is not None:
                (display if in_display or name in DISPLAY_ELEMENTS else points).append([ll[0], ll[1]])
            else:
                walk(c, in_display or name in DISPLAY_ELEMENTS)

    walk(record, False)
    if points:
        return _dedupe(points)
    return display[:1]


def _dedupe(pts: list[list[float]]) -> list[list[float]]:
    out: list[list[float]] = []
    for p in pts:
        if not out or out[-1] != p:
            out.append(p)
    return out


def _comment(record: ET.Element) -> str | None:
    best = None
    for d in record.iter():
        if local(d.tag) != "generalPublicComment":
            continue
        for v in d.iter():
            if local(v.tag) == "value" and v.text and v.text.strip():
                lang = v.get("lang") or v.get("{http://www.w3.org/XML/1998/namespace}lang")
                if lang == "nl":
                    return v.text.strip()
                best = best or v.text.strip()
    return best


def kind_of(record: ET.Element, rtype: str) -> str:
    texts = {d.text.strip() for d in record.iter() if d.text and local(d.tag) in {
        "roadOrCarriagewayOrLaneManagementType", "generalNetworkManagementType", "roadMaintenanceType"}}
    if any("bridge" in t.lower() for t in texts):
        return "bridge_opening"
    if texts & CLOSURE_TYPES:
        return "closure"
    if rtype == "RoadOrCarriagewayOrLaneManagement":
        return "lane_closure" if texts & LANE_TYPES else "other"
    return RECORD_KIND.get(rtype, "other")


def parse_record(record: ET.Element, situation: ET.Element, source: str) -> dict | None:
    rid = record.get("id")
    if not rid:
        return None
    status = _first_text(record, "validityStatus")
    if status == "suspended":
        return None
    geom = geometry(record)
    if not geom:
        return None
    rtype = (record.get(XSI_TYPE) or "").rsplit(":", 1)[-1]

    sev = _first_text(record, "severity") or _first_text(situation, "overallSeverity")
    # v2：<lane>lane1</lane>；v3：<lane><laneNumber>1</laneNumber>…</lane>
    lanes = []
    for d in record.iter():
        name = local(d.tag)
        if name == "lane" and d.text and d.text.strip():
            lanes.append(d.text.strip())
        elif name == "laneNumber" and d.text and d.text.strip().isdigit():
            lanes.append("lane" + d.text.strip())
    restricted = _first_text(record, "numberOfLanesRestricted")
    updated = (_first_text(record, "situationRecordVersionTime")
               or _first_text(situation, "situationVersionTime"))
    road = _first_text(record, "roadNumber")

    return {
        "id": rid,
        "kind": kind_of(record, rtype),
        "severity": SEVERITY.get(sev or "", "unknown"),
        "road": road.replace(" ", "").upper() if road else None,
        "geometry": geom,
        "closed_lanes": list(dict.fromkeys(lanes)),
        "lanes_restricted": int(restricted) if restricted and restricted.isdigit() else None,
        "start": format_time(parse_time(_first_text(record, "overallStartTime"))),
        "end": format_time(parse_time(_first_text(record, "overallEndTime"))),
        "updated": format_time(parse_time(updated)),
        "text": _comment(record),
        "source": source,
        "record_type": rtype or None,
    }


def _open(stream: IO[bytes]) -> IO[bytes]:
    """按魔数判断是否 gzip，不把整个文件读进内存（施工数据集解压后几十 MB）。"""
    buf = stream if hasattr(stream, "peek") else io.BufferedReader(stream)  # type: ignore[arg-type]
    if buf.peek(2)[:2] == b"\x1f\x8b":
        return gzip.GzipFile(fileobj=buf)
    return buf


def parse(stream: IO[bytes] | bytes, source: str) -> Iterator[dict]:
    """流式解析一个 DATEX II 文件（可 gzip）。逐个 situation 产出、随即释放内存。"""
    if isinstance(stream, (bytes, bytearray)):
        stream = io.BytesIO(stream)
    for _, el in ET.iterparse(_open(stream), events=("end",)):
        if local(el.tag) != "situation":
            continue
        for rec in _children(el, "situationRecord"):
            ev = parse_record(rec, el, source)
            if ev is not None:
                yield ev
        el.clear()


def public(event: dict) -> dict:
    """去掉内部字段，得到契约里的事件对象。"""
    return {k: v for k, v in event.items() if k != "record_type"}


def summarize(events: Iterable[dict]) -> dict:
    """给 inspect 用：类型分布、几何覆盖情况。"""
    by_type: dict[str, int] = {}
    by_kind: dict[str, int] = {}
    linear = point = 0
    unmapped: dict[str, int] = {}
    total = 0
    for e in events:
        total += 1
        rt = e.get("record_type") or "?"
        by_type[rt] = by_type.get(rt, 0) + 1
        by_kind[e["kind"]] = by_kind.get(e["kind"], 0) + 1
        if len(e["geometry"]) >= 2:
            linear += 1
        else:
            point += 1
        if e["kind"] == "other":
            unmapped[rt] = unmapped.get(rt, 0) + 1
    return {"total": total, "linear": linear, "point": point,
            "record_types": by_type, "kinds": by_kind, "unmapped_types": unmapped}
