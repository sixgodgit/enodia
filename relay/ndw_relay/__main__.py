"""python -m ndw_relay serve [--host H] [--port P]
python -m ndw_relay inspect <file.xml[.gz]> [--source NAME]
"""

from __future__ import annotations

import argparse
import json
import logging
import sys

from . import datex2
from .feeds import FeedPoller, feeds_from_env
from .server import make_server
from .store import EventStore


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="ndw_relay")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve", help="poll NDW feeds and serve /v1/events")
    s.add_argument("--host", default="127.0.0.1")
    s.add_argument("--port", type=int, default=8787)
    i = sub.add_parser("inspect", help="parse a downloaded DATEX II file and report coverage")
    i.add_argument("path")
    i.add_argument("--source", default="ndw:file")
    i.add_argument("--examples", type=int, default=3)
    args = ap.parse_args(argv)

    if args.cmd == "inspect":
        with open(args.path, "rb") as f:
            events = list(datex2.parse(f, args.source))
        report = datex2.summarize(events)
        report["examples"] = [datex2.public(e) for e in events[: args.examples]]
        json.dump(report, sys.stdout, ensure_ascii=False, indent=2)
        print()
        return 0

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    store = EventStore()
    FeedPoller(store, feeds_from_env()).start()
    server = make_server(store, args.host, args.port)
    logging.info("serving on http://%s:%d/v1/events", args.host, args.port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
