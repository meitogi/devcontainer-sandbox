# KNOWLEDGE — /diagram

Lessons accumulated across iterations. **Read before every `.excalidraw`
generation** — these rules prevent already-corrected mistakes from
reappearing.

Format : each entry has an explicit **Rule**, a **Why** (the pattern of
mistake that triggered the lesson) and a **How to apply** (concrete
action). Entries are project-agnostic — applicable to any diagram, not
tied to a specific codebase.

---

## L01 — Vertical spacing : 120px minimum between two rects connected by a labelled arrow

**Rule** — When two rects are stacked vertically and connected by an arrow
that carries a text label, leave **≥ 120px of free gap** between the
bottom edge of the upper rect and the top edge of the lower rect. For an
unlabelled arrow : 80px is enough.

**Why** — A past diagram shipped with 80px between two stacked rects and
a labelled arrow → the label text (16px) didn't fit in the gap, overlapped
the arrow or the boxes. Unreadable.

**How to apply** — Before writing coords : for each labelled vertical
arrow, check `(rect_dest.y - rect_src.y - rect_src.height) >= 120`. If
not, push the destination rect down.

---

## L02 — Large vertical gap before a fan-out / fan-in row

**Rule** — When a single node fans out to (or fans in from) multiple
target nodes arranged in a row, leave **≥ 200px of free gap** between the
upstream row and the fan-out row. Add +40px if any of those arrows carry
labels.

**Why** — A past diagram packed a fan-out row tightly against the
upstream process row → visual overlap, the reader lost the hierarchy and
the multiple arrows became indistinct.

**How to apply** — Identify fan-out / fan-in rows during design. Reserve
a dedicated band at the bottom (or top) of the diagram for them, with the
large gap baked in from the start.

---

## L03 — Fonts : monospace for code identifiers, handwritten for prose

**Rule** — Strict convention :

| `fontFamily` | When to use it |
|---|---|
| **7 (Cascadia, monospace)** | Any text that is a verbatim identifier from the codebase : file path, module name, class name, event name, registry key, function name, env var. |
| **5 (Excalifont, handwritten)** | Zone headers, descriptive prose, non-code action labels, diagram title. |

**Why** — A past diagram mixed fonts inconsistently within itself — some
code identifiers were handwritten, others mono. The « concept vs path »
criterion was too subjective and hard to apply repeatably.

**How to apply** — For each label, ask : *« does this exact text appear
verbatim in source code somewhere ? »*. If yes → mono (7). If no (prose,
category, header) → handwritten (5).

---

## L04 — Dashed frames to delimit logical zones

**Rule** — When a diagram has 2+ logical zones (e.g., client/server,
container/host, app/db, frontend/backend), wrap each zone in a **dashed
rectangle** :

```jsonc
{
  "type": "rectangle",
  "strokeStyle": "dashed",
  "strokeColor": "#868e96",      // discreet gray, recedes vs node black
  "strokeWidth": 1,              // 1, not 2 — frame lighter than nodes
  "backgroundColor": "transparent",
  "roundness": {"type": 3}
}
```

Position : wraps every node in the zone + the zone header. Add ~20px of
padding around. **Z-order : behind every node** (see L05).

**Why** — Without frames, standalone text headers at the top of each
zone aren't enough to visually delimit them. The reader can't tell where
one zone ends and the other begins.

**How to apply** — For each logical zone identified during design, add an
enclosing dashed rectangle as the very first element in the array
(background z-order).

---

## L05 — Background z-order : `Z*` indices before `a0`

**Rule** — To place an element in the background (frames, backdrops), use
an `index` that lex-sorts before `a0`. Convention : `"Zz"`, `"Zy"`,
`"Zx"`, ... (uppercase Z = ASCII 0x5A, lowercase a = 0x61, so `Z*` <
`a*`).

**Why** — Fractional indexing in Excalidraw uses ASCII lexicographic
sort. Smaller index = drawn first = in the background.

**How to apply** — Frames and backdrops first with `Z*`, then nodes /
arrows / labels with `a0`, `a1`, …, `aZ`, `b0`, …

---

## L06 — Generation workflow : NEVER produce output without re-reading KNOWLEDGE.md

**Rule** — On every `/diagram` skill invocation :
1. **Read KNOWLEDGE.md first** (not just skill.md).
2. For each lesson, ask « does my current generation respect this rule ? ».
3. If a lesson is violated → fix BEFORE writing.

**Why** — Lessons exist because the user already corrected the mistakes.
Without systematic re-reading, the agent falls back into the same
mistakes on every new session.

**How to apply** — First action after the skill trigger : `Read
.devcontainer/skills/diagram/KNOWLEDGE.md`. Only then, design.

---

## L07 — Colors : stable categorical palette

**Rule** — For cross-diagram readability, assign node backgrounds from a
fixed palette based on the node's role :

| Category | Background | Examples |
|---|---|---|
| Event source / IO | `#a5d8ff` (blue) | user input, hooks, webhooks, sensors |
| File / data store | `#ffec99` (yellow) | JSONL, DB table, queue, cache |
| Process / module | `#b2f2bb` (green) | daemon, worker, handler, transformer |
| Central hub / bus | `#ffc9c9` (pink) | event bus, message broker, dispatcher |
| Consumer / sink | `transparent` | UI, log file, downstream service |
| Error / cancel handler | `#ffa8a8` (saturated red) | retry, dead-letter, abort path |

**Why** — A reader scanning two consecutive diagrams with the same color
codes grasps the structure faster. Random or per-diagram colors create
visual noise across the body of work.

**How to apply** — Before picking a color, classify the node into one of
the 6 categories above. Stick to the palette unless the node truly
doesn't fit (rare).

---

## L08 — Re-test every rewrite : don't validate on JSON alone

**Rule** — After each generation / rewrite, **don't stop at « jq says
it's valid »**. The user must open the `.excalidraw` in excalidraw.com
(drag & drop) and verify visually :
- Bindings : moving a node makes arrows + labels follow
- Spacing : no text / arrow / rect overlap
- Readability : the flow is clear at first glance

**Why** — JSON validation says nothing about visual rendering. Past
diagrams shipped valid JSON but had cramped layouts that required
multiple correction iterations.

**How to apply** — In the recap, always explicitly ask the user to open
in the app and report on X / Y / Z. Don't claim « it's ready » without
this human-in-the-loop check.

---

## L09 — Verify event / call flow against the code, not just prose

**Rule** — When the diagram shows arrows representing code events (e.g.,
`bus.emit('X')`, `bus.on('X')`, function calls between modules), **grep
the codebase to confirm who emits and who consumes** before drawing.
README / doc prose can be ambiguous or out of date ; the code is
authoritative.

**Why** — In a past iteration, an arrow representing a code event was
nearly drawn the wrong direction based on a README's summary framing.
Grepping the code revealed the actual emitter / consumer was different
from what the prose implied.

**How to apply** — Quick grep before drawing :

```bash
# Who emits this event ?
grep -rn "emit\(.*<event_name>" <relevant_dir>/
# Who consumes it ?
grep -rn "on\(.*<event_name>" <relevant_dir>/
```

If the arrows you intend to draw don't match what grep returns, redesign
or annotate the diagram to reflect actual flow.

---

## L10 — Annotate sub-events at the SOURCE node, not the consumer node

**Rule** — When a node consumes / emits multiple sub-event types worth
documenting on the diagram, place the annotation on the **source side**
(the node that originates the events), not on the consumer side. Two
patterns :

- **Pattern A (lightweight)** : free-floating multi-line text below the
  source node. No container, mono font ~12-14px, left-aligned. Use when
  the source is a single node already in the diagram.
- **Pattern B (architectural)** : a dedicated rect with the sub-event
  list inside, plus an arrow from that rect to the file / queue / bus
  the events are written to. Use when the source itself deserves a
  visible box (external system, user actions, patched component). The
  rect's border can match the flow color (see L11).

**Why** — Cramming sub-types into the consumer's main label is
unreadable. Placing them under the *consumer* misleads the reader into
thinking the consumer generates them. Source-side annotation matches the
data-flow direction.

**How to apply** — Identify : does the source appear as its own node in
the diagram ? If yes, use Pattern A under it. If no, add a dedicated
source rect (Pattern B) with an arrow into the receiving file / queue,
and apply the flow color (L11) if the events belong to a non-primary
flow.

---

## L11 — Proactively color-code overlapping flows ; don't ship monochrome when flows converge

**Rule** — At design time, enumerate the distinct logical data flows the
diagram conveys. If **two or more flows share at least one node**, apply
the flow-color convention from skill.md (Layout → Colors → Flow overlay)
before writing the JSON. Mono-color is fine for a single flow ; the
moment flows overlap, mono creates ambiguity that arrow labels alone
don't resolve.

**Why** — A past iteration shipped monochrome despite two converging
flows. The user had to explicitly request color codes — meaning the
visual ambiguity was obvious at a glance to them but the agent missed
it. When a diagram requires the reader to parse every label to follow a
flow end-to-end, it has failed at its job.

**How to apply** — Before writing the elements array, ask : « how many
distinct logical flows does this diagram show ? ». If ≥ 2 with shared
nodes : pre-emptively color the secondary flow per the skill convention.
State it in the recap : « N flows detected, applied <color> overlay on
the secondary ».

---

## L12 — Arrow length must comfortably exceed the label length

**Rule** — For any arrow carrying a text label, the arrow's geometric
length must be **at least 2× the label's pixel width**. Holds especially
for diagonal and horizontal arrows where the label sits at the midpoint
and visually fills the arrow if too long.

**Why** — A past iteration drew diagonal arrows of ~160px with labels
~160px → the label completely covered the arrow body, leaving only the
arrowhead visible. The reader sees text floating in space rather than a
directed connection between two rects.

**How to apply** — Before committing arrow geometry, estimate label
width : `chars × fontSize × 0.6` (proportional Excalifont) or
`× 0.7` (monospace Cascadia). Compute the required minimum source-to-
target distance : **≥ 2× label width**. If the layout can't accommodate :
widen the column gap (push the receiving rect further away), shorten the
label, or split the label across 2 lines.

---

## L13 — Rect dimensions must accommodate their text content (no truncation)

**Rule** — Before committing rect dimensions, verify that every text
inside (containerized OR free-floating positioned within the rect bounds)
fits without clipping :

- **Width** : Excalidraw does NOT auto-wrap text in standalone text
  elements ; explicit `\n` line breaks are required. Compute the longest
  line's pixel width = `chars × fontSize × 0.6` (Excalifont proportional)
  or `× 0.7` (Cascadia mono). Rect width must exceed `longest_line + 20px`
  total padding.
- **Height** : count all rendered lines (each `\n`-separated segment is
  one line ; Excalidraw renders each segment as a single line whose
  width is the text element's natural width, regardless of the
  `width` field). Height needed = `lines × fontSize × lineHeight +
  20px padding`.
- **Multi-block annotations inside one rect** (e.g., title + send block +
  cancel block) : sum the heights of all blocks plus inter-block gaps
  (typically 10px between blocks).

**Why** — A past iteration produced source-info rects where the text
overflowed both horizontally (long line clipped at right edge) and
vertically (last bullet line cut off at bottom). The `width` field on a
text element is metadata for selection / interaction, not a rendering
wrap constraint.

**How to apply** — Pre-render mental check : compute the longest line's
width in pixels using the formulas above. Compute total content height.
Rect dimensions must exceed these + 20px padding. If a line genuinely
can't fit, wrap it explicitly with `\n` at a word boundary, indenting
the continuation with two spaces (`"  → continuation"`).

---

## L14 — Theme : nothing to write in the file, and that is by design

**Rule** — There is **no theme in the `.excalidraw` format**. Never add a
`theme` key, never author a dark-coloured variant, never ship two files for
one diagram. A diagram is written once, in light colours.

**Why** — The theme is a property of the **reader**, not of the document :
Excalidraw stores it in localStorage (Light / Dark / System, toggled with
`Alt+Shift+D` or from the hamburger menu) and applies *the reader's* choice
to whatever file is opened. That is exactly what makes one file correct in
both modes, so the exported `appState` deliberately omits it — it carries
only `viewBackgroundColor`, `gridSize`, `gridStep`, `gridModeEnabled`,
`lockedMultiSelections`.

Two independent proofs, both worth keeping :

- The same scene exported from excalidraw.com under two different app
  themes produced **byte-identical files** (`md5 0be2ada5…`), same 25 ×
  `#1e1e1e` strokes, same `viewBackgroundColor: #ffffff`.
- Dark mode is a render filter — `invert(93%) hue-rotate(180deg)` over the
  whole canvas, background included. Run the maths : a channel `c` becomes
  `c×0.07 + (255−c)×0.93`, so `#ffffff` → `17.85` ≈ **`#121212`**, which is
  precisely Excalidraw's dark canvas colour. Not a coincidence : that IS
  the mechanism.

**Corollary — a hard-coded dark file is actively wrong.** Setting
`viewBackgroundColor: "#000000"` inverts to `#ededed` in dark mode, i.e.
light, the opposite of the intent ; and in light mode it leaves every
`#1e1e1e` stroke black-on-black. It would demand repainting every stroke
and re-picking every pastel fill (which `hue-rotate` also shifts). The
filter already does all of that, for free and reversibly.

**How to apply** — When asked for a dark or "theme-dependent" diagram :
explain that it already is one, and point at the theme toggle. If the ask
is really a dark **image** for a dark doc page, the lever is the *Dark
mode* checkbox in the app's *Export image* dialog (`exportWithDarkMode`,
not persisted either) — one source file, two exported renders. Linking the
raw `.excalidraw` from the docs is even better : each reader gets their own
theme automatically.

---

## L15 — Emit the props the app writes, except the solved bindings

**Rule** — Match what excalidraw.com writes back, with **one deliberate
exception** :

- `autoResize: true` on **every** text element, last key of the object.
- The full 5-key `appState` (see the skill's envelope section).
- Arrow bindings stay `{elementId, focus, gap}` — **never** hand-write the
  migrated `{"mode": "orbit", "elementId": …, "fixedPoint": [x, y]}` form.

**Why** — A file generated by this skill and re-opened in the app comes
back with `autoResize` added on all its texts and a fuller `appState` : the
app injects them on open, so the file rewrites itself at the first save and
the diff drowns the real change. Five shipped diagrams were caught this way,
142 text elements short.

The bindings are the opposite case. The app also migrates `focus`/`gap` to
`fixedPoint`, but those values are **solved from the geometry, not
readable** : one observed migration produced `[0.5001, 0.5001]` for a centre
binding (a sentinel) and `[0.3996…, 0.6003…]` / `[0.2419…, 0.2419…]` for the
next arrow. Hand-written, they pin an arrow to an arbitrary point.
`focus: 0, gap: 8` says "centre to centre, 8px clearance", stays accepted,
and is migrated correctly on open — the very re-export that revealed this
lesson is the proof.

**How to apply** — Run the skill's validation `jq` after writing : the
"texts without `autoResize`" counter must be `0`. And if a future session
notices the `fixedPoint` form in an app-touched file, do not "align" the
skill on it — that decision is this lesson.
