#!/usr/bin/env python3
# @patch-category: ux
# @patch-files: package.json
# @patch-files: extension.js
# @patch-files: webview/index.js
# @patch-sentinel: /*fsp-boot-v3*/
# @patch-summary: Squares off the model and Remote Control pills so they match
#   the surrounding footer buttons.

"""
Adds the `claudeCode.fixStylePills` VS Code setting, which restyles the two
rounded pills in the prompt input footer — the model pill and the Remote
Control pill — to match the footer buttons next to them.

Measured on 2.1.258:

                    pills            footer buttons (target)
    border-radius   9999px           5px
    font-size       1em              .85em
    padding         4px 16px         2px 8px

A trap in that table: `.footerButton` is declared TWICE in index.css, and
the first rule's `border-radius:2px; padding:2px 4px` is overridden by a
later `border-radius:5px; height:26px`. 5px is what actually renders, and
is also what `menuButton` and `usageButtonV2` use; matching the dead 2px
reads on screen as no radius at all.

Padding is the one value not copied from a neighbour: the icon buttons run
`padding:0`, which is wrong for a control carrying text. It follows
model-badge-footer's own `2px 8px` instead, chosen for exactly that reason.

Supersedes `hide-model-legacy-pill.py`, which hid the stock pill outright
because `model-badge-footer.py` injects its own "Switch model" button. The
pills are restyled instead — the rules ride in as a <style> from the
bootstrap script, so there is no webview edit at all. Injections left by
that predecessor are stripped wherever they are still found.

Selectors
---------
The stylesheet class names are content-hashed (`modelPill_gGYT1w`) and drift
every build, so the rules anchor on semantics instead: `role="combobox"` is
unique to the model pill, and `aria-label="Remote Control"` to the RC pill.
Note `title="Switch model"` matches twice — the stock pill *and*
model-badge-footer's own button — hence the `role` qualifier, which keeps
this patch off the other patch's element.

The global is materialised at panel creation, so toggling the setting needs
a Reload Window.
"""

import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import GREEN, YELLOW, RESET, banner, resolve_ext_dir, check_files

SETTING_KEY = "claudeCode.fixStylePills"
GLOBAL = "window.__CC_fixStylePills__"

MARKER_BOOT = "/*fsp-boot-v3*/"

# Superseded injections, stripped wherever they are found.
#
# fsp-boot-v1 emitted `…=h0("fixStylePills")!==!1;` as literal text. That
# reads as browser JS, and h0 is an extension-host function — the webview's
# own `h0` is a different, module-scoped symbol loaded later — so the whole
# bootstrap <script> died on a ReferenceError and no style was ever injected.
# v2 evaluates the getter host-side inside `${…}` instead.
LEGACY_SETTING = "claudeCode.hideModelLegacyPill"
LEGACY_STRIPS = [
    # Boot injections occupy exactly one line each.
    re.compile(r'\n[ \t]*/\*hmlp-boot-v1\*/[^\n]*'),
    re.compile(r'\n[ \t]*/\*fsp-boot-v\d+\*/[^\n]*'),
    re.compile(r'/\*hmlp-pill-v1\*/style:window\.__CC_hideModelLegacyPill__\?'
               r'\{display:"none"\}:void 0,'),
    re.compile(r'/\*hmlp-row-v1\*/!window\.__CC_hideModelLegacyPill__&&'),
]

# footerButton is declared twice; the LATER rule wins, so the live values are
# radius 5px / height 26px — the same as menuButton and usageButtonV2. The
# first rule's 2px is dead, and matching it reads as no radius at all.
# Padding follows model-badge-footer's own choice for a text-bearing footer
# button (2px 8px) rather than the icon buttons' 0.
PILL_CSS = (
    'button[role="combobox"][title="Switch model"],'
    '[aria-label="Remote Control"]'
    '{border-radius:5px!important;padding:2px 8px!important;'
    'font-size:.85em!important}'
)

IMPACT_LINES = [
    "The claudeCode.fixStylePills setting will not work.",
    "The model and Remote Control pills keep their fully-rounded 1em style.",
    "Likely cause: CLAUDE_CODE_VERSION was bumped and the minified shape drifted.",
    "Re-anchor from: the IS_SIDEBAR bootstrap line in extension.js.",
]


def strip_legacy(content):
    """Revert hide-model-legacy-pill's injections. Returns (content, n)."""
    total = 0
    for pat in LEGACY_STRIPS:
        content, n = pat.subn("", content)
        total += n
    return content, total


def patch_package_json(path):
    pkg = json.loads(path.read_text())
    props = pkg["contributes"]["configuration"]["properties"]
    changed = props.pop(LEGACY_SETTING, None) is not None
    if SETTING_KEY not in props:
        props[SETTING_KEY] = {
            "type": "boolean",
            "default": True,
            "description": (
                "Square off the model and Remote Control pills in the prompt "
                "footer so they match the buttons beside them. "
                "Takes effect after Reload Window."
            ),
        }
        changed = True
    if not changed:
        print(f"{YELLOW}[1/3]{RESET} package.json — already declared")
        return None
    print(f"{GREEN}[1/3]{RESET} package.json — declared {SETTING_KEY}")
    return json.dumps(pkg, indent=2)


def patch_extension_js(content):
    content, n_legacy = strip_legacy(content)
    if MARKER_BOOT in content:
        print(f"{YELLOW}[2/3]{RESET} extension.js — already patched")
        return content if n_legacy else None

    helpers = set(re.findall(r'([\w$]+)\("disableLoginPrompt"\)', content))
    if len(helpers) != 1:
        banner("FIX-STYLE-PILLS PATCH FAILED",
               f"config getter resolved to {sorted(helpers) or 'nothing'} (expected 1)",
               IMPACT_LINES)
        return False
    helper = helpers.pop()

    anchor = re.compile(r'window\.IS_SIDEBAR\s*=\s*\$\{[^}]+\?"true":"false"\}')
    matches = list(anchor.finditer(content))
    if len(matches) != 1:
        banner("FIX-STYLE-PILLS PATCH FAILED",
               f"IS_SIDEBAR bootstrap anchor matched {len(matches)} times (expected 1)",
               IMPACT_LINES)
        return False

    # The getter runs on the extension host, so it has to be evaluated inside
    # `${…}` of the surrounding template literal — emitted bare it would ship
    # as browser JS and throw. Default-on: an absent setting reads as
    # undefined, so compare against false rather than true.
    # No webview edit is needed: the rules ride in as a <style> element.
    inject = (
        f'\n          {MARKER_BOOT}'
        f'{GLOBAL}=${{{helper}("fixStylePills")!==!1}};'
        f'if({GLOBAL}){{'
        f'var __fsp=document.createElement("style");'
        f"__fsp.textContent='{PILL_CSS}';"
        f'(document.head||document.documentElement).appendChild(__fsp);}}'
    )
    end = matches[0].end()
    print(f"{GREEN}[2/3]{RESET} extension.js — global wired via {helper}()"
          " + style injected")
    return content[:end] + inject + content[end:]


def patch_webview(content):
    """Strip the predecessor's injections. Nothing else touches the webview."""
    content, n_legacy = strip_legacy(content)
    msg = "legacy hide reverted" if n_legacy else "nothing to do"
    print(f"{GREEN}[3/3]{RESET} webview/index.js — {msg}")
    return content if n_legacy else None



def main():
    ext_dir = resolve_ext_dir(sys.argv)
    check_files(ext_dir, ["package.json", "extension.js", "webview/index.js"])

    pkg_path = ext_dir / "package.json"
    ext_path = ext_dir / "extension.js"
    wv_path = ext_dir / "webview/index.js"

    new_pkg = patch_package_json(pkg_path)

    new_ext = patch_extension_js(ext_path.read_text())
    if new_ext is False:
        return 1
    new_wv = patch_webview(wv_path.read_text())
    if new_wv is False:
        return 1

    if new_pkg is not None:
        pkg_path.write_text(new_pkg)
    if new_ext is not None:
        ext_path.write_text(new_ext)
    if new_wv is not None:
        wv_path.write_text(new_wv)

    print(f"{GREEN}✓{RESET} fix-style-pills applied")
    return 0


if __name__ == "__main__":
    sys.exit(main())
