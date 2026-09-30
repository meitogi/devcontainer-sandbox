---
description: |
  The visual fidelity loop — read real values from Figma and from the running
  app instead of eyeballing a PNG. Covers the baked script set at
  /opt/devcontainer/base/skills/visual-loop/scripts/, the 1:1 mockup-matching
  procedure, and the Figma 429 manual failover. Read this BEFORE any pixel work,
  and before driving the human's browser.

  Auto-trigger : "match the mockup", "1:1 with Figma", "pixel perfect",
  "reproduce this design", "screenshot the app", "compare against the mockup",
  "drive the browser", "figma returns 429", "the capture looks cropped",
  "measure this render", "read the computed styles", "the tab is not frontmost",
  "contact sheet of the breakpoints".
argument-hint: "[figma node id | url | component name]"
---

# Visual loop

Read real values, check real output. Never eyeball a PNG.

**Input — Figma.** `node /opt/devcontainer/base/skills/visual-loop/scripts/figma.mjs ls` → tree with node ids ; `get <id>` → reduced
JSON ; `png <id>` → reference render. Ids work as `195-2` or `195:2`, and any
node argument may be a pasted URL. **429 →
[manual failover](#figma-manual-failover), never a retry.**

**Output — the running app.** Everything goes through the [browser
half](#tooling). HOST-side prerequisites, both of them human actions the
container cannot perform : your project's dev server, and a debug-enabled
Chromium (in the repo this skill grew in, `wtf dev` and `wtf browser --install`).
Plus the app's **tab frontmost in its own window**. The window may sit behind the editor — captures rasterise from the
renderer, so an unfocused window is fine and `document.hasFocus() === false` is
the normal, supported state. A background **tab** is not : it stops painting,
so `cdp.mjs` refuses (**exit 9**) rather than measure a frozen frame.

- **Three refusals mean "the world is not ready", not "this is broken".** Read
  the exit code before doing anything : **9** the tab is not frontmost — say so
  and wait, or pre-position it with `node /opt/devcontainer/base/skills/visual-loop/scripts/front.mjs` ; **10** another
  session holds the browser — wait and re-run the same command, or pass
  `--wait-lock <seconds>` ; **3** the browser is not running — that is a
  **HUMAN action** — starting the debug browser is host-side and needs a
  window. Relay the
  message's own line as a markdown link or copy-pasteable command and **wait** ;
  never retry in a loop, and never try to launch it from the container. Same
  discipline as the Figma 429 : a failover, not a retry.

- **`--login` on every deep link.** An authenticated shell mounts only when
  authenticated ; logged out, the query string survives but nothing acts on
  it and the page renders empty. Same for any in-page seeding helper.
- **Presets** : `--device desktop|laptop|macbook` = 1920×950 · 1440×800 ·
  1512×789, *viewport* sizes. Iterate on one, `sweep` all at the end.
  `--height` overrides a preset — raise it so the whole element fits
  unscrolled while you iterate.
- **Clear the override when you stop measuring** —
  `node /opt/devcontainer/base/skills/visual-loop/scripts/cdp.mjs reset`, or `--reset` on a sweep
  that also has `--url` and `--out` (both are required, so `sweep --reset`
  alone only prints usage). A capture
  leaves it in place on purpose so a follow-up read measures what was shot —
  but the human then sees a page rendered larger than their window and
  reports it as cropped.
- Unreachable-endpoint messages distinguish "firewall not rebuilt" from
  "browser not running". Read them.

## Tooling

`/opt/devcontainer/base/skills/visual-loop/scripts/` — the things every visual session re-derives, shipped with this skill.
Ten files: `ab-shot.mjs` `cdp.mjs` `e2e.mjs` `figma.mjs` `figma-adopt.mjs`
`front.mjs` `pixel.mjs` `probe.mjs` `shot.mjs` `sweep.mjs`. **Use them instead of
a `node -e` blob** : a blob re-invents the traps above and its output cannot be
diffed against the last run. Coordinates are in **reference units** (the mockup's
own numbers), so `--scale` is the capture's DPR.

*A code span, not a markdown link — the rule below about handing paths to humans
as links is for workspace paths they can click. A baked `/opt` path is neither
relative nor clickable, so a link there would be a lie.*

```
node /opt/devcontainer/base/skills/visual-loop/scripts/pixel.mjs ink --img a.png --rect 24,88,300,108
node /opt/devcontainer/base/skills/visual-loop/scripts/probe.mjs --url '…' --login --origin .drawer '.field-row=gap'
```

`node /opt/devcontainer/base/skills/visual-loop/scripts/<tool>.mjs --help` is the reference — the scripts document themselves,
this file only says which one to reach for.

**The read-only half — touches no state the human owns.** Reads image files and
local processes. Chain it freely. Every row below is `node /opt/devcontainer/base/skills/visual-loop/scripts/<name>`.

| tool | for |
|---|---|
| `ab-shot.mjs` | capture + reference side by side, then `Read` the `--out` path. Refuses a >2 % width mismatch rather than let you measure a mis-crop. **`--detail x,y,w,h`** cuts the same control out of both and magnifies it — the only way a 1px radius or a stroke weight is visible |
| `pixel.mjs` | `edges` / `runs` scanlines · `ink` bounding box with its dominant *and* darkest colour (`--invert` for a white glyph on a brand fill) · `cmp` two-image delta table |

Both take **`--crop right:720`** (or `left:<w>`, `x,y,w,h`) so a raw capture is
read where it lies : no intermediate file, and every coordinate stays in the
element's own frame — the frame the mockup is written in.

**The browser half — drives the human's Chromium.** Every row below is
`node /opt/devcontainer/base/skills/visual-loop/scripts/<name>`. It does **not**
raise the window. It does navigate their tab away from whatever was on screen
and leave a viewport override behind, and `e2e` also clears cookies
browser-wide and writes to the dev database.

| tool | for |
|---|---|
| `shot.mjs` | the capture, `--url` as a flag and **`--scale 2` by default** |
| `probe.mjs` | the gap table : boxes + `getComputedStyle` per selector, boxes relative to `--origin` so they read as the mockup's coordinates |
| `sweep.mjs` | the three presets as one contact sheet, plus per-preset overflow of `--scroll <css>`, **both axes** |
| `e2e.mjs` | a suite of stateful scenarios over one held socket — `--suite plans/<plan>/suites/<name>.mjs`, `--only ID` to chase one. Holds the browser for 1-20 min. The suite supplies `meta.bridge` and, for a precondition, `meta.health` : without them `ctx.query` refuses rather than guessing a table |
| `front.mjs` | bring the app tab to the front of its window. The ONE command here that takes the front — a pre-run step, never automatic |

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
`node /opt/devcontainer/base/skills/visual-loop/scripts/cdp.mjs eval` only for what they do not cover, and then obey both by
hand.

**This directory is baked into the image — read-only in practice. Do not edit
it.** Four ways to change something, cheapest first :

- **A new probe** goes *beside*, in the project layer, at
  `.devcontainer/skills/visual-loop/scripts/<x>.mjs`. It shadows nothing — the
  absolute paths above still resolve — and the project owns it.
- **A change to this prose** ships a project
  `.devcontainer/skills/visual-loop/visual-loop.skill.md`. `sync-skills` reads
  base, then ext, then project, and the later one wins, so a same-named file
  replaces this one whole.
- **A change inside `cdp.mjs` itself** cannot be added beside. Fork it into the
  project layer and point at the fork, or open a PR against the base image.
- **An improvement worth keeping** goes upstream. A one-off blob that answers the
  same question twice belongs in the image, not in a session.

## Configuration

The browser half needs to know what it is looking at. Keys go in
`.devcontainer/.env` — gitignored, loaded into PID 1 by compose's `env_file`, so
every terminal and every Bash call inherits them; restart the container after an
edit.

| key | what | absent |
|---|---|---|
| `CDP_APP_URL` | the app under test | refuses, naming the key |
| `CDP_APP_HOST` | tab-preference host | derived from `CDP_APP_URL` |
| `CDP_APP_ROOT` | the element that means "rendered" | `#app` |
| `CDP_LOGIN_URL` | where the app POSTs credentials. `{origin}` is replaced **in the page**, because only the page knows its own origin — `{origin}/api/auth/login` for a path-prefix stack, `https://api.<host>/auth/login` for a subdomain one | `--login` refuses |
| `CDP_EMAIL` · `CDP_PASSWORD` | the test account | `--login` refuses |
| `CDP_AUTH_MOUNTED` · `CDP_AUTH_ANON` | the two child selectors that tell signed-in from signed-out | **documented no-op** — the render check takes its generic arm and reports the selector instead of the auth state. Both or neither: one alone cannot tell the states apart |
| `VISUAL_LOOP_OUT_DIR` | where Figma dumps and the lock live | `<cwd>/.tmp/design` |

**No silent fallback, anywhere.** There is no default URL and no default
credential — a credential baked into a published image is a trap shaped like a
convenience, and a guessed origin gets *measured* rather than refused, which
surfaces as a wrong number several steps later. A missing key prints one sentence
naming it.

`e2e.mjs` is configured by its suite rather than by the environment: `meta.bridge`
names the in-page function that runs SQL, `meta.seeded` is the expression that
turns true once data has landed, `meta.health` is a precondition checked once.
Without `seeded` the run says so in one dim line — a scenario reading zero rows
may be racing the first sync rather than hitting a bad seed.

## 1:1 procedure

When the task is *match the mockup*, not *use the right tokens*.

1. **Dump AND render.** JSON for structure, PNG for what JSON omits — text
   inside an instance, a placeholder colour, a glyph position. Freeze both
   in `plans/<slug>/design/` (gitignored) and cite the source file next to
   every value you write into code.
2. **The dump is not the last word.** Reduced JSON stops at a depth and
   drops `fills` on mixed-paint nodes. Missing or suspicious → measure the
   render.
3. **Measuring a render** — `node /opt/devcontainer/base/skills/visual-loop/scripts/pixel.mjs`, not a `node -e` blob :
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
4. **Capture at the reference's DPR** — `node /opt/devcontainer/base/skills/visual-loop/scripts/shot.mjs` already
   defaults to `--scale 2`. At 1x a 1.2px stroke covers no pixel fully : an
   icon read grey 190 against the reference's 121, pure artefact. At 2x both
   read 115.
5. **One viewport while iterating, all at the end.** A second resolution
   changes what wraps and turns every diff into guesswork. Raise `--height`
   instead so the whole element fits unscrolled, then
   `node /opt/devcontainer/base/skills/visual-loop/scripts/sweep.mjs --url '…' --out plans/<slug>/shots/x.png --reset`
   once it matches ; `macbook` is the shortest and decides whether a modal
   fits.
6. **A dedicated replica, not a modified demo.** The scroll demos prove
   scrolling and their tests assert row counts — put fidelity work in its
   own dev-only component, behind `process.env.NODE_ENV === 'development'` in
   your app's dev-only component registry.
7. **The replica holds no geometry.** Numbers live in your design system's
   reusable primitives. If a replica grows its own paddings, extract them
   before moving on.
8. **Side-by-side into `plans/<slug>/shots/`, then `Read` it** —
   `node /opt/devcontainer/base/skills/visual-loop/scripts/ab-shot.mjs --crop right:720 --out plans/<slug>/shots/…`.
   Both sides at the same scale, a coloured bar per side ; the container has
   no fonts, so baked-in text renders as boxes. Raw captures stay in
   `.tmp/shots/`.
9. **Close with numbers.** A visual match is not proof :
   `node /opt/devcontainer/base/skills/visual-loop/scripts/probe.mjs --origin <shell> '<sel>=<props>' …` over every value
   of the gap table, and paste the output. One call with many selectors, not
   one call per selector.
10. **Expect the mockup to be wrong somewhere.** Figma floors auto-layout
    frames and lets a child overflow a wrapper it declared too short — a
    36-tall row holding a 40-tall field eats 4px of the padding below it.
    When one band disagrees with the five that agree, reproduce the design
    intent and record the deviation ; do not fit the code to the artefact.

## Figma manual failover

**Never retry during a lock** — that is what escalates the tier : a
`Retry-After: 60` retried into a 4.6-day lock. `figma.mjs` persists the deadline
in `<cwd>/.tmp/design/.figma-lock.json` and refuses to call. Do not delete it.
**Run `figma.mjs` from your repo root** : the path is anchored on the working
directory (`VISUAL_LOOP_OUT_DIR` moves it), so a call from a subdirectory writes
a second lock that excludes nothing.

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
4. **JSON → a local Figma plugin.** Not shipped with this skill — a project
   supplies one, emitting the same reduced shape `figma.mjs get` writes. No
   quota, no PAT scope. Human : select the node (a COMPONENT_SET yields every
   variant) → run the plugin's dump command → copy the textarea → paste into the
   pre-created file.
   *Not "REST cannot" — REST exposes variants (`componentProperties`,
   `componentPropertyDefinitions`) and per-side borders
   (`individualStrokeWeights`) ; our reducer in
   `/opt/devcontainer/base/skills/visual-loop/scripts/figma.mjs` drops them. Widening it is the standing improvement.*
5. **PNG → Figma's own export, then adopt it.** Say exactly :

   > Export in **PNG 2x** (file or zip, whatever Figma gives you), rename it
   > `panel.zip`, drop it in [.tmp/inbox/](.tmp/inbox/).

   Then `node /opt/devcontainer/base/skills/visual-loop/scripts/figma-adopt.mjs .tmp/inbox/panel.zip --out
   plans/<slug>/design --width <frame width>` — it unzips, strips `@2x` and
   spaces, and **reports the export scale**. Expect a clean 2 ; below that, ask
   again rather than compensating in code.
6. Then work entirely off disk — no network needed for the rest.

## Dogfood shorthand (project wrappers)

The repo this skill grew in wraps the same scripts as `wtf claude-script <tool>`
and `wtf claude-live <tool>`. The image ships the `wtf` binary but **not** these
task definitions — they live in that project's own `.wtfcmd.yaml`. If
`wtf claude-live` is not a command where you are, use the `node` form above; it
is the canonical one.

**With the wrappers, put `--` before the tool's own flags.** The entries declare
only which tool to run; `--` is wtfcmd's end-of-flags marker (`wtf/router.go`: it
flips `canBeFlag` off, there is no passthrough variable), so everything after it
reaches the script verbatim. Without it wtf eats the flags and errors. The `node`
form has no such marker and needs none.

```
wtf claude-script pixel -- ink --img a.png --rect 24,88,300,108
wtf claude-live probe  -- --url '…' --login --origin .drawer '.field-row=gap'
```
