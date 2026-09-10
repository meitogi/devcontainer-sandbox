// Builder .excalidraw v2 — conventions de la skill /diagram (L01-L15).
// Sortie : JSON indenté 2 espaces, appState 5 clés, autoResize dernier,
// bindings réciproques focus/gap, index Z* (fonds) puis a0...b*.

const TS = 1717689600000;

export const charW = (fs, font) => fs * (font === 7 ? 0.7 : 0.6);

export function textDims(text, fs, font) {
  const lines = text.split('\n');
  const w = Math.max(...lines.map((l) => l.length)) * charW(fs, font);
  return { w: Math.ceil(w), h: Math.ceil(lines.length * fs * 1.25) };
}

const up20 = (v) => Math.ceil(v / 20) * 20;
const down20 = (v) => Math.floor(v / 20) * 20;

function idxSeq(i) {
  // a0..a9, aA..aZ, b0..b9, bA..bZ, ...
  const bucket = String.fromCharCode(97 + Math.floor(i / 36));
  const r = i % 36;
  return bucket + (r < 10 ? String(r) : String.fromCharCode(55 + r));
}

export class D {
  constructor(title) {
    this.els = [];   // nodes, texts, arrows (ordre = z-order)
    this.zones = []; // rendus avant, index Z*
    this.seed = 100000;
    this.byId = {};
    if (title) this.float(40, 40, title, { fs: 28 });
  }

  base(id, type) {
    return {
      id, type, x: 0, y: 0, width: 0, height: 0, angle: 0,
      strokeColor: '#1e1e1e', backgroundColor: 'transparent',
      fillStyle: 'solid', strokeWidth: 2, strokeStyle: 'solid',
      roughness: 1, opacity: 100, groupIds: [], frameId: null,
      roundness: null, seed: ++this.seed, version: 1,
      versionNonce: ++this.seed, isDeleted: false, boundElements: [],
      updated: TS, link: null, locked: false, index: '?',
    };
  }

  textEl(id, x, y, text, { fs = 20, font = 5, align = 'center', color = '#1e1e1e', containerId = null } = {}) {
    const { w, h } = textDims(text, fs, font);
    const t = this.base(id, 'text');
    Object.assign(t, {
      x, y, width: w, height: h, strokeColor: color,
      text, fontSize: fs, fontFamily: font, textAlign: align,
      verticalAlign: containerId ? 'middle' : 'top',
      baseline: fs - 2, lineHeight: 1.25, containerId,
      originalText: text, autoResize: true,
    });
    this.els.push(t);
    this.byId[id] = t;
    return t;
  }

  // Nœud rect/diamond auto-dimensionné autour de son texte (L13), centré sur cx.
  node(id, cx, y, text, { bg = 'transparent', font = 5, fs = 20, minW = 240, type = 'rectangle', stroke = '#1e1e1e', strokeW = 2, dash = false, textColor = '#1e1e1e' } = {}) {
    const { w: tw, h: th } = textDims(text, fs, font);
    let w, h;
    if (type === 'diamond') { w = up20(tw * 2 + 40); h = up20(th * 2 + 40); }
    else { w = up20(Math.max(minW, tw + 60)); h = up20(Math.max(80, th + 40)); }
    const x = down20(cx - w / 2);
    const r = this.base(id, type);
    Object.assign(r, {
      x, y, width: w, height: h, backgroundColor: bg,
      strokeColor: stroke, strokeWidth: strokeW,
      strokeStyle: dash ? 'dashed' : 'solid',
      roundness: type === 'rectangle' ? { type: 3 } : null,
      boundElements: [{ type: 'text', id: `${id}-t` }],
    });
    this.els.push(r);
    this.byId[id] = r;
    this.textEl(`${id}-t`, x + (w - tw) / 2, y + (h - th) / 2, text, { fs, font, containerId: id, color: textColor });
    return r;
  }

  float(x, y, text, { fs = 16, font = 5, align = 'left', color = '#1e1e1e' } = {}) {
    return this.textEl(`f${this.els.length}`, x, y, text, { fs, font, align, color });
  }

  anchor(el, side) {
    const cx = el.x + el.width / 2, cy = el.y + el.height / 2;
    if (side === 'top') return [cx, el.y];
    if (side === 'bottom') return [cx, el.y + el.height];
    if (side === 'left') return [el.x, cy];
    return [el.x + el.width, cy];
  }

  arrow(fromId, toId, { label = null, fs = 16, font = 5, color = '#1e1e1e', dashed = false, sideFrom = null, sideTo = null, via = null, shift = null, focus = 0, strokeW = 2 } = {}) {
    const A = this.byId[fromId], B = this.byId[toId];
    const dx = (B.x + B.width / 2) - (A.x + A.width / 2);
    const dy = (B.y + B.height / 2) - (A.y + A.height / 2);
    const vert = Math.abs(dy) >= Math.abs(dx);
    const sf = sideFrom ?? (vert ? (dy > 0 ? 'bottom' : 'top') : (dx > 0 ? 'right' : 'left'));
    const st = sideTo ?? (vert ? (dy > 0 ? 'top' : 'bottom') : (dx > 0 ? 'left' : 'right'));
    let [x1, y1] = this.anchor(A, sf);
    let [x2, y2] = this.anchor(B, st);
    if (shift) { x1 += shift[0]; y1 += shift[1]; x2 += shift[0]; y2 += shift[1]; }
    const id = `ar-${fromId}-${toId}`;
    const points = via
      ? [[0, 0], [via[0], via[1]], [x2 - x1, y2 - y1]]
      : [[0, 0], [x2 - x1, y2 - y1]];
    const xs = points.map((p) => p[0]), ys = points.map((p) => p[1]);
    const ar = this.base(id, 'arrow');
    Object.assign(ar, {
      x: x1, y: y1,
      width: Math.max(...xs) - Math.min(...xs),
      height: Math.max(...ys) - Math.min(...ys),
      strokeColor: color, strokeStyle: dashed ? 'dashed' : 'solid',
      strokeWidth: strokeW,
      roundness: { type: 2 }, points, lastCommittedPoint: null,
      startBinding: { elementId: fromId, focus, gap: 8 },
      endBinding: { elementId: toId, focus, gap: 8 },
      startArrowhead: null, endArrowhead: 'arrow', elbowed: false,
    });
    A.boundElements.push({ type: 'arrow', id });
    B.boundElements.push({ type: 'arrow', id });
    this.els.push(ar);
    this.byId[id] = ar;
    if (label) {
      const mid = via ? [x1 + via[0], y1 + via[1]] : [(x1 + x2) / 2, (y1 + y2) / 2];
      const { w: tw, h: th } = textDims(label, fs, font);
      const lt = this.textEl(`${id}-l`, mid[0] - tw / 2, mid[1] - th / 2, label, { fs, font, color, containerId: id });
      ar.boundElements.push({ type: 'text', id: lt.id });
    }
    return ar;
  }

  // Zone pointillée autour d'ids membres (+ header). Pad 30, bande header 50.
  zone(label, memberIds, pad = 30) {
    const ms = memberIds.map((i) => this.byId[i]);
    const x1 = Math.min(...ms.map((m) => m.x)) - pad;
    const y1 = Math.min(...ms.map((m) => m.y)) - pad - 50;
    const x2 = Math.max(...ms.map((m) => m.x + m.width)) + pad;
    const y2 = Math.max(...ms.map((m) => m.y + m.height)) + pad;
    const z = this.base(`zone${this.zones.length}`, 'rectangle');
    Object.assign(z, {
      x: down20(x1), y: down20(y1), width: up20(x2 - x1), height: up20(y2 - y1),
      strokeColor: '#868e96', strokeWidth: 1, strokeStyle: 'dashed',
      roundness: { type: 3 },
    });
    this.zones.push(z);
    this.textEl(`${z.id}-h`, down20(x1) + 20, down20(y1) + 14, label, { fs: 20, align: 'left' });
    return z;
  }

  toJSON() {
    this.zones.forEach((z, i) => { z.index = 'Z' + String.fromCharCode(112 + i); }); // Zp, Zq...
    this.els.forEach((e, i) => { e.index = idxSeq(i); });
    return {
      type: 'excalidraw', version: 2, source: 'claude-diagram-skill',
      elements: [...this.zones, ...this.els],
      appState: {
        viewBackgroundColor: '#ffffff', gridSize: 20, gridStep: 5,
        gridModeEnabled: false, lockedMultiSelections: {},
      },
      files: {},
    };
  }
}
