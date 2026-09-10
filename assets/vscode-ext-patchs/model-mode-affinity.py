#!/usr/bin/env python3
# @patch-category: ux
# @patch-files: webview/index.js
# @patch-sentinel: /*mma-v1*/
# @patch-summary: On an empty session, picking a model also moves the permission mode to
#   the one that model is meant for.
"""
Patches the Claude Code VS Code extension's webview (webview/index.js) so
that, on an EMPTY session, picking a model also moves the permission mode
to the one that model is meant for :

    non-Opus / non-Fable  chosen while in `plan`        → `acceptEdits`
    Opus / Fable          chosen while in `acceptEdits` → `plan`

Anything else is left alone — `default` (Manual), `auto` and
`bypassPermissions` are never entered nor left by this patch.

Why
---
The footer model badge (model-badge-footer.py) made switching models a
one-click affair, but the permission mode does not follow : you drop to
Sonnet for a mechanical task and stay stuck in Plan, then come back to
Opus to think and stay in "Edit automatically". The two controls sit side
by side in the composer footer and are almost always changed together.

The rule is deliberately a two-way mapping between exactly two modes, so
it is reversible : Opus → Sonnet → Opus lands back on Plan. Restricting
it to empty sessions keeps it out of the way once a conversation has a
history, where the mode is a considered choice rather than a default.

Strategy
--------
Hook the session store's `setModel(e)`, which in the webview has exactly
ONE caller — `onModelSelected:async(K)=>await e.setModel(K)`, i.e. always
a user pick from the picker (click, Enter, or the footer badge). Session
restore and launch seeding assign `modelSelection.value` directly and
never go through `setModel`, so hooking here cannot fire on replay.
(Every other `.setModel(` in the bundle belongs to Monaco.)

The injection sits in the comma chain of

    if(this.modelSelection.value=e.value,
       this.lastServedModel.value=void 0,
       this.refusalFallbackNotice.value=null,
       !this.claudeChannelId||!this.connection.value)return;

right before the `!this.claudeChannelId` early-return, which buys two
things for free :

- It runs even when the channel is not up yet — the common case for an
  empty session. `launchClaude()` passes `this.permissionMode.value` to
  the CLI, so a mode set locally before launch is carried through.
- The `catch` arm further down already restores the mode it captured
  before the call (`if(this.permissionMode.value!==i)
  this.setPermissionMode(i,!0,!1)`), so if `setModel` fails over the
  wire our switch is rolled back with it.

⚠ userInitiated MUST be false
-----------------------------
`setPermissionMode(mode, sendToCli, userInitiated)`. The extension host's
`persistDefaultPermissionMode` writes `globalState.defaultPermissionMode`
— but only for `default`/`auto`/`acceptEdits`, and only when
`userInitiated` is true. Passing `!0` there would make an automatic hop
to `acceptEdits` the sticky initial mode of every future session, which
is exactly the behaviour this patch exists to avoid. So we call
`setPermissionMode(mode,!0,!1)` : send it to the CLI, but do not persist.
`plan` is never persisted either way (host-side early-return).

Model classification : `/opus|fable/i` tested against `value` AND
`resolvedModel` concatenated. The picker mixes aliases with canonical ids
(`{value:"opus[1m]",resolvedModel:"claude-opus-5[1m]"}`,
`{value:"default",resolvedModel:"claude-opus-5[1m]"}`), so `default`
classifies as a thinking model through its resolution — and will follow
automatically if Anthropic ever re-points the alias.

Cross-version : the anchor names no component and no minified component
identifier — only stable property paths on the session store, plus the
argument name which is captured and re-emitted. Verified unique on
2.1.220 (a single match across the 4.8 MB bundle).

Application order is irrelevant : model-timing-probe.py injects its probe
between `async setModel(X){` and `let …=this.modelSelection.value,`,
upstream of this anchor, and its own `W8_PAT` still matches afterwards.

Prior shapes are stripped (region removed, reverting to the raw comma
chain) before v1 applies.

Idempotency at file level : delimited region `/*mma-vN*/ … /*mma-end*/`.
STRIP_PAT matches any version, so re-running always rebuilds from
pristine bytes rather than nesting injections.

Exit codes
----------
- 0 : applied or already patched
- 1 : regex miss / file missing (red banner via _common.banner)

Usage
-----
    model-mode-affinity.py [EXT_DIR]

If EXT_DIR is omitted, auto-discovers the latest
~/.vscode-server/extensions/anthropic.claude-code-*-{arch} directory.
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import YELLOW, GREEN, BOLD, RESET, banner, resolve_ext_dir, check_files


TAG = '/*mma-v1*/'
END = '/*mma-end*/'

STRIP_PAT = re.compile(r'/\*mma-v\d+\*/.*?/\*mma-end\*/', re.DOTALL)

# Ends on a lookahead so the early-return condition itself is untouched —
# the injection is appended to the match, landing inside the comma chain.
ANCHOR = re.compile(
    r'if\(this\.modelSelection\.value=([\w$]+)\.value,'
    r'this\.lastServedModel\.value=void 0,'
    r'this\.refusalFallbackNotice\.value=null,'
    r'(?=!this\.claudeChannelId)'
)

# Flagship families, i.e. the ones worth staying in Plan for. Mythos is
# access-gated so it is never pinned in the picker, but it does appear in the
# live list for accounts that have it — and left out of this test it would
# classify as non-thinking and knock Plan mode down to acceptEdits on pick.
THINKING_RE = 'opus|fable|mythos'

IMPACT_LINES = [
    "→ Picking a model no longer moves the permission mode on an empty",
    "  session : Sonnet/Haiku stay in Plan, Opus/Fable stay in",
    "  'Edit automatically'.",
    "→ Fallback still works : Shift+Tab cycles the mode, or use the mode",
    "  selector next to the model badge in the composer footer.",
    "Likely cause : CLAUDE_CODE_VERSION was bumped and setModel's body",
    "  drifted (property order in the comma chain, or the early-return",
    "  guard). Review the regex in",
    "  .devcontainer/claude/vscode-ext-patchs/model-mode-affinity.py.",
]


def _make_replacement(m):
    """Append the affinity IIFE to the matched comma-chain prefix.

    `arg` is setModel's minified parameter (`e` on 2.1.220) — the model
    entry that was just picked. Locals are `__`-prefixed so they cannot
    collide with the surrounding minified scope, and the whole thing is
    swallowed by a catch : a model switch must never break because the
    mode nudge threw.
    """
    arg = m.group(1)
    return (
        m.group(0) + TAG
        + '((__s,__m)=>{try{'
        'if(__s.messages.value.length)return;'
        f'var __t=/{THINKING_RE}/i.test('
        '((__m&&__m.value)||"")+" "+((__m&&__m.resolvedModel)||""));'
        'var __c=__s.permissionMode.value;'
        'if(__t){if(__c==="acceptEdits")__s.setPermissionMode("plan",!0,!1)}'
        'else if(__c==="plan")__s.setPermissionMode("acceptEdits",!0,!1)'
        '}catch(__e){}})'
        f'(this,{arg}),' + END
    )


def patch_webview_index_js(js_path):
    content = js_path.read_text()

    n_strip = len(STRIP_PAT.findall(content))
    if n_strip:
        content = STRIP_PAT.sub('', content)
        print(f"{YELLOW}[strip]{RESET} prior injection reverted (n={n_strip})")

    matches = list(ANCHOR.finditer(content))
    if not matches:
        banner("MODEL-MODE-AFFINITY PATCH FAILED",
               "webview/index.js: setModel comma-chain anchor not found",
               IMPACT_LINES)
        sys.exit(1)

    content, n = ANCHOR.subn(_make_replacement, content)
    js_path.write_text(content)

    args = ', '.join(m.group(1) for m in matches)
    print(f"{GREEN}[1/1]{RESET} webview/index.js — mode affinity injected at "
          f"{n} setModel site(s) (arg={args})")


def main():
    ext_dir = resolve_ext_dir(sys.argv)
    check_files(ext_dir, ["webview/index.js"])

    print(f"Patching Claude Code extension at: {ext_dir}")
    patch_webview_index_js(ext_dir / "webview" / "index.js")
    print(f"{GREEN}{BOLD}✓ model-mode-affinity patch complete{RESET}")


if __name__ == "__main__":
    main()
