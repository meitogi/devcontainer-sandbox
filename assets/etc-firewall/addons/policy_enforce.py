"""
policy_enforce.py — mitmproxy addon for Phase A2 of the devcontainer firewall.

Loads /var/run/devcontainer-firewall/policy.compiled.yaml (produced by
compile-policy.py from domains.txt + policy.d/ + local layer) and enforces, for
every request that reaches mitmdump:

  - host membership in the compiled policy (else 403)
  - allowed_methods at the host level (else 403)
  - blocked_paths regex at the host level (else 403)
  - endpoints regex match when policy.d/ defined them; the matched endpoint
    further constrains methods, max_body_kb, query_params schema
  - paths literal/glob match when only domains.txt declared paths (no endpoints)
  - host-level max_body_size_kb (statsig/sentry style telemetry caps)
  - URL/header length and count limits from defaults (+ defaults_override)
  - base64 / hex detection in the query string only (paths often look base64-ish
    e.g. VS Code marketplace URLs are 50+ chars of [A-Za-z0-9+/])
  - internal-path leak detection on the full URL (those should never be there)

Fail-closed: any uncaught exception in request() returns 503 with
X-Block-Reason: addon_error:policy_enforce:<exc>. A missing or malformed
policy.compiled.yaml degrades to a deny-all policy (every host -> 403).

Side-channel: every 4xx/5xx we emit also appends one JSON line to
/var/log/mitmproxy-blocks.log so `firewall-blocks` can show recent blocks
without re-reading the full mitmdump request log.
"""

import json
import os
import re
import sys
import time
import traceback

from mitmproxy import http
# mitmproxy's PyInstaller bundle ships ruamel.yaml (used internally) but NOT
# PyYAML — so we use ruamel's safe-typed loader to parse policy.compiled.yaml.
# `YAML(typ='safe').load()` returns plain Python dict/list/scalars identical
# to `yaml.safe_load()`. See .devcontainer/knowledge/firewall.md § "mitmproxy bundle: ruamel.yaml only".
from ruamel.yaml import YAML

_YAML = YAML(typ='safe')
POLICY_PATH = "/var/run/devcontainer-firewall/policy.compiled.yaml"
BLOCKS_LOG = "/var/log/mitmproxy-blocks.log"
ADDON_NAME = "policy_enforce"

# Policy-independent constants — never touched by reload.
BASE64_RE = re.compile(rb"[A-Za-z0-9+/=]{50,}")
HEX_RE = re.compile(rb"[0-9a-f]{100,}")
# Per-PATH-SEGMENT detection. We use SEARCH (not fullmatch) so an embedded
# base64 blob inside a segment also trips — `/prefix<60chars>suffix/`
# would otherwise sneak past a strict fullmatch. The alphabet excludes `/`
# (segment delimiter), `-`, `_`, `.` so contiguous-alphanumeric blobs are
# the signal :
#  - `claude-code`, `anthropic-sdk-python` etc. break on `-` ⇒ safe
#  - UUIDs (36 ch with `-`), Git SHAs (40 ch) ⇒ under 50 thresholds
#  - URL-safe base64 (`-_` instead of `+/`) ⇒ NOT caught (documented limit)
# Length check below is the second line of defense for embedded blobs
# that hide behind separators — `max_path_segment_length` defaults to 100.
SEGMENT_BASE64_RE = re.compile(rb"[A-Za-z0-9+=]{50,}")
SEGMENT_HEX_RE = re.compile(rb"[0-9a-f]{100,}")
INTERNAL_PATH_RE = re.compile(rb"/(workspace|home|var/lib|etc)/[a-zA-Z0-9_./-]+")

# Policy-derived globals — populated by _load_policy() at import and refreshed
# by _reload_if_stale() when policy.compiled.yaml mtime changes.
POLICY = {}
DEFAULTS = {}
DOMAINS = {}
RUNTIME = {}
# Headers are case-insensitive on the wire — apply IGNORECASE so `x-Custom`
# is treated the same as `X-Custom` for the allowlist negative-lookahead.
BLOCKED_HEADER_RES = []
_POLICY_MTIME_NS = None


def _glob_to_regex(pat: str):
    """domains.txt paths are literal, optionally with a single trailing `*`."""
    if pat.endswith("*"):
        return re.compile("^" + re.escape(pat[:-1]) + ".*$")
    return re.compile("^" + re.escape(pat) + "$")


def _load_policy() -> None:
    """Reload policy.compiled.yaml + re-run the regex pre-compile pass.
    Called at module import and by _reload_if_stale() when the file changes.

    Fail-safe semantics :
      - Initial load fails (POLICY still empty) ⇒ deny-all fallback (safe closed).
      - Reload fails (POLICY already populated) ⇒ keep last known good globals
        + log the exception. A mid-session corrupt YAML must NOT wipe a
        working policy — that would 403-storm the container exactly when
        we're trying to hot-reload.
    """
    global POLICY, DEFAULTS, DOMAINS, RUNTIME, BLOCKED_HEADER_RES
    try:
        with open(POLICY_PATH) as _f:
            _new = _YAML.load(_f) or {}
        _new_defaults = _new.get("defaults", {}) or {}
        _new_domains = _new.get("domains", {}) or {}
        _new_runtime = _new.get("runtime", {}) or {}
        _new_blocked_hdrs = [re.compile(p, re.IGNORECASE) for p in _new_defaults.get("blocked_header_patterns") or []]
        for _host, _hp in _new_domains.items():
            _methods = _hp.get("allowed_methods") or _new_defaults.get("allowed_methods", ["GET"])
            _hp["_methods_set"] = {m.upper() for m in _methods}
            _hp["_path_regexes"] = [_glob_to_regex(p) for p in _hp.get("paths") or []]
            _hp["_blocked_regexes"] = [re.compile(p) for p in _hp.get("blocked_paths") or []]
            # Per-host header allowlist that EXEMPTS matching headers from the
            # global blocked_header_patterns. Use this in policy.d/<host>.yaml to
            # declare vendor-specific prefixes (X-Vss-, X-GitHub-, X-Anthropic-)
            # that are only legitimate on this vendor's hosts.
            _hp["_allowed_header_regexes"] = [
                re.compile(p, re.IGNORECASE) for p in _hp.get("allowed_header_patterns") or []
            ]
            _eps = []
            for _ep in _hp.get("endpoints") or []:
                _eps.append({
                    "regex": re.compile(_ep["path"]),
                    "methods": {m.upper() for m in (_ep.get("methods") or _methods)},
                    "max_body_kb": _ep.get("max_body_kb"),
                    "query_params": _ep.get("query_params") or {},
                    "reject_unknown": bool(_ep.get("reject_unknown_params")),
                    # Per-endpoint defaults_override : merges on top of host's
                    # effective defaults at request time so you can relax (or
                    # tighten) e.g. max_path_segment_length for ONE URL only
                    # without affecting siblings.
                    "defaults_override": _ep.get("defaults_override") or {},
                })
            _hp["_endpoints"] = _eps
    except Exception as exc:
        # Any failure during load OR rebuild (parse, schema mismatch, regex
        # compile) — keep last-good globals on reload, deny-all on very first
        # load. All-or-nothing commit : if we can't build the FULL new state
        # cleanly, don't mutate any global (avoids half-updated state where
        # e.g. DOMAINS is new but BLOCKED_HEADER_RES is old).
        print(f"[policy_enforce] load {POLICY_PATH} failed: {exc}", file=sys.stderr)
        if POLICY:
            return
        POLICY = {"defaults": {}, "domains": {}, "runtime": {"policy_enforce_enabled": True}}
        DEFAULTS, DOMAINS, RUNTIME, BLOCKED_HEADER_RES = {}, {}, POLICY["runtime"], []
        return

    POLICY = _new
    DEFAULTS = _new_defaults
    DOMAINS = _new_domains
    RUNTIME = _new_runtime
    BLOCKED_HEADER_RES = _new_blocked_hdrs


def _reload_if_stale() -> None:
    """Cheap per-request mtime check. Reloads policy globals when
    policy.compiled.yaml has changed on disk. Safe against concurrent writers
    because compile-policy.py uses atomic_write() (rename bumps mtime
    atomically ; readers see either old-full or new-full, never partial)."""
    global _POLICY_MTIME_NS
    try:
        mt = os.stat(POLICY_PATH).st_mtime_ns
    except OSError:
        return
    if _POLICY_MTIME_NS != mt:
        _load_policy()
        _POLICY_MTIME_NS = mt


_load_policy()
try:
    _POLICY_MTIME_NS = os.stat(POLICY_PATH).st_mtime_ns
except OSError:
    _POLICY_MTIME_NS = None


def _find_host_policy(host: str):
    if host in DOMAINS:
        return host, DOMAINS[host]
    for k, v in DOMAINS.items():
        if host.endswith("." + k):
            return k, v
    return None, None


def _record_block(flow: http.HTTPFlow, code: int, reason: str, mode: str) -> None:
    """Append a JSON line to /var/log/mitmproxy-blocks.log so `firewall-blocks`
    can summarise recent blocks without scanning the full mitmdump request log.
    Best-effort: never re-raise (logging must not break enforcement).

    `mode` is `block` (request was rejected) or `warn` (request passed through
    but the rule would have matched). Used by firewall-blocks to distinguish
    enforcement from observation. `reason` is the FULL reason — if the caller
    capped the response header for HTTP size reasons, the full version still
    lands here so post-hoc analysis has everything."""
    try:
        entry = {
            "ts": time.time(),
            "addon": ADDON_NAME,
            "mode": mode,
            "method": flow.request.method,
            "host": flow.request.host,
            "path": flow.request.path,
            "code": code,
            "reason": reason,
            "ua": flow.request.headers.get("user-agent", "")[:120],
        }
        with open(BLOCKS_LOG, "a") as f:
            f.write(json.dumps(entry, separators=(",", ":")) + "\n")
    except Exception:
        pass


def _block(flow: http.HTTPFlow, code: int, reason: str, log_reason: str | None = None) -> None:
    """Block (or warn-only) on a policy violation. The enforcement mode is
    read from `flow._enforcement_mode` which `request()` sets after each
    relevant override resolution (DEFAULTS, host, endpoint).

    In `warn` mode we record the would-be block to /var/log/mitmproxy-blocks.log
    and return WITHOUT setting flow.response — mitmdump then forwards the
    request to upstream as if the rule didn't exist. The blocks log entry
    carries `"mode":"warn"` so `firewall-blocks` can distinguish them.

    `log_reason` lets the caller log a fuller version of the reason while
    keeping the X-Block-Reason response header short (e.g. blocked_header
    truncates at 5 headers in the response but logs the full list)."""
    mode = getattr(flow, "_enforcement_mode", "block")
    _record_block(flow, code, log_reason or reason, mode)
    if mode == "warn":
        return  # request passes through; rule was advisory only
    flow.response = http.Response.make(
        code,
        reason.encode(),
        {"X-Block-Reason": reason, "Content-Type": "text/plain"},
    )


def _validate_query_params(flow: http.HTTPFlow, schema: dict, reject_unknown: bool):
    for k, v in flow.request.query.items(multi=True):
        rules = schema.get(k)
        if rules is None:
            if reject_unknown:
                return f"unknown_query_param:{k}"
            continue
        t = rules.get("type")
        if t == "int":
            try:
                iv = int(v)
            except ValueError:
                return f"query_type:{k}:not_int"
            mn = rules.get("min")
            mx = rules.get("max")
            if mn is not None and iv < mn:
                return f"query_min:{k}"
            if mx is not None and iv > mx:
                return f"query_max:{k}"
        elif t == "string":
            ml = rules.get("max_length")
            if ml is not None and len(v) > ml:
                return f"query_max_length:{k}"
            pat = rules.get("pattern")
            if pat and not re.match(pat, v):
                return f"query_pattern:{k}"
        enum = rules.get("enum")
        if enum is not None and v not in enum:
            return f"query_enum:{k}"
    return None


def request(flow: http.HTTPFlow) -> None:
    _reload_if_stale()
    if not RUNTIME.get("policy_enforce_enabled", True):
        return
    try:
        # Default to the global enforcement mode for pre-host checks
        # (URL length, header count). Updated after host lookup with
        # per-host `defaults_override.enforcement_mode`, and again after
        # endpoint match with per-endpoint `defaults_override.enforcement_mode`.
        flow._enforcement_mode = DEFAULTS.get("enforcement_mode", "block")

        host = flow.request.host
        method = flow.request.method
        full_url = flow.request.url.encode()
        path_with_qs = flow.request.path
        bare_path, _, qs = path_with_qs.partition("?")

        if len(bare_path) > DEFAULTS.get("max_path_length", 512):
            return _block(flow, 414, "url_path_too_long")
        if len(flow.request.url) > DEFAULTS.get("max_url_total_length", 2048):
            return _block(flow, 414, "url_total_too_long")

        # Resource-bound header checks (no host context needed).
        if len(flow.request.headers) > DEFAULTS.get("max_header_count", 30):
            return _block(flow, 431, "too_many_headers")
        max_hv = DEFAULTS.get("max_header_value_length", 4096)
        for hk, hv in flow.request.headers.items():
            if len(hv) > max_hv:
                return _block(flow, 431, f"header_value_too_long:{hk}")

        matched_host, hp = _find_host_policy(host)
        if hp is None:
            return _block(flow, 403, f"host_not_in_policy:{host}")

        # Refresh enforcement mode from the host's defaults_override now
        # that we know which host we're on. host-level mode applies to all
        # remaining checks unless an endpoint override fires later.
        host_effective_mode = (hp.get("defaults_override") or {}).get(
            "enforcement_mode", DEFAULTS.get("enforcement_mode", "block")
        )
        flow._enforcement_mode = host_effective_mode

        # Blocked-header check AFTER host lookup so we can apply the per-host
        # allowed_header_patterns allowlist (vendor-specific prefixes are
        # only valid against that vendor's hosts — prevents X-Vss-Leak being
        # used to exfil to api.anthropic.com for instance).
        #
        # We collect ALL offending headers in one pass instead of returning
        # on the first match. Otherwise debugging is death-by-a-thousand-cuts :
        # user widens allowlist for header A, rebuilds, hits block on B, etc.
        # Reporting them together lets you whitelist in one shot.
        host_allowed_res = hp["_allowed_header_regexes"]
        blocked_hdrs = []
        for hk in flow.request.headers.keys():
            for r in BLOCKED_HEADER_RES:
                if not r.search(hk):
                    continue
                if any(ar.search(hk) for ar in host_allowed_res):
                    break  # exempted for this specific host
                blocked_hdrs.append(hk)
                break  # one matching pattern is enough per header
        if blocked_hdrs:
            # Cap the visible reason at 5 headers to keep the response header
            # short (HTTP header value byte budget). The FULL list goes to
            # /var/log/mitmproxy-blocks.log so post-hoc analysis sees every
            # offending header — important for warn-mode audit runs.
            full = ",".join(blocked_hdrs)
            summary = ",".join(blocked_hdrs[:5])
            if len(blocked_hdrs) > 5:
                summary += f"+{len(blocked_hdrs) - 5}more"
            return _block(flow, 403, f"blocked_header:{summary}",
                          log_reason=f"blocked_header:{full}")

        effective = {**DEFAULTS, **(hp.get("defaults_override") or {})}
        if len(qs) > effective.get("max_query_string_length", 256):
            return _block(flow, 414, "query_string_too_long")

        if method.upper() not in hp["_methods_set"] and "*" not in hp["_methods_set"]:
            return _block(flow, 403, f"method:{method}")

        for r in hp["_blocked_regexes"]:
            if r.search(bare_path):
                return _block(flow, 403, f"blocked_path:{bare_path}")

        if hp["_endpoints"]:
            matched_ep = None
            for ep in hp["_endpoints"]:
                if ep["regex"].match(bare_path):
                    matched_ep = ep
                    break
            if matched_ep is None:
                return _block(flow, 403, f"endpoint_not_matched:{bare_path}")
            if method.upper() not in matched_ep["methods"] and "*" not in matched_ep["methods"]:
                return _block(flow, 403, f"endpoint_method:{method}")
            if matched_ep["max_body_kb"] is not None:
                if len(flow.request.content or b"") > matched_ep["max_body_kb"] * 1024:
                    return _block(flow, 413, "body_too_large")
            err = _validate_query_params(flow, matched_ep["query_params"], matched_ep["reject_unknown"])
            if err:
                return _block(flow, 403, err)
            # Per-endpoint defaults_override applies on top of host defaults
            # for the segment / detection checks below. Lets a single URL
            # opt out of strict checks (e.g. badly-coded service that needs
            # 500-char path segments) without weakening sibling endpoints.
            # It can also flip enforcement_mode per-URL : useful for "block
            # globally but warn on this endpoint while I figure out the
            # schema" or the inverse.
            if matched_ep["defaults_override"]:
                effective = {**effective, **matched_ep["defaults_override"]}
                if "enforcement_mode" in matched_ep["defaults_override"]:
                    flow._enforcement_mode = matched_ep["defaults_override"]["enforcement_mode"]
        elif hp["_path_regexes"]:
            if not any(r.match(bare_path) for r in hp["_path_regexes"]):
                return _block(flow, 403, f"path_not_allowed:{bare_path}")

        host_max_body = hp.get("max_body_size_kb")
        if host_max_body is not None and len(flow.request.content or b"") > host_max_body * 1024:
            return _block(flow, 413, "host_body_too_large")

        # Detections — three scopes :
        #
        #  1. PATH SEGMENTS  : per `/`-separated segment, three layered checks
        #     (broader → narrower) so the X-Block-Reason names the actual
        #     pattern that fired :
        #       a. length > max_path_segment_length (100 by default) —
        #          generic "this segment is suspiciously long" catch-all even
        #          when the content uses separators inside (`prefix-<b64>-suffix`)
        #       b. hex blob substring (`[0-9a-f]{100,}` search) — specific
        #          before base64 because hex ⊂ alphanum so reasoning is clearer
        #       c. base64 blob substring (`[A-Za-z0-9+=]{50,}` search) —
        #          catches `/<b64>/` AND `/prefix<b64>suffix/` since we use
        #          search, not fullmatch. URL-safe base64 (`-_`) is NOT
        #          caught (would explode false positives on hyphenated names).
        #
        #  2. QUERY STRING   : substring scan for `[A-Za-z0-9+/=]{50,}` (full
        #     base64 incl `/`, since query strings aren't `/`-delimited).
        #     Tokens almost always leak via `?token=...` if not via path.
        #
        #  3. FULL URL       : internal-path-leak regex (workspace/home/etc.) —
        #     those filesystem prefixes should never appear ANYWHERE in a URL.
        path_segments = bare_path.encode().split(b"/")
        max_seg_len = effective.get("max_path_segment_length", 100)
        if max_seg_len:
            for seg in path_segments:
                if len(seg) > max_seg_len:
                    return _block(flow, 403, f"path_segment_too_long:{len(seg)}>{max_seg_len}")
        if effective.get("detect_hex_blob_in_url"):
            for seg in path_segments:
                if SEGMENT_HEX_RE.search(seg):
                    return _block(flow, 403, "hex_in_path_segment")
        if effective.get("detect_base64_in_url"):
            for seg in path_segments:
                if SEGMENT_BASE64_RE.search(seg):
                    return _block(flow, 403, "base64_in_path_segment")

        qs_bytes = qs.encode()
        if effective.get("detect_hex_blob_in_url") and qs_bytes and HEX_RE.search(qs_bytes):
            return _block(flow, 403, "hex_in_query")
        if effective.get("detect_base64_in_url") and qs_bytes and BASE64_RE.search(qs_bytes):
            return _block(flow, 403, "base64_in_query")
        if effective.get("detect_internal_path_leak") and INTERNAL_PATH_RE.search(full_url):
            return _block(flow, 403, "internal_path_in_url")

    except Exception as exc:
        print(
            f"[policy_enforce] EXCEPTION on {flow.request.method} {flow.request.url}: "
            f"{exc}\n{traceback.format_exc()}",
            file=sys.stderr,
        )
        _block(flow, 503, f"addon_error:policy_enforce:{type(exc).__name__}")
