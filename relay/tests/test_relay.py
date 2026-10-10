from __future__ import annotations

import gzip
import io
import json
import sys
import threading
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from ndw_relay import datex2  # noqa: E402
from ndw_relay.__main__ import main  # noqa: E402
from ndw_relay.feeds import feeds_from_env  # noqa: E402
from ndw_relay.server import make_server, parse_bbox  # noqa: E402
from ndw_relay.store import EventStore  # noqa: E402

FIXTURES = Path(__file__).parent / "fixtures"
CONTRACT = Path(__file__).resolve().parents[2] / "contracts" / "ndw-events.v1.example.json"
NOW = datetime(2026, 10, 12, 8, 0, 30, tzinfo=timezone.utc)


def load(name: str) -> list[dict]:
    with open(FIXTURES / name, "rb") as f:
        return list(datex2.parse(f, source="ndw:test"))


# ---------------------------------------------------------------- DATEX II


def test_v2_records_mapped():
    events = {e["id"]: e for e in load("situation_v2.xml")}
    assert set(events) == {"RWS03_900123_1", "NLRWS_WW_1_works", "NLRWS_WW_1_closure", "SPITS_1_a",
                           "BRUG_0451_1", "NEW_1"}, "suspended and geometry-less records are dropped"

    acc = events["RWS03_900123_1"]
    assert acc["kind"] == "accident"
    assert acc["severity"] == "high"
    assert acc["road"] == "A12"
    # 线性：起点 → 终点（行驶方向），显示用的点不混进几何。
    assert acc["geometry"] == [[52.0901, 5.0512], [52.0902, 5.0631]]
    assert acc["closed_lanes"] == ["lane1", "lane2"]
    assert acc["lanes_restricted"] == 2
    assert acc["start"] == "2026-10-12T07:41:00Z"
    assert acc["end"] is None
    assert acc["updated"] == "2026-10-12T07:58:12Z", "fractional seconds tolerated"
    assert acc["text"] == "Ongeval op de A12, 2 rijstroken dicht", "Dutch comment preferred"

    assert events["NLRWS_WW_1_works"]["kind"] == "roadworks"
    assert events["NLRWS_WW_1_closure"]["kind"] == "closure"
    assert events["SPITS_1_a"]["kind"] == "lane_closure"
    assert events["SPITS_1_a"]["closed_lanes"] == ["rushHourLane"]
    assert events["SPITS_1_a"]["geometry"] == [[52.1, 4.6]], "point falls back to locationForDisplay"
    assert events["BRUG_0451_1"]["kind"] == "bridge_opening"
    assert events["NEW_1"]["kind"] == "other", "unknown record types degrade, not crash"


def test_v3_records_mapped():
    events = {e["id"]: e for e in load("situation_v3.xml")}
    works = events["NDW_V3_77_1"]
    assert works["kind"] == "roadworks"
    assert works["severity"] == "low", "falls back to the situation's overallSeverity"
    assert works["road"] == "N201"
    assert works["geometry"] == [[52.231, 4.81], [52.2305, 4.815], [52.23, 4.825]], "posList is lat lon, deduped"
    assert works["closed_lanes"] == ["lane2"]
    assert works["start"] == "2026-10-12T04:00:00Z"
    assert works["end"] == "2026-10-12T16:00:00Z"
    assert works["text"].startswith("Werkzaamheden N201")
    assert events["NDW_V3_77_2"]["kind"] == "hazard"
    assert events["NDW_V3_77_2"]["geometry"] == [[52.21, 4.8]]


def test_gzip_input_and_inspect(tmp_path, capsys):
    raw = (FIXTURES / "situation_v2.xml").read_bytes()
    gz = tmp_path / "incidents.xml.gz"
    gz.write_bytes(gzip.compress(raw))
    assert len(list(datex2.parse(io.BytesIO(gzip.compress(raw)), "x"))) == 6
    assert main(["inspect", str(gz)]) == 0
    report = json.loads(capsys.readouterr().out)
    assert report["total"] == 6
    assert report["linear"] == 3
    assert report["unmapped_types"] == {"SomethingIntroducedLater": 1}
    assert "record_type" not in report["examples"][0]


def test_parse_time_variants():
    assert datex2.format_time(datex2.parse_time("2026-10-12T07:58:12.1Z")) == "2026-10-12T07:58:12Z"
    assert datex2.format_time(datex2.parse_time("2026-10-12T09:58:12.123456789+02:00")) == "2026-10-12T07:58:12Z"
    assert datex2.format_time(datex2.parse_time("2026-10-12T07:58:12")) == "2026-10-12T07:58:12Z"
    assert datex2.parse_time("not a date") is None
    assert datex2.parse_time(None) is None


# ---------------------------------------------------------------- store


def ev(i: str, lat: float = 52.09, lon: float = 5.1, **kw) -> dict:
    base = {"id": i, "kind": "accident", "severity": "high", "road": "A12", "geometry": [[lat, lon]],
            "closed_lanes": [], "lanes_restricted": None, "start": None, "end": None, "updated": None,
            "text": None, "source": "ndw:test"}
    base.update(kw)
    return base


def test_store_versions_only_bump_on_change():
    s = EventStore()
    assert s.replace_feed("incidents", [ev("a"), ev("b")], NOW) == 2
    v1 = s.version
    assert s.replace_feed("incidents", [ev("a"), ev("b")], NOW) == 0
    assert s.version == v1, "identical snapshot = no new version"
    s.replace_feed("incidents", [ev("a", text="update"), ev("c")], NOW)
    page = s.query(None, since=v1, now=NOW)
    assert not page["full"]
    assert [e["id"] for e in page["events"]] == ["a", "c"]
    assert page["removed"] == ["b"]


def test_store_feeds_are_independent():
    s = EventStore()
    s.replace_feed("incidents", [ev("a")], NOW)
    s.replace_feed("roadworks", [ev("w")], NOW)
    s.replace_feed("incidents", [], NOW)
    ids = [e["id"] for e in s.query(None, None, NOW)["events"]]
    assert ids == ["w"], "emptying one feed must not delete another feed's events"


def test_store_bbox_and_time_filters():
    s = EventStore()
    s.replace_feed("roadworks", [
        ev("utrecht", 52.09, 5.12),
        ev("groningen", 53.22, 6.57),
        ev("ended", end="2026-10-12T07:00:00Z"),
        ev("next-week", start="2026-10-19T07:00:00Z"),
        ev("tonight", start="2026-10-12T20:00:00Z"),
    ], NOW)
    page = s.query(parse_bbox("51.9,4.9,52.2,5.3"), None, NOW)
    assert page["full"]
    assert [e["id"] for e in page["events"]] == ["tonight", "utrecht"]


def test_store_stale_and_restart_semantics():
    s = EventStore()
    s.register_feed("incidents", 60)
    s.replace_feed("incidents", [ev("a")], NOW)
    assert s.query(None, None, NOW)["feeds"]["incidents"]["stale"] is False
    later = NOW + timedelta(minutes=5)
    assert s.query(None, None, later)["feeds"]["incidents"]["stale"] is True
    s.mark_unchanged("incidents", later)
    assert s.query(None, None, later)["feeds"]["incidents"]["stale"] is False
    s.mark_error("incidents", "HTTP 503")
    assert s.query(None, None, later)["feeds"]["incidents"]["stale"] is True
    # 客户端的 since 比中继当前版本还大（中继重启过）：给完整快照。
    assert s.query(None, since=999, now=NOW)["full"] is True


def test_store_old_since_gets_full_snapshot():
    s = EventStore(tombstone_versions=2)
    for k in range(5):
        s.replace_feed("incidents", [ev(f"e{k}")], NOW)
    assert s.query(None, since=1, now=NOW)["full"] is True
    delta = s.query(None, since=s.version - 1, now=NOW)
    assert delta["full"] is False and delta["removed"] == ["e3"]


def test_feeds_env_override():
    feeds = feeds_from_env("incidents=https://example/x.xml.gz@30,bridges=https://example/b.xml.gz@60")
    assert [(f.name, f.url, f.interval_s) for f in feeds] == [
        ("incidents", "https://example/x.xml.gz", 30.0), ("bridges", "https://example/b.xml.gz", 60.0)]
    assert len(feeds_from_env("")) == 4


# ---------------------------------------------------------------- HTTP + 契约


@pytest.fixture()
def server():
    store = EventStore(clock=lambda: NOW)
    store.register_feed("incidents", 60)
    store.replace_feed("incidents", load("situation_v2.xml"))
    srv = make_server(store, "127.0.0.1", 0)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    yield store, f"http://127.0.0.1:{srv.server_address[1]}"
    srv.shutdown()


def get(url: str, gzip_ok: bool = False):
    req = urllib.request.Request(url, headers={"Accept-Encoding": "gzip"} if gzip_ok else {})
    with urllib.request.urlopen(req) as r:
        body = r.read()
        if r.headers.get("Content-Encoding") == "gzip":
            body = gzip.decompress(body)
        return r.status, json.loads(body)


def test_http_events_match_contract(server):
    _, base = server
    status, page = get(base + "/v1/events?bbox=51.9,4.9,52.4,5.2", gzip_ok=True)
    assert status == 200
    contract = json.loads(CONTRACT.read_text())
    assert set(contract) <= set(page), "page keys the app relies on"
    assert {e["id"] for e in page["events"]} == {"RWS03_900123_1", "NLRWS_WW_1_works", "NLRWS_WW_1_closure"}
    for e in page["events"]:
        assert set(e) == set(contract["events"][0]), f"event keys drifted from the Swift contract: {e['id']}"

    _, delta = get(base + f"/v1/events?bbox=51.9,4.9,52.4,5.2&since={page['version']}")
    assert delta["full"] is False and delta["events"] == [] and delta["removed"] == []


def test_http_errors_and_health(server):
    _, base = server
    with pytest.raises(urllib.error.HTTPError) as e:
        get(base + "/v1/events?bbox=1,2,3")
    assert e.value.code == 400
    with pytest.raises(urllib.error.HTTPError) as e:
        get(base + "/v1/events?bbox=52.4,5.2,51.9,4.9")
    assert e.value.code == 400
    status, health = get(base + "/healthz")
    assert status == 200 and health["ok"] and health["feeds"]["incidents"]["stale"] is False


# ---------------------------------------------------------------- 车道数（OSM）

from ndw_relay.lanes import LaneService, segments_from_overpass, tiles_for  # noqa: E402

LANES_CONTRACT = Path(__file__).resolve().parents[2] / "contracts" / "lane-counts.v1.example.json"


def overpass_fixture() -> dict:
    return json.loads((FIXTURES / "overpass_lanes.json").read_text())


def test_overpass_segments_follow_travel_direction():
    segs = {s["id"]: s for s in segments_from_overpass(overpass_fixture())}
    assert segs["osm:way/4021"]["lanes"] == 3, "motorway is implicitly one-way"
    assert segs["osm:way/4022"]["lanes"] == 1, "so is motorway_link (the ramp anchor)"
    assert segs["osm:way/5000"]["geometry"][0] == [52.101, 5.11], "oneway=-1 → geometry reversed"
    assert segs["osm:way/7710:f"]["geometry"][0] == [52.23, 4.81]
    assert segs["osm:way/7710:b"]["geometry"][0] == [52.231, 4.825] and segs["osm:way/7710:b"]["lanes"] == 2
    assert "osm:way/7711" not in segs and not any(k.startswith("osm:way/7711") for k in segs), \
        "two-way road without lanes:forward/backward is ambiguous → skipped"
    assert segs["osm:way/7712"]["lanes"] == 2
    assert not any(k.startswith("osm:way/7713") for k in segs)


def test_lane_tiles_cached_and_failures_reported():
    calls = []

    def fetch(tile):
        calls.append(tile)
        if tile == (208, 20):
            raise TimeoutError("overpass busy")
        return overpass_fixture()

    now = [1000.0]
    svc = LaneService(fetch=fetch, clock=lambda: now[0], ttl_s=60)
    bbox = (52.0, 4.9, 52.3, 5.2)
    assert len(tiles_for(bbox)) == 4
    first = svc.query(bbox)
    assert first["tiles"] == {"cached": 0, "fetched": 3, "failed": 1}
    assert len({s["id"] for s in first["segments"]}) == len(first["segments"]), "one entry per way across tiles"
    second = svc.query(bbox)
    assert second["tiles"]["cached"] == 3 and len(calls) == 5, "only the failed tile is retried"
    now[0] += 120
    svc.query(bbox)
    assert len(calls) == 9, "expired tiles are fetched again"
    with pytest.raises(ValueError):
        svc.query((50.0, 3.0, 54.0, 8.0))


def test_http_lanes_match_contract():
    store = EventStore(clock=lambda: NOW)
    svc = LaneService(fetch=lambda tile: overpass_fixture())
    srv = make_server(store, "127.0.0.1", 0, lanes=svc)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    try:
        base = f"http://127.0.0.1:{srv.server_address[1]}"
        status, page = get(base + "/v1/lanes?bbox=52.0,4.9,52.3,5.2")
        assert status == 200
        contract = json.loads(LANES_CONTRACT.read_text())
        assert set(contract) <= set(page)
        for seg in page["segments"]:
            assert set(seg) == set(contract["segments"][0])
        with pytest.raises(urllib.error.HTTPError) as e:
            get(base + "/v1/lanes")
        assert e.value.code == 400
    finally:
        srv.shutdown()
