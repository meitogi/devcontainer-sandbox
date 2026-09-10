---
description: |
  Generate an .excalidraw file (Excalidraw v2 JSON) from an NL description, an
  ASCII sketch, or a node/edge structure. Writes the file at the path requested
  by the user via the Write tool. No SVG/PNG rendering — use the Excalidraw app
  (File → Export image).

  Auto-trigger : "fais-moi un diagramme excalidraw", "génère un .excalidraw",
  "draw this as excalidraw", "schéma excalidraw de X", "convertis ce Mermaid
  en .excalidraw", "diagramme d'architecture excalidraw", "turn this ASCII
  into excalidraw".
argument-hint: "<description | ASCII | Mermaid> → <path/out>.excalidraw"
---

# /diagram — zero-dependency `.excalidraw` generation

An `.excalidraw` file is just a v2 JSON whose schema has been stable since
2021. This skill bundles everything needed for an LLM to write a valid file
in one shot with the Write tool — no Node tooling, no install, no Dockerfile
or firewall changes.

For SVG/PNG : open the `.excalidraw` in the Excalidraw desktop app or on
excalidraw.com (drag & drop), then `File → Export image`. Handwritten fonts
applied automatically.

## ⚠️ Mandatory step 0 — re-read `KNOWLEDGE.md`

**Before any design work, read
[`KNOWLEDGE.md`](./KNOWLEDGE.md) in this skill's directory.** That file
accumulates rules distilled from past mistakes (arrow label spacing, font
consistency, dashed frames, color palette, z-order). Skipping it = falling
back into the same traps. The conventions below remain the schema reference ;
KNOWLEDGE.md adds the **readability** and **workflow** rules that the schema
alone doesn't enforce.

---

## When to use

- Architecture diagram (≤ 15 nodes), simple flow, short sequence.
- ASCII / simple Mermaid → editable `.excalidraw` conversion.
- The user wants a re-editable file rather than a frozen image.

## When NOT to use

- The user wants SVG / PNG directly → explain the 1-click export in the app.
- The graph exceeds ~20 nodes → suggest Mermaid + desktop app import
  (`File → Import → from Mermaid`). Manual layout becomes painful.
- Non-flowchart diagram (sequence, class, ER) — `.excalidraw` is freeform,
  but auto-layout for these types is out of scope.

---

## Excalidraw v2 schema — envelope

```json
{
  "type": "excalidraw",
  "version": 2,
  "source": "claude-diagram-skill",
  "elements": [ /* … */ ],
  "appState": {
    "viewBackgroundColor": "#ffffff",
    "gridSize": null
  },
  "files": {}
}
```

`type` / `version` are required. `source` is free-form. `appState` can be
empty `{}` but including at least `viewBackgroundColor` makes the export
clean. `files` is `{}` unless you embed images (out of scope).

---

## Fields common to every element

Every element must carry these fields (otherwise the app rejects or
regenerates them) :

```jsonc
{
  "id": "el-001",                  // unique string. "el-NNN" sequential is fine.
  "type": "...",                   // rectangle | ellipse | diamond | arrow | line | text
  "x": 0, "y": 0,                  // top-left corner (text: baseline-box position)
  "width": 0, "height": 0,
  "angle": 0,                      // radians ; always 0 unless explicit rotation
  "strokeColor": "#1e1e1e",
  "backgroundColor": "transparent",
  "fillStyle": "solid",            // solid | hachure | cross-hatch
  "strokeWidth": 2,                // 1 (thin) | 2 (medium) | 4 (thick)
  "strokeStyle": "solid",          // solid | dashed | dotted
  "roughness": 1,                  // 0 (none) | 1 (default) | 2 (cartoonist)
  "opacity": 100,                  // 0-100
  "groupIds": [],
  "frameId": null,
  "roundness": null,               // {"type": 3} on rectangle for rounded corners
  "seed": 100001,                  // random int, may be sequential
  "version": 1,                    // always 1 at creation
  "versionNonce": 100001,          // random int
  "isDeleted": false,
  "boundElements": [],             // [{type:"text"|"arrow", id}] — see Bindings
  "updated": 1717689600000,        // ms timestamp (exact value doesn't matter)
  "link": null,
  "locked": false,
  "index": "a0"                    // fractional index (z-order). a0,a1,...,a9,aA,aB,...
}
```

`index` : use a lex-sortable string. Simple convention : `a0`, `a1`, …, `a9`,
`aA`, …, `aZ`, `b0`, … Roughly 50 elements fit into `a0`-`a9` + `aA`-`aZ` +
`b0`-`bN`. The app regenerates if invalid but it's cleaner to provide valid
indices up front. For background elements (frames, backdrops) use `Z*`
prefixed indices (e.g., `Zy`, `Zz`) — ASCII `Z` sorts before `a`, so they
render behind everything else (see [KNOWLEDGE L05](./KNOWLEDGE.md)).

---

## Type-specific fields

### Rectangle / Ellipse / Diamond

Common fields above plus :

```jsonc
{
  "type": "rectangle",  // or "ellipse" / "diamond"
  "roundness": {"type": 3}  // rect only, for rounded corners. null otherwise.
}
```

### Text

```jsonc
{
  "type": "text",
  "text": "hook.js",
  "fontSize": 20,                  // 16 | 20 | 28 | 36
  "fontFamily": 5,                 // 5=Excalifont (handwritten) | 7=Cascadia (mono) | 8=Lilita
  "textAlign": "center",           // left | center | right
  "verticalAlign": "middle",       // top | middle | bottom
  "baseline": 18,                  // ≈ fontSize - 2. App recomputes anyway.
  "lineHeight": 1.25,
  "containerId": "rect-id-or-null", // ID of the rect/ellipse/diamond holding this text
  "originalText": "hook.js"        // always = text at creation
}
```

For font choice, follow [KNOWLEDGE L03](./KNOWLEDGE.md) : **mono (7) for any
code identifier**, **handwritten (5) only for prose and zone headers**.

### Arrow / Line

```jsonc
{
  "type": "arrow",
  "points": [[0, 0], [dx, dy]],    // min 2 points : [0,0] then delta to end
  "lastCommittedPoint": null,
  "startBinding": {                // null for floating arrow
    "elementId": "rect-from-id",
    "focus": 0,                    // -1 to 1, relative position on the edge. 0 = middle.
    "gap": 8                       // padding between rect edge and arrow start
  },
  "endBinding": { "elementId": "rect-to-id", "focus": 0, "gap": 8 },
  "startArrowhead": null,          // arrow | bar | dot | triangle | null
  "endArrowhead": "arrow",
  "elbowed": false,                // true = 90° polyline, false = straight
  "roundness": {"type": 2}         // arc smoothing. {"type": 2} = rounded.
}
```

For an arrow's `width` / `height` : absolute delta values (never negative).
`x, y` = position of the `[0,0]` point in `points`.

---

## Bindings — critical rules

### Text inside a shape (text ↔ shape)

```jsonc
// Rect declares it contains the text
{
  "id": "rect-hook",
  "type": "rectangle",
  "boundElements": [
    {"type": "text", "id": "text-hook"}
  ]
}

// Text points back to its container
{
  "id": "text-hook",
  "type": "text",
  "containerId": "rect-hook",
  "textAlign": "center",
  "verticalAlign": "middle"
}
```

Without this reciprocal binding the text isn't attached to the box —
moving the box leaves the text behind → broken diagram on edit.

### Arrow between two shapes (arrow ↔ shape)

```jsonc
// Each endpoint rect must reference the arrow
{
  "id": "rect-hook",
  "boundElements": [
    {"type": "text", "id": "text-hook"},
    {"type": "arrow", "id": "arrow-hook-queue"}
  ]
}

{
  "id": "rect-queue",
  "boundElements": [
    {"type": "text", "id": "text-queue"},
    {"type": "arrow", "id": "arrow-hook-queue"}
  ]
}

// Arrow references both rects
{
  "id": "arrow-hook-queue",
  "type": "arrow",
  "startBinding": {"elementId": "rect-hook",  "focus": 0, "gap": 8},
  "endBinding":   {"elementId": "rect-queue", "focus": 0, "gap": 8}
}
```

Without binding, moving a node leaves the arrow in place → broken.

### Arrow label (text ↔ arrow)

```jsonc
// Arrow holds its label
{
  "id": "arrow-hook-queue",
  "boundElements": [{"type": "text", "id": "text-arrow-label"}]
}

// Label points to the arrow as container
{
  "id": "text-arrow-label",
  "type": "text",
  "text": "fs.watch",
  "containerId": "arrow-hook-queue",
  "textAlign": "center",
  "verticalAlign": "middle"
}
```

The label auto-positions at the arrow's midpoint.

---

## Layout conventions (must respect)

| Element | Standard size |
|---|---|
| Rectangle (node) | `w=240, h=80` (or `w=120, h=60` for dense channel boxes) |
| Diamond (decision) | `w=160, h=100` |
| Ellipse (state, IO) | `w=160, h=80` |
| Spacing between nodes | `min 80px` horizontal, `120px` vertical when arrow has a label (see [KNOWLEDGE L01](./KNOWLEDGE.md)) |
| Grid | all coords multiples of `20` |

For vertical separation between event rows and consumer/channel rows, leave
**at least 200px** of gap (see [KNOWLEDGE L02](./KNOWLEDGE.md)).

Colors (Excalidraw standard palette, see also [KNOWLEDGE L07](./KNOWLEDGE.md)) :
- Stroke : `#1e1e1e` (always for nodes), `#868e96` (gray) for dashed zone frames
- Categorical backgrounds :
  - `#a5d8ff` (blue) = event sources / IO
  - `#ffec99` (yellow) = files / data
  - `#b2f2bb` (green) = process / module
  - `#ffc9c9` (pink) = central bus / message hub
  - `transparent` = consumer / output
- Always `fillStyle: "solid"` for categorical backgrounds (readability).

Arrows : `endArrowhead: "arrow"`, `startArrowhead: null`,
`roundness: {"type": 2}`.

---

## Copy-paste templates

### T1 — Box with label

```jsonc
[
  {
    "id": "rect-1", "type": "rectangle",
    "x": 100, "y": 100, "width": 240, "height": 80,
    "angle": 0, "strokeColor": "#1e1e1e", "backgroundColor": "#a5d8ff",
    "fillStyle": "solid", "strokeWidth": 2, "strokeStyle": "solid",
    "roughness": 1, "opacity": 100, "groupIds": [], "frameId": null,
    "roundness": {"type": 3}, "seed": 100001, "version": 1, "versionNonce": 100001,
    "isDeleted": false, "boundElements": [{"type": "text", "id": "text-1"}],
    "updated": 1717689600000, "link": null, "locked": false, "index": "a0"
  },
  {
    "id": "text-1", "type": "text",
    "x": 130, "y": 130, "width": 180, "height": 20,
    "angle": 0, "strokeColor": "#1e1e1e", "backgroundColor": "transparent",
    "fillStyle": "solid", "strokeWidth": 2, "strokeStyle": "solid",
    "roughness": 1, "opacity": 100, "groupIds": [], "frameId": null,
    "roundness": null, "seed": 100002, "version": 1, "versionNonce": 100002,
    "isDeleted": false, "boundElements": [], "updated": 1717689600000,
    "link": null, "locked": false, "index": "a1",
    "text": "hook.js", "fontSize": 20, "fontFamily": 7,
    "textAlign": "center", "verticalAlign": "middle", "baseline": 18,
    "lineHeight": 1.25, "containerId": "rect-1", "originalText": "hook.js"
  }
]
```

### T2 — Two boxes connected by an arrow

Copy T1 twice (ids `rect-1`/`text-1` and `rect-2`/`text-2`, different
x coords), then add :

```jsonc
{
  "id": "arrow-1-2", "type": "arrow",
  "x": 340, "y": 140,                        // [0,0] corner of points
  "width": 100, "height": 0,                 // absolute delta to end
  "angle": 0, "strokeColor": "#1e1e1e", "backgroundColor": "transparent",
  "fillStyle": "solid", "strokeWidth": 2, "strokeStyle": "solid",
  "roughness": 1, "opacity": 100, "groupIds": [], "frameId": null,
  "roundness": {"type": 2}, "seed": 100003, "version": 1, "versionNonce": 100003,
  "isDeleted": false, "boundElements": [], "updated": 1717689600000,
  "link": null, "locked": false, "index": "a4",
  "points": [[0, 0], [100, 0]],
  "lastCommittedPoint": null,
  "startBinding": {"elementId": "rect-1", "focus": 0, "gap": 8},
  "endBinding":   {"elementId": "rect-2", "focus": 0, "gap": 8},
  "startArrowhead": null, "endArrowhead": "arrow", "elbowed": false
}
```

**Don't forget** to add `{"type": "arrow", "id": "arrow-1-2"}` to
`boundElements` of `rect-1` AND `rect-2`.

### T3 — Decision (diamond) → 2 branches

Diamond instead of rectangle (`type: "diamond"`, `roundness: null`, size
`160×100`). Two outgoing arrows to 2 rects, each labelled (yes/no) via a
text with `containerId` = arrow id.

### T4 — Cluster (4-5 nodes in a grid)

Horizontal or vertical grid. Keep at least 60px between edges. All arrows
in `elbowed: false` mode to stay readable.

### T5 — Dashed zone frame

```jsonc
{
  "id": "frame-zone", "type": "rectangle",
  "x": 70, "y": 20, "width": 300, "height": 740,
  "angle": 0, "strokeColor": "#868e96", "backgroundColor": "transparent",
  "fillStyle": "solid", "strokeWidth": 1, "strokeStyle": "dashed",
  "roughness": 1, "opacity": 100, "groupIds": [], "frameId": null,
  "roundness": {"type": 3}, "seed": 100099, "version": 1, "versionNonce": 100099,
  "isDeleted": false, "boundElements": [], "updated": 1717689600000,
  "link": null, "locked": false, "index": "Zy"
}
```

`strokeStyle: "dashed"`, gray stroke, no fill, behind everything (`Zy`/`Zz`).
Use one per logical zone (e.g., client vs server, app vs database).

---

## Output workflow

When the user requests a diagram :

1. **Read [`KNOWLEDGE.md`](./KNOWLEDGE.md)** (mandatory, every time).
2. **Ask for the output path** if not provided. No default — the user
   decides where to store (`docs/img/`, `tmp/`, etc.).
3. **Verify the parent dir exists** via `ls`. If not, ask the user to
   create it or change the path — no silent `mkdir -p`.
4. **Design the element array** respecting bindings (text↔shape,
   arrow↔shape, arrow↔label) AND the grid layout (multiples of 20). Run
   through KNOWLEDGE.md rules one by one before writing.
5. **Write the file** via the Write tool, JSON indented at 2 spaces.
6. **Quick validate** : `jq '.type, .version, (.elements | length)' <file>`.
7. **Recap to user** with explicit ask to open in app and verify visually :
   ```
   Wrote <path> — N elements (X rects, Y arrows, Z texts).
   Open in excalidraw.com (drag & drop) or the desktop app.
   Test : move a node — arrows + labels should follow.
   Export SVG/PNG : File → Export image.
   ```

---

## Limits to surface to the user

- **No SVG/PNG from this skill.** The Excalidraw app exports in 1 click
  with the correct handwritten fonts — replicating headless would cost
  80-150 MB.
- **Beyond ~20 nodes**, manual layout becomes painful. If the user has a
  bigger graph : suggest Mermaid + `File → Import → from Mermaid` in the
  desktop app.
- **Handwritten fonts** (Excalifont, Cascadia) are applied by the app on
  open. The JSON doesn't bundle the WOFF2.
- **`index` field** : the app regenerates if invalid, but a valid sequence
  (`a0`, `a1`, …) avoids warnings.

---

## Smoke test (after creating the skill)

```bash
# Natural trigger : "fais-moi un diagramme excalidraw A → B → C in /tmp/test.excalidraw"
# → skill fires, Claude writes the file.

jq '.type, .version, (.elements | length)' /tmp/test.excalidraw
# expected : "excalidraw" \n 2 \n >= 7  (3 rects + 3 texts + 2 arrows)

# Open /tmp/test.excalidraw in excalidraw.com (drag & drop)
# - do arrows follow when you move a node ?
# - are the labels inside the boxes ?
# If yes, bindings OK.
```
