#!/usr/bin/env python3
# @patch-category: ux
# @patch-files: package.json
# @patch-files: extension.js
# @patch-sentinel: Primary Editor (Active Column)
# @patch-summary: Adds a 'primary' window location that opens Claude in the active editor
#   column instead of splitting.
"""
Patches the Claude Code VS Code extension to route every Claude panel
entry-point through the active editor column, with the new tab landing at
the end of the active tab group.

Patches applied (6 steps)
-------------------------
[1/6] package.json — add "primary" value to `claudeCode.preferredLocation`
      enum (+ enumDescription).
[2/6] extension.js editor.open guard — skip `setPreferredLocation("panel")`
      when the setting is "primary", so opening a session doesn't mutate
      the user's choice.
[3/6] extension.js editor.openLast — when the setting is "primary", route
      to the new `primaryEditor.open` command (icon, status bar item,
      command palette all go through this).
[4/6] extension.js primaryEditor.open — resolve the active column from
      `tabGroups.activeTabGroup.viewColumn` (an integer) instead of the
      symbolic `ViewColumn.Active`, so re-clicking doesn't split.
[5/6] extension.js "+" button handler — branch on preferredLocation:
      route the `new_conversation_tab` message to `primaryEditor.open`
      when "primary" (active column, full chrome), else fall back to
      the unmodified `editor.open(sid, prompt)`.
[6/6] extension.js editor.openLast — after `primaryEditor.open`, invoke
      `workbench.action.moveEditorToEnd` so the new tab lands at the end
      of the active tab group (right of all other tabs). Requires VS
      Code ≥ 1.109 (January 2026 release — PR microsoft/vscode#284999,
      milestone "December 2025", merged 2025-12-28). This wrapper is the
      only extension-callable path: `moveActiveEditor` is
      workbench-internal, `tabGroups.move()` doesn't exist (only
      `close()`). Not listed in the official commands reference page,
      but verified in the VS Code source.

Strategy
--------
Generic, version-resilient: search for stable anchors (Claude command names
and webview message-type strings — public API surface, unlikely to change
across minor versions) and capture the minified variable names dynamically
via regex backreferences. The patches survive bumps like 2.1.145 → 2.1.146
even when the minified bundle renames `R0` → `Q7`, etc.

Idempotent: re-running is a no-op for each step (markers / context inspection
detect prior application).

Exit codes
----------
- 0 : all steps applied or already patched
- 1 : regex miss, file missing, or JSON shape broken (red ANSI banner to
      stderr via _common.banner). The orchestrator (run-all.sh) absorbs
      this and keeps the container build green; the diagnostic is the
      per-script exit code visible in build logs.

Usage
-----
    icon-fix-open-in-current-panel.py [EXT_DIR]

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


IMPACT_LINES = [
    "→ The 'primary' value for claudeCode.preferredLocation will be",
    "  UNAVAILABLE. The Claude icon will use original Claude Code",
    "  behavior (split column / sidebar) instead of opening Claude",
    "  in the active editor column.",
    "→ The '+' button in the Claude webview header will open a split",
    "  column instead of a tab in the active group.",
    "→ The Claude icon / status bar item / 'Open last' command will",
    "  open the new tab next to the current one instead of at the end",
    "  of the active tab group.",
    "Likely cause: CLAUDE_CODE_VERSION was bumped and the minified",
    "  patterns no longer match. Review and update the regexes in",
    "  .devcontainer/claude/vscode-ext-patchs/icon-fix-open-in-current-panel.py.",
]


OWN_DESCS = {
    "primary": "Primary Editor (Active Column)",
    "--active-panel": "Active Panel (Active Column, Custom) — collision-safe alias",
    # Legacy — used by earlier version of this patch. Kept in enum for
    # backward compat with existing downstream configs; still claimed by
    # us if detected. New installs never re-inject this bare form.
    "active-panel": "Active Panel (Same Column, End of Group)",
}


def resolve_owned_names(pkg_path):
    """Return the enum values THIS patch owns, in a stable sorted order.

    Ownership rules :

    - `"--active-panel"` — always ours. The `--` prefix is our vendor
      namespace (WebKit-style) and Anthropic never uses it. Always
      claimed, always injected if absent.
    - `"primary"` — ours by default (Anthropic has never declared it
      natively as of v2.1.207). If a future Anthropic version adds
      `"primary"` to the schema with a description that differs from
      ours, we DON'T claim it (Anthropic owns their namespace), and
      users must migrate downstream configs to `"--active-panel"`.
    - `"active-panel"` (bare) — LEGACY, injected by previous versions
      of this patch on v2.1.202+ during the doomed "reserve primary
      for Anthropic" phase. Kept in the owned set if present with our
      old description so downstream configs still on that value keep
      working. Never re-injected on fresh installs.

    Detection uses the enumDescription entry at the same index as the
    enum value — matching our specific strings distinguishes our
    injection from a hypothetical Anthropic addition.
    """
    p = json.loads(pkg_path.read_text())
    try:
        loc = p["contributes"]["configuration"]["properties"]["claudeCode.preferredLocation"]
    except KeyError as e:
        banner("ICON-FIX-OPEN-IN-CURRENT-PANEL PATCH FAILED",
               f"package.json: schema path missing ({e})",
               IMPACT_LINES)
        sys.exit(1)
    enum = loc.get("enum", [])
    descs = loc.get("enumDescriptions", [])
    owned = ["--active-panel"]  # always ours
    # "primary" — claim unless Anthropic explicitly declared it with
    # a description that isn't our OWN_DESCS["primary"].
    if "primary" in enum:
        idx = enum.index("primary")
        if idx < len(descs) and descs[idx] != OWN_DESCS["primary"]:
            # Anthropic-owned — don't claim, don't touch.
            pass
        else:
            owned.append("primary")
    else:
        owned.append("primary")
    # Legacy "active-panel" — only claim if we injected it before
    # (identified by our previous description).
    if "active-panel" in enum:
        idx = enum.index("active-panel")
        if idx < len(descs) and descs[idx] == OWN_DESCS["active-panel"]:
            owned.append("active-panel")
    return sorted(owned)


def owned_check_expr(vs, owned):
    """Return the JS expression that evaluates to true when the user's
    `claudeCode.preferredLocation` matches any name we own. Rendered as
    an array literal `.includes(...)` so it stays a single expression
    inline with the surrounding minified code."""
    array = "[" + ",".join(f'"{n}"' for n in owned) + "]"
    return (f'{array}.includes({vs}.workspace'
            f'.getConfiguration("claudeCode").get("preferredLocation"))')


def patch_package_json(pkg_path, owned):
    """Inject any of the `owned` names into the enum if missing.
    Idempotent per-name : skips values already present."""
    p = json.loads(pkg_path.read_text())
    loc = p["contributes"]["configuration"]["properties"]["claudeCode.preferredLocation"]
    enum = loc["enum"]
    descs = loc.setdefault("enumDescriptions", [])
    added = []
    for name in owned:
        if name in enum:
            continue
        enum.append(name)
        descs.append(OWN_DESCS[name])
        added.append(name)
    if not added:
        print(f"{YELLOW}[1/6]{RESET} package.json — all owned values "
              f"({', '.join(owned)}) already in enum")
        return
    pkg_path.write_text(json.dumps(p, indent=2))
    print(f"{GREEN}[1/6]{RESET} package.json — added "
          f"{', '.join(repr(n) for n in added)} to preferredLocation enum "
          f"(owned={owned})")


def patch_editor_open_guard(content, owned):
    """Prevent `editor.open` from silently overwriting the preferredLocation
    setting when it matches any of our owned values (which would otherwise
    mutate it to "panel")."""
    # Idempotence marker : our injected shape uses `.includes(<ident>.workspace
    # .getConfiguration("claudeCode").get("preferredLocation"))` — a pattern
    # Anthropic itself never produces, so its presence is a reliable signal.
    marker = '.includes(_ccVsForPreferredLocationSentinel)'  # placeholder
    # Simpler check : look for our array-literal marker in the vicinity of
    # the editor.open command registration.
    idx = content.find('registerCommand("claude-vscode.editor.open"')
    if idx != -1:
        window = content[idx:idx + 600]
        if 'workspace.getConfiguration("claudeCode").get("preferredLocation"))' in window:
            print(f"{YELLOW}[2/6]{RESET} extension.js editor.open guard — already patched")
            return content
    # The arg list is captured whole rather than arg-by-arg: the command went
    # from 3 to 4 parameters in 2.1.258, and only the ViewColumn one matters
    # here. Re-emitted verbatim, so a further arity change costs nothing.
    pat = re.compile(
        r'registerCommand\("claude-vscode\.editor\.open",async\(([\w$,]*)\)=>\{'
        r'if\(([\w$]+)!==([\w$]+)\.ViewColumn\.Active\)([\w$]+)\.setPreferredLocation\("panel"\);'
    )
    m = pat.search(content)
    if not m:
        banner("ICON-FIX-OPEN-IN-CURRENT-PANEL PATCH FAILED",
               "extension.js: editor.open guard pattern not found",
               IMPACT_LINES)
        sys.exit(1)
    args, c1, vs, st = m.groups()
    replacement = (
        f'registerCommand("claude-vscode.editor.open",async({args})=>{{'
        f'if({c1}!=={vs}.ViewColumn.Active'
        f'&&!{owned_check_expr(vs, owned)})'
        f'{st}.setPreferredLocation("panel");'
    )
    new_content = pat.sub(replacement, content, count=1)
    print(f"{GREEN}[2/6]{RESET} extension.js editor.open guard — applied "
          f"(vscode={vs}, state={st}, owned={owned})")
    return new_content


def patch_editor_openLast(content, owned):
    """Redirect `editor.openLast` (= the icon and status bar handler) to
    `primaryEditor.open` when the setting matches any of our owned values."""
    # Anchored on the registerCommand site, not on the bare command name:
    # from 2.1.258 the name also appears earlier in a log message, and the
    # window opened there contains none of our injected markers — which made
    # the already-patched check miss on a second run.
    idx = content.find('registerCommand("claude-vscode.editor.openLast"')
    if idx != -1:
        window = content[idx:idx + 600]
        if '.includes(' in window and 'preferredLocation' in window:
            print(f"{YELLOW}[3/6]{RESET} extension.js editor.openLast — already patched")
            return content
    pat = re.compile(
        r'registerCommand\("claude-vscode\.editor\.openLast",async\(\)=>\{'
        r'if\(([\w$]+)\.getPreferredLocation\(\)==="sidebar"\)\{'
        r'await ([\w$]+)\.commands\.executeCommand\("claude-vscode\.sidebar\.open"\);return\}'
        r'await \2\.commands\.executeCommand\("claude-vscode\.editor\.open"\)'
    )
    m = pat.search(content)
    if not m:
        banner("ICON-FIX-OPEN-IN-CURRENT-PANEL PATCH FAILED",
               "extension.js: editor.openLast pattern not found",
               IMPACT_LINES)
        sys.exit(1)
    st, vs = m.groups()
    replacement = (
        f'registerCommand("claude-vscode.editor.openLast",async()=>{{'
        f'if({st}.getPreferredLocation()==="sidebar"){{'
        f'await {vs}.commands.executeCommand("claude-vscode.sidebar.open");return}}'
        f'if({owned_check_expr(vs, owned)}){{'
        f'await {vs}.commands.executeCommand("claude-vscode.primaryEditor.open");return}}'
        f'await {vs}.commands.executeCommand("claude-vscode.editor.open")'
    )
    new_content = pat.sub(replacement, content, count=1)
    print(f"{GREEN}[3/6]{RESET} extension.js editor.openLast — applied "
          f"(state={st}, vscode={vs}, owned={owned})")
    return new_content


def patch_primaryEditor_use_active_column(content):
    """Force `primaryEditor.open` to resolve the active editor column itself
    (via `tabGroups.activeTabGroup.viewColumn`) and pass that integer to
    `createPanel`, instead of the symbolic `ViewColumn.Active`. Without this,
    VS Code splits into a new editor column on every click when a webview of
    the same viewType already exists in the active column."""
    anchor = 'registerCommand("claude-vscode.primaryEditor.open"'
    idx = content.find(anchor)
    new_marker = 'tabGroups.activeTabGroup'
    if idx != -1 and new_marker in content[idx:idx + 400]:
        print(f"{YELLOW}[4/6]{RESET} extension.js primaryEditor.open active column — already patched")
        return content
    pat = re.compile(
        r'registerCommand\("claude-vscode\.primaryEditor\.open",async\(([\w$]+),([\w$]+)\)=>\{'
        r'[\s\S]*?'
        r'([\w$]+)\.createPanel\(\1,\2,([\w$]+)\.ViewColumn\.Active\)\}\)'
    )
    m = pat.search(content)
    if not m:
        banner("ICON-FIX-OPEN-IN-CURRENT-PANEL PATCH FAILED",
               "extension.js: primaryEditor.open pattern not found",
               IMPACT_LINES)
        sys.exit(1)
    a, r, pm, vs = m.groups()
    # `_tg` (underscore-prefixed) avoids shadow-collision when the captured
    # arrow params happen to include a bare `g` — the minifier assigned
    # `(g,b)` to primaryEditor.open on 2.1.202, which turned the previous
    # `let g=...` injection into `async(g,b)=>{let g=...}` (duplicate
    # declaration, SyntaxError). Minified names are one-lowercase-letter, so
    # any underscore prefix guarantees no future collision.
    replacement = (
        f'registerCommand("claude-vscode.primaryEditor.open",async({a},{r})=>{{'
        f'let _tg={vs}.window.tabGroups.activeTabGroup;'
        f'{pm}.createPanel({a},{r},_tg&&_tg.viewColumn?_tg.viewColumn:{vs}.ViewColumn.Active)}})'
    )
    new_content = pat.sub(replacement, content, count=1)
    print(f"{GREEN}[4/6]{RESET} extension.js primaryEditor.open active column — applied (panelMgr={pm}, vscode={vs})")
    return new_content


def patch_plus_button_active_column(content, owned):
    """Fix the `+` button in the Claude webview header. The handler for the
    `new_conversation_tab` message originally calls `editor.open(sessionId,
    prompt)`. Branch on `preferredLocation`: when it matches any of our
    owned values, route to `primaryEditor.open` (which resolves the active
    column via `tabGroups.activeTabGroup.viewColumn` and renders full
    chrome) ; else fall back to the unmodified two-arg
    `editor.open(sid, prompt)` (Anthropic's original split-column
    behavior). Mirrors step [3/6]'s branching pattern for
    `editor.openLast`."""
    anchor = '"new_conversation_tab"'
    idx = content.find(anchor)
    if idx != -1:
        # Fixed-size window, deliberately NOT bounded by the
        # "new_conversation_tab_response" literal: from 2.1.258 that string
        # also appears in the sessionId-validation guard, i.e. *before* the
        # call site we rewrite, which truncated the window and made this
        # already-patched check miss on a second run.
        window = content[idx:idx + 900]
        if '"claude-vscode.primaryEditor.open"' in window:
            print(f"{YELLOW}[5/6]{RESET} extension.js '+' button — already patched")
            return content
    # Group 2 absorbs whatever sits between the type test and `return await`:
    # the branch's closing `)` alone up to 2.1.220, and `){<sessionId
    # validation>;` from 2.1.258 on. Re-emitted verbatim so the branch keeps
    # its original bracketing.
    pat = re.compile(
        r'([\w$]+)\.request\.type==="new_conversation_tab"'
        r'(\)(?:\{if\([^;{}]*\)return\{[^{}]*\};)?)'
        r'return await '
        r'([\w$]+)\.commands\.executeCommand\("claude-vscode\.editor\.open",'
        r'\1\.request\.sessionId,\1\.request\.initialPrompt'
        r'(?:,\3\.ViewColumn\.Active)?\)'
    )
    m = pat.search(content)
    if not m:
        banner("ICON-FIX-OPEN-IN-CURRENT-PANEL PATCH FAILED",
               "extension.js: new_conversation_tab handler pattern not found",
               IMPACT_LINES)
        sys.exit(1)
    msg, sep, vs = m.groups()
    replacement = (
        f'{msg}.request.type==="new_conversation_tab"{sep}return await '
        f'({owned_check_expr(vs, owned)}'
        f'?{vs}.commands.executeCommand("claude-vscode.primaryEditor.open",'
        f'{msg}.request.sessionId,{msg}.request.initialPrompt)'
        f':{vs}.commands.executeCommand("claude-vscode.editor.open",'
        f'{msg}.request.sessionId,{msg}.request.initialPrompt))'
    )
    new_content = pat.sub(replacement, content, count=1)
    print(f"{GREEN}[5/6]{RESET} extension.js '+' button — applied "
          f"(msg={msg}, vscode={vs}, owned={owned})")
    return new_content


def patch_openlast_move_to_end(content, owned):
    """For the active-panel branch of `editor.openLast` (icon top-right /
    status bar item / command palette), follow `primaryEditor.open` with a
    single `workbench.action.moveEditorToEnd` so the new tab lands at the
    end of the active tab group. Wrapped in `try/catch` ; failures log to
    the « Claude VSCode » output channel via the PanelManager singleton's
    `.output` field.

    Why this command : `vscode.window.tabGroups` has no `move()` method
    (only `close()`) ; the internal `moveActiveEditor` is workbench-internal
    and gated on text-editor focus ; `workbench.action.moveEditorToEnd`
    (VS Code ≥ 1.109) is the only extension-callable path that works on
    webview tabs."""
    anchor = '"claude-vscode.primaryEditor.open");'
    idx = content.find(anchor)
    if idx != -1:
        marker = 'try{await '
        win = content[idx:idx + 600]
        if marker in win and '"workbench.action.moveEditorToEnd"' in win:
            print(f"{YELLOW}[6/6]{RESET} extension.js openLast move-to-end — already patched")
            return content

    pm_match = re.search(
        r'registerCommand\("claude-vscode\.primaryEditor\.open"[^}]*?([\w$]+)\.createPanel\(',
        content,
    )
    if not pm_match:
        banner("ICON-FIX-OPEN-IN-CURRENT-PANEL PATCH FAILED",
               "extension.js: panelMgr binding not found near "
               "primaryEditor.open (needed for the .output log target)",
               IMPACT_LINES)
        sys.exit(1)
    pm = pm_match.group(1)

    # Step 3 has already emitted `.includes(<vs>.workspace.getConfiguration(...))`
    # here — anchor on that shape (produced by owned_check_expr) rather
    # than a specific name, since the array literal contents depend on
    # what resolve_owned_names returned.
    pat = re.compile(
        r'(\.includes\([\w$]+\.workspace\.getConfiguration\("claudeCode"\)'
        r'\.get\("preferredLocation"\)\)\)'
        r'\{await ([\w$]+)\.commands\.executeCommand'
        r'\("claude-vscode\.primaryEditor\.open"\);)'
        r'[\s\S]*?'
        r'(return\})'
    )
    m = pat.search(content)
    if not m:
        banner("ICON-FIX-OPEN-IN-CURRENT-PANEL PATCH FAILED",
               "extension.js: openLast primary-branch pattern not found "
               "(expected from step [3/6])",
               IMPACT_LINES)
        sys.exit(1)
    vs = m.group(2)
    replacement = (
        rf'\1try{{await \2.commands.executeCommand'
        rf'("workbench.action.moveEditorToEnd")}}'
        rf'catch(e){{{pm}.output.error('
        rf'"[icon-fix] moveEditorToEnd failed: "+(e?.message??e))}};'
        rf'\3'
    )
    new_content = pat.sub(replacement, content, count=1)
    print(f"{GREEN}[6/6]{RESET} extension.js openLast move-to-end — applied (vscode={vs}, panelMgr={pm})")
    return new_content


def main():
    ext_dir = resolve_ext_dir(sys.argv)
    check_files(ext_dir, ["package.json", "extension.js"])
    pkg = ext_dir / "package.json"
    js = ext_dir / "extension.js"

    print(f"Patching Claude Code extension at: {ext_dir}")

    owned = resolve_owned_names(pkg)
    print(f"  owned enum values: {BOLD}{owned}{RESET}")

    patch_package_json(pkg, owned)

    content = js.read_text()
    original = content

    content = patch_editor_open_guard(content, owned)
    content = patch_editor_openLast(content, owned)
    content = patch_primaryEditor_use_active_column(content)
    content = patch_plus_button_active_column(content, owned)
    content = patch_openlast_move_to_end(content, owned)

    if content != original:
        js.write_text(content)

    print(f"{GREEN}{BOLD}✓ icon-fix-open-in-current-panel patches complete{RESET}")


if __name__ == "__main__":
    main()
