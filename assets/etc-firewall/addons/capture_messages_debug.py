"""
capture_messages_debug.py — debug addon (toggleable via sentinel file).

For every POST that lands on api.anthropic.com or ollama.internal with a path
starting with /v1/messages, dump the request to /tmp/claude-capture/ as a
ready-to-replay curl script + a sibling .json body file. We can then `bash
<script>` to send the EXACT same payload to Ollama (or any other backend)
and reproduce Claude Code's behavior 1:1.

Why this, not mitmproxy -w flow dumps : the flows file is a binary mitm
format ; replaying it needs mitmdump --client-replay which goes BACK through
the proxy chain (re-triggers policy_enforce etc.). A plain curl script is
trivial to redirect, edit, replay against alternate hosts.

Sanity : we redact the OAuth bearer / x-api-key into XXX in the curl script
so the file is safe to share. The .json body is untouched (no creds in it —
the auth lives in headers only).

LIVE TOGGLE (no mitmproxy restart needed) :
  - Enable  : touch /tmp/claude-capture/.enabled
  - Disable : rm    /tmp/claude-capture/.enabled
The addon checks the sentinel on EVERY request, so toggling takes effect
instantly. When disabled, the hook is a no-op (one stat() per matched
request, negligible cost).

LOAD-ON-DEMAND : the addon is loaded permanently by mitm-init.sh, but does
nothing until the sentinel exists. Safe to leave in production-style
configs ; only active when you explicitly enable it.

To use :
  1. mitm-init.sh loads this addon at every boot (already wired).
  2. touch /tmp/claude-capture/.enabled
  3. Run claude --print 'ping' (cloud or local).
  4. ls /tmp/claude-capture/ — one .sh + .json per /v1/messages POST.
  5. bash /tmp/claude-capture/<file>.sh — replays the call.
  6. rm /tmp/claude-capture/.enabled  (stop capturing)
"""
import json
import os
import shlex
import sys
import time
import traceback
import uuid

from mitmproxy import http

CAPTURE_DIR = "/tmp/claude-capture"
ENABLE_SENTINEL = os.path.join(CAPTURE_DIR, ".enabled")
TARGET_HOSTS = ("api.anthropic.com", "ollama.internal", "ollama.local")
TARGET_PATH_PREFIX = "/v1/messages"
REDACT_HEADERS = {"x-api-key", "authorization", "anthropic-auth-token"}

os.makedirs(CAPTURE_DIR, exist_ok=True)


def request(flow: http.HTTPFlow) -> None:
    try:
        host = flow.request.host
        path = flow.request.path  # includes query
        if host not in TARGET_HOSTS:
            return
        if not path.startswith(TARGET_PATH_PREFIX):
            return
        if flow.request.method != "POST":
            return
        # Live toggle : capture only when the sentinel file exists.
        # Cheap stat() per matched request ; takes effect instantly.
        if not os.path.exists(ENABLE_SENTINEL):
            return

        ts = time.strftime("%H%M%S")
        uid = uuid.uuid4().hex[:6]
        stem = f"{ts}-{uid}-{host.replace('.', '_')}"
        body_path = os.path.join(CAPTURE_DIR, f"{stem}.json")
        script_path = os.path.join(CAPTURE_DIR, f"{stem}.sh")

        body_bytes = flow.request.content or b""
        with open(body_path, "wb") as f:
            f.write(body_bytes)

        # Build the replay curl. -H lines for every header (redacted ones get XXX)
        header_lines = []
        for name, value in flow.request.headers.items():
            if name.lower() in REDACT_HEADERS:
                value = "XXX-REDACTED"
            header_lines.append(f"  -H {shlex.quote(f'{name}: {value}')}")

        target_url = f"http://{host}{path}"  # http: matches Ollama; for cloud the replay would need https:
        ollama_replay_url = f"http://ollama.internal:11434{path}"

        script = f"""#!/usr/bin/env bash
# Replay of {flow.request.method} {target_url}
# Captured at {time.strftime('%Y-%m-%d %H:%M:%S')} via capture_messages_debug.py
# Body : {body_path} ({len(body_bytes)} bytes)
#
# === Replay against ORIGINAL host ({host}) — keep proxy routing ===
# curl -sSv --max-time 120 -X POST {shlex.quote(target_url)} \\
{chr(10).join(header_lines)} \\
#   --data-binary @{shlex.quote(body_path)}
#
# === Replay against Ollama (substitute host, drop https→http) ===
curl -sSv --max-time 180 -X POST {shlex.quote(ollama_replay_url)} \\
  -H 'content-type: application/json' \\
  -H 'anthropic-version: 2023-06-01' \\
  -H 'x-api-key: ollama' \\
  --data-binary @{shlex.quote(body_path)} \\
  -o /tmp/claude-capture/{stem}.response \\
  -w '\\nhttp=%{{http_code}} t=%{{time_total}}s size=%{{size_download}}B\\n'
"""
        with open(script_path, "w") as f:
            f.write(script)
        os.chmod(script_path, 0o755)

    except Exception as exc:
        print(f"[capture_messages_debug] EXCEPTION: {exc}\n{traceback.format_exc()}",
              file=sys.stderr)
