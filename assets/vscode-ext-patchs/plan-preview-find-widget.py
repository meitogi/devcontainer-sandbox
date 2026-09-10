#!/usr/bin/env python3
# @patch-category: ux
# @patch-files: extension.js
# @patch-sentinel: enableFindWidget:!0
# @patch-summary: Enables the native find widget (Cmd+F) in the read-only plan preview
#   panel.
"""
Enables the native Cmd+F / Ctrl+F find widget inside the Claude Code
extension's `claudePlanPreview` webview (the read-only viewer that
displays a plan in Plan mode).

Anthropic's `class kj { static create(...) }` in extension.js constructs
the webview with these options :

    createWebviewPanel("claudePlanPreview", K,
        {viewColumn:N, preserveFocus:!0},
        {enableScripts:!0, retainContextWhenHidden:!0})

VS Code webviews accept a documented `enableFindWidget` field on the
options object that branches the native find-bar (matching the same
Cmd+F shortcut users expect in editors and other webviews) — Anthropic
just doesn't opt in. Adding `enableFindWidget:!0` is a one-token patch.

Strategy
--------
- Regex ancred on the stable string `"claudePlanPreview"` (the viewType,
  part of the public webview identity — extremely unlikely to churn).
- Backreferences capture the minified names of `require("vscode")`
  (currently `BK0`), the title parameter (currently `K`), and the
  viewColumn parameter (currently `N`), so the patch survives version
  bumps that rename bindings.
- Idempotence via presence check for `enableFindWidget:!0` within 300
  chars after the anchor.

Exit codes
----------
- 0 : applied or already patched
- 1 : regex miss / file missing (red banner via _common.banner)

Usage
-----
    plan-preview-find-widget.py [EXT_DIR]

If EXT_DIR is omitted, auto-discovers the latest
~/.vscode-server/extensions/anthropic.claude-code-*-{arch} directory.
"""

import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import YELLOW, GREEN, BOLD, RESET, banner, resolve_ext_dir, check_files


IMPACT_LINES = [
    "→ The native find widget (Cmd+F / Ctrl+F) will NOT be available",
    "  in the Claude Code plan-preview webview. Users must scroll",
    "  manually to locate text in the rendered plan.",
    "Likely cause: CLAUDE_CODE_VERSION was bumped and the minified",
    "  createWebviewPanel shape drifted. Review and update the regex in",
    "  .devcontainer/claude/vscode-ext-patchs/plan-preview-find-widget.py.",
]


def patch_enable_find_widget(content):
    """Add `enableFindWidget:!0` to the webview options passed to
    `createWebviewPanel("claudePlanPreview", ...)`.
    """
    anchor = '"claudePlanPreview"'
    idx = content.find(anchor)
    if idx != -1 and 'enableFindWidget:!0' in content[idx:idx + 300]:
        print(f"{YELLOW}[find-widget]{RESET} extension.js — already patched")
        return content

    pat = re.compile(
        r'([\w$]+)\.window\.createWebviewPanel\("claudePlanPreview",([\w$]+),'
        r'\{viewColumn:([\w$]+),preserveFocus:!0\},'
        r'\{enableScripts:!0,retainContextWhenHidden:!0\}\)'
    )
    m = pat.search(content)
    if not m:
        banner("PLAN-PREVIEW FIND-WIDGET PATCH FAILED",
               "extension.js: createWebviewPanel(\"claudePlanPreview\", ...) "
               "pattern not found",
               IMPACT_LINES)
        sys.exit(1)

    vs, title, vc = m.groups()
    replacement = (
        f'{vs}.window.createWebviewPanel("claudePlanPreview",{title},'
        f'{{viewColumn:{vc},preserveFocus:!0}},'
        f'{{enableScripts:!0,retainContextWhenHidden:!0,enableFindWidget:!0}})'
    )
    new_content = pat.sub(replacement, content, count=1)
    print(f"{GREEN}[find-widget]{RESET} extension.js — enableFindWidget:!0 "
          f"injected (vscode={vs})")
    return new_content


def main():
    ext_dir = resolve_ext_dir(sys.argv)
    check_files(ext_dir, ["extension.js"])
    js = ext_dir / "extension.js"

    print(f"Patching Claude Code extension at: {ext_dir}")

    content = js.read_text()
    original = content
    content = patch_enable_find_widget(content)

    if content != original:
        js.write_text(content)

    print(f"{GREEN}{BOLD}✓ plan-preview-find-widget patch complete{RESET}")


if __name__ == "__main__":
    main()
