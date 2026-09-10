---
description: |
  The visual fidelity loop — read real values from Figma and from the running
  app instead of eyeballing a PNG. Covers the `wtf claude-script` /
  `wtf claude-live` tooling, the 1:1 mockup-matching procedure, and the Figma
  429 manual failover. Read this BEFORE any pixel work, and before driving the
  human's browser.

  Auto-trigger : "match the mockup", "1:1 with Figma", "pixel perfect",
  "reproduce this design", "screenshot the app", "compare against the mockup",
  "wtf claude-live", "wtf figma returns 429", "the capture looks cropped",
  "measure this render", "read the computed styles".
argument-hint: "[figma node id | url | component name]"
---

# Visual loop

Read real values, check real output. Never eyeball a PNG.

**Input — Figma.** `wtf figma ls` → tree with node ids ; `get <id>` → reduced
JSON ; `png <id>` → reference render. Ids work as `195-2` or `195:2`, and any
node argument may be a pasted URL. **429 →
[manual failover](#figma-manual-failover), never a retry.**

**Output — the running app.** Everything goes through
[`wtf claude-live`](#tooling). HOST-side prerequisites : `wtf dev` *and*
`wtf browser` (`--install` once), and the app's **tab frontmost in its own
window**. The window may sit behind the editor — captures rasterise from the
renderer, so an unfocused window is fine and `document.hasFocus() === false` is
the normal, supported state. A background **tab** is not : it stops painting,
so `cdp.mjs` refuses (**exit 9**) rather than measure a frozen frame.

- **Three refusals mean "the world is not ready", not "this is broken".** Read
  the exit code before doing anything : **9** the tab is not frontmost — say so
  and wait, or pre-position it with `wtf claude-live front` ; **10** another
  session holds the browser — wait and re-run the same command, or pass
  `--wait-lock <seconds>` ; **3** the browser is not running — that is a
  **HUMAN action** (`wtf browser`, host-side, needs a window). Relay the
  message's own line as a markdown link or copy-pasteable command and **wait** ;
  never retry in a loop, and never try to launch it from the container. Same
  discipline as the Figma 429 : a failover, not a retry.

- **`--login` on every deep link.** `Layout.vue` mounts only when
  authenticated ; logged out, the query string survives but nothing acts on
  it and the page renders empty. Same for `window.seedCalendarDay()`.
- **Presets** : `--device desktop|laptop|macbook` = 1920×950 · 1440×800 ·
  1512×789, *viewport* sizes. Iterate on one, `sweep` all at the end.
  `--height` overrides a preset — raise it so the whole element fits
  unscrolled while you iterate.
- **Clear the override when you stop measuring** —
  `node .devcontainer/claude/scripts/cdp.mjs reset`, or `--reset` on a sweep
  that also has `--url` and `--out` (both are required, so `sweep --reset`
  alone only prints usage). A capture
  leaves it in place on purpose so a follow-up read measures what was shot —
  but the human then sees a page rendered larger than their window and
  reports it as cropped.
- Unreachable-endpoint messages distinguish "firewall not rebuilt" from
  "browser not running". Read them.

## Tooling

[.devcontainer/claude/scripts/](.devcontainer/claude/scripts/) — the things
every visual session re-derives. **Use them instead of a `node -e` blob** : a
blob re-invents the traps above and its output cannot be diffed against the last
run. Coordinates are in **reference units** (the mockup's own numbers), so
`--scale` is the capture's DPR.

**Put `--` before the tool's own flags.** The wtf entries declare only which
tool to run ; `--` is wtfcmd's end-of-flags marker (`wtf/router.go` : it flips
`canBeFlag` off, there is no passthrough variable), so everything after it
reaches the script verbatim. Without it wtf eats the flags and errors.

```
wtf claude-script pixel -- ink --img a.png --rect 24,88,300,108
wtf claude-live probe  -- --url '…' --login --origin .n-drawer '.field-row=gap'
```

`<tool> -- --help` is the reference — the scripts document themselves, this
file only says which one to reach for.

**`wtf claude-script <tool>` — touches no state the human owns.** Reads image
files and local processes. Chain it freely.

| | for |
|---|---|
| `ab-shot` | capture + reference side by side, then `Read` the `--out` path. Refuses a >2 % width mismatch rather than let you measure a mis-crop. **`--detail x,y,w,h`** cuts the same control out of both and magnifies it — the only way a 1px radius or a stroke weight is visible |
| `pixel` | `edges` / `runs` scanlines · `ink` bounding box with its dominant *and* darkest colour (`--invert` for a white glyph on a brand fill) · `cmp` two-image delta table |
| `gate` | lint + suite, read for you : the 0/0/0 totals, the per-layer counts, and every skip's diagnostic line quoted. Exits non-zero unless clear, which `wtf lint ; wtf test` cannot |

Both take **`--crop right:720`** (or `left:<w>`, `x,y,w,h`) so a raw capture is
read where it lies : no intermediate file, and every coordinate stays in the
element's own frame — the frame the mockup is written in.

**`wtf claude-live <tool>` — drives the human's Chromium.** It does **not**
raise the window. It does navigate their tab away from whatever was on screen
and leave a viewport override behind, and `e2e` also clears cookies
browser-wide and writes to the dev database.

| | for |
|---|---|
| `shot` | the capture, `--url` as a flag and **`--scale 2` by default** |
| `probe` | the gap table : boxes + `getComputedStyle` per selector, boxes relative to `--origin` so they read as the mockup's coordinates |
| `sweep` | the three presets as one contact sheet, plus per-preset overflow of `--scroll <css>`, **both axes** |
| `e2e` | a suite of stateful scenarios over one held socket — `--suite plans/<plan>/suites/<name>.mjs`, `--only ID` to chase one. Holds the browser for 1-20 min |
| `front` | bring the app tab to the front of its window. The ONE command here that takes the front — a pre-run step, never automatic |

Three rules for the live half :

- **Batch the reads.** One `probe` with ten selectors is one navigation ; ten
  calls are ten. This is the rule that never stopped mattering, and it now
  matters more : each call also takes and releases the browser lock.
- **Name it in the description**, in those words : "drives the browser". The
  window no longer flashes, but the human's tab still changes under them if
  they happen to be looking at it.
- **One browser command per Bash call.** Not for the flash — that is gone — but
  because two of them cannot overlap : the second is refused with **exit 10**
  while the first holds the lock, and in an `a && b` the description names only
  one of the two.

They re-navigate before every read and wrap their expression in an IIFE —
the tab may have moved, and evals share the page context so a bare `const`
collides with a previous call. Drop to
`node .devcontainer/claude/scripts/cdp.mjs eval` only for what they do not
cover, and then obey both by hand.

Improve them in place when a session needs a new probe. A one-off blob that
answers the same question twice belongs here.

## 1:1 procedure

When the task is *match the mockup*, not *use the right tokens*.

1. **Dump AND render.** JSON for structure, PNG for what JSON omits — text
   inside an instance, a placeholder colour, a glyph position. Freeze both
   in `plans/<slug>/design/` (gitignored) and cite the source file next to
   every value you write into code.
2. **The dump is not the last word.** Reduced JSON stops at a depth and
   drops `fills` on mixed-paint nodes. Missing or suspicious → measure the
   render.
3. **Measuring a render** — `wtf claude-script pixel`, not a `node -e` blob :
   - Derive the scale from a known value (frame width from the dump). Never
     assume 2x. `--scale` then makes every number a mockup number.
   - **Scan edges at mid-height** (`pixel runs --axis h --at <mid>`). A 16px
     corner radius pulls the top row ~7px inward ; a field's 10px radius
     makes its left edge read 8px too far right if you scan its top border
     row.
   - **Colour = dominant or darkest, never the mean.** Antialiasing drags a
     mean towards the background ; `pixel ink` reports both.
   - **Font size = a ratio.** Cap height against a run whose size the dump
     gives, or ink width against `ctx.measureText()` at candidate sizes.
   - **`pixel cmp` pairs runs by index** — solid on structure, noise on a row
     of glyphs. Compare rules and borders with it, not text.
4. **Capture at the reference's DPR** — `wtf claude-live shot` already
   defaults to `--scale 2`. At 1x a 1.2px stroke covers no pixel fully : an
   icon read grey 190 against the reference's 121, pure artefact. At 2x both
   read 115.
5. **One viewport while iterating, all at the end.** A second resolution
   changes what wraps and turns every diff into guesswork. Raise `--height`
   instead so the whole element fits unscrolled, then
   `wtf claude-live sweep -- --url '…' --out plans/<slug>/shots/x.png --reset`
   once it matches ; `macbook` is the shortest and decides whether a modal
   fits.
6. **A dedicated replica, not a modified demo.** The scroll demos prove
   scrolling and their tests assert row counts — put fidelity work in its
   own dev-only component behind
   `process.env.NODE_ENV === 'development'` in
   [services/doctor/src/modals.ts](services/doctor/src/modals.ts).
7. **The replica holds no geometry.** Numbers live in reusable primitives —
   [services/doctor/src/ui/form/](services/doctor/src/ui/form/). If a
   replica grows its own paddings, extract them before moving on.
8. **Side-by-side into `plans/<slug>/shots/`, then `Read` it** —
   `wtf claude-script ab-shot -- --crop right:720 --out plans/<slug>/shots/…`.
   Both sides at the same scale, a coloured bar per side ; the container has
   no fonts, so baked-in text renders as boxes. Raw captures stay in
   `.tmp/shots/`.
9. **Close with numbers.** A visual match is not proof :
   `wtf claude-live probe -- --origin <shell> '<sel>=<props>' …` over every value
   of the gap table, and paste the output. One call with many selectors, not
   one call per selector.
10. **Expect the mockup to be wrong somewhere.** Figma floors auto-layout
    frames and lets a child overflow a wrapper it declared too short — a
    36-tall row holding a 40-tall field eats 4px of the padding below it.
    When one band disagrees with the five that agree, reproduce the design
    intent and record the deviation ; do not fit the code to the artefact.

## Figma manual failover

**Never retry during a lock** — that is what escalates the tier : a
`Retry-After: 60` retried into a 4.6-day lock. `figma.mjs` persists the
deadline in `.tmp/design/.figma-lock.json` and refuses to call. Do not
delete it.

1. **Pre-create the JSON targets empty**, so the human pastes into an
   existing file : `: > plans/<slug>/design/frame-panel.json`. **Never
   pre-create a PNG** — a zero-byte file is not an image and looks like a
   finished export.
2. **Hand over a `.md` of clickable links** —
   `plans/<slug>/design/TODO-export.md`, one row per node, each target in
   `[text](<path from the workspace root>)` form. Same rule for every path you
   give the human, anywhere : markdown link, never backticks.
3. **Ask for everything in one batch** — frame, every component set whose
   states you need, and the render.
4. **JSON → the local plugin** [scripts/figma-plugin/](scripts/figma-plugin/) :
   no quota, no PAT scope, already in the shape we consume. Human : select
   the node (a COMPONENT_SET yields every variant) → run *Symptems dump* →
   copy the textarea → paste into the pre-created file.
   *Not "REST cannot" — REST exposes variants (`componentProperties`,
   `componentPropertyDefinitions`) and per-side borders
   (`individualStrokeWeights`) ; our reducer in
   [.devcontainer/claude/scripts/figma.mjs](.devcontainer/claude/scripts/figma.mjs)
   drops them. Widening it is the standing improvement.*
5. **PNG → Figma's own export, then adopt it.** Say exactly :

   > Export in **PNG 2x** (file or zip, whatever Figma gives you), rename it
   > `panel.zip`, drop it in [.tmp/inbox/](.tmp/inbox/).

   Then `node .devcontainer/claude/scripts/figma-adopt.mjs .tmp/inbox/panel.zip --out
   plans/<slug>/design --width <frame width>` —
   [it](.devcontainer/claude/scripts/figma-adopt.mjs) unzips, strips `@2x` and
   spaces, and **reports the export scale**. Expect a clean 2 ; below that, ask
   again rather than compensating in code.
6. Then work entirely off disk — no network needed for the rest.
