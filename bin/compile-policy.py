#!/usr/bin/env python3
"""
compile-policy.py — devcontainer firewall policy compiler.

Reads (from --config-dir, default /etc/devcontainer-firewall):
  domains.txt           allowlist baseline, extended syntax (5 formats)
  domains.local.txt     local overrides (!disable + redefine)
  policy.d/*.yaml       committed advanced rules, one file per host
  policy.local.d/*.yaml local advanced overrides, one file per host

Emits (atomic .tmp + rename):
  --out-dnsmasq PATH    flat `server=/host/8.8.8.8` + `ipset=/host/allowed-domains`
  --out-policy  PATH    merged policy.compiled.yaml (consumed by mitmproxy addons in A2)

Other modes:
  --parse-only FILE [FILE...] [--json]    parse files, emit entries (testing)
  --list-hosts  FILE [FILE...]            flat deduped hostnames (used by init-firewall.sh shim)

Syntax:
  Format 1: bare host                 -> docs.anthropic.com
  Format 2: methods inline            -> [GET,POST] api.anthropic.com
  Format 3: multi-line indented paths -> [*] api.anthropic.com\n  /v1/messages
  Format 4: single-line path          -> POST api.anthropic.com/v1/messages
  Format 5: wildcard host/path        -> [POST] *.statsig.com / [GET] host/repos/foo/*
  Override: !disable host  or  redefine line in domains.local.txt

Indent: EXACTLY 2 spaces for Format 3 paths. Tab / 1 / 3+ spaces -> parse error.
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

def _require_yaml():
    """Lazy import: yaml is only needed in compile mode (policy.d/ + emission)."""
    try:
        import yaml
        return yaml
    except ImportError:
        print("FATAL: python3-yaml not installed (apt install python3-yaml)", file=sys.stderr)
        sys.exit(2)


METHODS_VALID = {"GET", "HEAD", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "*"}
SINGLE_METHOD_RE = re.compile(r'^(GET|HEAD|POST|PUT|DELETE|PATCH|OPTIONS)\s+(\S.*)$', re.IGNORECASE)
BRACKET_RE = re.compile(r'^\[([^\]]*)\]\s*(\S.*)$')
DISABLE_RE = re.compile(r'^!disable\s+(\S+)\s*$')
HOSTNAME_RE = re.compile(r'^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$')
INDENT = "  "  # exactly 2 spaces

DEFAULTS = {
    # `block` (default) returns 403/413/431 with X-Block-Reason as before ;
    # `warn` lets the request through to upstream but still appends a JSON
    # line to /var/log/mitmproxy-blocks.log tagged `"mode":"warn"`. Use this
    # to discover what a workload actually needs (paths, headers, methods)
    # before tightening the policy. Override per-host or per-endpoint via
    # `defaults_override.enforcement_mode`.
    "enforcement_mode": "block",
    "allowed_methods": ["GET", "HEAD", "OPTIONS"],
    "max_query_string_length": 256,
    "max_path_length": 512,
    "max_path_segment_length": 100,    # single /-delimited segment ceiling
    "max_url_total_length": 2048,
    "max_header_count": 30,
    "max_header_value_length": 4096,
    # Header pattern blocklist — applied to every request header by the addon.
    # Tight by default : only universal proxy standards in the negative-lookahead
    # allowlist. Vendor-specific prefixes (X-Vss-, X-GitHub-, X-Anthropic-, …)
    # are added PER-HOST via `allowed_header_patterns` in policy.d/<host>.yaml
    # so an attacker can't reuse e.g. `X-Vss-Leak` against api.anthropic.com to
    # exfiltrate — the prefix is only valid on Microsoft Marketplace hosts.
    # The addon compiles these with re.IGNORECASE.
    "blocked_header_patterns": [
        "^X-(?!Forwarded|Real-IP|Request-Id)",
    ],
    "detect_base64_in_url": True,
    "detect_base64_in_headers": True,
    "detect_hex_blob_in_url": True,
    "detect_internal_path_leak": True,
    "block_archive_magic": True,
    "block_archive_in_base64": True,
}

RUNTIME_DEFAULTS = {
    "policy_enforce_enabled": True,
    "passive_log_enabled": True,
    "format_detect_enabled": True,
    "warn_on_local_overrides": True,
}


def strip_inline_comment(line: str) -> str:
    """Strip from first `#` onwards. Preserves leading whitespace (for indent detection)."""
    idx = line.find('#')
    return line[:idx] if idx >= 0 else line


def validate_hostname(host: str) -> bool:
    """Validate bare hostname (no leading `*.`, no path). Allows dotted segments."""
    if not host or '..' in host or host.startswith('.') or host.endswith('.'):
        return False
    return bool(HOSTNAME_RE.match(host))


def parse_methods(methods_str: str, line_no: int, errors: list) -> list | None:
    """Parse `GET,POST` or `*` or `get, post` (case-insensitive). Returns list or None on error."""
    methods_str = methods_str.strip()
    if methods_str == "":
        errors.append({"line": line_no, "message": "empty methods bracket []"})
        return None
    if methods_str == "*":
        return ["*"]
    out = []
    for tok in methods_str.split(','):
        tok = tok.strip().upper()
        if not tok:
            continue
        if tok not in METHODS_VALID:
            errors.append({"line": line_no, "message": f"unknown method {tok!r}"})
            return None
        out.append(tok)
    if not out:
        errors.append({"line": line_no, "message": "no valid methods in bracket"})
        return None
    return out


def split_host_path(rest: str) -> tuple[str, str]:
    """Split `host` or `host/path` -> (host, path-with-leading-slash-or-empty)."""
    if '/' in rest:
        host, _, path = rest.partition('/')
        return host.strip(), '/' + path.strip()
    return rest.strip(), ''


def parse_file(path: str | Path) -> tuple[list, list]:
    """Parse a domains.txt-style file.

    Returns (entries, errors).
    Each entry is a dict with keys: host, methods, paths, disable, line, host_raw.
    `host` is the bare hostname (wildcard `*.` stripped); `host_raw` keeps the original.
    `methods=[]` for !disable entries. `paths=[]` if no path specified.
    """
    entries: list = []
    errors: list = []
    try:
        with open(path) as f:
            lines = f.readlines()
    except FileNotFoundError:
        return entries, errors

    current = None  # open Format 3 block (host header awaiting indented paths)

    def flush():
        nonlocal current
        if current is not None:
            entries.append(current)
            current = None

    for i, raw_with_nl in enumerate(lines):
        line_no = i + 1
        raw = raw_with_nl.rstrip('\n').rstrip('\r')
        stripped = strip_inline_comment(raw)

        # Blank or comment-only -> skip (does NOT terminate a Format 3 block)
        if stripped.strip() == "":
            continue

        # Indented line -> Format 3 path (only valid inside an open block)
        if raw and raw[0] in (' ', '\t'):
            indent_part = raw[:len(raw) - len(raw.lstrip(' \t'))]
            if indent_part != INDENT:
                errors.append({
                    "line": line_no,
                    "message": f"invalid indent (expected exactly 2 spaces, got {indent_part!r})",
                })
                continue
            if current is None:
                errors.append({"line": line_no, "message": "indented path outside any host block"})
                continue
            path_str = stripped.strip()
            if not path_str.startswith('/'):
                errors.append({"line": line_no, "message": f"path must start with /, got {path_str!r}"})
                continue
            current['paths'].append(path_str)
            continue

        # Not indented -> flush any open block
        flush()
        line = stripped.strip()
        if not line:
            continue

        # !disable host
        m = DISABLE_RE.match(line)
        if m:
            host_raw = m.group(1)
            host_bare = host_raw[2:] if host_raw.startswith('*.') else host_raw
            if not validate_hostname(host_bare):
                errors.append({"line": line_no, "message": f"invalid hostname in !disable: {host_raw!r}"})
                continue
            entries.append({
                "host": host_bare, "host_raw": host_raw,
                "methods": [], "paths": [], "disable": True, "line": line_no,
            })
            continue

        # Methods detection: brackets first, then bare-method prefix
        methods = None
        rest = line
        m = BRACKET_RE.match(line)
        if m:
            methods = parse_methods(m.group(1), line_no, errors)
            if methods is None:
                continue
            rest = m.group(2).strip()
        else:
            m = SINGLE_METHOD_RE.match(line)
            if m:
                methods = [m.group(1).upper()]
                rest = m.group(2).strip()

        if methods is None:
            methods = ["GET"]  # default

        host_part, path_part = split_host_path(rest)
        host_bare = host_part[2:] if host_part.startswith('*.') else host_part
        if not validate_hostname(host_bare):
            errors.append({"line": line_no, "message": f"invalid hostname: {host_part!r}"})
            continue

        if path_part:
            # Format 4: single-line path, no Format 3 block follows
            entries.append({
                "host": host_bare, "host_raw": host_part,
                "methods": methods, "paths": [path_part],
                "disable": False, "line": line_no,
            })
        else:
            # Format 1/2/3 header: open a block; if next line is not indented, it flushes as Format 1/2.
            current = {
                "host": host_bare, "host_raw": host_part,
                "methods": methods, "paths": [],
                "disable": False, "line": line_no,
            }

    flush()
    return entries, errors


def merge_entries(entries: list) -> dict:
    """Merge same-host entries: methods union, paths concat.

    Also tracks `_path_method_pairs` — the per-entry (path, methods) tuples —
    so emit_compiled_policy can synthesize per-path-method endpoints. Without
    this, a user splitting their domains.txt blocks like

        [GET]  api.example.com
          /v1/usage
        [POST] api.example.com
          /v1/messages

    would see the methods unioned to {GET, POST} on BOTH paths (i.e. GET on
    /v1/messages would erroneously be allowed). The synthetic-endpoint pass
    preserves per-path method scoping.

    Returns {host: {allowed_methods: set, paths: list, _path_method_pairs: list}}."""
    hosts: dict = {}
    for e in entries:
        if e['disable']:
            continue
        h = e['host']
        pairs = [(p, list(e['methods'])) for p in e['paths']]
        if h not in hosts:
            hosts[h] = {
                "allowed_methods": set(e['methods']),
                "paths": list(e['paths']),
                "_path_method_pairs": list(pairs),
            }
        else:
            hosts[h]["allowed_methods"] |= set(e['methods'])
            hosts[h]["paths"].extend(e['paths'])
            hosts[h]["_path_method_pairs"].extend(pairs)
    return hosts


def load_policy_d(directory: Path, hosts: dict, overrides: list, source_label: str) -> None:
    """Deep-merge top-level keys from policy.d/<host>.yaml into hosts[<host>]. Records overrides."""
    if not directory.is_dir():
        return
    yaml = _require_yaml()
    for yf in sorted(directory.glob('*.yaml')):
        host = yf.stem
        if host not in hosts:
            print(f"WARN: {source_label}/{yf.name} references {host!r} not in domains.txt — ignored", file=sys.stderr)
            continue
        try:
            with open(yf) as f:
                data = yaml.safe_load(f) or {}
        except yaml.YAMLError as exc:
            print(f"FATAL: {source_label}/{yf.name} invalid YAML: {exc}", file=sys.stderr)
            sys.exit(2)
        if not isinstance(data, dict):
            print(f"FATAL: {source_label}/{yf.name} must be a YAML mapping", file=sys.stderr)
            sys.exit(2)
        for k, v in data.items():
            hosts[host][k] = v
        overrides.append({"host": host, "source": f"{source_label}/{yf.name}", "action": "merge"})


def apply_local(entries_local: list, hosts: dict, overrides: list) -> None:
    """Apply domains.local.txt: !disable removes, redefine UPDATES paths/
    methods/_path_method_pairs in place. It does NOT wipe other keys
    (`endpoints`, `blocked_paths`, `allowed_header_patterns`, …) that were
    loaded earlier from policy.d/. Without that preservation, a local
    redefine of e.g. `[GET] github.com /...` silently drops policy.d's POST
    endpoint for /git-upload-pack and breaks `git ls-remote`."""
    for e in entries_local:
        h = e['host']
        if e['disable']:
            if h in hosts:
                del hosts[h]
                overrides.append({"host": h, "source": "domains.local.txt", "action": "disable"})
            else:
                overrides.append({"host": h, "source": "domains.local.txt", "action": "disable-nop"})
            continue
        pairs = [(p, list(e['methods'])) for p in e['paths']]
        if h not in hosts:
            hosts[h] = {}
        hosts[h]["allowed_methods"] = set(e['methods'])
        hosts[h]["paths"] = list(e['paths'])
        hosts[h]["_path_method_pairs"] = pairs
        overrides.append({"host": h, "source": "domains.local.txt", "action": "redefine"})


def atomic_write(path: str | Path, content: str) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.tmp')
    with open(tmp, 'w') as f:
        f.write(content)
    os.rename(tmp, path)


def emit_dnsmasq(hosts: dict, out_path: str, ipset_name: str = "allowed-domains") -> None:
    lines = [
        "# Auto-generated by compile-policy.py — do not edit",
        f"# Generated-at: {datetime.now(timezone.utc).isoformat()}",
        "",
    ]
    for h in sorted(hosts.keys()):
        lines.append(f"server=/{h}/8.8.8.8")
        lines.append(f"ipset=/{h}/{ipset_name}")
    atomic_write(out_path, '\n'.join(lines) + '\n')


def _path_to_endpoint_regex(path: str) -> str:
    """Convert a domains.txt path (literal, optional trailing `*`) to the
    regex form used in `policy.compiled.yaml.domains[h].endpoints[].path`.

    Matching is anchored. Trailing `*` becomes `.*` so `/anthropics/*` matches
    `/anthropics/foo/bar`. Inputs are otherwise treated as literal."""
    if path.endswith("*"):
        return "^" + re.escape(path[:-1]) + ".*$"
    return "^" + re.escape(path) + "$"


def _regex_literal_prefix(pattern: str) -> str:
    """Extract the literal-character prefix of a regex. Strips a leading `^`
    anchor and stops at the first metacharacter / character class /
    quantifier / group. Resolves single-char `\\<x>` escapes (e.g. `\\.` → `.`)
    so `^/v1/files(/.*)?$` → `/v1/files`, `^/_apis/.../.gallerycdn`
    → `/_apis/.../gallerycdn` (after the dot escape).

    Used to test whether a policy.d endpoint regex falls under a domains.txt
    wildcard path : compare the prefix against the literal portion of the
    domains.txt path (stripped of trailing `*`)."""
    if pattern.startswith("^"):
        pattern = pattern[1:]
    out: list = []
    i = 0
    while i < len(pattern):
        c = pattern[i]
        if c == "\\" and i + 1 < len(pattern):
            out.append(pattern[i + 1])
            i += 2
            continue
        if c in r".*+?()[]{}|$":
            break
        out.append(c)
        i += 1
    return "".join(out)


def _domains_txt_covers_policy_d(policy_d_path: str, pairs: list) -> bool:
    """True iff the policy.d regex's coverage overlaps a domains.txt path :
      - wildcard `P*` (or `P/*`) : policy.d's literal prefix must equal `P`
        normalized OR start with `P/` — covers `/api/event_logging(/.*)?$`
        under domains.txt `/api/*`
      - literal `P`              : the policy.d REGEX must match `P` directly —
        covers `^/v1/(usage|models|orgs)(/.*)?$` matching literal `/v1/usage`
    Both tests use `.rstrip("/")` to absorb trailing-slash mismatches between
    the policy.d prefix and the wildcard base."""
    try:
        regex = re.compile(policy_d_path)
    except re.error:
        return False
    policy_d_prefix = _regex_literal_prefix(policy_d_path).rstrip("/")
    for path, _methods in pairs:
        if path.endswith("*"):
            base = path[:-1].rstrip("/")
            if policy_d_prefix == base or policy_d_prefix.startswith(base + "/"):
                return True
        else:
            if regex.match(path):
                return True
    return False


def synthesize_per_path_endpoints(hosts: dict) -> None:
    """Walk `_path_method_pairs` per host and append synthetic endpoints to
    `hosts[h]["endpoints"]` — but ONLY for paths not already covered by an
    explicit policy.d endpoint regex. Same-path entries with different
    methods get UNIONED so a path declared in two blocks (one [GET], one
    [POST]) accepts both methods on that single path.

    Dedup rule : a synthetic candidate is dropped if any policy.d regex
    `.match()`es the literal path (or `path-stripped-of-trailing-* + "a"`
    for wildcard paths). The policy.d entry already enforces ON that path
    via the addon's first-match rule, so adding the synthetic would be
    dead code AND visually duplicate the compiled YAML.

    Synthetic endpoints are tagged `_origin: domains.txt` for diagnostics."""
    for h, hp in hosts.items():
        pairs = hp.pop("_path_method_pairs", None)
        if not pairs:
            continue

        existing_endpoints = list(hp.get("endpoints") or [])
        existing_regexes = []
        for ep in existing_endpoints:
            try:
                existing_regexes.append(re.compile(ep["path"]))
            except (re.error, KeyError, TypeError):
                continue

        # Union methods for paths declared multiple times in domains.txt.
        path_methods: dict = {}
        for path, methods in pairs:
            existing = path_methods.setdefault(path, set())
            existing.update(methods)

        # Build the synthetic-dedup test : skip synthesizing a path if any
        # policy.d regex already matches a representative form of it.
        synthetic = []
        for path, methods_set in path_methods.items():
            test_str = (path[:-1] + "a") if path.endswith("*") else path
            covered = any(r.match(test_str) for r in existing_regexes)
            if covered:
                continue
            synthetic.append({
                "path": _path_to_endpoint_regex(path),
                "methods": sorted(methods_set),
                "_origin": "domains.txt",          # tag for diagnostics
            })

        # Orphan warn : every policy.d endpoint should fall UNDER a path
        # already declared in domains.txt. The check uses the policy.d
        # regex's literal prefix (extracted by _regex_literal_prefix) and
        # compares against domains.txt paths (literal or wildcard). This
        # is a soft warn — orphan endpoints are still emitted for compat,
        # but the user is asked to either add the prefix to domains.txt
        # (preferred — domains.txt is the canonical access list) or
        # remove the orphan from policy.d.
        for ep in existing_endpoints:
            ep_path = ep.get("path", "")
            if not ep_path or _domains_txt_covers_policy_d(ep_path, pairs):
                continue
            print(
                f"WARN: policy.d/{h}.yaml endpoint {ep_path!r} doesn't "
                f"fall under any path declared in domains.txt — kept "
                f"standalone for compat, but consider adding the equivalent "
                f"prefix to domains.txt (literal or wildcard).",
                file=sys.stderr,
            )

        hp["endpoints"] = existing_endpoints + synthetic

        # Union endpoint methods into host-level allowed_methods. Without
        # this, a domains.local.txt redefine declaring only [GET] on a
        # host that has policy.d POST endpoints (e.g. github.com
        # /anthropics/*.git/git-upload-pack) blocks POST at the host-level
        # fast-path before endpoint matching ever runs. Safe : the endpoint
        # regex remains the gatekeeper for which paths accept POST.
        ep_methods: set = set()
        for ep in hp["endpoints"]:
            for m in (ep.get("methods") or []):
                ep_methods.add(m.upper())
        if ep_methods:
            hp["allowed_methods"] = (hp.get("allowed_methods") or set()) | ep_methods


def emit_compiled_policy(hosts: dict, overrides: list, out_path: str) -> None:
    # Generate per-path-method endpoints from domains.txt pairs BEFORE
    # serialising. This is the bridge between domains.txt's compact syntax
    # and the addon's endpoint-regex enforcement.
    synthesize_per_path_endpoints(hosts)

    compiled = {
        "defaults": dict(DEFAULTS),
        "domains": {},
        "runtime": dict(RUNTIME_DEFAULTS),
    }
    for h in sorted(hosts.keys()):
        entry = dict(hosts[h])
        if isinstance(entry.get("allowed_methods"), set):
            entry["allowed_methods"] = sorted(entry["allowed_methods"])
        compiled["domains"][h] = entry
    compiled["runtime"]["_overrides_applied"] = overrides

    header = (
        "# Auto-generated by compile-policy.py — do not edit\n"
        "# Sources: domains.txt + domains.local.txt + policy.d/ + policy.local.d/\n"
        f"# Generated-at: {datetime.now(timezone.utc).isoformat()}\n"
    )
    yaml = _require_yaml()
    body = yaml.safe_dump(compiled, sort_keys=False, default_flow_style=False, allow_unicode=True)
    atomic_write(out_path, header + body)


def mode_parse_only(args) -> int:
    all_entries, all_errors = [], []
    for f in args.files:
        e, err = parse_file(f)
        all_entries.extend(e)
        all_errors.extend(err)
    if args.json:
        print(json.dumps({"entries": all_entries, "errors": all_errors}, indent=2))
    else:
        for e in all_entries:
            tag = "DISABLE" if e['disable'] else ""
            print(f"  {tag:8} host={e['host']:40} methods={e['methods']} paths={e['paths']} (line {e['line']})")
        for err in all_errors:
            print(f"ERROR line {err['line']}: {err['message']}", file=sys.stderr)
    return 1 if all_errors else 0


def mode_list_hosts(args) -> int:
    """Emit deduped bare hosts after applying !disable from any layer."""
    all_entries, all_errors = [], []
    for f in args.files:
        e, err = parse_file(f)
        for entry in e:
            entry['src'] = str(f)
        all_entries.extend(e)
        all_errors.extend(err)
    if all_errors:
        for err in all_errors:
            print(f"ERROR line {err['line']}: {err['message']}", file=sys.stderr)
        return 2
    # Apply !disable with the same rule as mode_compile: entries from the
    # disabling file itself survive (disable + redeclare in one file), every
    # other file's entries for that host are removed.
    disabled_by: dict = {}
    for e in all_entries:
        if e['disable']:
            disabled_by.setdefault(e['host'], set()).add(e['src'])
    hosts = {e['host'] for e in all_entries
             if not e['disable']
             and (e['host'] not in disabled_by or e['src'] in disabled_by[e['host']])}
    for h in sorted(hosts):
        print(h)
    return 0


def mode_compile(args) -> int:
    config_dir = Path(args.config_dir)
    domains_txt = config_dir / 'domains.txt'
    domains_local = config_dir / 'domains.local.txt'
    domains_d = config_dir / 'domains.d'
    policy_d = config_dir / 'policy.d'
    policy_local_d = config_dir / 'policy.local.d'

    committed, err1 = parse_file(domains_txt)
    local, err2 = parse_file(domains_local)
    for e in committed:
        e['src'] = 'domains.txt'

    # F2: load every .txt under domains.d/ alphabetically. These files are
    # additive on top of domains.txt baseline — same-host entries merge
    # (methods union + paths concat) via merge_entries(). The base image ships
    # its own baseline as domains.d/00-base.txt (overlaid by the bake);
    # per-ecosystem files are committed by the project under domains.d/.
    domains_d_entries: list = []
    domains_d_errors: list = []
    if domains_d.is_dir():
        for txt in sorted(domains_d.glob('*.txt')):
            e, err = parse_file(txt)
            for entry in e:
                entry['src'] = f'domains.d/{txt.name}'
            domains_d_entries.extend(e)
            domains_d_errors.extend(err)

    if err1 or err2 or domains_d_errors:
        for e in err1 + err2 + domains_d_errors:
            print(f"PARSE ERROR (line {e['line']}): {e['message']}", file=sys.stderr)
        return 2

    overrides: list = []
    # Committed-layer !disable — the project opt-out from base-image entries.
    # Rule: a `!disable host` in any committed file (domains.txt, domains.d/*)
    # removes that host's entries from every OTHER file ; non-disable entries
    # in the disabling file itself survive, so one file can both drop the
    # inherited definition and redeclare a narrower one. The local layer keeps
    # its own semantics (apply_local: disable removes, redefine updates).
    pool = committed + domains_d_entries
    disabled_by: dict = {}
    for e in pool:
        if e['disable']:
            disabled_by.setdefault(e['host'], set()).add(e['src'])
    if disabled_by:
        for h in sorted(disabled_by):
            for src in sorted(disabled_by[h]):
                overrides.append({"host": h, "source": src, "action": "disable"})
        pool = [e for e in pool
                if not e['disable']
                and (e['host'] not in disabled_by or e['src'] in disabled_by[e['host']])]

    hosts = merge_entries(pool)
    load_policy_d(policy_d, hosts, overrides, "policy.d")

    # Snapshot AFTER policy.d, BEFORE local layers. Hosts added by
    # apply_local() or policy.local.d/ end up in the "local" partition;
    # baseline hosts stay in "base" even if redefined by the local layer.
    base_hosts_snapshot = set(hosts.keys()) if args.split_local else None

    apply_local(local, hosts, overrides)
    load_policy_d(policy_local_d, hosts, overrides, "policy.local.d")

    if args.split_local:
        remaining = set(hosts.keys())
        local_hosts_set = remaining - base_hosts_snapshot
        base_hosts_set = remaining & base_hosts_snapshot
        base_dict = {h: hosts[h] for h in base_hosts_set}
        local_dict = {h: hosts[h] for h in local_hosts_set}
        if args.out_dnsmasq_base:
            emit_dnsmasq(base_dict, args.out_dnsmasq_base, ipset_name="allowed-domains-base")
        if args.out_dnsmasq_local:
            emit_dnsmasq(local_dict, args.out_dnsmasq_local, ipset_name="allowed-domains-local")
    else:
        if args.out_dnsmasq:
            emit_dnsmasq(hosts, args.out_dnsmasq)
    if args.out_policy:
        emit_compiled_policy(hosts, overrides, args.out_policy)

    # Log summary for boot output (non-machine-consumed; the YAML _overrides_applied is the source of truth)
    #
    # One line, not one per override. Measured on a real boot: a workspace with
    # a populated domains.local.txt printed 120 lines here — by a wide margin
    # the largest block of the whole start sequence, for a fact that fits in a
    # sentence. Nothing reads these lines: the compiled policy carries
    # _overrides_applied, which IS the source of truth, and this comment said so
    # before the list was trimmed.
    #
    # DEBUG=1 brings the detail back, the same switch devc-hook uses for xtrace
    # (bin/devc-hook), so there is one way to ask this image for more output.
    if overrides:
        by_action: dict[str, int] = {}
        for o in overrides:
            by_action[o['action']] = by_action.get(o['action'], 0) + 1
        breakdown = ', '.join(f"{n} {action}" for action, n in sorted(by_action.items()))
        print(
            f"compile-policy: {len(overrides)} override(s) applied ({breakdown})"
            f"{'' if os.environ.get('DEBUG') == '1' else ' — DEBUG=1 to list them'}",
            file=sys.stderr,
        )
        if os.environ.get('DEBUG') == '1':
            for o in overrides:
                print(f"  {o['action']:10} {o['host']:40} ({o['source']})", file=sys.stderr)
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--parse-only', action='store_true', help='parse files and emit entries (testing)')
    p.add_argument('--list-hosts', action='store_true', help='emit deduped bare hosts from files')
    p.add_argument('--json', action='store_true', help='JSON output (used with --parse-only)')
    p.add_argument('--config-dir', default=os.environ.get('FIREWALL_CONFIG_DIR', '/etc/devcontainer-firewall'),
                   help='firewall config root (default: $FIREWALL_CONFIG_DIR or /etc/devcontainer-firewall)')
    p.add_argument('--out-dnsmasq', default=None, help='write dnsmasq conf to this path (compile mode)')
    p.add_argument('--out-policy', default=None, help='write policy.compiled.yaml to this path (compile mode)')
    p.add_argument('--split-local', action='store_true',
                   help='emit dnsmasq in 2 files with distinct ipsets (base + local) — basic-mode reload')
    p.add_argument('--out-dnsmasq-base', default=None,
                   help='dnsmasq conf for baseline hosts (used with --split-local)')
    p.add_argument('--out-dnsmasq-local', default=None,
                   help='dnsmasq conf for local-layer hosts (used with --split-local)')
    p.add_argument('files', nargs='*', help='files to parse (for --parse-only / --list-hosts)')
    args = p.parse_args()

    if args.parse_only and args.list_hosts:
        print("FATAL: --parse-only and --list-hosts are mutually exclusive", file=sys.stderr)
        return 2

    if args.parse_only:
        if not args.files:
            print("FATAL: --parse-only requires at least one file path", file=sys.stderr)
            return 2
        return mode_parse_only(args)

    if args.list_hosts:
        if not args.files:
            print("FATAL: --list-hosts requires at least one file path", file=sys.stderr)
            return 2
        return mode_list_hosts(args)

    # Default: compile mode
    return mode_compile(args)


if __name__ == '__main__':
    sys.exit(main())
