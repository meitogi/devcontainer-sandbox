#!/usr/bin/env python3
# @patch-category: fix
# @patch-files: extension.js
# @patch-sentinel: /*__VSCODE_NAVIGATOR_PENDING_MIGRATION_FIX_v1__*/
# @patch-critical: true
# @patch-summary: Neutralises VS Code's throwing navigator getter, without which the
#   extension crashes on activation.
"""
Patches the Claude Code VS Code extension to neutralize VS Code's
`navigator` PendingMigration getter on globalThis before any other
code in the bundle runs.

Why
---
Recent VS Code installs `globalThis.navigator` as a PendingMigration
getter that throws on any access (typeof included), to push extensions
to migrate their environment-detection code now that Node has
`navigator` as a real global. Claude Code 2.1.x bundles a Zod version
whose schema construction touches `navigator` at module load, which
trips the throw and crashes the extension on activation.

Stack from the live log:
    PendingMigrationError: navigator is now a global in nodejs
        at get (extensionHostProcess.js:805:7210)
        at new ZodObject (anthropic.claude-code-*/extension.js:166:73934)

Strategy
--------
Prepend a tiny IIFE to extension.js that redefines
`globalThis.navigator` as a plain `value: undefined` property. Every
subsequent `typeof navigator` becomes a primitive `"undefined"` lookup
(no getter call → no throw), and every `navigator.*` access is already
guarded in the bundle by `typeof navigator !== "undefined"` checks.
Verified : the bundle reads `.userAgent` (x9) and `.product` (x4),
all behind a `typeof`/`&&` guard. Setting navigator to undefined is
the Node-environment behavior the code was written for, so all guards
skip the browser-only branches correctly.

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


MARKER = "/*__VSCODE_NAVIGATOR_PENDING_MIGRATION_FIX_v1__*/"

PRELUDE = (
    MARKER
    + "try{Object.defineProperty(globalThis,'navigator',"
    + "{value:undefined,writable:true,configurable:true});}catch(e){}"
)

IMPACT_LINES = [
    "→ Claude Code extension will crash on activation with",
    "  PendingMigrationError: navigator is now a global in nodejs.",
    "  The chat panel fails to load, the icon flashes and dies.",
    "Likely cause: CLAUDE_CODE_VERSION was bumped to a build whose",
    "  bundled Zod no longer touches `navigator` at module load,",
    "  making this patch obsolete. Verify by checking the",
    "  « Claude VSCode » output channel for the PendingMigrationError",
    "  trace ; if absent after a fresh install, drop this script.",
]


def patch_extension_js(js_path):
    content = js_path.read_text()
    if MARKER in content:
        print(f"{YELLOW}[1/1]{RESET} extension.js — already patched")
        return
    js_path.write_text(PRELUDE + content)
    print(f"{GREEN}[1/1]{RESET} extension.js — navigator getter neutralized")


def main():
    ext_dir = resolve_ext_dir(sys.argv)
    check_files(ext_dir, ["extension.js"])

    print(f"Patching Claude Code extension at: {ext_dir}")
    patch_extension_js(ext_dir / "extension.js")
    print(f"{GREEN}{BOLD}✓ navigator-pending-migration-fix patch complete{RESET}")


if __name__ == "__main__":
    main()
