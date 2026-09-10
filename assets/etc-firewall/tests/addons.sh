#!/usr/bin/env bash
# Unit tests for A2 mitmproxy addons (policy_enforce, format_detect, passive_log).
# Stubs mitmproxy.http + ruamel.yaml so the addons load without the mitmproxy
# bundle. Drives a synthetic policy.compiled.yaml through each addon via a mock
# HTTPFlow and asserts the expected X-Block-Reason (or pass-through).
#
# A3 note: addons import `ruamel.yaml` (not PyYAML) because that's what the
# mitmproxy PyInstaller bundle ships. This test stubs ruamel.yaml.YAML.load
# with python3-yaml's safe_load so we don't need ruamel apt-side. See
# .devcontainer/knowledge/firewall.md § "mitmproxy bundle: ruamel.yaml only".
#
# Standalone — only requires python3 + python3-yaml (apt: python3-yaml).
# Usage: ./addons.sh

set -uo pipefail

THIS_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || realpath "$0")")" && pwd)"
ADDONS_DIR="$THIS_DIR/../addons"

if [ ! -d "$ADDONS_DIR" ]; then
  # Fall back to baked-in image path
  ADDONS_DIR=/etc/devcontainer-firewall/addons
fi

if [ ! -f "$ADDONS_DIR/policy_enforce.py" ]; then
  echo "❌ addons not found at $ADDONS_DIR" >&2
  exit 1
fi

if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "❌ python3-yaml required (apt install python3-yaml)" >&2
  exit 1
fi

export ADDONS_DIR

python3 - <<'PY'
import os, sys, types, tempfile, importlib.util, builtins

ADDONS_DIR = os.environ["ADDONS_DIR"]
PASS, FAIL = 0, 0

# --- Stub mitmproxy.http -----------------------------------------------------
class FakeHeaders:
    def __init__(self, headers=None):
        self._h = dict(headers or {})
    def __len__(self): return len(self._h)
    def keys(self): return list(self._h.keys())
    def items(self): return list(self._h.items())
    def get(self, k, default=None): return self._h.get(k, default)

class FakeResponse:
    def __init__(self, status_code, content, headers):
        self.status_code = status_code
        self.content = content
        self.headers = dict(headers or {})
    @classmethod
    def make(cls, code, body=b"", headers=None):
        return cls(code, body, headers)

class FakeHTTPFlow: pass

mitm_pkg = types.ModuleType("mitmproxy")
mitm_http = types.ModuleType("mitmproxy.http")
mitm_http.Response = FakeResponse
mitm_http.HTTPFlow = FakeHTTPFlow
mitm_pkg.http = mitm_http
sys.modules["mitmproxy"] = mitm_pkg
sys.modules["mitmproxy.http"] = mitm_http

# --- Stub ruamel.yaml --------------------------------------------------------
# A3: the addons import ruamel.yaml because that's what the mitmproxy
# PyInstaller bundle ships. The unit test environment uses python3-yaml (apt),
# so we wrap yaml.safe_load behind a ruamel-shaped facade.
import yaml as _pyyaml
class _StubYAML:
    def __init__(self, *args, typ=None, **kwargs):
        pass
    def load(self, stream):
        return _pyyaml.safe_load(stream)

ruamel_pkg = types.ModuleType("ruamel")
ruamel_yaml_pkg = types.ModuleType("ruamel.yaml")
ruamel_yaml_pkg.YAML = _StubYAML
ruamel_pkg.yaml = ruamel_yaml_pkg
sys.modules["ruamel"] = ruamel_pkg
sys.modules["ruamel.yaml"] = ruamel_yaml_pkg

# --- Synthetic policy.compiled.yaml ------------------------------------------
POLICY_YAML = """
defaults:
  enforcement_mode: block
  allowed_methods: [GET, HEAD, OPTIONS]
  max_query_string_length: 256
  max_path_length: 512
  max_path_segment_length: 100
  max_url_total_length: 2048
  max_header_count: 30
  max_header_value_length: 4096
  blocked_header_patterns:
    - "^X-(?!Forwarded|Real-IP|Request-Id)"
  detect_base64_in_url: true
  detect_hex_blob_in_url: true
  detect_internal_path_leak: true
  block_archive_magic: true
  block_archive_in_base64: true

domains:
  api.anthropic.com:
    allowed_methods: [GET, POST]
    paths: []
    allowed_header_patterns:
      - "^X-(Api|Anthropic|Service|Claude|Stainless)-?"
    endpoints:
      - path: "^/v1/messages$"
        methods: [POST]
        max_body_kb: 1
      - path: "^/v1/usage$"
        methods: [GET]
        query_params:
          since: { type: string, max_length: 10, pattern: "^[0-9-]+$" }
        reject_unknown_params: true
      - path: "^/v1/files(/.*)?$"
        methods: [POST, GET, DELETE]
      - path: "^/v1/mcp_servers(/.*)?$"
        methods: [GET]
      - path: "^/mcp-registry/.+$"
        methods: [GET]
      - path: "^/api/event_logging(/.*)?$"
        methods: [POST]
        max_body_kb: 256
      - path: "^/api/.+$"
        methods: [GET, POST]
        max_body_kb: 1024
      - path: "^/legacy/needs-long-paths(/.+)?$"
        methods: [GET]
        defaults_override:
          max_path_segment_length: 500
          detect_base64_in_url: false
          detect_hex_blob_in_url: false
      - path: "^/audit/.+$"
        methods: [GET, POST]
        defaults_override:
          enforcement_mode: warn
  audit-host.example.com:
    allowed_methods: [GET]
    paths: []
    defaults_override:
      enforcement_mode: warn

  # Simulates what compile-policy.py emits for the split-by-method case :
  #   [GET]  per-path-host.example.com
  #     /readonly
  #   [POST] per-path-host.example.com
  #     /writable
  # After merge : host methods = {GET, POST}, BUT synthetic endpoints scope
  # methods per-path. So POST /readonly must 403 even though host has POST.
  per-path-host.example.com:
    allowed_methods: [GET, POST]
    paths: ["/readonly", "/writable"]
    endpoints:
      - path: "^/readonly$"
        methods: [GET]
        _origin: domains.txt
      - path: "^/writable$"
        methods: [POST]
        _origin: domains.txt
  docs.anthropic.com:
    allowed_methods: [GET, HEAD]
    paths: []
  statsig.com:
    allowed_methods: [POST]
    paths: []
    max_body_size_kb: 10
  github.com:
    allowed_methods: [GET, POST]
    paths: ["/anthropics/anthropic-sdk-python/info/refs", "/anthropics/anthropic-sdk-python/*"]
  marketplace.visualstudio.com:
    allowed_methods: [GET, POST]
    paths: []
    allowed_header_patterns:
      - "^X-(Vss|Tfs|Market|Msedge|Vsassets|Vscode|Microsoft|Ms)-"
    endpoints:
      - path: "^/_apis/public/gallery/extensionquery$"
        methods: [POST]
        max_body_kb: 64

runtime:
  policy_enforce_enabled: true
  passive_log_enabled: true
  format_detect_enabled: true
"""

tmpdir = tempfile.mkdtemp(prefix="addons-test-")
policy_path = os.path.join(tmpdir, "policy.compiled.yaml")
writes_log = os.path.join(tmpdir, "mitmproxy-writes.log")
blocks_log = os.path.join(tmpdir, "mitmproxy-blocks.log")
with open(policy_path, "w") as f:
    f.write(POLICY_YAML)

# Redirect file opens for the hardcoded production paths to our temp files,
# so we can import the addons unchanged.
_real_open = builtins.open
PATH_REDIRECT = {
    "/var/run/devcontainer-firewall/policy.compiled.yaml": policy_path,
    "/var/log/mitmproxy-writes.log": writes_log,
    "/var/log/mitmproxy-blocks.log": blocks_log,
}
def _patched_open(path, *a, **k):
    return _real_open(PATH_REDIRECT.get(path, path), *a, **k)
builtins.open = _patched_open

def _load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(ADDONS_DIR, f"{name}.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

policy_enforce = _load("policy_enforce")
format_detect  = _load("format_detect")
passive_log    = _load("passive_log")
stream_sse     = _load("stream_sse")

# --- Mock flow builder -------------------------------------------------------
class FakeQuery:
    def __init__(self, pairs):
        self.pairs = list(pairs)
    def items(self, multi=False):
        return list(self.pairs)

class FakeRequest:
    def __init__(self, host, method, path, content=b"", headers=None, query=None):
        self.host = host
        self.method = method
        self.path = path
        bare, _, qs = path.partition("?")
        self.url = f"https://{host}{path}"
        self.content = content
        hdrs = {"host": host}
        if headers:
            hdrs.update(headers)
        self.headers = FakeHeaders(hdrs)
        if query is None:
            qpairs = []
            if qs:
                for piece in qs.split("&"):
                    k, _, v = piece.partition("=")
                    qpairs.append((k, v))
            self.query = FakeQuery(qpairs)
        else:
            self.query = FakeQuery(query)

class FakeFlow:
    def __init__(self, req):
        self.request = req
        self.response = None

def mkflow(host, method, path, content=b"", headers=None, query=None):
    return FakeFlow(FakeRequest(host, method, path, content, headers, query))

# --- Assertions --------------------------------------------------------------
def case(desc, cond):
    global PASS, FAIL
    if cond:
        print(f"  ✔ {desc}")
        PASS += 1
    else:
        print(f"  ❌ {desc}")
        FAIL += 1

def assert_blocked(desc, flow, expected_reason_substr, expected_code=None):
    cond = (
        flow.response is not None
        and expected_reason_substr in flow.response.headers.get("X-Block-Reason", "")
        and (expected_code is None or flow.response.status_code == expected_code)
    )
    if not cond:
        if flow.response is None:
            print(f"      response=None (expected block on {expected_reason_substr!r})")
        else:
            print(f"      actual response={flow.response.status_code} reason={flow.response.headers.get('X-Block-Reason')!r}")
    case(desc, cond)

def assert_pass(desc, flow):
    cond = flow.response is None
    if not cond:
        print(f"      unexpected block: {flow.response.status_code} {flow.response.headers.get('X-Block-Reason')!r}")
    case(desc, cond)

# --- policy_enforce.py tests -------------------------------------------------
print("policy_enforce")

f = mkflow("api.anthropic.com", "POST", "/v1/messages", content=b"x" * 100)
policy_enforce.request(f)
assert_pass("POST /v1/messages within body limit -> pass", f)

f = mkflow("evil.example.com", "GET", "/")
policy_enforce.request(f)
assert_blocked("unknown host -> 403 host_not_in_policy", f, "host_not_in_policy", 403)

f = mkflow("api.anthropic.com", "DELETE", "/v1/messages")
policy_enforce.request(f)
assert_blocked("DELETE on api.anthropic.com -> 403 method", f, "method:DELETE", 403)

f = mkflow("api.anthropic.com", "POST", "/v1/messages", content=b"x" * (1024 * 1024 + 1))
policy_enforce.request(f)
assert_blocked("POST > max_body_kb=1 -> 413 body_too_large", f, "body_too_large", 413)

f = mkflow("api.anthropic.com", "GET", "/v1/usage?since=2026-01-01")
policy_enforce.request(f)
assert_pass("GET /v1/usage with valid query -> pass", f)

f = mkflow("api.anthropic.com", "GET", "/v1/usage?surprise=1")
policy_enforce.request(f)
assert_blocked("GET /v1/usage with unknown query (reject_unknown) -> 403", f, "unknown_query_param", 403)

f = mkflow("api.anthropic.com", "GET", "/v1/usage?since=BAD")
policy_enforce.request(f)
assert_blocked("GET /v1/usage with bad pattern -> 403 query_pattern", f, "query_pattern", 403)

# Subdomain match: cdn.statsig.com -> matches bare statsig.com
f = mkflow("cdn.statsig.com", "POST", "/track", content=b"x" * 500)
policy_enforce.request(f)
assert_pass("subdomain matches *.statsig.com bare entry -> pass", f)

# host-level max_body_size_kb
f = mkflow("statsig.com", "POST", "/track", content=b"x" * (10 * 1024 + 1))
policy_enforce.request(f)
assert_blocked("statsig.com POST > host_max_body -> 413", f, "host_body_too_large", 413)

# paths literal/glob (github.com)
f = mkflow("github.com", "GET", "/anthropics/anthropic-sdk-python/info/refs")
policy_enforce.request(f)
assert_pass("github.com literal path matches -> pass", f)

f = mkflow("github.com", "GET", "/anthropics/anthropic-sdk-python/anything")
policy_enforce.request(f)
assert_pass("github.com glob path /anthropics/anthropic-sdk-python/* matches -> pass", f)

f = mkflow("github.com", "GET", "/some-other-org/repo")
policy_enforce.request(f)
assert_blocked("github.com unmatched path -> 403 path_not_allowed", f, "path_not_allowed", 403)

# base64 in QUERY STRING (not path — path scans were removed because legit
# CDN/marketplace URLs trip false positives on long alphanumeric segments)
f = mkflow("docs.anthropic.com", "GET", "/?token=" + "a" * 80)
policy_enforce.request(f)
assert_blocked("base64-ish token in query string -> 403 base64_in_query", f, "base64_in_query", 403)

# Regression : long base64-alphabet path passes (segments individually < 50ch).
# Used to break VS Code Marketplace CDN, cf. diag-a2-paranoid.log.
f = mkflow("docs.anthropic.com", "GET", "/_apis/public/gallery/publisher/anthropic/extension/claude-code/manifest")
policy_enforce.request(f)
assert_pass("multi-segment alnum path passes (no false positive)", f)

# Path segment >= 50 chars of pure base64 alphabet -> blocked (#Q3 exfil gap)
f = mkflow("docs.anthropic.com", "GET", "/" + "a" * 60 + "/some-tail")
policy_enforce.request(f)
assert_blocked("/<60-alnum-segment>/ -> 403 base64_in_path_segment", f, "base64_in_path_segment", 403)

# Same with mid-path segment
f = mkflow("docs.anthropic.com", "GET", "/api/" + "B" * 80 + "/data")
policy_enforce.request(f)
assert_blocked("/api/<80-alnum>/data -> 403 base64_in_path_segment (mid-path)", f, "base64_in_path_segment", 403)

# Path with hyphens in segments must NOT trigger (false positive guard)
f = mkflow("docs.anthropic.com", "GET", "/anthropic-sdk-python/refs/heads/main/something-with-many-hyphens")
policy_enforce.request(f)
assert_pass("hyphenated path segments pass (real package paths)", f)

# Hex blob in path : segment must be >=100 hex but <=max_path_segment_length
# so the length check doesn't intercept first (use 100-char segment exactly).
f = mkflow("docs.anthropic.com", "GET", "/blobs/" + "f" * 100)
policy_enforce.request(f)
assert_blocked("/blobs/<100-hex> -> 403 hex_in_path_segment", f, "hex_in_path_segment", 403)

# Embedded base64 inside a larger segment (search, not fullmatch) -> blocked
f = mkflow("docs.anthropic.com", "GET", "/data/prefix" + "a" * 55 + "suffix")
policy_enforce.request(f)
assert_blocked("/data/prefix<55-alnum>suffix -> 403 base64_in_path_segment (substring search)", f, "base64_in_path_segment", 403)

# Path segment longer than max_path_segment_length (100) -> blocked even if
# it contains separators that would otherwise break the base64 regex
f = mkflow("docs.anthropic.com", "GET", "/data/" + "ab-cd-" * 25 + "extra")
policy_enforce.request(f)
assert_blocked("path segment > 100 chars (with hyphens) -> 403 path_segment_too_long", f, "path_segment_too_long", 403)

# Per-endpoint defaults_override : long segment + base64-looking content
# allowed on /legacy/needs-long-paths (override bumps limit to 500 + disables
# base64 detect) but blocked on any sibling endpoint of the same host.
f = mkflow("api.anthropic.com", "GET", "/legacy/needs-long-paths/" + "a" * 200)
policy_enforce.request(f)
assert_pass("/legacy/<200-alnum> passes (endpoint defaults_override relaxes both checks)", f)

# Sibling endpoint without override blocks the same long segment
f = mkflow("api.anthropic.com", "GET", "/v1/files/" + "a" * 200)
policy_enforce.request(f)
assert_blocked("sibling /v1/files/<200-alnum> blocked (no override on this endpoint)",
               f, "path_segment_too_long", 403)

# Per-host header allowlist : X-Vss-* PASSES on marketplace.visualstudio.com
f = mkflow("marketplace.visualstudio.com", "POST", "/_apis/public/gallery/extensionquery",
           content=b"{}", headers={"X-Vss-RequestContextId": "abc"})
policy_enforce.request(f)
assert_pass("X-Vss-* allowed on marketplace.visualstudio.com (per-host allowlist)", f)

# Same X-Vss-* BLOCKED on api.anthropic.com (allowlist is per-host)
f = mkflow("api.anthropic.com", "POST", "/v1/messages", content=b"x",
           headers={"X-Vss-Leak": "secret-data"})
policy_enforce.request(f)
assert_blocked("X-Vss-* blocked on api.anthropic.com (no per-host allowlist exemption)", f, "blocked_header", 403)

# Multi-header block : reason must list ALL offending headers in one shot
# (#Q2 — avoid reload-loop debugging where user widens allowlist one header at a time)
f = mkflow("api.anthropic.com", "POST", "/v1/messages", content=b"x",
           headers={"X-Leak-One": "a", "X-Leak-Two": "b", "X-Leak-Three": "c"})
policy_enforce.request(f)
multi_reason = f.response.headers.get("X-Block-Reason", "") if f.response else ""
case(f"multi blocked headers listed in one reason (got: {multi_reason!r})",
     f.response is not None
     and "X-Leak-One" in multi_reason
     and "X-Leak-Two" in multi_reason
     and "X-Leak-Three" in multi_reason)

# Anthropic-specific allowlist: x-api-key passes on api.anthropic.com
f = mkflow("api.anthropic.com", "POST", "/v1/messages", content=b"x",
           headers={"x-api-key": "sk-ant-xxx"})
policy_enforce.request(f)
assert_pass("x-api-key allowed on api.anthropic.com (case-insensitive match)", f)

# X-Claude-Code-Session-Id (real Claude Code CLI header) passes on Anthropic
f = mkflow("api.anthropic.com", "POST", "/v1/messages", content=b"x",
           headers={"X-Claude-Code-Session-Id": "sess-xxx"})
policy_enforce.request(f)
assert_pass("X-Claude-Code-Session-Id allowed on api.anthropic.com (^X-Claude- allowlist)", f)

# x-service-name (Claude Code telemetry header) passes on Anthropic
f = mkflow("api.anthropic.com", "POST", "/api/event_logging/v2/batch", content=b"{}",
           headers={"x-service-name": "claude-code"})
policy_enforce.request(f)
assert_pass("x-service-name + /api/event_logging endpoint allowed on api.anthropic.com", f)

# X-Stainless-* (Anthropic SDK metadata) passes on Anthropic (cf. user-reported
# "blocked_header:X-Stainless-Arch,X-Stainless-Lang,..." auth failure)
f = mkflow("api.anthropic.com", "POST", "/v1/messages", content=b"x",
           headers={
               "X-Stainless-Arch": "arm64",
               "X-Stainless-Lang": "js",
               "X-Stainless-OS": "Linux",
               "X-Stainless-Package-Version": "0.96.0",
               "X-Stainless-Retry-Count": "0",
           })
policy_enforce.request(f)
assert_pass("X-Stainless-* allowed on api.anthropic.com (SDK metadata)", f)

# Catch-all /api/.+ accepts known Claude Code endpoints (bootstrap, OAuth,
# feature flags, eval). All seen in firewall-blocks log round 3.
for path in [
    "/api/claude_code_grove",
    "/api/claude_code_penguin_mode",
    "/api/oauth/account/settings",
    "/api/claude_cli/bootstrap",
]:
    f = mkflow("api.anthropic.com", "GET", path)
    policy_enforce.request(f)
    assert_pass(f"GET {path} matches /api/.+ catch-all", f)

f = mkflow("api.anthropic.com", "POST", "/api/eval/sdk-zAZezfDKGoZuXXKe", content=b"{}")
policy_enforce.request(f)
assert_pass("POST /api/eval/<id> matches /api/.+ catch-all", f)

# MCP registry endpoints — Claude Code discovers MCP servers via these
f = mkflow("api.anthropic.com", "GET", "/v1/mcp_servers?limit=1000")
policy_enforce.request(f)
assert_pass("GET /v1/mcp_servers matches specific endpoint", f)

f = mkflow("api.anthropic.com", "GET", "/mcp-registry/v0/servers")
policy_enforce.request(f)
assert_pass("GET /mcp-registry/v0/servers matches /mcp-registry/.+ endpoint", f)

# Catch-all order test : /api/event_logging stays at its tight body cap
# because it's listed BEFORE the /api/.+ catch-all in the YAML
f = mkflow("api.anthropic.com", "POST", "/api/event_logging/v2/batch",
           content=b"x" * (300 * 1024))   # 300 KB > 256 KB event_logging cap
policy_enforce.request(f)
assert_blocked("/api/event_logging body 300KB > 256KB blocked (specific entry wins order)",
               f, "body_too_large", 413)

# --- enforcement_mode: warn (audit) ------------------------------------------
print("warn mode")

# Per-endpoint warn : /audit/* is in warn mode on api.anthropic.com.
# DELETE (host method violation) should LOG but let the request pass.
f = mkflow("api.anthropic.com", "DELETE", "/audit/whatever")
policy_enforce.request(f)
# In warn mode flow.response stays None (request would pass to upstream).
# Wait — DELETE check fires BEFORE endpoint match (method is host-level).
# So flow._enforcement_mode at that point is still host-level (block here).
# To test endpoint-level warn, we need a violation AFTER endpoint match
# (e.g. body too large, path segment, query schema).
case("DELETE on /audit (host method check) still blocks — endpoint mode not yet resolved",
     f.response is not None and "method:DELETE" in f.response.headers.get("X-Block-Reason", ""))

# Endpoint warn on a check that fires AFTER endpoint match : body too large
# (endpoint /audit/.+ has no max_body_kb explicitly so falls through)
# Actually need a check that fires AFTER endpoint resolution. Path segment
# is good : audit/<long segment> should warn (because endpoint /audit/.+
# matched AND enforcement_mode is warn).
f = mkflow("api.anthropic.com", "GET", "/audit/" + "a" * 200)  # 200 chars > 100
policy_enforce.request(f)
case("path_segment_too_long on /audit/ endpoint WARNS instead of blocks (request passes)",
     f.response is None)

# Whole-host warn : audit-host.example.com is in audit mode globally.
# DELETE (host method check) still fires the rule but in warn mode.
f = mkflow("audit-host.example.com", "DELETE", "/")
policy_enforce.request(f)
case("DELETE on audit-host warns (host-level enforcement_mode: warn)",
     f.response is None)

# But blocks log MUST still record the would-be-block entry
import json as _j2
warn_entries = []
if os.path.exists(blocks_log):
    with open(blocks_log) as bf:
        for line in bf:
            try:
                e = _j2.loads(line)
                if e.get("mode") == "warn":
                    warn_entries.append(e)
            except Exception:
                pass
case(f"warn-mode entries recorded with mode=warn in blocks log (got {len(warn_entries)} warns)",
     len(warn_entries) >= 2)

# Block mode (default) still blocks
f = mkflow("api.anthropic.com", "DELETE", "/v1/messages", content=b"x")
policy_enforce.request(f)
case("DELETE on non-warn endpoint still blocks (default enforcement_mode: block)",
     f.response is not None and "method:DELETE" in f.response.headers.get("X-Block-Reason", ""))

# --- per-path-method (synthetic endpoints from domains.txt path-method pairs) -
print("per-path-method")

# Host allows both GET and POST (union of [GET] and [POST] blocks), but
# synthetic endpoints scope methods per-path. GET on /writable must 403.
f = mkflow("per-path-host.example.com", "GET", "/writable")
policy_enforce.request(f)
assert_blocked("GET on POST-only synthetic endpoint /writable -> 403 endpoint_method",
               f, "endpoint_method:GET", 403)

# POST on /readonly must 403 (endpoint scoped to GET)
f = mkflow("per-path-host.example.com", "POST", "/readonly", content=b"x")
policy_enforce.request(f)
assert_blocked("POST on GET-only synthetic endpoint /readonly -> 403 endpoint_method",
               f, "endpoint_method:POST", 403)

# But the right method on the right path passes
f = mkflow("per-path-host.example.com", "GET", "/readonly")
policy_enforce.request(f)
assert_pass("GET on GET-allowed synthetic endpoint /readonly passes", f)

f = mkflow("per-path-host.example.com", "POST", "/writable", content=b"x")
policy_enforce.request(f)
assert_pass("POST on POST-allowed synthetic endpoint /writable passes", f)

# --- blocked_header full list in log (Fix #1) --------------------------------
print("blocked_header full log")

# Wipe blocks log for this section
if os.path.exists(blocks_log):
    os.unlink(blocks_log)

# Trigger blocked_header with > 5 headers — visible reason gets truncated
# to "+Nmore" but the log entry must contain ALL headers.
many_headers = {f"X-Leak-{i:02d}": "x" for i in range(8)}
f = mkflow("api.anthropic.com", "POST", "/v1/messages", content=b"x", headers=many_headers)
policy_enforce.request(f)

# Response header is capped (5 + Nmore)
visible = f.response.headers.get("X-Block-Reason", "") if f.response else ""
case(f"response X-Block-Reason caps at 5 + Nmore (got: {visible!r})",
     "+3more" in visible)

# But the log entry contains the FULL list
import json as _j3
last_entry = None
if os.path.exists(blocks_log):
    with open(blocks_log) as bf:
        for line in bf:
            try:
                last_entry = _j3.loads(line)
            except Exception:
                pass

logged_reason = (last_entry or {}).get("reason", "")
all_listed = all(f"X-Leak-{i:02d}" in logged_reason for i in range(8))
case(f"blocks.log entry lists ALL 8 headers (no +Nmore truncation)", all_listed)

# Endpoint trailing-slash regression : `/v1/files/` (with trailing slash) passes
f = mkflow("api.anthropic.com", "GET", "/v1/files/")
policy_enforce.request(f)
assert_pass("/v1/files/ (trailing slash) matches ^/v1/files(/.*)?$ regex", f)

# But x-api-key BLOCKED on marketplace.visualstudio.com (Anthropic-specific)
f = mkflow("marketplace.visualstudio.com", "POST", "/_apis/public/gallery/extensionquery",
           content=b"{}", headers={"x-api-key": "exfil-attempt"})
policy_enforce.request(f)
assert_blocked("x-api-key blocked on marketplace.visualstudio.com (not in its allowlist)", f, "blocked_header", 403)

# Bare X-Custom blocked everywhere
f = mkflow("docs.anthropic.com", "GET", "/", headers={"X-Custom": "leak"})
policy_enforce.request(f)
assert_blocked("X-Custom header -> 403 blocked_header (no host exempts it)", f, "blocked_header", 403)

# Case-insensitive header matching : `x-leak` (lowercase) still blocked
f = mkflow("docs.anthropic.com", "GET", "/", headers={"x-leak": "data"})
policy_enforce.request(f)
assert_blocked("lowercase x-* header still blocked (IGNORECASE)", f, "blocked_header", 403)

# --- format_detect.py tests --------------------------------------------------
print("format_detect")

f = mkflow("api.anthropic.com", "POST", "/v1/files", content=b"PK\x03\x04rest-of-zip")
format_detect.request(f)
assert_blocked("POST raw zip magic -> 403 archive_magic:zip", f, "archive_magic:zip", 403)

f = mkflow("api.anthropic.com", "POST", "/v1/files", content=b"\x1f\x8b" + b"y" * 100)
format_detect.request(f)
assert_blocked("POST gzip magic -> 403 archive_magic:gzip", f, "archive_magic:gzip", 403)

import base64 as _b64
zip_b64 = _b64.b64encode(b"PK\x03\x04" + b"A" * 500)
f = mkflow("api.anthropic.com", "POST", "/v1/files", content=b"prefix " + zip_b64 + b" suffix")
format_detect.request(f)
assert_blocked("POST base64-encoded zip -> 403 archive_in_base64:zip", f, "archive_in_base64:zip", 403)

f = mkflow("api.anthropic.com", "GET", "/v1/messages")
format_detect.request(f)
assert_pass("GET (non-write method) skipped by format_detect", f)

f = mkflow("api.anthropic.com", "POST", "/v1/messages", content=b'{"msg":"hello"}')
format_detect.request(f)
assert_pass("POST plain JSON not detected as archive", f)

# --- blocks log (cross-addon) ------------------------------------------------
print("blocks log")

# Wipe blocks log before this section
if os.path.exists(blocks_log):
    os.unlink(blocks_log)

# Trigger a block via policy_enforce
f = mkflow("evil.example.com", "GET", "/")
policy_enforce.request(f)
# Trigger a block via format_detect
f2 = mkflow("api.anthropic.com", "POST", "/v1/messages", content=b"PK\x03\x04zip")
format_detect.request(f2)

# Read blocks log
import json as _j
ok_entries, total = False, 0
addons_seen = set()
if os.path.exists(blocks_log):
    with open(blocks_log) as bf:
        for line in bf:
            try:
                e = _j.loads(line)
                addons_seen.add(e.get("addon"))
                total += 1
                if all(k in e for k in ("ts", "method", "host", "path", "code", "reason", "addon")):
                    ok_entries = True
            except Exception:
                pass
case(f"blocks log written with valid JSON entries (got {total} entries)", ok_entries and total >= 2)
case(f"blocks log includes both addons (got: {sorted(addons_seen)})",
     {"policy_enforce", "format_detect"}.issubset(addons_seen))

# --- stream_sse.py tests -----------------------------------------------------
print("stream_sse")

class FakeResponseHeaders:
    """Minimal stand-in for mitmproxy's response object in responseheaders hook."""
    def __init__(self, headers):
        self.headers = FakeHeaders(headers)
        self.stream = False

def mkresp_flow(content_type=None, transfer_encoding=None, content_length=None):
    headers = {}
    if content_type is not None:
        headers["content-type"] = content_type
    if transfer_encoding is not None:
        headers["transfer-encoding"] = transfer_encoding
    if content_length is not None:
        headers["content-length"] = content_length
    flow = FakeFlow(FakeRequest("api.anthropic.com", "POST", "/v1/messages"))
    flow.response = FakeResponseHeaders(headers)
    return flow

# SSE → stream
f = mkresp_flow(content_type="text/event-stream")
stream_sse.responseheaders(f)
case("text/event-stream response → flow.response.stream = True (Claude SSE)",
     f.response.stream is True)

# NDJSON → stream
f = mkresp_flow(content_type="application/x-ndjson")
stream_sse.responseheaders(f)
case("application/x-ndjson response → stream = True", f.response.stream is True)

# Chunked without Content-Length → stream
f = mkresp_flow(content_type="application/json", transfer_encoding="chunked")
stream_sse.responseheaders(f)
case("chunked+no-content-length response → stream = True", f.response.stream is True)

# Normal JSON with Content-Length → DON'T stream (default buffer behavior)
f = mkresp_flow(content_type="application/json", content_length="1234")
stream_sse.responseheaders(f)
case("application/json with Content-Length → stream = False (buffered)",
     f.response.stream is False)

# HTML response → DON'T stream
f = mkresp_flow(content_type="text/html; charset=utf-8")
stream_sse.responseheaders(f)
case("text/html → stream = False", f.response.stream is False)

# --- passive_log.py tests ----------------------------------------------------
print("passive_log")

# Wipe the log first
if os.path.exists(writes_log):
    os.unlink(writes_log)

f = mkflow("api.anthropic.com", "GET", "/v1/messages")
passive_log.request(f)
case("GET not logged", not os.path.exists(writes_log) or os.path.getsize(writes_log) == 0)

f = mkflow("api.anthropic.com", "POST", "/v1/messages", content=b"hello")
passive_log.request(f)
content = open(writes_log).read() if os.path.exists(writes_log) else ""
import json as _json
line_ok = False
try:
    line = content.strip().splitlines()[-1]
    entry = _json.loads(line)
    line_ok = (entry["method"] == "POST" and entry["host"] == "api.anthropic.com" and entry["size"] == 5)
except Exception as e:
    print(f"      parse error: {e}; raw: {content!r}")
case("POST appended one JSON line with expected fields", line_ok)

# --- mtime-based reload tests ------------------------------------------------
# Guards the zero-downtime reload mechanism : addons detect policy.compiled.yaml
# changes via os.stat().st_mtime_ns at the start of every request() and re-run
# _load_policy() when the mtime bumps.
#
# Run LAST so previous tests exercise the pristine POLICY loaded at import.
# Reset the mtime tracking to the tmpdir path so subsequent _reload_if_stale()
# calls stat the real fixture file instead of the production /var/run/... path
# (which doesn't exist in the test env — os.stat there fails and returns early).
print("mtime reload")

policy_enforce.POLICY_PATH = policy_path
policy_enforce._POLICY_MTIME_NS = os.stat(policy_path).st_mtime_ns
format_detect.POLICY_PATH = policy_path
format_detect._POLICY_MTIME_NS = os.stat(policy_path).st_mtime_ns

# Test C — perf guard : two requests without touching the file must not reload.
_load_calls = [0]
_orig_load = policy_enforce._load_policy
def _spy():
    _load_calls[0] += 1
    _orig_load()
policy_enforce._load_policy = _spy

f = mkflow("api.anthropic.com", "GET", "/v1/messages")
policy_enforce.request(f)
f = mkflow("api.anthropic.com", "GET", "/v1/messages")
policy_enforce.request(f)
case(f"no policy reload when mtime unchanged (perf guard) — spy count={_load_calls[0]}",
     _load_calls[0] == 0)

# Test A — mtime bump triggers reload : add a new domain to the YAML on disk,
# next request() must recognize it (proving _reload_if_stale ran + _load_policy
# rebuilt DOMAINS). Insert BEFORE `runtime:` so the new key stays under
# `domains:` (appending after `runtime:` would nest under runtime instead).
# open("w") rewrites → mtime bumps (nsec resolution on ext4).
_new_domain_yaml = """  test-reload-domain.example.com:
    allowed_methods: [GET]
    paths: []

runtime:"""
new_yaml = POLICY_YAML.replace("runtime:", _new_domain_yaml, 1)
with open(policy_path, "w") as fh:
    fh.write(new_yaml)

f = mkflow("test-reload-domain.example.com", "GET", "/")
policy_enforce.request(f)
case("mtime bump triggers reload — new domain now honored", f.response is None)
case(f"reload was actually invoked (spy fired) — count={_load_calls[0]}",
     _load_calls[0] == 1)

# Test B — corrupt YAML on reload preserves last-known-good globals.
# The domain we added in Test A must still be recognized (POLICY not wiped).
# Use unclosed bracket : PyYAML raises ParserError (unlike "garbage text"
# which is parsed as a plain scalar → schema mismatch, different path).
with open(policy_path, "w") as fh:
    fh.write("[unclosed")

f = mkflow("test-reload-domain.example.com", "GET", "/")
policy_enforce.request(f)
case("corrupt YAML on reload : old globals preserved (domain still known)",
     f.response is None)

policy_enforce._load_policy = _orig_load

# Test D — format_detect mtime bump : toggling block_archive_magic in the YAML
# must flip BLOCK_MAGIC on next request(). Verifies the symmetric refactor
# actually rewires format_detect's globals (not just policy_enforce's).
with open(policy_path, "w") as fh:
    fh.write(POLICY_YAML.replace("block_archive_magic: true", "block_archive_magic: false"))

f = mkflow("api.anthropic.com", "POST", "/v1/files", content=b"PK\x03\x04rest-of-zip")
format_detect.request(f)
case("format_detect mtime bump : BLOCK_MAGIC=false → zip magic passes",
     f.response is None)

# --- Summary -----------------------------------------------------------------
print()
print(f"{PASS} passed, {FAIL} failed")
sys.exit(0 if FAIL == 0 else 1)
PY
