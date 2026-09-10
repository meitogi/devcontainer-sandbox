#!/usr/bin/env node
// Checker .excalidraw — relit les fichiers DEPUIS LE DISQUE (un bug du
// builder ne doit pas masquer un bug de sortie). Règles : enveloppe,
// bindings réciproques focus/gap, z-order Z*<a*, L01/L12/L13, grille,
// chevauchements 2D, nœud jamais à cheval sur une bordure de zone.
//
// Usage :
//   node check.mjs <dir | fichiers.excalidraw...>   vérifie tout
//   node check.mjs <dir | fichier> --neg            contrôle négatif
//     (3 défauts injectés en mémoire dans le 1er fichier → ≥ 4 findings
//      attendus, sinon exit 2 : un checker sans contrôle négatif ne
//      prouve rien)
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, basename } from 'node:path';

const args = process.argv.slice(2).filter(a => a !== '--neg');
const neg = process.argv.includes('--neg');
if (!args.length) {
  console.error('usage: node check.mjs <dir | fichiers.excalidraw...> [--neg]');
  process.exit(2);
}
const files = args.flatMap(a =>
  statSync(a).isDirectory()
    ? readdirSync(a).filter(f => f.endsWith('.excalidraw')).sort().map(f => join(a, f))
    : [a],
);

const charW = (fs, font) => fs * (font === 7 ? 0.7 : 0.6);
const dims = t => {
  const lines = t.text.split('\n');
  return {
    w: Math.max(...lines.map(l => l.length)) * charW(t.fontSize, t.fontFamily),
    h: lines.length * t.fontSize * 1.25,
  };
};
const overlap = (a, b, eps = 1) =>
  a.x + eps < b.x + b.width && b.x + eps < a.x + a.width &&
  a.y + eps < b.y + b.height && b.y + eps < a.y + a.height;
const inside = (a, z) =>
  a.x >= z.x && a.y >= z.y &&
  a.x + a.width <= z.x + z.width && a.y + a.height <= z.y + z.height;

function checkDoc(name, doc) {
  const F = [];
  const f = msg => F.push(`${name}: ${msg}`);

  if (doc.type !== 'excalidraw' || doc.version !== 2) f('enveloppe type/version');
  const ak = Object.keys(doc.appState ?? {}).sort().join(',');
  if (ak !== 'gridModeEnabled,gridSize,gridStep,lockedMultiSelections,viewBackgroundColor')
    f(`appState inattendu: ${ak}`);
  if ('theme' in (doc.appState ?? {})) f('appState.theme interdit (L14)');

  const els = doc.elements;
  const byId = Object.fromEntries(els.map(e => [e.id, e]));
  const ids = els.map(e => e.id);
  if (new Set(ids).size !== ids.length) f('ids non uniques');

  const idx = els.map(e => e.index);
  if (new Set(idx).size !== idx.length) f('index non uniques');
  for (let i = 1; i < idx.length; i++)
    if (!(idx[i - 1] < idx[i])) f(`index non croissants: ${idx[i - 1]} !< ${idx[i]}`);
  // zone = cadre pointillé fin SANS texte lié (un encadré d'aide est
  // pointillé fin aussi, mais il contient son texte)
  const zones = els.filter(e => e.strokeStyle === 'dashed' && e.type === 'rectangle' && e.strokeWidth === 1 && (e.boundElements ?? []).length === 0);
  const nodes = els.filter(e => (e.type === 'rectangle' || e.type === 'diamond' || e.type === 'ellipse') && !zones.includes(e));
  for (const z of zones) if (!z.index.startsWith('Z')) f(`zone ${z.id} index ${z.index} pas en Z* (L05)`);

  for (const e of els) {
    for (const k of ['id', 'type', 'x', 'y', 'width', 'height', 'angle', 'strokeColor',
      'backgroundColor', 'fillStyle', 'strokeWidth', 'strokeStyle', 'roughness', 'opacity',
      'groupIds', 'frameId', 'roundness', 'seed', 'version', 'versionNonce', 'isDeleted',
      'boundElements', 'updated', 'link', 'locked', 'index'])
      if (!(k in e)) f(`${e.id}: champ manquant ${k}`);
    if (e.type === 'text') {
      if (e.autoResize !== true) f(`${e.id}: autoResize absent/false (L15)`);
      const keys = Object.keys(e);
      if (keys[keys.length - 1] !== 'autoResize') f(`${e.id}: autoResize pas en dernière clé`);
      if (![5, 7].includes(e.fontFamily)) f(`${e.id}: fontFamily ${e.fontFamily}`);
      if (![16, 20, 28, 36].includes(e.fontSize)) f(`${e.id}: fontSize ${e.fontSize}`);
      if (e.text !== e.originalText) f(`${e.id}: text !== originalText`);
      if (e.containerId) {
        const c = byId[e.containerId];
        if (!c) f(`${e.id}: containerId inconnu`);
        else if (!(c.boundElements ?? []).some(b => b.type === 'text' && b.id === e.id))
          f(`${e.id}: conteneur ${c.id} ne le référence pas`);
        if (c && c.type !== 'arrow') {
          const { w, h } = dims(e);
          const fit = c.type === 'diamond' ? 0.55 : 1; // zone utile du losange
          if (c.width * fit < w + 20) f(`${e.id}: déborde en largeur de ${c.id} (L13)`);
          if (c.height * fit < h + 10) f(`${e.id}: déborde en hauteur de ${c.id} (L13)`);
        }
      }
    }
    if (e.type === 'arrow') {
      for (const [end, b] of [['start', e.startBinding], ['end', e.endBinding]]) {
        if (!b) { f(`${e.id}: ${end}Binding null`); continue; }
        if ('fixedPoint' in b || 'mode' in b) f(`${e.id}: binding migré interdit (L15)`);
        if (typeof b.focus !== 'number' || typeof b.gap !== 'number') f(`${e.id}: binding sans focus/gap`);
        const t = byId[b.elementId];
        if (!t) f(`${e.id}: ${end}Binding cible inconnue`);
        else if (!(t.boundElements ?? []).some(x => x.type === 'arrow' && x.id === e.id))
          f(`${e.id}: ${t.id} ne référence pas la flèche`);
        else if (t.type === 'arrow' || t.type === 'line' || t.type === 'text')
          f(`${e.id}: binding vers un non-shape (${t.type})`);
      }
    }
  }

  for (const e of els) for (const b of e.boundElements ?? []) {
    const t = byId[b.id];
    if (!t) { f(`${e.id}: boundElements → id inconnu ${b.id}`); continue; }
    if (b.type === 'text' && t.containerId !== e.id) f(`${e.id}: texte lié ${b.id} sans containerId retour`);
    if (b.type === 'arrow' && t.startBinding?.elementId !== e.id && t.endBinding?.elementId !== e.id)
      f(`${e.id}: flèche liée ${b.id} sans binding retour`);
  }

  for (const e of [...nodes, ...zones])
    for (const k of ['x', 'y', 'width', 'height'])
      if (e[k] % 20 !== 0) f(`${e.id}: ${k}=${e[k]} hors grille 20`);

  for (const e of els.filter(x => x.type === 'arrow')) {
    const label = els.find(t => t.type === 'text' && t.containerId === e.id);
    const pts = e.points;
    let len = 0;
    for (let i = 1; i < pts.length; i++)
      len += Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]);
    const [dx, dy] = pts[pts.length - 1];
    if (label) {
      const { w, h } = dims(label);
      if (Math.abs(dx) >= Math.abs(dy) && pts.length === 2 && len < 2 * w)
        f(`${e.id}: flèche ${Math.round(len)}px < 2× label ${Math.round(w)}px (L12)`);
      if (Math.abs(dy) > Math.abs(dx) && pts.length === 2 && len < Math.max(120, 2 * h))
        f(`${e.id}: flèche verticale ${Math.round(len)}px trop courte pour label (L01)`);
    } else if (pts.length === 2 && len < 60) f(`${e.id}: flèche ${Math.round(len)}px < 60px`);
  }

  const floats = els.filter(e => e.type === 'text' && !e.containerId);
  const labels = els.filter(e => e.type === 'text' && byId[e.containerId]?.type === 'arrow');
  const solid = [...nodes, ...floats];
  for (let i = 0; i < solid.length; i++)
    for (let j = i + 1; j < solid.length; j++)
      if (overlap(solid[i], solid[j])) f(`chevauchement ${solid[i].id} × ${solid[j].id}`);
  for (const l of labels) for (const n of nodes)
    if (overlap(l, n)) f(`label ${l.id} sur le nœud ${n.id}`);
  for (const n of [...nodes, ...floats]) for (const z of zones)
    if (overlap(n, z) && !inside(n, z)) f(`${n.id} à cheval sur ${z.id}`);
  for (let i = 0; i < zones.length; i++)
    for (let j = i + 1; j < zones.length; j++)
      if (overlap(zones[i], zones[j])) f(`zones ${zones[i].id} × ${zones[j].id} se chevauchent`);

  return F;
}

if (neg) {
  const doc = JSON.parse(readFileSync(files[0], 'utf8'));
  const t = doc.elements.find(e => e.type === 'text' && e.containerId);
  t.containerId = null;
  const r = doc.elements.find(e => e.type === 'rectangle' && e.boundElements.length);
  r.width = 40; r.x += 4;
  const a = doc.elements.find(e => e.type === 'arrow');
  a.startBinding = { mode: 'orbit', elementId: a.startBinding.elementId, fixedPoint: [0.5, 0.5] };
  const F = checkDoc('NEG', doc);
  console.log(`contrôle négatif (${basename(files[0])}) : ${F.length} findings (attendu ≥ 4)`);
  F.slice(0, 8).forEach(x => console.log('  ' + x));
  process.exit(F.length >= 4 ? 0 : 2);
}
let total = 0, checked = 0;
for (const path of files) {
  const doc = JSON.parse(readFileSync(path, 'utf8'));
  const F = checkDoc(basename(path, '.excalidraw'), doc);
  checked += doc.elements.length;
  total += F.length;
  console.log(`${basename(path)} — ${doc.elements.length} éléments, ${F.length} finding(s)`);
  F.forEach(x => console.log('  ' + x));
}
console.log(`\nTOTAL : ${checked} éléments vérifiés, ${total} finding(s)`);
process.exit(total ? 1 : 0);
