"""
stream_sse.py — mitmproxy addon for Phase A2.

Marks response bodies for STREAMING (no buffering) when the upstream returns
a Content-Type that indicates a long-lived / chunked response (SSE for
Claude API, NDJSON, gRPC). Without this, mitmproxy in `--mode regular`
buffers the entire response body before forwarding to the client, and
long Claude streams (HTTP/2 SSE on /v1/messages) trigger a 502 once the
buffer timeout hits.

The REQUEST side stays buffered — format_detect.py continues to inspect
POST/PUT/PATCH bodies for archive magic bytes. Only RESPONSE inspection
is forgone for streamed flows, which is fine since none of our addons
inspect response bodies anyway.

Streaming is decided on response headers (mitmproxy's `responseheaders`
hook fires after headers arrive, before body). Setting
`flow.response.stream = True` is the official mitmproxy API for opt-in
per-flow streaming.
"""

import sys
import traceback

from mitmproxy import http

# Content-Type prefixes that signal streaming responses. mitmproxy buffers
# the entire body by default ; for these media types the response is
# either long-running (SSE), unbounded (NDJSON / gRPC-Web), or otherwise
# expected to start arriving before completion.
STREAM_CONTENT_TYPES = (
    "text/event-stream",        # SSE — Claude API /v1/messages streaming
    "application/x-ndjson",     # newline-delimited JSON
    "application/grpc",
    "application/grpc-web",
)


def responseheaders(flow: http.HTTPFlow) -> None:
    """Decide per-flow whether to stream the response body. Called after
    upstream sent the response headers but before the body arrives."""
    try:
        if flow.response is None:
            return
        ct = (flow.response.headers.get("content-type") or "").lower()
        for marker in STREAM_CONTENT_TYPES:
            if marker in ct:
                flow.response.stream = True
                return
        # Also stream chunked-transfer responses without a Content-Length —
        # they're typically long-poll / SSE / live data feeds where the
        # client expects bytes as they arrive.
        te = (flow.response.headers.get("transfer-encoding") or "").lower()
        cl = flow.response.headers.get("content-length")
        if "chunked" in te and cl is None:
            flow.response.stream = True
    except Exception as exc:
        print(
            f"[stream_sse] responseheaders EXCEPTION: {exc}\n"
            f"{traceback.format_exc()}",
            file=sys.stderr,
        )
