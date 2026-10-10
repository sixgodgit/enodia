"""HTTP 接口（标准库 http.server）。

GET /v1/events?bbox=min_lat,min_lon,max_lat,max_lon[&since=N]   → ndw-events/v1
GET /v1/lanes?bbox=min_lat,min_lon,max_lat,max_lon              → lane-counts/v1（OSM 车道数）
GET /healthz                                                    → 版本号与各数据集新鲜度
"""

from __future__ import annotations

import gzip
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from .lanes import LaneService
from .store import EventStore


def parse_bbox(value: str | None) -> tuple[float, float, float, float] | None:
    if value is None:
        return None
    parts = [float(x) for x in value.split(",")]
    if len(parts) != 4:
        raise ValueError("bbox needs 4 numbers")
    a, b, c, d = parts
    if not (a <= c and b <= d and -90 <= a <= 90 and -90 <= c <= 90 and -180 <= b <= 180 and -180 <= d <= 180):
        raise ValueError("bbox must be min_lat,min_lon,max_lat,max_lon")
    return (a, b, c, d)


def make_handler(store: EventStore, lanes: LaneService | None = None) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "ndw-relay/0.1"

        def do_GET(self) -> None:  # noqa: N802
            url = urlparse(self.path)
            qs = parse_qs(url.query)
            if url.path == "/healthz":
                page = store.query(None, since=store.version)
                self._json(200, {"ok": True, "version": page["version"], "feeds": page["feeds"]})
                return
            if url.path == "/v1/lanes" and lanes is not None:
                try:
                    bbox = parse_bbox(qs.get("bbox", [None])[0])
                    if bbox is None:
                        raise ValueError("bbox is required")
                    self._json(200, lanes.query(bbox))
                except ValueError as e:
                    self._json(400, {"error": str(e)})
                return
            if url.path != "/v1/events":
                self._json(404, {"error": "not found"})
                return
            try:
                bbox = parse_bbox(qs.get("bbox", [None])[0])
                since = int(qs["since"][0]) if "since" in qs else None
            except (ValueError, KeyError) as e:
                self._json(400, {"error": str(e)})
                return
            self._json(200, store.query(bbox, since))

        def _json(self, status: int, body: dict) -> None:
            data = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode()
            gz = "gzip" in (self.headers.get("Accept-Encoding") or "")
            if gz:
                data = gzip.compress(data)
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            if gz:
                self.send_header("Content-Encoding", "gzip")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, fmt: str, *args) -> None:  # 安静点：轮询每分钟都来
            pass

    return Handler


def make_server(store: EventStore, host: str = "127.0.0.1", port: int = 8787,
                lanes: LaneService | None = None) -> ThreadingHTTPServer:
    return ThreadingHTTPServer((host, port), make_handler(store, lanes))
