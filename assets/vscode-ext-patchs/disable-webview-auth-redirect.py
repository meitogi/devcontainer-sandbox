#!/usr/bin/env python3
# @patch-category: ux
# @patch-files: package.json
# @patch-files: extension.js
# @patch-files: webview/index.js
# @patch-sentinel: claude-code-disable-webview-auth-redirect-inject-v2
# @patch-sentinel: claude-code-disable-webview-auth-redirect-gate-v1
# @patch-sentinel: claude-code-disable-webview-auth-redirect-isauth-v2
# @patch-summary: Adds an opt-in setting that stops the chat webview from flipping to the
#   login screen on an authentication error.
"""
Adds the `claudeCode.disableWebviewAuthRedirect` setting to the Claude Code
VS Code extension. When true, the chat webview no longer redirects to the
login screen on `authentication_failed` errors — the error surfaces inline
via the existing `#claude-error` sentinel and the panel stays on the chat
view.

Why
---
The existing `claudeCode.disableLoginPrompt` setting only gates the
extension-side login modal. It is never plumbed to the webview. On a 401,
the webview receives an assistant message tagged `error:"authentication_failed"`
and unconditionally calls `this.context.showLogin()` — which flips
`forceLogin.value=true` and re-renders the chat panel as the login screen.

Users authenticating externally (devcontainer bearer token, host-side
OAuth flow, ...) want the hijack gone while keeping user-initiated login
paths intact.

Strategy
--------
Three coordinated edits :

  1. `package.json` — declare the new boolean setting so it shows up in
     the VS Code Settings UI (default `false`, unchanged behavior).

  2. `extension.js` — inject a `window.__CC_disableWebviewAuthRedirect__`
     global into the pre-bundle `<script nonce="${…}">` block of the
     webview HTML. Materialised at panel creation, synchronous — no race
     with a boot-time 401. Mirrors the existing `window.IS_SIDEBAR`
     exposure pattern. The config-getter helper is renamed by the
     minifier between versions (`E1` on v2.1.145 / `Pn` on v2.1.202) —
     resolved at patch time from the existing `<helper>("disableLoginPrompt")`
     call.

  3. `webview/index.js` — two coordinated gates :

     a. Rewrite the single buggy `authentication_failed` call site :

          if(<var>.error==="authentication_failed")<var>.context.showLogin();

        into :

          if(<var>.error==="authentication_failed"&&!window.__CC_disableWebviewAuthRedirect__)<var>.context.showLogin();

        The other 2 `showLogin()` sites (command-palette
        « Log in with a different account » entries) stay untouched —
        clicking login is supposed to open login.

     b. Bypass the `isAuthenticated` reactive getter right after its
        `forceLogin` guard (v2). The getter has 5 branches ; the
        pre-v2 injection sat at the tail fallback and was skipped when
        the CLI reported `claudeConfig.account.tokenSource==="none"`
        (branch 3 short-circuits with `return false`). The v2 site
        injects immediately after :

          if(this.forceLogin.value)return!1;
          /*<marker>*/if(window.__CC_disableWebviewAuthRedirect__)return!0;

        User-initiated login still wins (forceLogin=true → return
        false → login screen). Setting-driven bypass covers every
        other branch.

Anchors
-------
- `authentication_failed` — public webview protocol identifier, unlikely
  to change (single match in the webview bundle, in `processMessage`).
- `IS_SIDEBAR = ${…}` — inside `getHtmlForWebview` in ext.js. The
  minifier renames the surrounding variable (`N`, `i`, …) but the
  string literal stays.
- `<helper>("disableLoginPrompt")` — helper name floats, string
  argument is stable.

Markers
-------
- `claude-code-disable-webview-auth-redirect-inject-v2` — extension-side
  global injection.
- `claude-code-disable-webview-auth-redirect-gate-v1` — webview call-site
  gate.
- `"claudeCode.disableWebviewAuthRedirect"` — string presence guard in
  `package.json` (no comment marker possible in JSON).

Idempotence : each patch function checks for its marker before applying.
Re-run on an already-patched extension is a no-op.

Exit codes
----------
- 0 : all steps applied or already patched
- 1 : any regex miss / file missing / JSON shape broken (red banner via
      _common.banner + IMPACT_LINES). run-all.sh absorbs the 1 so the
      container build stays green ; the diagnostic surfaces in the
      per-script exit code visible in build logs.

Usage
-----
    disable-webview-auth-redirect.py [EXT_DIR]

If EXT_DIR is omitted, auto-discovers the latest
~/.vscode-server/extensions/anthropic.claude-code-*-{arch} directory.
"""

import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import YELLOW, GREEN, BOLD, RESET, banner, resolve_ext_dir, check_files


SETTING_KEY = "claudeCode.disableWebviewAuthRedirect"
# v1 emitted `<helper>("disableWebviewAuthRedirect")===!0` as literal text
# into the webview <script>. That helper is an extension-host function — the
# webview's own same-named symbol is unrelated, module-scoped and loaded
# later — so the bootstrap block died on a ReferenceError, the global was
# never set, and every gate below it silently fell through to the login
# redirect. v2 evaluates the getter host-side inside `${…}`.
MARKER_INJECT = "claude-code-disable-webview-auth-redirect-inject-v2"
MARKER_INJECT_V1 = "claude-code-disable-webview-auth-redirect-inject-v1"
V1_INJECT_LINE = re.compile(
    r'\n[ \t]*/\*' + re.escape(MARKER_INJECT_V1) + r'\*/[^\n]*'
)
MARKER_GATE = "claude-code-disable-webview-auth-redirect-gate-v1"
MARKER_ISAUTH = "claude-code-disable-webview-auth-redirect-isauth-v2"
MARKER_ISAUTH_V1 = "claude-code-disable-webview-auth-redirect-isauth-v1"

IMPACT_LINES = [
    "→ The 'claudeCode.disableWebviewAuthRedirect' setting will be",
    "  UNAVAILABLE (or partially applied). The Claude chat webview will",
    "  continue to redirect to the login screen on authentication_failed",
    "  errors even when external auth is in use.",
    "Likely cause: CLAUDE_CODE_VERSION was bumped and the minified",
    "  shape drifted. Re-anchor from these pretty locations :",
    "  - pretty/extension.js — getHtmlForWebview, around the",
    "    <script nonce=...> block that exposes window.IS_SIDEBAR",
    "  - pretty/webview-index.js — processMessage, the",
    "    `authentication_failed` branch (single call site)",
    "  - pretty/webview-index.js — the `isAuthenticated=` reactive",
    "    getter (single occurrence). v2 injects right after the",
    "    `if(this.forceLogin.value)return!1;` guard (not at the tail).",
    "  Then update regexes in",
    "  .devcontainer/claude/vscode-ext-patchs/disable-webview-auth-redirect.py.",
]


def patch_package_json(pkg_path):
    p = json.loads(pkg_path.read_text())
    try:
        props = p["contributes"]["configuration"]["properties"]
    except KeyError as e:
        banner("DISABLE-WEBVIEW-AUTH-REDIRECT PATCH FAILED",
               f"package.json: schema path missing ({e})",
               IMPACT_LINES)
        sys.exit(1)
    if SETTING_KEY in props:
        print(f"{YELLOW}[1/4]{RESET} package.json — {SETTING_KEY!r} already declared")
        return
    props[SETTING_KEY] = {
        "type": "boolean",
        "default": False,
        "description": (
            "When true, the chat webview will NOT redirect to the login "
            "screen on authentication_failed errors. Use when "
            "authentication is handled externally."
        ),
    }
    pkg_path.write_text(json.dumps(p, indent=2))
    print(f"{GREEN}[1/4]{RESET} package.json — added {SETTING_KEY!r}")


def patch_extension_bridge(content):
    """Inject the `window.__CC_disableWebviewAuthRedirect__` global into
    the webview HTML template literal, right after the existing
    `window.IS_SIDEBAR = ${…}` line inside the `<script nonce>` block.
    """
    content, n_v1 = V1_INJECT_LINE.subn("", content)
    if MARKER_INJECT in content:
        n = content.count(MARKER_INJECT)
        print(f"{YELLOW}[2/4]{RESET} extension.js bridge — already patched ({n} site(s))")
        return content
    if n_v1:
        print(f"{YELLOW}[strip]{RESET} extension.js bridge — reverted {n_v1} v1 injection(s)")

    helper_match = re.search(r'([\w$]+)\("disableLoginPrompt"\)', content)
    if not helper_match:
        banner("DISABLE-WEBVIEW-AUTH-REDIRECT PATCH FAILED",
               'extension.js: <helper>("disableLoginPrompt") call not found — '
               "cannot resolve config-getter name",
               IMPACT_LINES)
        sys.exit(1)
    helper = helper_match.group(1)

    # Anchors on the raw template-literal source. Both min and pretty share
    # the same template-literal bytes (js-beautify preserves them). The
    # ternary variable (`N`, `i`, ...) floats — captured as `[^}]+`.
    #
    # Deliberately does NOT require IS_FULL_EDITOR to follow: sibling patches
    # (fix-style-pills, model-badge-footer) inject their own globals right
    # after this same IS_SIDEBAR line, so the two are no longer adjacent. The
    # old two-part anchor only kept working because run-all happens to run
    # this patch first, alphabetically — not something to depend on.
    pat = re.compile(r'window\.IS_SIDEBAR\s*=\s*\$\{[^}]+\?"true":"false"\}')
    matches = list(pat.finditer(content))
    if len(matches) != 1:
        banner("DISABLE-WEBVIEW-AUTH-REDIRECT PATCH FAILED",
               f"extension.js: IS_SIDEBAR anchor in getHtmlForWebview matched "
               f"{len(matches)} times (expected 1)",
               IMPACT_LINES)
        sys.exit(1)
    m = matches[0]

    # Evaluated host-side inside `${…}`: the getter does not exist in the
    # webview, and emitting it bare is what broke v1.
    inject = (
        f'\n          /*{MARKER_INJECT}*/'
        f'window.__CC_disableWebviewAuthRedirect__='
        f'${{{helper}("disableWebviewAuthRedirect")===!0}};'
    )
    new_content = content[:m.end()] + inject + content[m.end():]
    print(f"{GREEN}[2/4]{RESET} extension.js bridge — injected global (helper={helper})")
    return new_content


def patch_webview_gate(content):
    """Gate the single buggy `showLogin()` call site on the new global."""
    if MARKER_GATE in content:
        n = content.count(MARKER_GATE)
        print(f"{YELLOW}[3/4]{RESET} webview/index.js gate — already patched ({n} site(s))")
        return content

    pat = re.compile(
        r'if\(([\w$]+)\.error==="authentication_failed"\)'
        r'([\w$]+)\.context\.showLogin\(\);'
    )
    matches = list(pat.finditer(content))
    if len(matches) == 0:
        banner("DISABLE-WEBVIEW-AUTH-REDIRECT PATCH FAILED",
               "webview/index.js: authentication_failed → showLogin call site not found",
               IMPACT_LINES)
        sys.exit(1)
    if len(matches) > 1:
        banner("DISABLE-WEBVIEW-AUTH-REDIRECT PATCH AMBIGUOUS",
               f"webview/index.js: authentication_failed call site matched {len(matches)} times (expected 1)",
               IMPACT_LINES)
        sys.exit(1)

    m = matches[0]
    e_var, ctx_var = m.group(1), m.group(2)
    replacement = (
        f'/*{MARKER_GATE}*/'
        f'if({e_var}.error==="authentication_failed"'
        f'&&!window.__CC_disableWebviewAuthRedirect__)'
        f'{ctx_var}.context.showLogin();'
    )
    new_content = content[:m.start()] + replacement + content[m.end():]
    print(f"{GREEN}[3/4]{RESET} webview/index.js gate — applied (e={e_var}, ctx={ctx_var})")
    return new_content


V1_ISAUTH_INJECTION = re.compile(
    r'/\*' + re.escape(MARKER_ISAUTH_V1) + r'\*/'
    r'if\(window\.__CC_disableWebviewAuthRedirect__\)return!0;'
)


def strip_isauth_v1_injection(content):
    """Remove any pre-existing v1 isauth injection so v2 can be applied
    cleanly. v1 sat at the tail fallback of the `isAuthenticated` getter
    (skipped when `claudeConfig.account.tokenSource==="none"`); v2 sits
    right after the `forceLogin` guard so every non-forceLogin path is
    covered. Self-healing pattern per vendor CLAUDE.md §Marker naming.
    """
    return V1_ISAUTH_INJECTION.sub('', content)


def patch_webview_isauthenticated(content):
    """Gate the `isAuthenticated` reactive getter on the global, right
    after the `forceLogin` guard (v2 site).

    Two live redirect paths trigger the login screen : (1) the synthetic
    assistant message with `error:"authentication_failed"` calling
    `showLogin()` — covered by patch_webview_gate above ; (2) the extension
    pushing an `update_state` with `authStatus:null` + a `claudeConfig`
    reporting no valid token (OAuth session expired / never authed
    externally). The getter has 5 branches ; injecting at the tail
    fallback (v1) was skipped when branch 3 (claudeConfig +
    tokenSource==="none") returned false first. v2 injects at
    position 1.5 — after forceLogin, before every other branch —
    so user-initiated login (forceLogin=true) still wins while the
    setting bypasses everything else.
    """
    content = strip_isauth_v1_injection(content)

    if MARKER_ISAUTH in content:
        n = content.count(MARKER_ISAUTH)
        print(f"{YELLOW}[4/4]{RESET} webview/index.js isAuthenticated — already patched ({n} site(s))")
        return content

    pat = re.compile(
        r'(isAuthenticated=[\w$]+\(\(\)=>\{'
        r'if\(this\.forceLogin\.value\)return!1;)'
        r'(if\(this\.authStatus\.value!==null\)return!0;'
        r'let ([\w$]+)=this\.comms\.connection\.value;'
        r'if\(\3\)\{let ([\w$]+)=\3\.claudeConfig\.value;'
        r'if\(\4\)return!!\(\4\.account\.tokenSource&&\4\.account\.tokenSource!=="none"'
        r'\|\|\4\.account\.subscriptionType\)\}'
        r'return!1\}\);)'
    )
    matches = list(pat.finditer(content))
    if len(matches) == 0:
        banner("DISABLE-WEBVIEW-AUTH-REDIRECT PATCH FAILED",
               "webview/index.js: isAuthenticated getter anchor not found",
               IMPACT_LINES)
        sys.exit(1)
    if len(matches) > 1:
        banner("DISABLE-WEBVIEW-AUTH-REDIRECT PATCH AMBIGUOUS",
               f"webview/index.js: isAuthenticated getter matched {len(matches)} times (expected 1)",
               IMPACT_LINES)
        sys.exit(1)

    m = matches[0]
    injection_point = m.end(1)
    injection = (
        f'/*{MARKER_ISAUTH}*/'
        f'if(window.__CC_disableWebviewAuthRedirect__)return!0;'
    )
    new_content = content[:injection_point] + injection + content[injection_point:]
    print(f"{GREEN}[4/4]{RESET} webview/index.js isAuthenticated — bypass injected after forceLogin guard")
    return new_content


def main():
    ext_dir = resolve_ext_dir(sys.argv)
    check_files(ext_dir, ["package.json", "extension.js", "webview/index.js"])
    pkg = ext_dir / "package.json"
    ext = ext_dir / "extension.js"
    wv = ext_dir / "webview" / "index.js"

    print(f"Patching Claude Code extension at: {ext_dir}")

    patch_package_json(pkg)

    ext_content = ext.read_text()
    ext_new = patch_extension_bridge(ext_content)
    if ext_new != ext_content:
        ext.write_text(ext_new)

    wv_content = wv.read_text()
    wv_new = patch_webview_gate(wv_content)
    wv_new = patch_webview_isauthenticated(wv_new)
    if wv_new != wv_content:
        wv.write_text(wv_new)

    print(f"{GREEN}{BOLD}✓ disable-webview-auth-redirect patch complete{RESET}")


if __name__ == "__main__":
    main()
