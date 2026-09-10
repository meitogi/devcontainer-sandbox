#!/usr/bin/env python3
# @patch-category: fix
# @patch-files: package.json
# @patch-files: extension.js
# @patch-sentinel: notify-queue-rename-session-nofile-v1
# @patch-summary: Restores first-prompt tab auto-rename, broken since 2.1.205 by a check
#   that reads a transcript file not yet on disk.
"""
Fixes the first-prompt auto-rename path silently broken from v2.1.205
onwards by an over-aggressive `if(!s)return!0;` defensive check in
`Session.renameSession()` inside extension.js. That check treats "session
transcript file not yet on disk" (the DETERMINISTIC case on first prompt
in v2.1.205+, since the CLI now batches queue-op + attachments + first
user message into a single deferred flush ~4s after channelId assignment)
as "session already has a customTitle" (skip).

Symptom (deterministic, not intermittent)
-----------------------------------------
Fresh session opened via `+` in the Claude webview, paste + Enter :

- Webview → ext `generate_session_title` (dispatched OK)
- SDK CLI returns a valid title (~2s later)
- Webview → ext `rename_session(sessionId, title, onlyIfNoCustomTitle=true)`
- Ext calls `settings.renameSession(...)` which reads the transcript file
- **File does NOT exist yet** — CLI hasn't flushed. Empirical measurement
  on v2.1.207 : file birth ~4s after first queue-op timestamp, vs ~180ms
  on v2.1.145 (immediate flush).
- 207 shape: `let s=await fF(n); if(!s) return !0;` → skipped=true → webview
  receives {skipped:true} → `if(!g.skipped) this.summary.value = u` branch
  NOT taken → no reactive `renameTab` emit → tab title stays on fallback
  (the truncated first prompt, e.g. "# Session C07 — GR2 flag…").

Fix strategy — retry-poll + fallback write
------------------------------------------
Rather than immediately falling through to appendFile (which pre-creates
the file, inverting the natural record order into
`ai-title,queue-op,queue-op,user-msg`), we WAIT for the CLI to flush its
own first records first — preserving the natural order
`queue-op,queue-op,user-msg,...,ai-title`.

Before (205+/207) :
    let s=await fF(n);
    if(!s)return!0;
    if(Rs(s.tail,"customTitle")||Rs(s.head,"customTitle"))return!0;

After :
    let s=await fF(n);/*<marker>*/
    let _w=0;
    while(!s && _w < 10000) {
        await new Promise(r => setTimeout(r, 100));
        _w += 100;
        s = await fF(n);
    }
    if(s && (Rs(s.tail,"customTitle")||Rs(s.head,"customTitle"))) return !0;
    // s falsy after timeout → fall through to appendFile (creates file,
    // 145 fallback semantics — auto-rename never silent-skips).

Budget rationale — 10 s covers 99.9 % of observed flush lag (empirical
v2.1.145: ~180 ms; v2.1.207: ~4 s; large-paste + plan-mode worst case
< 8 s in the wild). Poll interval 100 ms = 100 max readdir syscalls,
negligible cost. On the fast path (file already exists at first read,
which will be the norm ~2 s after our fix propagates) we do exactly one
`fF` call — same cost as pre-patch behaviour.

Version applicability
---------------------
- v2.1.145 : the buggy `if(!s)return!0;` guard does NOT exist. Script
  detects no match and no marker, prints an INFO line, exits 0.
- v2.1.205 / v2.1.207 (and later, until Anthropic renames again) : regex
  matches once, replaces once, marker inserted for idempotence.

Strategy
--------
- Anchor : the ENTIRE Anthropic-side guard sequence (`let s=await fF(n);
  if(!s)return!0; if(Rs(s.tail,"customTitle")||Rs(s.head,"customTitle"))
  return!0;`). Regex captures all 4 minified names (`s`, `fF`, `n`, `Rs`)
  via `\w+` backrefs to survive minor bumps.
- Idempotence : marker `notify-queue-rename-session-nofile-v1` embedded as
  `/*marker*/` right after the `let s=await fF(n);`.
- 145-safety : no match AND no marker AND version < 2.1.205 → clean exit 0
  with a YELLOW "not applicable" line. Any other combination of miss+no-
  marker → red banner + exit 1 (means the shape drifted, needs review).

Exit codes
----------
- 0 : applied, already patched, or version not applicable (145)
- 1 : regex miss on an affected version (shape drift → needs review)

Usage
-----
    rename-session-restore-empty-file-fallthrough.py [EXT_DIR]

If EXT_DIR is omitted, auto-discovers the latest
~/.vscode-server/extensions/anthropic.claude-code-*-{arch} directory.
"""

import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import RED, YELLOW, GREEN, BOLD, RESET, banner, resolve_ext_dir, check_files


MARKER = "notify-queue-rename-session-nofile-v1"

IMPACT_LINES = [
    "→ Fresh sessions opened via `+` (or any first-prompt path) on",
    "  v2.1.205 and later will NOT get an auto-generated tab title.",
    "  The webview trigger fires and the SDK CLI generates the title,",
    "  but Session.renameSession() returns skipped=true because the",
    "  transcript file hasn't been flushed yet at that moment. The",
    "  webview's summary.value update is then skipped, so the reactive",
    "  `renameTab` effect never emits and the tab stays on the fallback",
    "  title (truncated first prompt).",
    "Likely cause: CLAUDE_CODE_VERSION was bumped and the guard shape",
    "  around Session.renameSession's `let s=await <fn>(n);if(!s)...`",
    "  drifted. Inspect vendor/anthropic.claude-code/v<VER>/pretty/",
    "  extension.js in `async renameSession(z, K, V)` (or the current",
    "  minified equivalent) and update the regex accordingly.",
]


def parse_version(pkg_path):
    """Return (major, minor, patch) for the extension's package.json.

    Defensive parse: any component that isn't a plain int falls through to
    a very-old sentinel (0, 0, 0) so we treat unknown versions as "affected"
    and let the regex do the discrimination.
    """
    try:
        p = json.loads(pkg_path.read_text())
        return tuple(int(x) for x in p["version"].split("."))
    except (KeyError, ValueError, json.JSONDecodeError):
        return (0, 0, 0)


def patch_remove_empty_file_early_return(content):
    """Replace the `if(!s)return!0;` early skip with a bounded retry-poll
    that waits for the CLI to flush the session transcript before deciding.

    Anchor (v2.1.205 / v2.1.207 shape) :
        let s=await fF(n);
        if(!s)return!0;
        if(Rs(s.tail,"customTitle")||Rs(s.head,"customTitle"))return!0;

    Post-patch :
        let s=await fF(n);/*notify-queue-rename-session-nofile-v1*/
        let _w=0;
        while(!s&&_w<10000){await new Promise(r=>setTimeout(r,100));_w+=100;s=await fF(n);}
        if(s&&(Rs(s.tail,"customTitle")||Rs(s.head,"customTitle")))return!0;

    Timeout — 10 000 ms budget with 100 ms polls (max 100 stat syscalls,
    cheap). Empirical observations : file birth 180 ms on 145, ~4 s on
    207. 10 s covers observed worst-case + margin. On timeout we fall
    through to the `appendFile` below, creating the file (145 fallback)
    rather than silent-skipping — the auto-rename always fires.
    """
    if MARKER in content:
        print(f"{YELLOW}[rename-session-nofile]{RESET} extension.js — already patched")
        return content, "already-patched"

    pat = re.compile(
        r'let ([\w$]+)=await ([\w$]+)\(([\w$]+)\);'
        r'if\(!\1\)return!0;'
        r'if\(([\w$]+)\(\1\.tail,"customTitle"\)\|\|\4\(\1\.head,"customTitle"\)\)return!0;'
    )
    m = pat.search(content)
    if not m:
        return content, "no-match"

    s_var, fF_fn, n_var, Rs_fn = m.groups()
    replacement = (
        f'let {s_var}=await {fF_fn}({n_var});/*{MARKER}*/'
        f'let _w=0;'
        f'while(!{s_var}&&_w<10000){{'
            f'await new Promise(r=>setTimeout(r,100));'
            f'_w+=100;'
            f'{s_var}=await {fF_fn}({n_var});'
        f'}}'
        f'if({s_var}&&({Rs_fn}({s_var}.tail,"customTitle")'
        f'||{Rs_fn}({s_var}.head,"customTitle")))return!0;'
    )
    new_content = pat.sub(replacement, content, count=1)
    print(f"{GREEN}[rename-session-nofile]{RESET} extension.js — inserted retry-poll "
          f"(s={s_var}, load={fF_fn}, path={n_var}, has-field={Rs_fn}, budget=10s)")
    return new_content, "applied"


def main():
    ext_dir = resolve_ext_dir(sys.argv)
    check_files(ext_dir, ["package.json", "extension.js"])
    pkg = ext_dir / "package.json"
    js = ext_dir / "extension.js"

    print(f"Patching Claude Code extension at: {ext_dir}")
    version = parse_version(pkg)
    affected = version >= (2, 1, 205)
    print(f"  extension version: {'.'.join(str(x) for x in version)} "
          f"({'affected' if affected else 'not affected'})")

    content = js.read_text()
    original = content
    content, status = patch_remove_empty_file_early_return(content)

    if status == "no-match":
        if not affected:
            print(f"{YELLOW}[rename-session-nofile]{RESET} extension.js — "
                  f"guard not present on this version (pre-2.1.205), skipping")
            return
        banner("RENAME-SESSION NOFILE PATCH FAILED",
               "extension.js: renameSession `let s=await ...; if(!s) return !0;` "
               "guard pattern not found (expected on 2.1.205+)",
               IMPACT_LINES)
        sys.exit(1)

    if content != original:
        js.write_text(content)

    print(f"{GREEN}{BOLD}✓ rename-session-restore-empty-file-fallthrough patches complete{RESET}")


if __name__ == "__main__":
    main()
