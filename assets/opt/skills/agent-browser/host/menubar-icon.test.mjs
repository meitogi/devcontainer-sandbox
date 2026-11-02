// menubar-icon.test.mjs — the SVG edits and the PNG stamp as pure checks. The
// rendering itself needs the host's Chromium and is not run here.
//
//   node --test /opt/devcontainer/base/skills/agent-browser/host/menubar-icon.test.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { deflateSync } from 'node:zlib';
import { STATES, TRAY_SIZES, TRAY_THEMES, cropPng, decodePng, encodePng, stateSvg, toIco, trayLayout, withColor, withLetters, withMark, withPhys } from './menubar-icon.mjs';

const SVG = readFileSync(new URL('./menubar-icon.svg', import.meta.url), 'utf8');

test('letters: replaced in #letters, three shrink the font, anything else refused', () => {
	const two = withLetters(SVG, 'DC');
	assert.match(two, /id="letters"[^>]*font-size="11"[^>]*>DC<\/text>/);
	assert.doesNotMatch(two, />RO</);
	assert.match(withLetters(SVG, 'DCT'), /id="letters"[^>]*font-size="8"[^>]*>DCT<\/text>/);
	for (const bad of ['', 'ABCD', 'a&', '<b>']) assert.throws(() => withLetters(SVG, bad), /1 to 3 letters/, bad);
	assert.throws(() => withLetters('<svg></svg>', 'DC'), /no <text id="letters">/);
});

test('state: the root viewBox moved onto that state\'s 44×36 cell', () => {
	const cells = { running: '0 0', idle: '52 0', unloaded: '104 0', stray: '156 0' };
	for (const state of STATES) {
		const root = stateSvg(SVG, state).match(/<svg\b[^>]*>/)[0];
		assert.match(root, new RegExp(`width="44" height="36" viewBox="${cells[state]} 44 36"`), state);
		assert.equal(root.match(/viewBox=/g).length, 1, state);
	}
	assert.throws(() => stateSvg('<svg></svg>', 'idle'), /no <g id="idle">/);
});

test('instance mark: b drawn in the dot of b\'s icons, a unmarked, stray untouched, one letter only', () => {
	const svg = withLetters(SVG, 'DC');
	for (const state of STATES) {
		const a = stateSvg(svg, state);
		assert.equal(withMark(a, state, ''), a, state);
		const b = withMark(a, state, 'b');
		if (state === 'stray') {
			assert.equal(b, a);
			continue;
		}
		assert.notEqual(b, a, state);
		assert.match(b, /<g mask="url\(#ab-mark-gap\)">/, state);
		assert.match(b, />b<\/text>/, state);
		assert.equal(b.match(/<svg\b/g).length, 1, state);
	}
	assert.match(withMark(stateSvg(svg, 'idle'), 'idle', 'b'), /<circle cx="90" cy="29" r="7.5"/);
	for (const bad of ['B', 'bb', '1', '<']) assert.throws(() => withMark(stateSvg(svg, 'idle'), 'idle', bad), /one letter/, bad);
});

function png(w, h, colourType, extra = []) {
	const c = (type, data) => {
		const out = Buffer.alloc(12 + data.length);
		out.writeUInt32BE(data.length, 0);
		out.write(type, 4, 'latin1');
		data.copy(out, 8);
		return out;
	};
	const ihdr = Buffer.alloc(13);
	ihdr.writeUInt32BE(w, 0);
	ihdr.writeUInt32BE(h, 4);
	ihdr[8] = 8;
	ihdr[9] = colourType;
	return Buffer.concat([Buffer.from('\x89PNG\r\n\x1a\n', 'latin1'), c('IHDR', ihdr), ...extra.map(([t, d]) => c(t, d)), c('IDAT', deflateSync(Buffer.alloc(1))), c('IEND', Buffer.alloc(0))]);
}

test('pHYs: one chunk, 144 dpi, right after IHDR, an old one dropped ; wrong size or no alpha refused', () => {
	const out = withPhys(png(44, 36, 6, [['pHYs', Buffer.alloc(9, 1)]]));
	assert.equal(out.toString('latin1', 37, 41), 'pHYs');
	assert.equal(out.readUInt32BE(41), 5669);
	assert.equal(out.readUInt32BE(45), 5669);
	assert.equal(out[49], 1);
	assert.equal(out.toString('latin1').split('pHYs').length - 1, 1);
	assert.match(out.toString('latin1'), /IDAT[\s\S]*IEND/);
	assert.throws(() => withPhys(png(88, 72, 6)), /88×72, expected 44×36/);
	assert.throws(() => withPhys(png(44, 36, 2)), /colour type 2/);
	assert.throws(() => withPhys(Buffer.from('nope, not a png at all, really')), /not a PNG/);
});

test('tray colour: the root\'s currentColor set, nothing else touched', () => {
	const root = withColor(stateSvg(SVG, 'idle'), '#f2f2f2').match(/<svg\b[^>]*>/)[0];
	assert.match(root, /style="color:#f2f2f2"/);
	assert.equal(root.match(/style=/g).length, 1);
	assert.match(withColor('<svg width="1"><g/></svg>', '#000000'), /^<svg style="color:#000000" width="1">/);
	assert.throws(() => withColor(SVG, 'red;x:y'), /a #rrggbb colour/);
});

test('tray layout: every theme × size × state in its own square, none overlapping', () => {
	const { width, height, cells } = trayLayout();
	assert.equal(cells.length, TRAY_THEMES.length * TRAY_SIZES.length * STATES.length);
	assert.deepEqual(TRAY_SIZES, [16, 24, 32]);
	for (const c of cells) assert.ok(c.x + c.size <= width && c.y + c.size <= height, JSON.stringify(c));
	for (const a of cells) for (const b of cells) {
		if (a === b) continue;
		const apart = a.x + a.size <= b.x || b.x + b.size <= a.x || a.y + a.size <= b.y || b.y + b.size <= a.y;
		assert.ok(apart, `${JSON.stringify(a)} overlaps ${JSON.stringify(b)}`);
	}
});

test('PNG: encode → decode round trip, every filter of a real screenshot decoded, a crop keeps its pixels', () => {
	const w = 5, h = 4, rgba = Buffer.alloc(w * h * 4);
	for (let i = 0; i < rgba.length; i++) rgba[i] = (i * 37) & 255;
	const back = decodePng(encodePng(w, h, rgba));
	assert.deepEqual([back.width, back.height], [w, h]);
	assert.deepEqual(back.data, rgba);
	// Filters 1–4 on rows, as a browser writes them.
	const filtered = [];
	const bpp = 4, stride = w * bpp;
	for (let y = 0; y < h; y++) {
		const f = (y % 4) + 1, row = Buffer.alloc(stride + 1);
		row[0] = f;
		for (let x = 0; x < stride; x++) {
			const raw = rgba[y * stride + x], a = x >= bpp ? rgba[y * stride + x - bpp] : 0, b = y ? rgba[(y - 1) * stride + x] : 0, c = x >= bpp && y ? rgba[(y - 1) * stride + x - bpp] : 0;
			const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
			const pred = [0, a, b, (a + b) >> 1, pa <= pb && pa <= pc ? a : pb <= pc ? b : c][f];
			row[x + 1] = (raw - pred) & 255;
		}
		filtered.push(row);
	}
	assert.deepEqual(decodePng(rawPng(w, h, deflateSync(Buffer.concat(filtered)))).data, rgba);
	const crop = decodePng(cropPng(encodePng(w, h, rgba), 1, 2, 3, 2));
	assert.deepEqual([crop.width, crop.height], [3, 2]);
	assert.deepEqual(crop.data.subarray(0, 4), rgba.subarray((2 * w + 1) * 4, (2 * w + 1) * 4 + 4));
	assert.throws(() => cropPng(encodePng(w, h, rgba), 4, 0, 3, 1), /outside/);
});

function rawPng(w, h, idat) {
	const ihdr = Buffer.alloc(13);
	ihdr.writeUInt32BE(w, 0);
	ihdr.writeUInt32BE(h, 4);
	ihdr[8] = 8;
	ihdr[9] = 6;
	const c = (type, data) => {
		const out = Buffer.alloc(12 + data.length);
		out.writeUInt32BE(data.length, 0);
		out.write(type, 4, 'latin1');
		data.copy(out, 8);
		return out;
	};
	return Buffer.concat([Buffer.from('\x89PNG\r\n\x1a\n', 'latin1'), c('IHDR', ihdr), c('IDAT', idat), c('IEND', Buffer.alloc(0))]);
}

test('ICO: a header, one 16-byte entry per PNG with its size and offset, the PNGs as they are', () => {
	const a = encodePng(16, 16, Buffer.alloc(16 * 16 * 4, 1));
	const b = encodePng(32, 32, Buffer.alloc(32 * 32 * 4, 2));
	const ico = toIco([a, b]);
	assert.deepEqual([ico.readUInt16LE(0), ico.readUInt16LE(2), ico.readUInt16LE(4)], [0, 1, 2]);
	assert.deepEqual([ico[6], ico[7], ico.readUInt16LE(10), ico.readUInt16LE(12)], [16, 16, 1, 32]);
	assert.equal(ico.readUInt32BE(0), 0x00000100);
	const off1 = ico.readUInt32LE(18), off2 = ico.readUInt32LE(34);
	assert.equal(off1, 6 + 2 * 16);
	assert.equal(ico.readUInt32LE(14), a.length);
	assert.equal(off2, off1 + a.length);
	assert.equal(ico[22], 32);
	assert.deepEqual(ico.subarray(off2), b);
});
