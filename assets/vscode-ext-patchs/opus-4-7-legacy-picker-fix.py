#!/usr/bin/env python3
# @patch-category: ux
# @patch-files: extension.js
# @patch-files: webview/index.js
# @patch-sentinel: /*opus-fix-v8*/
# @patch-summary: Keeps a chosen set of flagship models in the picker after the server
#   tier filter drops them, and marks the fetch as loading.
"""
Patches the Claude Code VS Code extension's model picker
(webview/index.js — component name drifts: dt1 on 2.1.145, UXe on
2.1.207, VXe on 2.1.220) to always surface a version-specific set of
flagship models, regardless of whether the server-side tier filter
still lists them as "current", and to display a "Loading models…"
badge while the config fetch is in flight.

Why
---
Opus 4.7/4.8 are the models this project relies on for its dominant
workload (~53 % share-of-spend on Ragexe RE). Opus 5 exists but
empirically refuses more often on offensive-framed prompts ; Fable
5 was similar after v207 gained `refusal_fallback` in its capabilities
array (NB : that flag is client-side plumbing for fallback UI when a
refusal arrives — not proof of a server-side classifier, just a signal
Anthropic wired one up for that model). Once Anthropic rotates a model
out of the server-side "current" tier the picker silently drops it
even though the binary still accepts the model ID.

Symptom before patch : `/model` picker shows only tier-current models.
On the 5-10 s first-fetch after Reload Window, the picker was blank
except for the previous patch's hard-coded 4.7 pin — no signal that
more was coming.

Strategy
--------
- Extract the pin list DYNAMICALLY per extension version by scanning
  string literals in extension.js. This means we only pin what the
  extension actually declares (except Opus 4.7 which is a baseline —
  the CLI accepts it across every shipped version, even v145 whose
  baked catalog stops at 4.6).
- Wrap `availableModels:X.claudeConfig.value?.models` at the picker
  call-site :
  - While loading (`__m === void 0`) → return the pins array so the
    user can pick immediately.
  - Once loaded → dedup-merge pins into the real list via `.reduce`.
- On versions ≥ 2.1.207 the picker call-site also passes an
  `unavailableModels` prop. Wrap it so that while loading, an extra
  `{value:"__loading__", displayName:"Loading models…"}` entry is
  appended — rendered `aria-disabled` (non-clickable) in the picker,
  giving users a clear "more is coming" signal.
- On 2.1.145 the picker component signature omits `unavailableModels`
  entirely (`function dt1({isOpen, onClose, availableModels,
  currentModel, onModelSelected})`), so the loading badge silently
  degrades — only the pins are visible during load.

Cross-version : regex captures the minified identifier before
`.claudeConfig.value?.models`. Same call-site anchor works on 145,
207, 220 because the picker component name is not in the anchor — only
the stable prop name + config path are.

Self-healing v1 → v2 → v3 → v4 → v5 → v6 → v7
---------------------------------------------
- v1 (2026-07 initial) : single-model IIFE that pinned only 4.7.
- v2 (2026-07 rewrite) : `.reduce` over pins from `models??[]` — broke
  the loading empty-state because it always emitted a non-empty array.
- v3 (2026-07 fix)     : IIFE returning `void 0` while models is
  undefined, so the built-in "Loading models…" empty-state could fire
  again. But no pins were visible during load — no "safety net" to
  pick anything before the first fetch resolved.
- v4 (2026-07)         : dynamic pins per version + non-void loading
  return so pins are pickable during load + `unavailableModels`
  wrapper that pushes a "Loading models…" pseudo-entry (v207+).
  Regression: dedup was by `.value` equality, but Anthropic ships
  alias entries (`{value:"opus[1m]", resolvedModel:"claude-opus-5[1m]",
  displayName:"Opus"}` and `{value:"sonnet", resolvedModel:"claude-
  sonnet-5", displayName:"Sonnet"}`) — my pins for Opus 5 / Sonnet 5
  / Fable 5 fell through and appeared as visual duplicates.
- v5 (2026-07)         : dedup on canonical id (strip trailing `[1m]`
  suffix, compare against BOTH `.value` and `.resolvedModel` on
  server entries). Pins now carry a `description` field so the sub-
  line renders on the survivors (Opus 4.7, 4.8 typically). Strip
  patterns collapsed to a single generic wrapper-strip so future
  cycles don't need per-version rewrites.
- v6 (2026-08)         : timing probes 6 & 7. The IIFE already sits on
  the exact pins→live switch point, so it stamps an ISO timestamp and
  an entry count on each branch — to `console.log` and to a cumulative
  `window.__modelTiming` array. Counterpart to the extension-side
  probes in model-timing-probe.py, which measure cache hit/miss and
  probe duration; together they bracket the fill latency end to end.
  Grafting here rather than adding a new anchor means these probes
  cannot rot independently: if this patch breaks on a version bump,
  they break with it, loudly, instead of going silently dark.
- v7 (current)         : `default` no longer absorbs a pin through the
  `.resolvedModel` arm of the dedup. The account list lost its
  `opus[1m]` / "Opus" alias, leaving Opus 5 reachable only as
  `{value:"default", resolvedModel:"claude-opus-5[1m]", displayName:
  "Default (recommended)"}` — so v5's dedup swallowed the Opus 5 pin
  and the picker showed no row naming that generation at all. But
  `default` is an account policy, not a model : what it resolves to
  can rotate without notice, which is exactly why a hard pin has to
  survive beside it. Every other alias (`sonnet`, `haiku`,
  `claude-fable-5[1m]`) keeps absorbing its pin, so no duplicate rows
  come back.

- pins-v1 (2026-09)    : the pins are also published to the webview as
  `window.__CC_modelPins__`, from extension.js's `IS_SIDEBAR` bootstrap.
  The composer footer's model pill (2.1.258+) builds its own pool from
  `claudeConfig` and so cannot name a model picked out of THIS list while
  the config frame is still in flight — it renders the literal "Model".
  model-selection-fix.py's fix 6 v2 reads the global. Its own sentinel,
  its own file, undeclared (see PINS_TAG); the `availableModels` wrapper
  and V8_TAG are untouched.

Prior shapes are stripped (revert to raw prop) before v7 applies.

Idempotency at file level : MARKER = literal string `V8_TAG` (below)
emitted inline right after `availableModels:`. Guaranteed absent from
Anthropic's minified webview code and specific to v7's wrapper shape,
so pre-v7 injections aren't misdetected as already-patched.

Exit codes
----------
- 0 : applied or already patched
- 1 : regex miss / file missing (red banner via _common.banner)

Usage
-----
    opus-4-7-legacy-picker-fix.py [EXT_DIR]

If EXT_DIR is omitted, auto-discovers the latest
~/.vscode-server/extensions/anthropic.claude-code-*-{arch} directory.
"""

import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import YELLOW, GREEN, BOLD, RESET, banner, resolve_ext_dir, check_files


BASELINE_PINS = [
    ('claude-opus-4-7[1m]', 'Opus 4.7'),
]

# Which family leads the picker, newest generation first. See
# apply_display_order().
FLAGSHIP_ORDER = ('fable', 'opus', 'sonnet')


def _family_of(value):
    m = re.match(r'claude-([a-z]+)-', value)
    return m.group(1) if m else ''


# Families pinned as legacy fallbacks, in picker tier order. Mythos is
# deliberately absent: it is access-gated, so it shows up in the live list
# only for accounts that have it — pinning it would advertise a model most
# users cannot select. Sonnet keeps its single "latest" pin (see below)
# rather than a full generation sweep.
PINNED_FAMILIES = ('fable', 'opus')

# Anthropic release dates (verified against anthropic.com/news, wikipedia,
# and platform.claude.com/docs release notes — Sep 2026 snapshot). The
# static catalog only ever exposed `knowledge_cutoff`, which is the
# training-data cutoff and not the release date — and from 2.1.258 it is
# gone from extension.js entirely. Purely decorative: a missing entry just
# drops the "Released …" clause from the picker sub-line.
RELEASE_DATES = {
    'claude-opus-4-5':  'Nov 2025',
    'claude-opus-4-6':  'Jan 2026',
    'claude-opus-4-7':  'Apr 2026',
    'claude-opus-4-8':  'May 2026',
    'claude-opus-5':    'Jul 2026',
    'claude-fable-5':   'Jun 2026',
    'claude-fable-5-1': 'Sep 2026',
    'claude-sonnet-5':  'Jun 2026',
}

# Model ids live in the native CLI binary, which is the authority: it is what
# accepts or rejects an id typed into /model. Until 2.1.220 extension.js also
# carried a static catalog (`id:"…" … knowledge_cutoff:"…"`); 2.1.258 dropped
# it, taking `claude-opus-5`, `claude-fable-5` and `claude-opus-4-7` with it —
# so deriving from extension.js there would silently lose the flagships.
NATIVE_BINARY = 'resources/native-binary/claude'

# Bounded on both sides, and the version is restricted to one or two numeric
# components. Both constraints earn their keep against a raw binary scan:
#   - the boundaries stop a match mid-identifier;
#   - the numeric shape rejects ids forged by two adjacent literals sitting
#     back to back in the binary ("claude-fable-5" + "-mythos-5" reads as the
#     contiguous "claude-fable-5-mythos-5"), which no boundary check can see;
#   - the 2-digit cap on the minor rejects dated aliases whose date reads as
#     a numeric minor (claude-opus-4-20250514);
#   - longer dated aliases (claude-opus-4-1-20250805) and tuning suffixes
#     (-fast, -v1) fail the trailing boundary, so they drop out for free.
_BIN_ID_RE = re.compile(
    rb'(?<![A-Za-z0-9._-])(claude-(?:opus|sonnet|haiku|fable|mythos)-'
    rb'[0-9]+(?:-[0-9]{1,2})?)(?![A-Za-z0-9._-])'
)

V8_TAG = '/*opus-fix-v8*/'

# The pins have to reach the composer footer's model pill too, and it cannot
# get them from the wrapper below: it builds its own pool straight from
# `claudeConfig`, and the wrapper's IIFE only runs when the PICKER renders —
# later than, and conditional on, the footer. So the list is published as a
# webview global from extension.js's bootstrap, where it is in place before
# the bundle loads; model-selection-fix.py's fix 6 consumes it.
#
# Sharing a value rather than an anchor is deliberate: the pill's pool sits in
# a statement fix 6 already rewrites, and a second patcher matching it would
# find it mutated and stop matching in silence.
#
# NOT declared in @patch-sentinel, for the same reason fix-style-pills.py
# leaves its two branch markers undeclared: `restore-ext-patches --list` calls
# a patch live only when EVERY declared sentinel is present at once, and this
# one is skipped wherever the bootstrap anchor is absent.
PINS_TAG = '/*opus-pins-v1*/'
PINS_GLOBAL = 'window.__CC_modelPins__'
# Same anchor fix-style-pills.py and model-badge-footer.py stack their own
# lines on.
BOOT_ANCHOR = re.compile(r'window\.IS_SIDEBAR\s*=\s*\$\{[^}]+\?"true":"false"\}')
PINS_STRIP = re.compile(r'\n[ \t]*/\*opus-pins-v\d+\*/[^\n]*')

TIMING_PREFIX = '[model-timing]'
# Same knob as model-timing-probe.py's webview half. A browser context has no
# process.env, so localStorage carries it — and toggles live, no restart.
TIMING_GATE = (
    '!["0","off","false","no"].includes('
    'String(localStorage.getItem("CLAUDE_EXT_VSCODE_LOG")??"1").toLowerCase())'
)

STRIP_AVAIL_PAT = re.compile(
    r'availableModels:(?:/\*.*?\*/)?\(\(__[a-zA-Z_][\w$]*\)=>.*?\)'
    r'\(([\w$]+\.claudeConfig\.value\?\.models)\)',
    re.DOTALL,
)
STRIP_UNAVAIL_PAT = re.compile(
    r'unavailableModels:(?:/\*.*?\*/)?\(\(__[a-zA-Z_][\w$]*\)=>.*?\)'
    r'\(([\w$]+\.claudeConfig\.value\?\.unavailable_models)\)',
    re.DOTALL,
)

AVAIL_PAT = re.compile(r'availableModels:([\w$]+)\.claudeConfig\.value\?\.models')
UNAVAIL_PAT = re.compile(r'unavailableModels:([\w$]+)\.claudeConfig\.value\?\.unavailable_models')


IMPACT_LINES = [
    "→ The '/model' picker may not surface flagship pins (every Fable and",
    "  Opus generation the native CLI binary accepts, plus the newest",
    "  Sonnet) if Anthropic's server-side tier drops them from the",
    "  'current' set.",
    "→ Fallback still works :",
    "    • type `/model claude-opus-4-7[1m]` (or any pinned ID) in chat, or",
    "    • set \"model\": \"claude-opus-4-7[1m]\" in .claude/settings*.json.",
    "Likely cause : CLAUDE_CODE_VERSION was bumped and the picker call-site",
    "  anchor drifted (prop name or claudeConfig path). Review the regex in",
    "  .devcontainer/claude/vscode-ext-patchs/opus-4-7-legacy-picker-fix.py.",
]


def _semver_tuple(vstr):
    parts = re.findall(r'\d+', vstr)
    return tuple(int(p) for p in parts) if parts else (0,)


def _find_cutoff(content, base_id):
    """Extract knowledge_cutoff from the model's static catalog entry."""
    pat = re.compile(
        rf'id:\s*"{re.escape(base_id)}"[\s\S]{{0,4000}}?knowledge_cutoff:\s*"([^"]+)"'
    )
    m = pat.search(content)
    return m.group(1) if m else None


def _description(display_name, released, cutoff):
    parts = [display_name]
    if released:
        parts.append(f'Released {released}')
    if cutoff:
        parts.append(f'Knowledge cutoff {cutoff}')
    if len(parts) == 1:
        parts.append('Legacy pinned model')
    return ' · '.join(parts)


def _pretty_name(base_id):
    """`claude-opus-4-7` → `Opus 4.7`, `claude-fable-5-1` → `Fable 5.1`."""
    family, _, version = base_id[len('claude-'):].partition('-')
    return f'{family.capitalize()} {version.replace("-", ".")}'


def scan_native_binary(bin_path):
    """Collect model ids from the native CLI binary.

    Read in 8 MB chunks with a small overlap so an id straddling a chunk
    boundary is still seen — the binary is ~215 MB and slurping it whole
    would spike memory during an image build.

    Returns {family: [version, …]} sorted newest first.
    """
    families = {}
    overlap = 64
    tail = b''
    with open(bin_path, 'rb') as fh:
        while True:
            chunk = fh.read(8 << 20)
            if not chunk:
                break
            for m in _BIN_ID_RE.finditer(tail + chunk):
                mid = m.group(1).decode('ascii')
                family, _, version = mid[len('claude-'):].partition('-')
                families.setdefault(family, set()).add(version)
            tail = chunk[-overlap:]

    out = {}
    for family, versions in families.items():
        # `claude-opus-4` and `claude-opus-4-0` are the same model under two
        # names; keep the explicit one so the picker doesn't show both
        # "Opus 4" and "Opus 4.0".
        versions -= {v for v in versions if '-' not in v and f'{v}-0' in versions}
        out[family] = sorted(versions, key=_semver_tuple, reverse=True)
    return out


def extract_pins(ext_dir):
    """Derive the version-specific pin set from the native CLI binary.

    Returns a list of `(value, displayName, description)` triples, in picker
    tier order: Fable (newest→oldest), then Opus (newest→oldest), then the
    single newest Sonnet. Every generation the binary accepts is pinned, so a
    version bump that adds a family member needs no edit here.

    `knowledge_cutoff` is still read from extension.js when that version
    carries a static catalog (up to 2.1.220); on later bundles the sub-line
    simply falls back to the release date.
    """
    content = (ext_dir / 'extension.js').read_text()
    binary = ext_dir / NATIVE_BINARY
    if not binary.is_file():
        return []
    families = scan_native_binary(binary)

    def make(value, base_id):
        display_name = _pretty_name(base_id)
        return (value, display_name, _description(
            display_name, RELEASE_DATES.get(base_id), _find_cutoff(content, base_id)))

    pins, seen = [], set()

    def add(value, base_id):
        if base_id in seen:
            return
        seen.add(base_id)
        pins.append(make(value, base_id))

    # Fable carries no [1m] variant; Opus and Sonnet do.
    for version in families.get('fable', []):
        add(f'claude-fable-{version}', f'claude-fable-{version}')

    for version in families.get('opus', []):
        add(f'claude-opus-{version}[1m]', f'claude-opus-{version}')

    # Opus 4.7 is the baseline: emitted even when the binary does not list it
    # (2.1.145 stops at 4.6), because the CLI still accepts the id. Deduped
    # against the derived set above, so it never appears twice.
    for value, _display in BASELINE_PINS:
        add(value, value.replace('[1m]', ''))

    sonnet = families.get('sonnet', [])
    if sonnet:
        add(f'claude-sonnet-{sonnet[0]}[1m]', f'claude-sonnet-{sonnet[0]}')

    return apply_display_order(pins)


def apply_display_order(pins):
    """Lead with the newest of each family, then every older generation.

    extract_pins() groups by family (all Fable, then all Opus, then Sonnet),
    which buries the current Opus behind last generation's Fable. Since v8 the
    pin order IS the picker order, and the picker spills its tail into "More
    models" — so the flagships have to come first. Yields Fable 5.1, Opus 5,
    Sonnet 5, then Fable 5, Opus 4.8, Opus 4.7 … in the order built above.
    """
    head, taken = [], set()
    for family in FLAGSHIP_ORDER:
        for pin in pins:
            if _family_of(pin[0]) == family:
                head.append(pin)
                taken.add(pin[0])
                break
    return head + [p for p in pins if p[0] not in taken]


def _js_string(s):
    # The pins array is also emitted inside extension.js's bootstrap TEMPLATE
    # LITERAL, where a backtick or a `${` would break straight out of it and
    # ship an unparseable bundle. No model id or display name has ever carried
    # either; fail loudly rather than find out in the webview.
    if '`' in s or '${' in s:
        raise ValueError(f'pin string is unsafe in a template literal: {s!r}')
    return s.replace('\\', '\\\\').replace('"', '\\"')


def _pins_arr_js(pins):
    """Emit a JS array literal of `{value, displayName, description}` objects."""
    items = ','.join(
        f'{{value:"{_js_string(v)}",displayName:"{_js_string(d)}",description:"{_js_string(desc)}"}}'
        for v, d, desc in pins
    )
    return '[' + items + ']'


def _make_avail_replacement(pins):
    pins_arr = _pins_arr_js(pins)

    def _sub(m):
        ident = m.group(1)
        # v5 dedup: Anthropic ships alias entries whose `.value` (e.g.
        # `opus[1m]`, `sonnet`, `default`, `claude-fable-5[1m]`) differs
        # from the canonical model id, but `.resolvedModel` names the real
        # target. So compare pin.value's canonical form (strip trailing
        # `[1m]`) against BOTH server entry `.value` AND `.resolvedModel`,
        # both canonicalized the same way. Guarantees pins collapse into
        # existing server entries when they represent the same model.
        # v7: `default` is exempt from the `.resolvedModel` arm. It is not a
        # model, it is an account policy — whatever it resolves to today can
        # rotate tomorrow, so letting it absorb a hard pin is what made
        # "Opus 5" vanish once the account list lost its `opus[1m]` alias.
        # The `.value` arm stays unconditional: "default" never equals a pin.
        # v6 probes 6 & 7: this IIFE IS the pins→live switch point, so it
        # stamps each branch. Failure is swallowed — an observability probe
        # must never be able to break the picker it observes.
        return (
            f'availableModels:{V8_TAG}((__m)=>{{'
            f'try{{if({TIMING_GATE}){{'
            f'var __ts=new Date().toISOString();'
            f'var __ph=__m===void 0?"pins":"live";'
            f'var __n=__m===void 0?{len(pins)}:__m.length;'
            f'var __v=(__m===void 0?{pins_arr}:__m).map((__x)=>__x.value+'
            f'(__x.resolvedModel&&__x.resolvedModel!==__x.value'
            f'?">"+__x.resolvedModel:"")).join(",");'
            f'(window.__modelTiming=window.__modelTiming||[])'
            f'.push({{ts:__ts,phase:"render:"+__ph,n:__n,values:__v}});'
            f'console.log("{TIMING_PREFIX} "+__ts+" render:"+__ph'
            f'+" n="+__n+" values="+__v);'
            f'}}}}catch(__e){{}}'
            f'return __m===void 0?{pins_arr}:(()=>{{'
            f'var __P={pins_arr};'
            f'var __c=(__v)=>(__v||"").replace(/\\[1m\\]$/,"");'
            f'var __hit=(__p,__x)=>{{var __pc=__c(__p.value);'
            f'return __c(__x.value)===__pc||'
            f'(__x.value!=="default"&&__c(__x.resolvedModel)===__pc);}};'
            f'var __merged=__P.reduce((__a,__p)=>'
            f'__a.some((__x)=>__hit(__p,__x))?__a:[...__a,__p],__m);'
            # v8: the pins array is the display order, not just a safety net.
            # The reduce seeds from the server list, so a pin the server no
            # longer lists was appended LAST — which is what put Opus 4.8
            # (still tier-current) ahead of Opus 5 and pushed Opus 5 into
            # "More models". Rank by pin index instead; models absent from
            # the pins keep their server order behind them, since Array#sort
            # is stable as of ES2019.
            # `default` is not a model but the account policy row, and it led
            # the server list before v8 imposed an order. Keep it leading:
            # without this it is unpinned, so it would sort to the bottom.
            f'var __rank=(__x)=>{{'
            f'if(__x.value==="default")return -1;'
            f'var __i=__P.findIndex((__p)=>__hit(__p,__x));'
            f'return __i<0?__P.length:__i;}};'
            f'return __merged.slice().sort((__x,__y)=>__rank(__x)-__rank(__y));'
            f'}})();'
            f'}})'
            f'({ident}.claudeConfig.value?.models)'
        )
    return _sub


def _make_unavail_replacement(m):
    ident = m.group(1)
    return (
        f'unavailableModels:{V8_TAG}((__u)=>{ident}.claudeConfig.value===void 0'
        f'?[...(__u??[]),{{value:"__loading__",displayName:"Loading models…"}}]'
        f':__u)'
        f'({ident}.claudeConfig.value?.unavailable_models)'
    )


def patch_extension_js(js_path, pins):
    """Publish the pins as a webview global, from the bootstrap template.

    Each file gets its own already-patched test: an `extension.js` that still
    needs the global must not be skipped because `webview/index.js` is already
    at v8. Here the strip runs unconditionally and the line is re-emitted, so
    re-applying is idempotent by construction.
    """
    content = js_path.read_text()
    content, n_strip = PINS_STRIP.subn('', content)

    matches = list(BOOT_ANCHOR.finditer(content))
    if len(matches) != 1:
        # Not fatal, and not a banner: the picker is this patcher's job and it
        # is done. Below 2.1.258 there is no footer pill to name anyway. Said
        # out loud rather than passed over, so it cannot rot silently.
        print(f"{YELLOW}[2/2]{RESET} extension.js — IS_SIDEBAR bootstrap anchor "
              f"matched {len(matches)}× (expected 1); pins not published, the "
              f"footer pill keeps its stock label")
        if n_strip:
            js_path.write_text(content)
        return

    end = matches[0].end()
    inject = f'\n          {PINS_TAG}{PINS_GLOBAL}={_pins_arr_js(pins)};'
    js_path.write_text(content[:end] + inject + content[end:])
    print(f"{GREEN}[2/2]{RESET} extension.js — {len(pins)} pins published as "
          f"{PINS_GLOBAL} from the bootstrap"
          + (" (prior line stripped)" if n_strip else ""))


def patch_webview_index_js(js_path, pins):
    content = js_path.read_text()

    if V8_TAG in content:
        print(f"{YELLOW}[1/2]{RESET} webview/index.js — already patched v8 (marker found)")
        return

    n_strip_avail = len(STRIP_AVAIL_PAT.findall(content))
    if n_strip_avail:
        content = STRIP_AVAIL_PAT.sub(r'availableModels:\1', content)
    n_strip_unavail = len(STRIP_UNAVAIL_PAT.findall(content))
    if n_strip_unavail:
        content = STRIP_UNAVAIL_PAT.sub(r'unavailableModels:\1', content)
    if n_strip_avail or n_strip_unavail:
        print(f"{YELLOW}[strip]{RESET} prior wrapper reverted (avail={n_strip_avail}, unavail={n_strip_unavail})")

    avail_matches = list(AVAIL_PAT.finditer(content))
    if not avail_matches:
        banner("OPUS-LEGACY-PICKER-FIX PATCH FAILED",
               "webview/index.js: picker availableModels prop pattern not found",
               IMPACT_LINES)
        sys.exit(1)

    content, n_avail = AVAIL_PAT.subn(_make_avail_replacement(pins), content)
    avail_captures = ', '.join(m.group(1) for m in avail_matches)

    unavail_matches = list(UNAVAIL_PAT.finditer(content))
    if unavail_matches:
        content, n_unavail = UNAVAIL_PAT.subn(_make_unavail_replacement, content)
        unavail_note = f", Loading pseudo-item wired in unavailableModels at {n_unavail} site(s)"
    else:
        unavail_note = " (no unavailableModels prop on this version — Loading badge skipped)"

    js_path.write_text(content)
    pin_summary = ', '.join(d for _, d, _ in pins)
    print(f"{GREEN}[1/2]{RESET} webview/index.js — pins [{pin_summary}] injected at {n_avail} availableModels site(s) (ident={avail_captures}){unavail_note}")


def main():
    ext_dir = resolve_ext_dir(sys.argv)
    check_files(ext_dir, ["webview/index.js", "extension.js"])

    print(f"Patching Claude Code extension at: {ext_dir}")
    pins = extract_pins(ext_dir)
    if not pins:
        binary = ext_dir / NATIVE_BINARY
        reason = (f"{NATIVE_BINARY}: not found — cannot derive model ids"
                  if not binary.is_file()
                  else f"{NATIVE_BINARY}: no model ids matched — pin list empty")
        banner("OPUS-LEGACY-PICKER-FIX EXTRACTOR EMPTY", reason, IMPACT_LINES)
        sys.exit(1)
    print(f"  pins derived from {NATIVE_BINARY}: "
          + ", ".join(v for v, _d, _desc in pins))
    patch_webview_index_js(ext_dir / "webview" / "index.js", pins)
    patch_extension_js(ext_dir / "extension.js", pins)
    print(f"{GREEN}{BOLD}✓ opus-legacy-picker-fix patch complete{RESET}")


if __name__ == "__main__":
    main()
