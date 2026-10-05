#!/usr/bin/env node
// Merges several .excalidraw into one: horizontal bands in argument order,
// ids prefixed s1-/s2-/…, indices regenerated
// (zones Z* d'abord). Générique — aucun contenu projet.
//
// Usage : node merge.mjs <sortie.excalidraw> <in1> <in2>... [--gutter=N]
import { readFileSync, writeFileSync } from 'node:fs';

const args = process.argv.slice(2);
const gutterArg = args.find(a => a.startsWith('--gutter='));
const GUTTER = gutterArg ? Number(gutterArg.split('=')[1]) : 160;
const [out, ...inputs] = args.filter(a => !a.startsWith('--'));
if (!out || inputs.length < 2) {
  console.error('usage: node merge.mjs <sortie.excalidraw> <in1> <in2>... [--gutter=N]');
  process.exit(2);
}

const idxSeq = i => {
  const b = String.fromCharCode(97 + Math.floor(i / 36));
  const r = i % 36;
  return b + (r < 10 ? String(r) : String.fromCharCode(55 + r));
};

// Real bbox: for an arrow, x/y is the START POINT and the points can be
// negative — x+width overestimates the right edge of an arrow pointing
// leftwards (the error stacked up from band to band).
const ext = e => {
  if (e.type === 'arrow' && e.points?.length) {
    const xs = e.points.map(p => p[0]), ys = e.points.map(p => p[1]);
    return {
      x1: e.x + Math.min(...xs), x2: e.x + Math.max(...xs),
      y1: e.y + Math.min(...ys), y2: e.y + Math.max(...ys),
    };
  }
  return { x1: e.x, x2: e.x + e.width, y1: e.y, y2: e.y + e.height };
};

let ox = 0;
const zones = [], others = [];
for (let i = 0; i < inputs.length; i++) {
  const doc = JSON.parse(readFileSync(inputs[i], 'utf8'));
  const els = doc.elements;
  const minX = Math.min(...els.map(e => ext(e).x1));
  const minY = Math.min(...els.map(e => ext(e).y1));
  const p = id => (id == null ? id : `s${i + 1}-${id}`);
  for (const e of els) {
    e.id = p(e.id);
    e.x = e.x - minX + ox;
    e.y = e.y - minY;
    e.boundElements = (e.boundElements ?? []).map(b => ({ ...b, id: p(b.id) }));
    if (e.containerId) e.containerId = p(e.containerId);
    if (e.startBinding) e.startBinding.elementId = p(e.startBinding.elementId);
    if (e.endBinding) e.endBinding.elementId = p(e.endBinding.elementId);
    (e.index.startsWith('Z') ? zones : others).push(e);
  }
  // max is in absolute coordinates (els already normalised): we SET the next
  // start, we do not add to it — `+=` re-counted the previous offset and the
  // gap between bands grew with every merge.
  ox = Math.max(...els.map(e => ext(e).x2)) + GUTTER;
}
zones.forEach((z, i) => { z.index = 'Z' + String.fromCharCode(103 + i); });
others.forEach((e, i) => { e.index = idxSeq(i); });
const doc = {
  type: 'excalidraw', version: 2, source: 'claude-diagram-skill',
  elements: [...zones, ...others],
  appState: {
    viewBackgroundColor: '#ffffff', gridSize: 20, gridStep: 5,
    gridModeEnabled: false, lockedMultiSelections: {},
  },
  files: {},
};
writeFileSync(out, JSON.stringify(doc, null, 2) + '\n');
console.log(`${out}: ${doc.elements.length} éléments (${inputs.length} bandes, gutter ${GUTTER})`);
