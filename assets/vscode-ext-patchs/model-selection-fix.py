#!/usr/bin/env python3
# @patch-category: fix
# @patch-files: extension.js
# @patch-files: webview/index.js
# @patch-sentinel: /*msf-v1*/
# @patch-summary: Makes the configured model win over a narrower fallback, and makes the
#   picker tick it in both render phases.
#     b("div",{className:Nl.checkIcon,children:o===h.value&&b(_N,{})})
"""
Makes the Claude Code VS Code extension actually honour the configured
model: `.claude/settings.local.json` wins, and the picker ticks it in both
render phases.

Why
---
Three defects, all confirmed by the `[model-timing]` probes rather than
inferred. `.claude/settings.local.json` IS read correctly — the probe shows
`settingsModel=claude-fable-5`, a value that exists in no other file of the
chain — but two stages downstream can still discard it.

1. RACE (real consequences, not cosmetic).

       getModelSetting(){
         return this.cachedClaudeSettings?.effective?.model   // merged: sees .local.json
             ?? this.cachedUserSettings?.model                // ~/.claude/settings.json ONLY
             ?? "default"
       }

   `cachedUserSettings` is the raw parse of `<config-dir>/settings.json`
   alone (see loadUserSettings) — it structurally cannot know about
   `.claude/settings.local.json`. So the fallback is not a degraded version
   of the same answer, it is a DIFFERENT answer from a narrower file.
   Observed live, 3 pushes out of 8 carried the wrong one:

       15:45:46.500Z pushStateUpdate WARM … settingsModel=opus[1m]
       15:45:46.505Z pushStateUpdate WARM … settingsModel=claude-fable-5

   Note both are WARM: the config promise had resolved while
   cachedClaudeSettings had not yet been assigned, so gating on "config
   loaded" does NOT close this window — that was tried and rejected.
   If launchClaude seeds during those milliseconds it locks onto
   `opus[1m]`, and `if(!this.modelSelection.value)` means it never
   re-seeds. modelSelection is what goes to the spawn, so the SESSION runs
   on the wrong model, not merely the checkmark.

2. STRICT EQUALITY. The picker does `l.find((p) => p.value === o)`. The
   server list is not even stable in shape — the same Fable entry arrived
   two ways four seconds apart:

       15:45:42  …, claude-fable-5,                    …
       15:45:46  …, claude-fable-5[1m]>claude-fable-5, …

   So `claude-fable-5` ticks during the first push and stops ticking on the
   final one. Verified by executing the injected code against both lists:
   NO settings value can satisfy the pins frame and the live frame at once
   (`claude-fable-5` ticks before / nothing after; `claude-fable-5[1m]` the
   exact inverse). Chasing the "right" string is therefore a dead end —
   the comparison has to become tolerant.

3. NO PRECEDENCE. `if(!this.modelSelection.value)` means a manual pick,
   once persisted, outranks the settings file forever.

Strategy
--------
Fix 1 — publish `modelSettingReady` (= cachedClaudeSettings is populated)
  in getCurrentState(), next to modelSetting itself.

  An earlier attempt silenced getModelSetting() instead — return undefined
  until the settings load. It closed the race but broke the footer badge and
  the pre-load checkmark, because during the ~10 s config fetch the webview
  is served by pushChannelStateUpdate() with `config: undefined`: modelSetting
  is then the ONLY model information it holds, and blanking it left nothing
  to display or tick. Kept here as the reason this is a flag and not a guard.

  The real defect was conflating two uses of one value. SEEDING the session
  model must not be wrong; DISPLAYING the current model must not be blank.
  So getModelSetting() stays untouched — the badge and the picker keep their
  best-known guess — and the flag lets the one consumer that must be right
  wait for certainty.

Fix 2 — reuse the three-tier cascade Anthropic already ships in
  `currentModelInfo` (exact → strip trailing `[1m]` → resolvedModel) at the
  one place they forgot it. `l` is `[...availableModels, ...unavailableModels]`,
  so a single edit covers the pinned frame and the live frame both.

Fix 3 — seed whenever modelSetting is defined, instead of only when
  modelSelection is empty. Composes with fix 1 at no extra cost: during the
  race modelSetting is `undefined`, so the "is it defined" guard skips the
  window without a line of special-casing.

Ownership note: the pickerMatch and launchSeed probes live HERE, not in
model-timing-probe.py, because they observe the two statements this script
rewrites. Split across two scripts, whichever ran second would find its
anchor already mutated and stop matching silently.

Cross-version: every minified identifier is CAPTURED, never hard-coded.
Anchors key off stable method names and the shape of the statements.

Idempotency: each injection is delimited by `/*msf-vN*/ … /*msf-end*/`, so
stripping is mechanical and restores the pristine bytes — verified by
running the patch twice and comparing checksums.

Self-healing v1
---------------
- v1 (2026-08) : initial three fixes.
- (2026-09) : fix 6 — the upstream footer pill, new in 2.1.258, reads
  `modelSelection` alone and so renders the literal "Model" for as long as
  fix 3 legitimately withholds the seed. Display-path fallback to
  modelSetting, 2.1.258+ only (the pill does not exist before).

Exit codes
----------
- 0 : applied
- 1 : regex miss / file missing (red banner via _common.banner)

Usage
-----
    model-selection-fix.py [EXT_DIR]
"""

import re
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import YELLOW, GREEN, BOLD, RESET, banner, resolve_ext_dir, check_files


TAG = '/*msf-v1*/'
END = '/*msf-end*/'
PREFIX = '[model-timing]'

GATE = (
    '!["0","off","false","no"].includes('
    'String(localStorage.getItem("CLAUDE_EXT_VSCODE_LOG")??"1").toLowerCase())'
)


def probe(phase, pairs):
    """console + cumulative window.__modelTiming, same shape as the probe script."""
    text = '+" "+'.join(f'"{k}="+({v})' for k, v in pairs)
    fields = ''.join(f',{k}:({v})' for k, v in pairs)
    return (
        f'try{{if({GATE}){{'
        f'var __t=new Date().toISOString();'
        f'console.log("{PREFIX} "+__t+" {phase} "+{text});'
        f'(window.__modelTiming=window.__modelTiming||[])'
        f'.push({{ts:__t,phase:"{phase}"{fields}}});'
        f'}}}}catch(__e){{}};'
    )


IMPACT_LINES = [
    "→ The configured model (.claude/settings.local.json) may be IGNORED:",
    "  the picker won't tick it, and a stale manual pick can outrank it.",
    "→ Fallback : pick the model by hand in /model each session.",
    "Likely cause : CLAUDE_CODE_VERSION was bumped and an anchor drifted",
    "  (getModelSetting body, the picker's find, or the launchClaude seed).",
    "  Review the regexes in",
    "  .devcontainer/claude/vscode-ext-patchs/model-selection-fix.py.",
]


# --- Fix 1 : publish whether modelSetting can be trusted yet --------------
# NOT by silencing getModelSetting(): that was tried and broke both the badge
# and the pre-load checkmark. During the ~10 s config fetch the webview is
# served by pushChannelStateUpdate() with `config: undefined`, so modelSetting
# is the ONLY model information it has; returning undefined there left nothing
# to display or tick.
#
# The mistake was conflating two uses of one value. SEEDING the session model
# needs a trustworthy value; DISPLAYING the current one is fine with the best
# known guess. So keep getModelSetting() intact and ship a flag alongside it:
# consumers that must not be wrong check the flag, consumers that must not be
# blank ignore it.
F1_PAT = re.compile(
    r'getCurrentState\(\)\{let ([\w$]+)=this\.getAuthStatus\(\);return\{'
)


def _f1_sub(m):
    auth = m.group(1)
    return (
        f'getCurrentState(){{let {auth}=this.getAuthStatus();return{{'
        + TAG + 'modelSettingReady:this.cachedClaudeSettings!==void 0,' + END
    )


F1_STRIP = (
    re.compile(
        r'getCurrentState\(\)\{let ([\w$]+)=this\.getAuthStatus\(\);return\{'
        r'/\*msf-v\d+\*/.*?/\*msf-end\*/',
        re.DOTALL,
    ),
    r'getCurrentState(){let \1=this.getAuthStatus();return{',
)


# --- Fix 2 : canonical cascade + the probe that watches it ----------------
# --- Fix 2 : resolve the current model ONCE, feed both consumers ----------
# The checkmark is NOT driven by the `l.find(...)` effect — that only feeds
# `s`, the keyboard-highlight (`activeModelItem`). The tick is a separate raw
# comparison, repeated for the available and unavailable lists:
#
#     b("div",{className:Nl.checkIcon,children:o===h.value&&b(_N,{})})
#
# Patching only the effect therefore fixed the highlight and left the tick
# exactly as broken as before. Both consumers now read one resolved value.
#
# Resolving once also avoids a trap in the obvious alternative: comparing
# each row canonically would tick SEVERAL rows, since `default` and
# `opus[1m]` both canonicalise to claude-opus-5.

def _f2a_sub(m):
    act, set_act, pool, avail, unavail, ref1, ref2 = m.groups()
    # `o` (currentModel) is a VXe parameter, in scope here.
    return (
        f'let[{act},{set_act}]=ne(null),{pool}=co(()=>[...{avail}??[],'
        f'...{unavail}??[]],[{avail},{unavail}]),'
        f'{ref1}=Se(null),{ref2}=Se(null);'
        + '/*msf-sel*/'
        + 'var __mc=(__v)=>(__v||"").replace(/\\[1m\\]$/,"");'
        + 'var __mo=__mc(o);'
        # Tier 3 runs twice, skipping `default` first: it is a pointer, not a
        # model, and resolves to the same target as the concrete entry. It
        # sits first in the server list, so a naive find ticks "Default".
        + f'var __sf={pool}.find((__p)=>__p.value===o)'
        + f'||{pool}.find((__p)=>__mc(__p.value)===__mo)'
        + f'||{pool}.find((__p)=>__p.value!=="default"'
        '&&__mc(__p.resolvedModel)===__mo)'
        + f'||{pool}.find((__p)=>__mc(__p.resolvedModel)===__mo);'
        + 'var __sel=__sf?__sf.value:o;'
        + END
    )


F2A_PAT = re.compile(
    r'let\[([\w$]+),([\w$]+)\]=ne\(null\),([\w$]+)=co\(\(\)=>\[\.\.\.([\w$]+)\?\?\[\],'
    r'\.\.\.([\w$]+)\?\?\[\]\],\[\4,\5\]\),([\w$]+)=Se\(null\),([\w$]+)=Se\(null\);'
)
F2A_STRIP = (
    re.compile(r'/\*msf-sel\*/.*?/\*msf-end\*/', re.DOTALL), '',
)


# The highlight effect now matches on the resolved value — plain equality is
# enough once __sel names a real entry.
def _f2b_sub(m):
    is_open, found, pool, arg, current, setter = m.groups()
    return (
        f'if(!{is_open})return;' + '/*msf-eff*/'
        + f'let {found}={pool}.find((__p)=>__p.value===__sel);'
        + probe('pickerMatch', [
            ('current', current),
            ('resolved', '__sel'),
            ('matched', f'{found}?{found}.value:"NONE"'),
            ('poolSize', f'{pool}?{pool}.length:0'),
            ('pool', f'({pool}||[]).map((__x)=>__x.value+'
                     '(__x.resolvedModel&&__x.resolvedModel!==__x.value'
                     '?">"+__x.resolvedModel:"")).join(",")'),
        ])
        + END
        + f'{setter}({found}?.value||null)'
    )


F2B_PAT = re.compile(
    r'if\(!([\w$]+)\)return;let ([\w$]+)=([\w$]+)\.find\(\(([\w$]+)\)=>\4\.value===([\w$]+)\);'
    r'([\w$]+)\(\2\?\.value\|\|null\)'
)
F2B_STRIP = (
    re.compile(
        r'/\*msf-eff\*/let ([\w$]+)=([\w$]+)\.find\(\(__p\)=>__p\.value===__sel\);'
        r'.*?/\*msf-end\*/',
        re.DOTALL,
    ),
    r'let \1=\2.find((p)=>p.value===o);',
)


# The checkmark itself, both lists. The original currentModel ident is carried
# in the marker so the strip can restore it verbatim across versions.
def _f2c_sub(m):
    css, current, item, icon = m.groups()
    return (
        f'b("div",{{className:{css}.checkIcon,children:'
        f'/*msf-chk:{current}*/__sel==={item}.value'
        f'&&b({icon},{{}})}})'
    )


F2C_PAT = re.compile(
    r'b\("div",\{className:([\w$]+)\.checkIcon,children:([\w$]+)===([\w$]+)\.value'
    r'&&b\(([\w$]+),\{\}\)\}\)'
)
F2C_STRIP = (
    re.compile(r'/\*msf-chk:([\w$]+)\*/__sel===([\w$]+)\.value'),
    r'\1===\2.value',
)


# --- Fix 3 : settings outranks a persisted pick + seeding probes ----------
def _f3_sub(m):
    conn = m.group(1)
    setting = f'{conn}.config.value?.modelSetting'
    ready = f'{conn}.config.value?.modelSettingReady'
    return (
        TAG
        + probe('launchSeed:before', [
            ('selection', 'this.modelSelection.value'),
            ('modelSetting', setting),
            ('ready', ready),
        ])
        # Gate on the flag, not on the value: during the fetch window
        # modelSetting is the user-level fallback, which is a plausible-looking
        # WRONG answer (it cannot see .claude/settings.local.json). Seeding it
        # would lock the session onto the wrong model for good.
        + f'if({ready}&&{setting}!==void 0)this.modelSelection.value={setting};'
        + probe('launchSeed:after', [
            ('selection', 'this.modelSelection.value'),
        ])
        + END
    )


F3_PAT = re.compile(
    r'if\(!this\.modelSelection\.value\)this\.modelSelection\.value='
    r'([\w$]+)\.config\.value\?\.modelSetting;'
)
F3_STRIP = (
    re.compile(
        r'/\*msf-v\d+\*/.*?if\(([\w$]+)\.config\.value\?\.modelSettingReady&&'
        r'\1\.config\.value\?\.modelSetting!==void 0\)'
        r'this\.modelSelection\.value=\1\.config\.value\?\.modelSetting;'
        r'.*?/\*msf-end\*/',
        re.DOTALL,
    ),
    r'if(!this.modelSelection.value)this.modelSelection.value='
    r'\1.config.value?.modelSetting;',
)


# --- Fix 4 : read the project settings on the FAST path ------------------
# The extension already reads ~/.claude/settings.json itself, in the
# constructor, without waiting for the CLI — that is why a value is available
# during the 5-10 s config fetch. But it reads ONLY that file, so the value it
# serves is the user-level one, and the badge shows "Opus" before flipping to
# "Opus 5" once the CLI's merged settings land.
#
# Reading the two project files on the same fast path removes the flicker at
# its source: three small readFile calls versus a 10 s process spawn.
# Precedence mirrors Claude Code's own chain, local overriding project.
#
# Deliberately narrow: only `model` is lifted, into a private field. Merging
# whole settings objects would silently affect permissions and hooks, and
# cachedUserSettings is shipped verbatim to the webview — mutating it would
# make "user settings" mean something else for every other consumer.
def _f4_sub(m):
    cfgdir, es_fn, path_var, path_mod, raw, fs_mod = m.groups()
    return (
        'async loadUserSettings(){' + '/*msf-proj*/'
        + 'try{for(var __f of[".claude/settings.local.json",'
        '".claude/settings.json"]){try{'
        f'var __raw=await {fs_mod}.readFile({path_mod}.join(this.cwd,__f),"utf-8");'
        'var __pm=JSON.parse(__raw)?.model;'
        'if(__pm!==void 0){this.__msfProjectModel=__pm;break}'
        '}catch(__e){}}}catch(__e){}' + END
        + f'let {cfgdir}={es_fn}(),{path_var}={path_mod}.join({cfgdir},"settings.json"),{raw};'
        f'try{{{raw}=await {fs_mod}.readFile({path_var},"utf-8")}}'
        'catch{return this.cachedUserSettings}'
    )


F4_PAT = re.compile(
    r'async loadUserSettings\(\)\{let ([\w$]+)=([\w$]+)\(\),([\w$]+)=([\w$]+)\.join'
    r'\(\1,"settings\.json"\),([\w$]+);try\{\5=await ([\w$]+)\.readFile'
    r'\(\3,"utf-8"\)\}catch\{return this\.cachedUserSettings\}'
)
F4_STRIP = (re.compile(r'/\*msf-proj\*/.*?/\*msf-end\*/', re.DOTALL), '')


# --- Fix 5 : prefer the project model over the user-level fallback --------
F5_PAT = re.compile(
    r'getModelSetting\(\)\{return this\.cachedClaudeSettings\?\.effective'
    r'\?\.model\?\?this\.cachedUserSettings\?\.model\?\?"default"\}'
)
F5_SUB = (
    'getModelSetting(){return this.cachedClaudeSettings?.effective?.model'
    + '/*msf-gms*/??this.__msfProjectModel' + END
    + '??this.cachedUserSettings?.model??"default"}'
)
F5_STRIP = (re.compile(r'/\*msf-gms\*/.*?/\*msf-end\*/', re.DOTALL), '')


# --- Fix 2, modern flavour (2.1.258+) ------------------------------------
# The picker was restructured: the model row became its own component fed a
# pre-computed `isCurrent` boolean, and the available/unavailable spread was
# replaced by a split memo. The three legacy anchors describe code that no
# longer exists — but the same three jobs remain, and they get *smaller*:
#
#   1. resolve the current model once   -> a `__msfSel` helper + `__msfC`,
#      spliced into the component's own `let` chain right after the split memo
#   2. the keyboard-highlight seed      -> one `.main.find(...)` call
#   3. the tick                         -> a single `isCurrent:` prop, where
#      the legacy bundle repeated a raw comparison per list
#
# The helper is declared inside the picker component, not at module scope:
# both consumers live in that component, so nothing leaks into the bundle.
_MSF_HELPER = (
    '__msfSel=(__pool,__cur)=>{'
    'var __mc=(__v)=>(__v||"").replace(/\\[1m\\]$/,"");'
    'var __mo=__mc(__cur),__p=__pool||[];'
    'return __p.find((__x)=>__x.value===__cur)'
    '||__p.find((__x)=>__mc(__x.value)===__mo)'
    # `default` is a pointer, not a model: it resolves to the same target as
    # the concrete entry and sits first, so a naive scan ticks "Default".
    '||__p.find((__x)=>__x.value!=="default"&&__mc(__x.resolvedModel)===__mo)'
    '||__p.find((__x)=>__mc(__x.resolvedModel)===__mo)}'
)

F2A258_PAT = re.compile(
    r'([\w$]+)=([\w$]+)\(\(\)=>([\w$]+)\(([\w$]+)\?\?\[\],([\w$]+)\?\?\[\],'
    r'([\w$]+)\),\[\4,\5,\6\]\),'
)


def _f2a258_sub(m):
    split, memo, splitter, avail, unavail, cur = m.groups()
    return (
        f'{split}={memo}(()=>{splitter}({avail}??[],{unavail}??[],{cur}),'
        f'[{avail},{unavail},{cur}]),'
        + TAG + _MSF_HELPER + ','
        + f'__msfC=__msfSel([...({avail}??[]),...({unavail}??[])],{cur}),'
        + END
    )


F2A258_STRIP = (
    re.compile(r'/\*msf-v\d+\*/__msfSel=.*?/\*msf-end\*/', re.DOTALL), '',
)

F2B258_PAT = re.compile(
    r'([\w$]+)\(([\w$]+)\.main\.find\(\(([\w$]+)\)=>\3\.value===([\w$]+)\)'
    r'\?\.value\?\?null\)'
)


def _f2b258_sub(m):
    setter, split, item, cur = m.groups()
    # The seed runs inside an effect reading a ref, so it resolves against
    # that ref's currentModel rather than the render-time `__msfC`.
    return f'{setter}(/*msf-seed*/__msfSel({split}.main,{cur})?.value??null)'


F2B258_STRIP = (
    re.compile(
        r'([\w$]+)\(/\*msf-seed\*/__msfSel\(([\w$]+)\.main,([\w$]+)\)'
        r'\?\.value\?\?null\)'
    ),
    r'\1(\2.main.find((__i)=>__i.value===\3)?.value??null)',
)

F2C258_PAT = re.compile(r'isCurrent:([\w$]+)===([\w$]+)\.value')


def _f2c258_sub(m):
    cur, item = m.groups()
    return f'isCurrent:/*msf-chk:{cur}*/(__msfC?.value??{cur})==={item}.value'


F2C258_STRIP = (
    re.compile(
        r'isCurrent:/\*msf-chk:([\w$]+)\*/\(__msfC\?\.value\?\?\1\)==='
        r'([\w$]+)\.value'
    ),
    r'isCurrent:\1===\2.value',
)


# --- Fix 6 : the footer pill has a label before the seed runs (2.1.258+) --
# The composer footer gained an upstream model pill in 2.1.258, and it reads
# `modelSelection` alone:
#
#     $1=$.modelSelection.value, … c=…:t??($1&&i.length>0?yi($1,"Model"):void 0)
#     …
#     D(Q$0,{label:c,…})            // button renders `children: $??"Model"`
#
# `modelSelection` is undefined until the seed in launchClaude() fires — and
# fix 3 gates that seed on modelSettingReady while launchClaude() early-returns
# on a set claudeChannelId, so a cold start that preloads before the settings
# land never seeds at all. The pill then reads the literal "Model" for the
# whole life of the tab, even though the pinned frame already carries
# everything needed: `{value:"default", resolvedModel:"claude-opus-5[1m]"}`.
#
# Restoring the eager seed would reinstate the race fix 3 exists to close, so
# the repair belongs on the display path — the same split this file already
# draws: seeding must not be WRONG, displaying must not be BLANK. Falling back
# to `modelSetting` is what the popup's own tick does two lines below
# (`r30(i,$1||$.config.value?.modelSetting)`); the pill just never got it.
#
# Rebinding `$1` rather than patching the `c=` cascade makes the whole footer
# behave exactly as it would have if the seed had run — same z1, same effort
# capabilities, same picker round-trip — instead of leaving the label agreeing
# with a selection the rest of the block still reads as empty.
#
# Anchored through `if(<entry>?.supportsEffort)`: the effort-level command
# action opens with a byte-identical binding chain and must NOT be caught here.
def _f6_sub(m):
    pool, sess, sel, canon, entry, item = m.groups()
    return (
        f'{pool}=JH({sess}.claudeConfig.value),{sel}='
        + '/*msf-pill*/'
        + f'({sess}.modelSelection.value??{sess}.config.value?.modelSetting)'
        + END + ','
        + f'{canon}={sel}==="default"||!{sel}?"default":{sel},'
        + f'{entry}={pool}.find(({item})=>{item}.value==={canon});'
        + f'if({entry}?.supportsEffort)'
    )


F6_PAT = re.compile(
    r'([\w$]+)=JH\(([\w$]+)\.claudeConfig\.value\),([\w$]+)=\2\.modelSelection\.value,'
    r'([\w$]+)=\3==="default"\|\|!\3\?"default":\3,'
    r'([\w$]+)=\1\.find\(\(([\w$]+)\)=>\6\.value===\4\);if\(\5\?\.supportsEffort\)'
)
F6_STRIP = (
    re.compile(
        r'([\w$]+)=/\*msf-pill\*/\(([\w$]+)\.modelSelection\.value\?\?'
        r'\2\.config\.value\?\.modelSetting\)/\*msf-end\*/,'
    ),
    r'\1=\2.modelSelection.value,',
)


EXT_FIXES = [
    ("modelSettingReady", F1_PAT, _f1_sub, F1_STRIP),
    ("projectSettingsFastPath", F4_PAT, _f4_sub, F4_STRIP),
    ("getModelSettingPrefersProject", F5_PAT, F5_SUB, F5_STRIP),
]
# Legacy picker (2.1.145 → 2.1.220).
WEB_FIXES = [
    ("resolveCurrent", F2A_PAT, _f2a_sub, F2A_STRIP),
    ("highlightEffect", F2B_PAT, _f2b_sub, F2B_STRIP),
    ("checkIcon", F2C_PAT, _f2c_sub, F2C_STRIP),
    ("settingsPrecedence", F3_PAT, _f3_sub, F3_STRIP),
]
# Restructured picker (2.1.258+). Fix 3 is shared — its anchor did not move.
WEB_FIXES_258 = [
    ("resolveCurrent258", F2A258_PAT, _f2a258_sub, F2A258_STRIP),
    ("highlightEffect258", F2B258_PAT, _f2b258_sub, F2B258_STRIP),
    ("checkIcon258", F2C258_PAT, _f2c258_sub, F2C258_STRIP),
    ("settingsPrecedence", F3_PAT, _f3_sub, F3_STRIP),
    ("footerPillLabel258", F6_PAT, _f6_sub, F6_STRIP),
]


def _apply(js_path, fixes, label, quiet=False):
    """Apply a fix set atomically: the file is written only if EVERY fix in
    the set matched. `quiet` suppresses the failure banner so a caller can
    probe one flavour before falling back to another."""
    content = js_path.read_text()

    stripped = 0
    for _name, _pat, _sub, (spat, srepl) in fixes:
        content, n = spat.subn(srepl, content)
        stripped += n

    results, missing = [], []
    for name, pat, sub, _strip in fixes:
        repl = sub if callable(sub) else (lambda _m, _s=sub: _s)
        content, n = pat.subn(repl, content)
        results.append(f"{name}={n}")
        if n == 0:
            missing.append(name)

    if missing:
        if not quiet:
            banner("MODEL SELECTION FIX NOT APPLIED",
                   f"{label}: no match for {', '.join(missing)}",
                   IMPACT_LINES)
        return None

    js_path.write_text(content)
    note = f" (stripped {stripped} stale)" if stripped else ""
    return f"{label} — {', '.join(results)}{note}"


def main():
    ext_dir = resolve_ext_dir(sys.argv)
    check_files(ext_dir, ["extension.js", "webview/index.js"])

    ext_line = _apply(ext_dir / "extension.js", EXT_FIXES, "extension.js")

    # Legacy picker first, restructured picker second. The two anchor sets are
    # mutually exclusive on every vendored bundle, so the order is arbitrary —
    # but a failed probe writes nothing, which is what makes the retry safe.
    web_js = ext_dir / "webview" / "index.js"
    web_line = _apply(web_js, WEB_FIXES, "webview/index.js", quiet=True)
    if web_line is None:
        web_line = _apply(web_js, WEB_FIXES_258, "webview/index.js")

    if ext_line is None or web_line is None:
        sys.exit(1)

    print(f"{GREEN}[1/2]{RESET} {ext_line}")
    print(f"{GREEN}[2/2]{RESET} {web_line}")


if __name__ == "__main__":
    main()
