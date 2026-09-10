#!/usr/bin/env python3
# @patch-category: ux
# @patch-files: package.json
# @patch-files: extension.js
# @patch-files: webview/index.js
# @patch-sentinel: /*mbf-v2*/
# @patch-sentinel: /*mbf-open*/
# @patch-sentinel: /*mbf-boot-v2*/
# @patch-summary: Shows the model currently in use as a read-only badge in the composer
#   footer, behind claudeCode.modelBadgeFooter — off by default from 2.1.258,
#   where the restyled stock pill already names the model.
#     n.commandRegistry.registerAction({id:"model",…},"Model",()=>{z(!0)})
"""
Adds a small read-only badge to the composer footer of the Claude Code VS
Code extension, showing the model currently in use — without having to open
the `/model` picker to find out.

Why
---
Nothing in the UI states which model is answering. The information exists
(`currentModelInfo`) but is only surfaced inside the picker popup, so the
one question asked most often — "what am I actually talking to right now?"
— costs two clicks and a 9-second config fetch to answer.

That is worse than merely inconvenient here, because the model can change
without any user action: `applyRefusalFallback()` silently reassigns
`modelSelection` when a refusal triggers a fallback, and a race in
`getModelSetting()` could seed the wrong one at launch (both documented in
model-selection-fix.py). A permanently visible badge turns those from
invisible into obvious.

Placement
---------
Footer row, immediately before the permission-mode selector:

    [attach] [/] [context %] ──spacer── ( Fable 5 )[mode ▾] [send]

i.e. after `Ld.spacer`, so the badge groups with the other session-state
controls rather than the left-hand action cluster — which grows with
attachments and would otherwise push it around.

Styling reuses `footerButton` — the exact class on the permission-mode
trigger, which renders its label as `b("span",{children:g.label})` inside
`` className:`${Ld.footerButton} …` ``. Sharing it is what makes font-size,
line-height and vertical alignment match the neighbouring "Edit
automatically" precisely rather than approximately; an invented style was
tried first and read as visibly off. A 4 px right margin separates the two,
and pointerEvents:none strips the button affordances: this is a readout,
never a control, and making it clickable would duplicate the mode selector
sitting right beside it.

Label
-----
Built from the CANONICAL model id, not the server `displayName`. Alias
entries ship generic names — the account default and `opus[1m]` are both
labelled just "Opus", and the Fable entry just "Fable" — which hides the
generation actually in use. Reading `resolvedModel` instead (the alias's
real target) makes `default`, `opus[1m]` and `claude-opus-5[1m]` all render
"Opus 5", and `claude-fable-5[1m]` render "Fable 5".

The formatter strips the `claude-` prefix and any `[1m]` suffix, drops
6+-digit date segments, capitalises the family and dot-joins the version:
`claude-opus-4-8[1m]` → "Opus 4.8", `claude-haiku-4-5-20251001` → "Haiku
4.5". displayName remains the fallback when an id doesn't parse.

Resolution
----------
Same three-tier cascade as model-selection-fix.py (exact → strip trailing
`[1m]` → resolvedModel), applied to `modelSelection || modelSetting`.

It deliberately does NOT read `currentModelInfo` as its primary source:
that computed resolves `modelSelection || "default"` and never consults
modelSetting, so before any manual pick it reports the ACCOUNT default
(Opus) rather than the configured model. Using it directly would have made
the badge contradict the picker's own checkmark. It is kept only as a last
resort when the cascade finds nothing.

Every property access is optional-chained and the whole thing is wrapped in
a try/catch returning "": a decorative readout must never be able to break
the composer it sits in. An empty result renders nothing at all rather than
an empty pill.

Cross-version: the JSX factory, the CSS-module object, the picker component
and the store are ALL captured from the anchor — none is hard-coded, since
every one of them is a minified name that drifts between releases.

Idempotency: the injection is delimited by `/*mbf-vN*/ … /*mbf-end*/` and
stripped before re-applying, so the file returns to pristine bytes.

Self-healing v1
---------------
- v1 (2026-08) : initial badge.

Exit codes
----------
- 0 : applied
- 1 : regex miss / file missing (red banner via _common.banner)

Usage
-----
    model-badge-footer.py [EXT_DIR]
"""

import json
import re
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import YELLOW, GREEN, BOLD, RESET, banner, resolve_ext_dir, check_files


TAG = '/*mbf-v2*/'
OPEN_TAG = '/*mbf-open*/'
END = '/*mbf-end*/'
BOOT_MARKER = '/*mbf-boot-v2*/'
# v1 emitted `h0("modelBadgeFooter")` as literal text; h0 is an extension-host
# function, so it threw in the webview and killed the bootstrap script. v2
# evaluates it host-side inside `${…}`. Stripped on sight — one line each.
BOOT_STRIP = re.compile(r'\n[ \t]*/\*mbf-boot-v1\*/[^\n]*')

SETTING_KEY = "claudeCode.modelBadgeFooter"
GLOBAL = "window.__CC_modelBadgeFooter__"

# From this release the stock model pill is restyled rather than hidden (see
# fix-style-pills.py) and already names the model, so the badge is redundant
# and ships off. Older bundles keep it on: there the pill is hidden instead.
BADGE_OFF_SINCE = (2, 1, 258)

STRIP_PAT = re.compile(r'/\*mbf-(?:v\d+|open)\*/.*?/\*mbf-end\*/', re.DOTALL)


# --- Expose the picker's opener -------------------------------------------
# The badge lives in the footer component (MXe); the picker's open state is
# held three components away (rendered in `en`), so the setter is simply not
# in scope. Rather than thread a prop through minified intermediaries — which
# would break on any re-bundling — capture the handler the existing
# "Switch model…" command action already closes over:
#
#     n.commandRegistry.registerAction({id:"model",…},"Model",()=>{z(!0)})
#
# The badge then opens the picker through the exact same code path as the
# command palette entry, instead of a second, parallel way to open it.
# Re-assigned on every render of the owning component, so it always points at
# the live setter.
OPENER_PAT = re.compile(r'\},"Model",\(\)=>\{([\w$]+)\(!0\)\}\)\}\)')


def _opener_sub(m):
    setter = m.group(1)
    return (
        '},"Model",()=>{' + setter + '(!0)})'
        + OPEN_TAG
        # Toggle, not force-open: clicking the badge again closes the picker,
        # matching how the mode selector's own trigger behaves.
        + ';window.__mbfToggleModelPicker=()=>{' + setter + '((__o)=>!__o)};'
        + END
        + '})'
    )

IMPACT_LINES = [
    "→ The composer footer will NOT show the model in use; you have to open",
    "  /model to find out, and silent model changes stay invisible.",
    "→ No functional impact: the badge is a read-only decoration.",
    "Likely cause : CLAUDE_CODE_VERSION was bumped and the footer layout",
    "  changed (spacer div, permission-mode call-site, or the store ident).",
    "  Review the regex in",
    "  .devcontainer/claude/vscode-ext-patchs/model-badge-footer.py.",
]

ANCHOR = re.compile(
    r'([\w$]+)\("div",\{className:([\w$]+)\.spacer\}\),'
    r'\1\(([\w$]+),\{mode:([\w$]+),availableModes:([\w$]+),'
    r'onSelect:\(([\w$]+)\)=>void ([\w$]+)\.setPermissionMode'
)


def _sub(m):
    jsx, css, picker, mode_var, modes_var, sel_arg, store = m.groups()

    # Resolve a display name defensively: the store exposes the connection
    # either directly or one level down depending on the render path.
    resolve = (
        '(()=>{try{'
        f'var __s={store}.modelSelection?.value'
        f'||{store}.config?.value?.modelSetting'
        f'||{store}.connection?.value?.config?.value?.modelSetting;'
        f'var __cc={store}.claudeConfig?.value'
        f'||{store}.connection?.value?.claudeConfig?.value;'
        'var __l=[...(__cc?.models??[]),...(__cc?.unavailable_models??[])];'
        'var __c=(__v)=>(__v||"").replace(/\\[1m\\]$/,"");'
        'var __o=__c(__s);'
        # Same tier order as the picker's cascade, including the `default`
        # de-prioritisation — badge and checkmark must never disagree about
        # which entry is current.
        'var __m=__l.find((__x)=>__x.value===__s)'
        '||__l.find((__x)=>__c(__x.value)===__o)'
        '||__l.find((__x)=>__x.value!=="default"&&__c(__x.resolvedModel)===__o)'
        '||__l.find((__x)=>__c(__x.resolvedModel)===__o);'
        # Build the label from the canonical id, not the server displayName:
        # aliases ship generic names ("Opus", "Fable") that hide the actual
        # generation. resolvedModel is preferred because it is the alias's
        # real target — `default` and `opus[1m]` both resolve to
        # claude-opus-5[1m], and must therefore both read "Opus 5".
        'var __pretty=(__id)=>{'
        'var __b=__c(__id||"").replace(/^claude-/,"");'
        'var __p=__b.split("-").filter((__x)=>__x&&!/^\\d{6,}$/.test(__x));'
        'if(!__p.length)return "";'
        'var __n=__p[0].charAt(0).toUpperCase()+__p[0].slice(1);'
        'var __r=__p.slice(1).join(".");'
        'return __r?__n+" "+__r:__n;};'
        'var __id=__m?.resolvedModel||__m?.value||__s;'
        f'return __pretty(__id)||__m?.displayName'
        f'||{store}.currentModelInfo?.value?.displayName||__s||"";'
        '}catch(__e){return ""}})()'
    )

    # Reuse the permission-mode trigger's own class: it is the sibling this
    # badge sits against, so sharing it is the only way font-size, line-height
    # and vertical alignment match exactly instead of approximately.
    #
    # type:"button" is not optional — the footer sits inside a form whose send
    # control is type:"submit", so a bare <button> would submit the prompt on
    # every click.
    # footerButton ships `padding:2px 4px` and
    # `color:var(--app-secondary-foreground)` — sized for a button that leads
    # with an icon, and deliberately muted. This one is text-only and names
    # the model actually answering, so it gets roomier horizontal padding and
    # the primary foreground. Everything else (font-size, radius, hover,
    # alignment) still comes from the shared class.
    badge = (
        f'((__d)=>__d&&{GLOBAL}?{jsx}("button",'
        f'{{type:"button",className:{css}.footerButton,'
        'style:{marginRight:"4px",padding:"2px 8px",'
        'color:"var(--app-primary-foreground)"},'
        'title:"Switch model",'
        'onClick:()=>{try{window.__mbfToggleModelPicker&&'
        'window.__mbfToggleModelPicker()}catch(__e){}},'
        f'children:__d}})'
        f':null)({resolve}),'
    )

    return (
        f'{jsx}("div",{{className:{css}.spacer}}),'
        + TAG + badge + END
        + f'{jsx}({picker},{{mode:{mode_var},availableModes:{modes_var},'
        f'onSelect:({sel_arg})=>void {store}.setPermissionMode'
    )


def patch(js_path):
    content = js_path.read_text()

    stripped = len(STRIP_PAT.findall(content))
    if stripped:
        content = STRIP_PAT.sub('', content)

    matches = list(ANCHOR.finditer(content))
    if not matches:
        banner("MODEL BADGE NOT INJECTED",
               "webview/index.js: composer footer anchor not found",
               IMPACT_LINES)
        return None

    content, n = ANCHOR.subn(_sub, content)

    # Without the opener the badge still renders, it just does nothing on
    # click — degrade loudly rather than shipping a dead control silently.
    content, n_open = OPENER_PAT.subn(_opener_sub, content)
    if n_open == 0:
        banner("MODEL BADGE OPENER NOT WIRED",
               'webview/index.js: the "Switch model…" registerAction anchor '
               "was not found — the badge will render but stay inert",
               IMPACT_LINES)

    js_path.write_text(content)
    idents = ', '.join(matches[0].groups())
    note = f" (stripped {stripped} stale)" if stripped else ""
    return (f"webview/index.js — badge injected at {n} site(s) "
            f"(idents={idents}), opener wired at {n_open} site(s){note}")


def ext_version(ext_dir):
    raw = json.loads((ext_dir / "package.json").read_text()).get("version", "0")
    parts = re.findall(r"\d+", raw)[:3]
    return tuple(int(p) for p in parts) + (0,) * (3 - len(parts))


def patch_package_json(path, default_on):
    """Declare the setting. Its default follows the extension version."""
    pkg = json.loads(path.read_text())
    props = pkg["contributes"]["configuration"]["properties"]
    if props.get(SETTING_KEY, {}).get("default") == default_on:
        print(f"{YELLOW}[1/3]{RESET} package.json — already declared")
        return None
    props[SETTING_KEY] = {
        "type": "boolean",
        "default": default_on,
        "description": (
            "Show the model in use as a badge in the composer footer. "
            "Off by default from 2.1.258, where the restyled model pill "
            "already names it. Takes effect after Reload Window."
        ),
    }
    print(f"{GREEN}[1/3]{RESET} package.json — declared {SETTING_KEY} "
          f"(default={str(default_on).lower()})")
    return json.dumps(pkg, indent=2)


def patch_extension_js(path):
    """Materialise the setting as a global in the webview bootstrap script."""
    content = path.read_text()
    content, n_stale = BOOT_STRIP.subn("", content)
    if BOOT_MARKER in content:
        print(f"{YELLOW}[2/3]{RESET} extension.js — already patched")
        return content if n_stale else None

    helpers = set(re.findall(r'([\w$]+)\("disableLoginPrompt"\)', content))
    if len(helpers) != 1:
        banner("MODEL BADGE SETTING NOT WIRED",
               f"config getter resolved to {sorted(helpers) or 'nothing'} (expected 1)",
               IMPACT_LINES)
        return False
    helper = helpers.pop()

    anchor = re.compile(r'window\.IS_SIDEBAR\s*=\s*\$\{[^}]+\?"true":"false"\}')
    matches = list(anchor.finditer(content))
    if len(matches) != 1:
        banner("MODEL BADGE SETTING NOT WIRED",
               f"IS_SIDEBAR bootstrap anchor matched {len(matches)} times (expected 1)",
               IMPACT_LINES)
        return False

    end = matches[0].end()
    # Evaluated host-side inside `${…}`: h0 does not exist in the webview.
    inject = (f'\n          {BOOT_MARKER}'
              f'{GLOBAL}=${{{helper}("modelBadgeFooter")===!0}};')
    print(f"{GREEN}[2/3]{RESET} extension.js — global wired via {helper}()")
    return content[:end] + inject + content[end:]


def main():
    ext_dir = resolve_ext_dir(sys.argv)
    check_files(ext_dir, ["package.json", "extension.js", "webview/index.js"])

    version = ext_version(ext_dir)
    default_on = version < BADGE_OFF_SINCE
    print(f"  extension {'.'.join(map(str, version))} → badge default "
          f"{'on' if default_on else 'off'}")

    new_pkg = patch_package_json(ext_dir / "package.json", default_on)
    new_ext = patch_extension_js(ext_dir / "extension.js")
    if new_ext is False:
        sys.exit(1)

    # The webview half rewrites in place, so it goes last — nothing after it
    # can fail and leave package.json describing a setting nothing reads.
    line = patch(ext_dir / "webview" / "index.js")
    if line is None:
        sys.exit(1)

    if new_pkg is not None:
        (ext_dir / "package.json").write_text(new_pkg)
    if new_ext is not None:
        (ext_dir / "extension.js").write_text(new_ext)
    print(f"{GREEN}[3/3]{RESET} {line}")


if __name__ == "__main__":
    main()
