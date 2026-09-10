#!/usr/bin/env python3
# @patch-category: ux
# @patch-files: extension.js
# @patch-files: webview/index.js
# @patch-sentinel: claude-code-webview-vscode-api-window-v1
# @patch-sentinel: claude-code-webview-login-retry-button-v1
# @patch-sentinel: claude-code-webview-retry-reload-handler-v1
# @patch-summary: Adds a 'Continue where I left off' button to the login screen as a one-
#   click recovery path.
#   b("button",{className:`${Vo.fullWidthButton} ${Vo.primary}`,onClick:()=>i("claudeai"),disabled:t,...
#   Xn.default.createElement("button",{className:`${Y4.fullWidthButton} ${Y4.primary}`,onClick:()=>J("claudeai"),disabled:Z,...
"""
Injects a "Continue where I left off" fallback button on the Claude Code
webview login screen. Clicking it posts a message to the extension,
which reassigns `webview.html = getHtmlForWebview(...)` — repainting the
webview and resuming the persisted session state (sessionId + summary
kept on the extension side).

Why
---
The existing `disable-webview-auth-redirect.py` patch is meant to keep
the chat panel on the current view when the CLI reports
`authentication_failed`. In practice, the login popup still fires when
opening a fresh chat tab (root cause deferred to a follow-up patch).
Until then, users type `bump` in the chat to reset the session — this
button gives them a one-click recovery path instead.

Strategy
--------
Two files, five gates :

  1. `webview/index.js` — expose the VS Code API on `window` at boot.
     The `Mkt`/`qN0` login-screen React component's `context` prop
     exposes `openURL()` and `openClaudeInTerminal()` but NOT
     `postMessage()`. Rather than trace the context wrapper class
     (which drifts more between versions — `Zme` → `Gme` → …), we hook
     the single `acquireVsCodeApi()` call site (a stable Web API name,
     never minified) and store the resulting handle on
     `window.__CC_vscodeApi__`. The button's onClick reaches it from
     there.

  2. `webview/index.js` — inject the button as the first child of the
     login-screen `methodSelection` container, before the Claude.ai
     Subscription button. Two flavours of injection depending on the
     JSX factory in use : compact `b("button",{…,children:"…"})` for
     v2.1.207+ (Preact-style jsx bundles), or the verbose
     `React.default.createElement("button",{…},"…")` for the legacy
     bundle in v2.1.145.

  3. `extension.js` — inject a `cc-reload-webview-session` handler at
     the head of each of the 3 chat/sidebar/sessionListView
     `onDidReceiveMessage` callbacks. The handler reassigns
     `webview.html` with the exact same arguments the site uses for
     its initial paint — captured verbatim from the nearest reassign
     expression in the enclosing scope (~10-20 chars back in min).
     The (4-arg / 5-arg / 6-arg) shape of `getHtmlForWebview(...)`
     is preserved without re-guessing which vars are in the closure
     — the last argument at the session-panel site drifts (`i` on
     v2.1.207, `n` on v2.1.218), so verbatim copy absorbs it.

Anchors
-------
- `acquireVsCodeApi` — Web API name, byte-stable across every version.
- `"Claude.ai Subscription"` — public protocol UX identifier, unique
  string literal, stable across every version.
- `` onDidReceiveMessage((X)=>{this.output.info(`Received…${…}`),
  Y?.fromClient(X)} `` — the log-then-delegate handler shape, stable
  across the 3 target versions. Comment-panel handler uses inline
  dispatch (no `fromClient`, no log line) so it is excluded naturally.

Markers
-------
- `claude-code-webview-vscode-api-window-v1` — boot-side `window.__CC_vscodeApi__` exposure.
- `claude-code-webview-login-retry-button-v1` — button injection in Mkt/qN0.
- `claude-code-webview-retry-reload-handler-v1` — three-handler
  injection in extension.js (idempotence checked globally on the file).

Idempotence : each patch function checks for its marker before applying.
Re-run on an already-patched extension is a no-op.

Exit codes
----------
- 0 : all steps applied or already patched
- 1 : any regex miss / file missing (red banner via _common.banner
      + IMPACT_LINES). run-all.sh absorbs the 1 so the container build
      stays green ; the diagnostic surfaces in the per-script exit
      code visible in build logs.

Usage
-----
    webview-login-retry-button.py [EXT_DIR]

If EXT_DIR is omitted, auto-discovers the latest
~/.vscode-server/extensions/anthropic.claude-code-*-{arch} directory.
"""

import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import YELLOW, GREEN, BOLD, RESET, banner, resolve_ext_dir, check_files


MARKER_API = "claude-code-webview-vscode-api-window-v1"
MARKER_BUTTON = "claude-code-webview-login-retry-button-v1"
MARKER_HANDLER = "claude-code-webview-retry-reload-handler-v1"

BUTTON_LABEL = "Continue where I left off"
BUTTON_TITLE = "Reload webview — resumes your session if auth was refreshed externally"
RELOAD_MSG_TYPE = "cc-reload-webview-session"

IMPACT_LINES = [
    "→ The 'Continue where I left off' button will be UNAVAILABLE on",
    "  the login screen. Users must keep typing 'bump' in chat to reset",
    "  the session after an auth-failed redirect.",
    "Likely cause: CLAUDE_CODE_VERSION was bumped and the minified",
    "  shape drifted. Re-anchor from these pretty locations:",
    "  - pretty/webview-index.js — `acquireVsCodeApi(` (single call).",
    "  - pretty/webview-index.js — the login-screen button block,",
    "    around the string literal `\"Claude.ai Subscription\"`. Look at",
    "    the enclosing methodSelection <div> and the classname var.",
    "  - pretty/extension.js — the three `onDidReceiveMessage`",
    "    handlers preceded by a `Received message from webview:` log",
    "    line (sidebar / session panel / sessionListView).",
    "  Then update the regexes in",
    "  .devcontainer/claude/vscode-ext-patchs/webview-login-retry-button.py.",
]


# ---------------------------------------------------------------------------
# Gate 1 — expose VS Code api on window at boot
# ---------------------------------------------------------------------------

def patch_webview_expose_api(content):
    """Store the return of the single `acquireVsCodeApi()` call on
    `window.__CC_vscodeApi__` so the login-screen button can reach it.

    The call site shape is stable across versions :

        let <X>=acquireVsCodeApi(),<Y>=new <Wrapper>(<X>);

    The identifier `<X>` may be `$` on v2.1.145 (valid JS ident but not
    matched by Python `\\w` — use `[\\w$]`).

    We match the FULL let statement (from `let` up to and including
    the terminating `;`) and inject after it, so we don't break the
    comma-separated declaration into an orphan `,Y=B` fragment.
    """
    if MARKER_API in content:
        n = content.count(MARKER_API)
        print(f"{YELLOW}[1/3]{RESET} webview/index.js api-window — already patched ({n} site(s))")
        return content

    # Capture the whole `let X=acquireVsCodeApi()<rest>;` declaration.
    # `[^;]*?` is non-greedy up to the first ';' — the RHS of
    # `new Wrapper($)` has no semicolons.
    pat = re.compile(r'(let\s+([\w$]+)\s*=\s*acquireVsCodeApi\s*\(\s*\)[^;]*?;)')
    matches = list(pat.finditer(content))
    if len(matches) != 1:
        banner("WEBVIEW-LOGIN-RETRY-BUTTON PATCH FAILED",
               f"webview/index.js: acquireVsCodeApi anchor matched {len(matches)} times (expected 1)",
               IMPACT_LINES)
        sys.exit(1)

    m = matches[0]
    var = m.group(2)
    inject = f'window.__CC_vscodeApi__={var};/*{MARKER_API}*/'
    new_content = content[:m.end(1)] + inject + content[m.end(1):]
    print(f"{GREEN}[1/3]{RESET} webview/index.js api-window — exposed (var={var})")
    return new_content


# ---------------------------------------------------------------------------
# Gate 2 — inject the login retry button
# ---------------------------------------------------------------------------

def _button_modern(jsx_var, classname_var, disabled_var):
    return (
        f'{jsx_var}("button",{{className:`${{{classname_var}.fullWidthButton}} '
        f'${{{classname_var}.primary}}`,'
        f'onClick:()=>window.__CC_vscodeApi__.postMessage({{type:"{RELOAD_MSG_TYPE}"}}),'
        f'disabled:{disabled_var},'
        f'title:"{BUTTON_TITLE}",'
        f'children:"{BUTTON_LABEL}"}})'
    )


def _button_legacy(react_var, classname_var, disabled_var):
    return (
        f'{react_var}.default.createElement("button",{{className:`'
        f'${{{classname_var}.fullWidthButton}} ${{{classname_var}.primary}}`,'
        f'onClick:()=>window.__CC_vscodeApi__.postMessage({{type:"{RELOAD_MSG_TYPE}"}}),'
        f'disabled:{disabled_var},'
        f'title:"{BUTTON_TITLE}"}},"{BUTTON_LABEL}")'
    )


# Modern JSX (v2.1.207+):
#   b("button",{className:`${Vo.fullWidthButton} ${Vo.primary}`,onClick:()=>i("claudeai"),disabled:t,...
# The jsx factory ident is captured, not hardcoded: it is `b` on 2.1.207/2.1.220
# and `D` on 2.1.258 (Bun renames it on every rebundle).
_BUTTON_PAT_MODERN = re.compile(
    r'([\w$]+)\("button",\{className:`\$\{([\w$]+)\.fullWidthButton\} '
    r'\$\{\2\.primary\}`,onClick:\(\)=>[\w$]+\("claudeai"\),'
    r'disabled:([\w$]+)'
)

# Legacy React.createElement (v2.1.145):
#   Xn.default.createElement("button",{className:`${Y4.fullWidthButton} ${Y4.primary}`,onClick:()=>J("claudeai"),disabled:Z,...
_BUTTON_PAT_LEGACY = re.compile(
    r'([\w$]+)\.default\.createElement\("button",\{className:`\$\{'
    r'([\w$]+)\.fullWidthButton\} \$\{\2\.primary\}`,onClick:\(\)=>[\w$]+\("claudeai"\),'
    r'disabled:([\w$]+)'
)


def patch_webview_button(content):
    """Inject the retry button as the sibling immediately before the
    Claude.ai Subscription button. On modern bundles this is a
    `b("button",{...})` call ; on the v2.1.145 legacy bundle it is a
    `Xn.default.createElement("button",{...},"…")` call. Both preserve
    the container's children/positional-args structure."""
    if MARKER_BUTTON in content:
        n = content.count(MARKER_BUTTON)
        print(f"{YELLOW}[2/3]{RESET} webview/index.js button — already patched ({n} site(s))")
        return content

    # Try modern first
    matches = list(_BUTTON_PAT_MODERN.finditer(content))
    if len(matches) == 1:
        m = matches[0]
        jsx_var, classname_var, disabled_var = m.group(1), m.group(2), m.group(3)
        button_src = _button_modern(jsx_var, classname_var, disabled_var)
        injection = f'{button_src},/*{MARKER_BUTTON}*/'
        new_content = content[:m.start()] + injection + content[m.start():]
        print(f"{GREEN}[2/3]{RESET} webview/index.js button — injected modern "
              f"(jsx={jsx_var}, cls={classname_var}, disabled={disabled_var})")
        return new_content
    if len(matches) > 1:
        banner("WEBVIEW-LOGIN-RETRY-BUTTON PATCH AMBIGUOUS",
               f"webview/index.js: modern Claude.ai button matched {len(matches)} times (expected 1)",
               IMPACT_LINES)
        sys.exit(1)

    # Fall back to legacy React.createElement
    matches = list(_BUTTON_PAT_LEGACY.finditer(content))
    if len(matches) == 1:
        m = matches[0]
        react_var, classname_var, disabled_var = m.group(1), m.group(2), m.group(3)
        button_src = _button_legacy(react_var, classname_var, disabled_var)
        injection = f'{button_src},/*{MARKER_BUTTON}*/'
        new_content = content[:m.start()] + injection + content[m.start():]
        print(f"{GREEN}[2/3]{RESET} webview/index.js button — injected legacy "
              f"(react={react_var}, cls={classname_var}, disabled={disabled_var})")
        return new_content
    if len(matches) > 1:
        banner("WEBVIEW-LOGIN-RETRY-BUTTON PATCH AMBIGUOUS",
               f"webview/index.js: legacy Claude.ai button matched {len(matches)} times (expected 1)",
               IMPACT_LINES)
        sys.exit(1)

    banner("WEBVIEW-LOGIN-RETRY-BUTTON PATCH FAILED",
           "webview/index.js: Claude.ai Subscription button anchor not found (neither modern nor legacy)",
           IMPACT_LINES)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Gate 3 — 3 extension.js onDidReceiveMessage handlers
# ---------------------------------------------------------------------------

# Log-line anchor unique to the 3 chat/sidebar/list handlers. Not
# present in the comments-panel handler (inline dispatch). Just the
# log line — the following comma/fromClient may be rewritten by prior
# patches (e.g. user-action-observer replaces `,` with `;` and injects
# a try/catch observer block after the log line before delegating).
# Only param_var is captured.
_LOG_LINE_PAT = re.compile(
    r'this\.output\.info\(`Received message from webview: '
    r'\$\{JSON\.stringify\(([\w$]+)\)\}`\)'
)

# Enclosing onDidReceiveMessage opener — found by scanning backward
# from a log-line match. `\1` refers to the param_var captured by
# _LOG_LINE_PAT.
def _find_enclosing_handler_opener(content, log_line_start, param_var):
    """Return (webview_var, opener_end_offset) for the
    `<webview>.webview.onDidReceiveMessage((<param>)=>{` that
    encloses the log line at `log_line_start`, or None if not found."""
    # Scan back up to 4 KB — accommodates arbitrary prior injections.
    window_start = max(0, log_line_start - 4096)
    window = content[window_start:log_line_start]
    pat = re.compile(
        r'([\w$]+)\.webview\.onDidReceiveMessage'
        r'\(\(' + re.escape(param_var) + r'\)=>\{'
    )
    matches = list(pat.finditer(window))
    if not matches:
        return None
    last = matches[-1]
    return (last.group(1), window_start + last.end())

# Reassign shape : X.webview.html=this.getHtmlForWebview(X.webview, ...);
# The rest-of-args is captured as-is (no interpretation) so the (4/5/6)-arg
# shape drift and any var-name drift in the middle args are absorbed.
_REASSIGN_PAT = re.compile(
    r'([\w$]+)\.webview\.html\s*=\s*(this\.getHtmlForWebview\(\1\.webview[^;)]*\))'
)


def patch_extension_handlers(content):
    """Inject a `cc-reload-webview-session` fast-path at the head of
    each chat handler. The reassign RHS is copied verbatim from the
    nearest preceding `X.webview.html=this.getHtmlForWebview(...)` in
    the same scope — no re-guessing of the (4/5/6)-arg shape or of
    the drifting session-panel var (`i` in v2.1.207, `n` in v2.1.218).
    """
    if MARKER_HANDLER in content:
        n = content.count(MARKER_HANDLER)
        print(f"{YELLOW}[3/3]{RESET} extension.js handlers — already patched ({n} site(s))")
        return content

    log_matches = list(_LOG_LINE_PAT.finditer(content))
    if len(log_matches) != 3:
        banner("WEBVIEW-LOGIN-RETRY-BUTTON PATCH FAILED",
               f"extension.js: expected 3 `Received message from webview` "
               f"log lines (sidebar/session/list), found {len(log_matches)}",
               IMPACT_LINES)
        sys.exit(1)

    # For each log line, resolve its enclosing onDidReceiveMessage
    # opener (backward scan), then locate the nearest preceding reassign
    # expression (also backward scan). Inject just before the log line —
    # prior head-of-callback injections (e.g. user-action-observer) still
    # fire on all messages, our fast-path returns before fromClient.
    injections = []  # list of (offset, injected_text)
    webview_vars = []
    param_vars = []
    for lm in log_matches:
        param_var = lm.group(1)
        log_line_start = lm.start()

        opener = _find_enclosing_handler_opener(content, log_line_start, param_var)
        if opener is None:
            banner("WEBVIEW-LOGIN-RETRY-BUTTON PATCH FAILED",
                   f"extension.js: enclosing onDidReceiveMessage not found "
                   f"for log line at offset {log_line_start} (param={param_var})",
                   IMPACT_LINES)
            sys.exit(1)
        webview_var, opener_end = opener
        webview_vars.append(webview_var)
        param_vars.append(param_var)

        # Nearest preceding reassign with matching webview_var. 4 KB back:
        # the gap was ~1.5 KB up to 2.1.220 and grew to ~2.6 KB in 2.1.258.
        # Only the NEAREST match is used, so a wider window cannot pick a
        # wrong reassign — it only avoids missing a legitimate one.
        window_start = max(0, opener_end - 4096)
        window_text = content[window_start:opener_end]
        candidates = list(_REASSIGN_PAT.finditer(window_text))
        matching = [c for c in candidates if c.group(1) == webview_var]
        if not matching:
            banner("WEBVIEW-LOGIN-RETRY-BUTTON PATCH FAILED",
                   f"extension.js: no matching reassign found before handler "
                   f"at offset {opener_end} (webview_var={webview_var})",
                   IMPACT_LINES)
            sys.exit(1)
        reassign_rhs = matching[-1].group(2)  # e.g. "this.getHtmlForWebview(e.webview, void 0, void 0, !0)"

        # if-return at the head — ASI terminates the block after `}` so
        # the following comma-op expression statement
        # (`this.output.info(...),X?.fromClient(P)`) parses correctly.
        inject = (
            f'if({param_var}.type==="{RELOAD_MSG_TYPE}"){{'
            f'{webview_var}.webview.html={reassign_rhs};return;'
            f'}}/*{MARKER_HANDLER}*/'
        )
        injections.append((log_line_start, inject))

    # Apply in reverse offset order to preserve earlier offsets
    new_content = content
    for offset, inject in sorted(injections, key=lambda p: -p[0]):
        new_content = new_content[:offset] + inject + new_content[offset:]

    print(f"{GREEN}[3/3]{RESET} extension.js handlers — 3 sites instrumented "
          f"(webviews={','.join(sorted(set(webview_vars)))}, "
          f"params={','.join(param_vars)})")
    return new_content


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

def main():
    ext_dir = resolve_ext_dir(sys.argv)
    check_files(ext_dir, ["extension.js", "webview/index.js"])
    ext = ext_dir / "extension.js"
    wv = ext_dir / "webview" / "index.js"

    print(f"Patching Claude Code extension at: {ext_dir}")

    wv_content = wv.read_text()
    wv_new = patch_webview_expose_api(wv_content)
    wv_new = patch_webview_button(wv_new)
    if wv_new != wv_content:
        wv.write_text(wv_new)

    ext_content = ext.read_text()
    ext_new = patch_extension_handlers(ext_content)
    if ext_new != ext_content:
        ext.write_text(ext_new)

    print(f"{GREEN}{BOLD}✓ webview-login-retry-button patch complete{RESET}")


if __name__ == "__main__":
    main()
