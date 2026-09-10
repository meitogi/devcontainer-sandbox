#!/usr/bin/env python3
# @patch-category: notify
# @patch-files: extension.js
# @patch-sentinel: /*__NOTIFY_QUEUE_AUTHORITY_WRITER_v1__*/
# @patch-summary: Writes the container's remote authority to the notify queue so a
#   notification can focus the right window.
"""
Patches the Claude Code VS Code extension to write the container's
remote authority string to `<workspace>/.devcontainer/notify/queue/.authority`
at extension load, so the notify-queue hook can produce a `launchUrl`
on the JSONL queue line and the notify-app consumer's `--on-click`
body-click routing focuses the emitting VS Code window on user click.

The cache lives on the bind-mounted workspace so the file is visible
from the host (debug via `cat` on host, no `docker exec` needed) and
survives container rebuilds — the extension rewrites it at every
activation regardless, but persistence gives the notify daemon (host-
side, may start before Claude Code activates) a fighting chance to
read it on cold boot.

Why
---
The devcontainer authority (`dev-container+<hex>`) is the only piece
of state that VS Code needs to route a `vscode-remote://` URL back to
the correct window. Everything else on the launch URL is deterministic
from the workspace path. Without the authority, the notify daemon's
`--on-click focus:open-a://Visual Studio Code/<launchUrl>` binding
either doesn't fire (empty URL → no `--on-click` arg passed) or
targets an approximate URL that reloads the active window instead of
focusing the target one.

The container has no organic source for this authority — it's a
host-side extension concept. The hook has two heuristic fallbacks
(History scan, env-based reconstruction) but neither is 100% reliable
across all setups (fresh boot with empty History → History fallback
misses ; non-Docker-Desktop context → reconstruction guesses wrong).

This patch closes the loop by lifting the authority directly from
VS Code's own API — `vscode.workspace.workspaceFolders[0].uri.authority`
— at extension load, and writing it to the cache path the hook already
reads. Ground truth, cross-platform, zero guess.

Strategy
--------
Prepend a self-contained IIFE to extension.js. The IIFE :

  1. Requires `vscode`, `fs`, `path` inside a try/catch — all three
     are guaranteed available in the extension host process, but the
     try/catch means a future breakage in either can never brick the
     extension.
  2. Reads `vscode.workspace.workspaceFolders[0].uri.authority` and
     writes it to `<workspaceFsPath>/.devcontainer/notify/queue/.authority`
     if it looks like `dev-container+<hex>`. Uses `mkdirSync(recursive)`
     to survive a fresh clone where the queue dir doesn't yet exist.
     Immediate attempt covers the common case where the extension
     loads after the workspace is already open.
  3. On miss, arms a 200ms poll (capped at 30s) so the authority is
     captured whenever the workspace does become available. Cheap
     (few hundred kb of code, event-loop friendly).

Same PRELUDE approach as navigator-pending-migration-fix — no anchor
regex needed, survives version bumps as long as `require('vscode')`
stays the module API (stable across 3+ years of VS Code).

Idempotent via the sentinel marker MARKER : re-running finds the
marker at the head of extension.js and short-circuits.

Exit codes
----------
- 0 : applied or already patched
- 1 : extension.js missing (red banner via _common.banner)
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import YELLOW, GREEN, BOLD, RESET, resolve_ext_dir, check_files


MARKER = "/*__NOTIFY_QUEUE_AUTHORITY_WRITER_v1__*/"

# Kept as a one-line IIFE so a `git diff` on extension.js shows a
# single prepended line. The `\` line continuations below concatenate
# at build time into a single JS statement.
PRELUDE = MARKER + (
    "(function(){"
      "try{"
        "var v=require('vscode'),f=require('fs'),p=require('path');"
        "var w=function(){"
          "try{"
            "var wf=v.workspace.workspaceFolders;"
            "if(!wf||!wf[0]||!wf[0].uri)return false;"
            "var a=wf[0].uri.authority;"
            "if(!a||a.indexOf('dev-container+')!==0)return false;"
            "var d=p.join(wf[0].uri.fsPath,'.devcontainer/notify/queue');"
            "f.mkdirSync(d,{recursive:true});"
            "f.writeFileSync(p.join(d,'.authority'),a);"
            "return true;"
          "}catch(e){}"
          "return false;"
        "};"
        "if(!w()){"
          "var t=setInterval(function(){if(w())clearInterval(t);},200);"
          "setTimeout(function(){clearInterval(t);},30000);"
        "}"
      "}catch(e){}"
    "})();"
)

IMPACT_LINES = [
    "→ Notify body-click routing will fall back to the hook's",
    "  best-effort resolvers (History scan → reconstruction).",
    "  In the worst case (fresh boot + non-Docker-Desktop context)",
    "  the `launchUrl` may be absent or wrong, making the desktop",
    "  notif click a silent no-op instead of focusing VS Code.",
    "Likely cause: extension.js structure changed such that a top-of-",
    "  file prelude no longer runs before other code that touches",
    "  `require('vscode')`. Verify by checking",
    "  `<workspace>/.devcontainer/notify/queue/.authority` after a",
    "  fresh boot ; if absent after 30s, re-inspect this patch against",
    "  the installed extension.js head.",
]


def patch_extension_js(js_path):
    content = js_path.read_text()
    if MARKER in content:
        print(f"{YELLOW}[1/1]{RESET} extension.js — already patched")
        return
    js_path.write_text(PRELUDE + content)
    print(f"{GREEN}[1/1]{RESET} extension.js — authority writer IIFE prepended")


def main():
    ext_dir = resolve_ext_dir(sys.argv)
    check_files(ext_dir, ["extension.js"])

    print(f"Patching Claude Code extension at: {ext_dir}")
    patch_extension_js(ext_dir / "extension.js")
    print(f"{GREEN}{BOLD}✓ authority-writer patch complete{RESET}")


if __name__ == "__main__":
    main()
