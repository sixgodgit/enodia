"""带版本号的事件集合：支持按区域查询和增量下发。

每个数据集（feed）每次拉取都是一份完整快照；store 拿它和上一份比较，
只有真正变化（新增/内容变了/消失）的事件才拿到新版本号。手机带着 since=上次版本 来问，
只拿到变化的部分 —— 在 4G 上每分钟轮询也只是几百字节。
"""

from __future__ import annotations

import threading
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Callable

from .datex2 import parse_time, public


@dataclass
class FeedState:
    fetched_at: datetime | None = None
    interval_s: float = 60
    error: str | None = None

    def status(self, now: datetime) -> dict:
        age = (now - self.fetched_at).total_seconds() if self.fetched_at else None
        return {
            "fetched_at": self.fetched_at.strftime("%Y-%m-%dT%H:%M:%SZ") if self.fetched_at else None,
            "age_s": round(age) if age is not None else None,
            # 三个周期没成功更新，或最近一次出错 → 标记为陈旧（数据仍然下发，旧事件好过没有事件）
            "stale": age is None or age > 3 * self.interval_s or self.error is not None,
        }


@dataclass
class EventStore:
    #: 规划中的施工只保留未来这么多小时内开始的
    horizon: timedelta = timedelta(hours=24)
    #: 墓碑保留多少个版本；更早的 since 直接给完整快照
    tombstone_versions: int = 5000
    #: 可注入的时钟（测试用）
    clock: Callable[[], datetime] = field(default=lambda: datetime.now(timezone.utc), repr=False)

    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)
    _version: int = 0
    _events: dict[str, tuple[dict, int]] = field(default_factory=dict)
    _feed_of: dict[str, str] = field(default_factory=dict)
    _tombstones: dict[str, int] = field(default_factory=dict)
    _oldest_delta: int = 0
    _feeds: dict[str, FeedState] = field(default_factory=dict)

    @property
    def version(self) -> int:
        return self._version

    def register_feed(self, name: str, interval_s: float) -> None:
        with self._lock:
            self._feeds.setdefault(name, FeedState(interval_s=interval_s))

    def replace_feed(self, feed: str, events: list[dict], now: datetime | None = None) -> int:
        """用一个数据集的最新完整快照替换它之前的内容。返回变化的事件数。"""
        now = now or self.clock()
        keep = [e for e in events if self._relevant(e, now)]
        with self._lock:
            state = self._feeds.setdefault(feed, FeedState())
            state.fetched_at, state.error = now, None
            current = {i for i, f in self._feed_of.items() if f == feed}
            incoming = {e["id"]: e for e in keep}
            changed = [e for i, e in incoming.items() if i not in self._events or self._events[i][0] != e]
            gone = current - incoming.keys()
            if not changed and not gone:
                return 0
            self._version += 1
            v = self._version
            for e in changed:
                self._events[e["id"]] = (e, v)
                self._feed_of[e["id"]] = feed
                self._tombstones.pop(e["id"], None)
            for i in gone:
                self._events.pop(i, None)
                self._feed_of.pop(i, None)
                self._tombstones[i] = v
            self._prune()
            return len(changed) + len(gone)

    def mark_error(self, feed: str, error: str) -> None:
        with self._lock:
            self._feeds.setdefault(feed, FeedState()).error = error

    def mark_unchanged(self, feed: str, now: datetime | None = None) -> None:
        """HTTP 304：数据没变，但"新鲜度"要刷新。"""
        with self._lock:
            state = self._feeds.setdefault(feed, FeedState())
            state.fetched_at, state.error = now or self.clock(), None

    def query(self, bbox: tuple[float, float, float, float] | None, since: int | None,
              now: datetime | None = None) -> dict:
        """bbox = (min_lat, min_lon, max_lat, max_lon)。"""
        now = now or self.clock()
        with self._lock:
            full = since is None or since < self._oldest_delta or since > self._version
            events = [e for e, v in self._events.values()
                      if (full or v > since) and self._relevant(e, now) and _in_bbox(e, bbox)]
            removed = [] if full else sorted(i for i, v in self._tombstones.items() if v > since)
            return {
                "schema": "ndw-events/v1",
                "version": self._version,
                "full": full,
                "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "feeds": {name: s.status(now) for name, s in sorted(self._feeds.items())},
                "events": [public(e) for e in sorted(events, key=lambda e: e["id"])],
                "removed": removed,
            }

    def _relevant(self, e: dict, now: datetime) -> bool:
        end = parse_time(e.get("end"))
        if end is not None and end < now:
            return False
        start = parse_time(e.get("start"))
        return start is None or start <= now + self.horizon

    def _prune(self) -> None:
        floor = self._version - self.tombstone_versions
        if floor <= self._oldest_delta:
            return
        self._tombstones = {i: v for i, v in self._tombstones.items() if v > floor}
        self._oldest_delta = floor


def _in_bbox(e: dict, bbox: tuple[float, float, float, float] | None) -> bool:
    if bbox is None:
        return True
    a, b, c, d = bbox
    return any(a <= lat <= c and b <= lon <= d for lat, lon in e["geometry"])
