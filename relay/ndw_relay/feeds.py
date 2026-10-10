"""NDW 开放数据集与后台拉取。

数据集清单见 https://opendata.ndw.nu/ （NDW = Nationaal Dataportaal Wegverkeer）。
下面的文件名按 NDW 公布的开放数据整理；NDW 偶尔改名或换 DATEX 版本，
所以全部可以通过环境变量 NDW_FEEDS 覆盖（格式：name=url@秒,name=url@秒）。
"""

from __future__ import annotations

import logging
import os
import threading
import urllib.error
import urllib.request
from dataclasses import dataclass

from . import datex2
from .store import EventStore

log = logging.getLogger("ndw_relay")


@dataclass(frozen=True)
class Feed:
    name: str
    url: str
    interval_s: float


DEFAULT_FEEDS = (
    # 事故等突发事件（Rijkswaterstaat 交通中心）
    Feed("incidents", "https://opendata.ndw.nu/incidents.xml.gz", 60),
    # 当前状态消息：封路、车道关闭等
    Feed("status", "https://opendata.ndw.nu/actuele_statusberichten.xml.gz", 60),
    # 施工（含计划中的；store 只保留 24 小时内开始的）
    Feed("roadworks", "https://opendata.ndw.nu/wegwerkzaamheden.xml.gz", 300),
    # 开合桥
    Feed("bridges", "https://opendata.ndw.nu/brugopeningen.xml.gz", 60),
)


def feeds_from_env(value: str | None = None) -> tuple[Feed, ...]:
    value = value if value is not None else os.environ.get("NDW_FEEDS", "")
    if not value.strip():
        return DEFAULT_FEEDS
    out = []
    for part in value.split(","):
        name, rest = part.strip().split("=", 1)
        url, _, interval = rest.rpartition("@")
        out.append(Feed(name, url, float(interval)))
    return tuple(out)


class FeedPoller:
    """每个数据集一个线程：条件请求（ETag / Last-Modified）→ 解析 → 替换 store 里该数据集的内容。

    拉取或解析失败只标记错误，绝不清空已有数据。
    """

    def __init__(self, store: EventStore, feeds: tuple[Feed, ...] = DEFAULT_FEEDS,
                 user_agent: str = "nyx-nav-ndw-relay/0.1 (personal use)") -> None:
        self.store = store
        self.feeds = feeds
        self.user_agent = user_agent
        self._validators: dict[str, dict[str, str]] = {}
        self._stop = threading.Event()
        self._threads: list[threading.Thread] = []

    def start(self) -> None:
        for f in self.feeds:
            self.store.register_feed(f.name, f.interval_s)
            t = threading.Thread(target=self._loop, args=(f,), name=f"ndw-{f.name}", daemon=True)
            t.start()
            self._threads.append(t)

    def stop(self) -> None:
        self._stop.set()

    def _loop(self, feed: Feed) -> None:
        while not self._stop.is_set():
            self.poll_once(feed)
            self._stop.wait(feed.interval_s)

    def poll_once(self, feed: Feed) -> None:
        headers = {"User-Agent": self.user_agent, **self._validators.get(feed.name, {})}
        req = urllib.request.Request(feed.url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                events = list(datex2.parse(resp, source=f"ndw:{feed.name}"))
                validators = {}
                if resp.headers.get("ETag"):
                    validators["If-None-Match"] = resp.headers["ETag"]
                if resp.headers.get("Last-Modified"):
                    validators["If-Modified-Since"] = resp.headers["Last-Modified"]
                self._validators[feed.name] = validators
            changed = self.store.replace_feed(feed.name, events)
            log.info("%s: %d events, %d changed, version %d", feed.name, len(events), changed, self.store.version)
        except urllib.error.HTTPError as e:
            if e.code == 304:
                self.store.mark_unchanged(feed.name)
            else:
                self.store.mark_error(feed.name, f"HTTP {e.code}")
                log.warning("%s: HTTP %s", feed.name, e.code)
        except Exception as e:  # noqa: BLE001 —— 任何失败都不能让轮询线程死掉
            self.store.mark_error(feed.name, type(e).__name__)
            log.warning("%s: %s", feed.name, e)
