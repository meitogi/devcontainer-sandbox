#!/usr/bin/env python3
# @patch-category: notify
# @patch-files: extension.js
# @patch-sentinel: notify-queue-uri-workspace-v2
# @patch-summary: Teaches the extension's URI handler to focus a target workspace before
#   revealing a session.
#   1: session var    (e.g. "_", "b", "I")
#   2: URLSearchParams var (e.g. "b", "_", "R")
#   3: prompt var     (e.g. "w", "v")
#   4: vscode alias   (e.g. "ke", "Se", "R0")
"""
Patches the Claude Code VS Code extension `handleUri` for `/open` to accept
two new query params on top of the existing `session` and `prompt` :

    workspace   URI of the target workspace (typically `vscode-remote://
                dev-container+<hex>/workspace`, URL-encoded). If provided
                and it doesn't match the current window's workspace, the
                ext focuses the target workspace via `vscode.openFolder`,
                then re-dispatches the URI without the workspace param.
                VS Code's global UriHandlerService then delivers it to
                the (now-focused) target window, whose Claude Code ext
                does the normal panel reveal.

    sleep       ms to wait after `openFolder` resolves before the
                re-dispatch. Optional. Use only if the `await` on
                `openFolder` returns before the WM focus swap is
                effective (e.g. fullscreen Space transitions on macOS).

Behavior — three branches
-------------------------
- No `workspace` param                       → historical behavior (compat).
- `workspace` matches current window's URI   → historical behavior.
- `workspace` mismatches current             → openFolder + optional sleep
                                                + openExternal follow-up.

Callsite example (single `open -a`)
-----------------------------------
    open -a "Visual Studio Code" \\
        "vscode://anthropic.claude-code/open?workspace=<url-encoded-uri>&session=<uuid>&sleep=200"

Strategy
--------
Anchor on the exact minified /open case shape. Capture the 4 minified
identifiers (session var, URLSearchParams var, prompt var, vscode alias)
via backrefs so the patch survives version bumps that rename them.

Idempotent : marker `notify-queue-uri-workspace-v1` embedded as a JS
comment inside the replacement block ; presence = skip.

Exit codes
----------
- 0 : applied or already patched
- 1 : regex miss / file missing (red banner via _common.banner)

Usage
-----
    handle-uri-workspace.py [EXT_DIR]

Auto-discovers latest `~/.vscode-server/extensions/anthropic.claude-code-*-<arch>`
if EXT_DIR is omitted.
"""

import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import RED, YELLOW, GREEN, BOLD, RESET, banner, resolve_ext_dir, check_files


MARKER = "notify-queue-uri-workspace-v2"
MARKER_V1 = "notify-queue-uri-workspace-v1"

IMPACT_LINES = [
    "→ The single-URI form",
    "    vscode://anthropic.claude-code/open?workspace=…&session=…",
    "  will fall through to the historical behavior (workspace param",
    "  silently ignored). The two-step `open -a` workflow keeps",
    "  working — this patch is purely additive.",
    "Likely cause: CLAUDE_CODE_VERSION bumped and the minified /open",
    "  case shape drifted. Review the regex in",
    "  .devcontainer/claude/vscode-ext-patchs/handle-uri-workspace.py.",
]


# Matches the current minified /open case, capturing:
#   1: session var    (e.g. "_", "b", "I")
#   2: URLSearchParams var (e.g. "b", "_", "R")
#   3: prompt var     (e.g. "w", "v")
#   4: session-id validation guard, verbatim — empty before 2.1.258, and
#      `if(x!==void 0&&!SH(x))return;` from 2.1.258 on. Matched loosely so a
#      future variant still parses, and re-emitted untouched.
#   5: vscode alias   (e.g. "ke", "Se", "R0")
PATTERN = re.compile(
    r'case"/open":\{'
    r'let ([\w$]+)=([\w$]+)\.get\("session"\)\?\?void 0,'
    r'([\w$]+)=\2\.get\("prompt"\)\?\?void 0;'
    r'((?:if\([^;{}]*\)return;)?)'
    r'([\w$]+)\.commands\.executeCommand\('
    r'"claude-vscode\.primaryEditor\.open",\1,\3\);'
    r'return\}'
)


def build_replacement(match):
    """Compose the new /open case body preserving the captured identifiers.

    Injected locals are underscore-prefixed (_ws, _sl, _t, _c, _f, _r, _e)
    to avoid collision with the one-letter minified names in the outer
    scope. Same convention as the existing `_tg` used by
    icon-fix-open-in-current-panel.
    """
    S = match.group(1)  # session var — reused verbatim
    B = match.group(2)  # URLSearchParams
    P = match.group(3)  # prompt var
    G = match.group(4)  # session-id validation guard (may be empty)
    V = match.group(5)  # vscode alias

    return (
        f'case"/open":{{'
        f'/*{MARKER}*/'
        f'let {S}={B}.get("session")??void 0,'
        f'{P}={B}.get("prompt")??void 0,'
        f'_ws={B}.get("workspace")??void 0,'
        f'_sl=parseInt({B}.get("sleep")??"0",10)||0;'
        # Anthropic's own session-id validation, re-emitted verbatim and kept
        # ahead of every branch so an invalid id is rejected the same way it
        # was before the patch.
        f'{G}'
        # Branch 1: no workspace hint → historical behavior.
        f'if(!_ws){{'
        f'{V}.commands.executeCommand("claude-vscode.primaryEditor.open",{S},{P});'
        f'return}}'
        # Normalize external OS-scheme wrapper (`vscode://vscode-remote/<auth>/<path>`)
        # to internal form (`vscode-remote://<auth>/<path>`) so Uri.parse yields
        # the same shape as `workspaceFolders[0].uri`. Without this, comparison
        # never matches AND openFolder receives an invalid folder scheme.
        f'if(_ws.startsWith("vscode://vscode-remote/"))'
        f'_ws="vscode-remote://"+_ws.slice(23);'
        # Branch 2: workspace matches current window → historical behavior.
        f'let _t={V}.Uri.parse(_ws),'
        f'_c={V}.workspace.workspaceFolders?.[0]?.uri;'
        f'if(_c&&_c.scheme===_t.scheme&&_c.authority===_t.authority&&_c.path===_t.path){{'
        f'{V}.commands.executeCommand("claude-vscode.primaryEditor.open",{S},{P});'
        f'return}}'
        # Branch 3: mismatch → focus target workspace, then re-dispatch URI
        # without the workspace param. VS Code's UriHandlerService routes
        # the follow-up to the now-focused target window.
        f'(async()=>{{try{{'
        f'await {V}.commands.executeCommand("vscode.openFolder",_t,{{forceReuseWindow:false}});'
        f'if(_sl>0)await new Promise(_r=>setTimeout(_r,_sl));'
        f'let _f="vscode://anthropic.claude-code/open?session="+encodeURIComponent({S}??"")'
        f'+({P}?"&prompt="+encodeURIComponent({P}):"");'
        f'await {V}.env.openExternal({V}.Uri.parse(_f))'
        f'}}catch(_e){{}}}})();'
        f'return}}'
    )


V1_STRIP_PATTERN = re.compile(
    r'case"/open":\{/\*' + MARKER_V1 + r'\*/'
    r'let ([\w$]+)=([\w$]+)\.get\("session"\)\?\?void 0,'
    r'([\w$]+)=\2\.get\("prompt"\)\?\?void 0,'
    r'_ws=\2\.get\("workspace"\)\?\?void 0,'
    r'_sl=parseInt\(\2\.get\("sleep"\)\?\?"0",10\)\|\|0;'
    r'if\(!_ws\)\{([\w$]+)\.commands\.executeCommand'
    r'\("claude-vscode\.primaryEditor\.open",\1,\3\);return\}'
    r'.*?'
    r'\}\)\(\);return\}',
    re.DOTALL,
)


def strip_v1_injection(content):
    """Revert the v1 injected block to the original /open case shape so the
    v2 patch can be applied cleanly on top. The v1 shape lacked the
    external-URI-scheme normalization, which caused Uri.parse to yield a
    different scheme than workspaceFolders[0].uri — the comparison never
    matched and openFolder received an invalid folder URI (reload / error
    depending on VS Code behavior)."""
    m = V1_STRIP_PATTERN.search(content)
    if not m:
        return content
    S, B, P, V = m.groups()
    original_shape = (
        f'case"/open":{{'
        f'let {S}={B}.get("session")??void 0,'
        f'{P}={B}.get("prompt")??void 0;'
        f'{V}.commands.executeCommand("claude-vscode.primaryEditor.open",{S},{P});'
        f'return}}'
    )
    print(f"{YELLOW}[0/1]{RESET} extension.js handleUri /open — v1 injection detected, "
          f"reverting to original shape before v2 apply")
    return V1_STRIP_PATTERN.sub(original_shape, content, count=1)


def patch_handle_uri(content):
    if MARKER in content:
        print(f"{YELLOW}[1/1]{RESET} extension.js handleUri /open — already patched (v2 marker present)")
        return content

    content = strip_v1_injection(content)

    m = PATTERN.search(content)
    if not m:
        banner("HANDLE-URI-WORKSPACE PATCH FAILED",
               "extension.js: /open case pattern not found",
               IMPACT_LINES)
        sys.exit(1)

    S, B, P, G, V = m.groups()
    new_content = PATTERN.sub(build_replacement, content, count=1)
    print(f"{GREEN}[1/1]{RESET} extension.js handleUri /open — applied "
          f"(session={S}, params={B}, prompt={P}, vscode={V}, "
          f"guard={'yes' if G else 'none'})")
    return new_content


def main():
    ext_dir = resolve_ext_dir(sys.argv)
    check_files(ext_dir, ["extension.js"])
    js = ext_dir / "extension.js"

    print(f"Patching Claude Code extension at: {ext_dir}")

    content = js.read_text()
    original = content
    content = patch_handle_uri(content)

    if content != original:
        js.write_text(content)

    print(f"{GREEN}{BOLD}✓ handle-uri-workspace patch complete{RESET}")


if __name__ == "__main__":
    main()
