"""
passive_log.py — mitmproxy addon for Phase A2.

Records one JSON line per non-GET request into /var/log/mitmproxy-writes.log
so any write attempt can be audited offline. GET / HEAD / OPTIONS are skipped
(they're already in /var/log/mitmproxy.log via mitmdump's default request log
and the audit goal is to surface POST/PUT/PATCH/DELETE traffic).

Synchronous append: acceptable for the dev volumes we see (<< 100 req/s).
If volume grows, switch to a buffered writer or hand off to a queue.

Failures here MUST NOT block traffic — passive_log is observability, not
enforcement.
"""

import json
import sys
import time
import traceback

from mitmproxy import http

WRITE_LOG = "/var/log/mitmproxy-writes.log"
SKIP = {"GET", "HEAD", "OPTIONS"}


def request(flow: http.HTTPFlow) -> None:
    try:
        if flow.request.method in SKIP:
            return
        entry = {
            "ts": time.time(),
            "method": flow.request.method,
            "host": flow.request.host,
            "path": flow.request.path,
            "size": len(flow.request.content or b""),
            "ct": flow.request.headers.get("content-type", ""),
            "ua": flow.request.headers.get("user-agent", "")[:120],
        }
        with open(WRITE_LOG, "a") as f:
            f.write(json.dumps(entry, separators=(",", ":")) + "\n")
    except Exception as exc:
        print(
            f"[passive_log] EXCEPTION: {exc}\n{traceback.format_exc()}",
            file=sys.stderr,
        )
