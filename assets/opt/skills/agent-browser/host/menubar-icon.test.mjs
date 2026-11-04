// menubar-icon.test.mjs — the SVG edits and the PNG stamp as pure checks, a
// Chromium that draws nothing against a stub, and the render itself against a
// real Chromium when MENUBAR_ICON_TEST_CHROMIUM names one (agent-browser-live.sh
// runs it in the sidecar image) — skipped otherwise.
//
//   node --test /opt/devcontainer/base/skills/agent-browser/host/menubar-icon.test.mjs
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { deflateSync } from 'node:zlib';
import { STATES, TRAY_SIZES, TRAY_THEMES, cropPng, decodePng, encodePng, readyMade, stateSvg, toIco, trayLayout, trayNames, withColor, withLetters, withMark, withPhys } from './menubar-icon.mjs';

const SVG = readFileSync(new URL('./menubar-icon.svg', import.meta.url), 'utf8');
const SCRIPT = new URL('./menubar-icon.mjs', import.meta.url).pathname;
const SVG_FILE = new URL('./menubar-icon.svg', import.meta.url).pathname;
const run = (...args) => spawnSync(process.execPath, [SCRIPT, SVG_FILE, 'DC', ...args], { encoding: 'utf8', timeout: 90000 });

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

test('a Chromium that exits 0 and draws nothing: named, with its version, path and last stderr line — never an ENOENT', () => {
	const dir = mkdtempSync(join(tmpdir(), 'menubar-icon-test-'));
	try {
		const stub = join(dir, 'chromium');
		writeFileSync(stub, '#!/bin/sh\n[ "$1" = --version ] && echo "Chromium 153.0.7979.0" && exit 0\necho "CVDisplayLinkCreateWithCGDisplay failed" >&2\nexit 0\n');
		chmodSync(stub, 0o755);
		for (const extra of [[], ['--tray', dir]]) {
			const r = run(stub, ...extra);
			assert.equal(r.status, 1, extra.join(' '));
			assert.equal(r.stdout, '', extra.join(' '));
			assert.equal(r.stderr.trim(), `Chromium 153.0.7979.0 wrote no image (${stub}): exited 0 — CVDisplayLinkCreateWithCGDisplay failed`, extra.join(' '));
			assert.doesNotMatch(r.stderr, /ENOENT/);
		}
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test('ready-made: the whole set used as it is, no Chromium started ; none → drawn ; some → refused, naming the missing', () => {
	const dir = mkdtempSync(join(tmpdir(), 'menubar-icon-ready-'));
	try {
		const own = join(dir, 'menubar-icon');
		const tray = join(dir, 'tray');
		mkdirSync(own);
		mkdirSync(tray);
		// A Chromium that must not be asked: it fails the run if it is.
		const stub = join(dir, 'chromium');
		writeFileSync(stub, '#!/bin/sh\necho "Chromium started" >&2\nexit 1\n');
		chmodSync(stub, 0o755);
		assert.equal(readyMade(own, STATES, '', 'png'), null);
		assert.equal(readyMade('', STATES, '', 'png'), null);
		assert.match(run(stub, '--png', own).stderr, /wrote no image/);

		const pngs = STATES.map((_, i) => encodePng(44, 36, Buffer.alloc(44 * 36 * 4, i + 1)));
		STATES.forEach((state, i) => writeFileSync(join(own, `${state}.png`), pngs[i]));
		let r = run(stub, '--png', own);
		assert.equal(r.status, 0, r.stderr);
		const lines = r.stdout.trim().split('\n');
		STATES.forEach((state, i) => assert.equal(lines[i], `ICON_${state.toUpperCase()}=${withPhys(pngs[i]).toString('base64')}`));
		// b has no set of its own: drawn, like any instance without one.
		assert.match(run(stub, 'b', '--png', own).stderr, /wrote no image/);
		writeFileSync(join(own, 'idle.b.png'), pngs[1]);
		assert.equal(run(stub, 'b', '--png', own).stderr.trim(), `${own}: running.b.png, unloaded.b.png, stray.b.png missing — ship the whole set, or none of it`);
		writeFileSync(join(own, 'stray.png'), encodePng(88, 72, Buffer.alloc(88 * 72 * 4)));
		assert.equal(run(stub, '--png', own).stderr.trim(), `${join(own, 'stray.png')}: rendered 88×72, expected 44×36`);

		const icos = trayNames().map((n) => [n, toIco([encodePng(16, 16, Buffer.alloc(16 * 16 * 4, n.length))])]);
		assert.equal(icos.length, STATES.length * TRAY_THEMES.length);
		for (const [n, ico] of icos) writeFileSync(join(own, `${n}.ico`), ico);
		r = run(stub, '--tray', tray, '--png', own);
		assert.equal(r.status, 0, r.stderr);
		for (const [n, ico] of icos) assert.deepEqual(readFileSync(join(tray, `${n}.ico`)), ico, n);
		writeFileSync(join(own, 'idle-dark.ico'), 'not an icon at all, no');
		assert.equal(run(stub, '--tray', tray, '--png', own).stderr.trim(), `${join(own, 'idle-dark.ico')}: not an ICO`);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

const CHROMIUM = process.env.MENUBAR_ICON_TEST_CHROMIUM;
const LIVE = CHROMIUM ? false : 'set MENUBAR_ICON_TEST_CHROMIUM=<a Chromium> to render through a real one';

test('live: the four states, 44×36 RGBA at 144 dpi, drawn, corners transparent', { skip: LIVE }, () => {
	const r = run(CHROMIUM, 'b');
	assert.equal(r.status, 0, r.stderr);
	const lines = r.stdout.trim().split('\n');
	assert.deepEqual(lines.map((l) => l.split('=')[0]), STATES.map((s) => `ICON_${s.toUpperCase()}`));
	for (const line of lines) {
		const png = Buffer.from(line.slice(line.indexOf('=') + 1), 'base64');
		assert.equal(png.toString('latin1', 37, 41), 'pHYs', line.slice(0, 12));
		const { width, height, data } = decodePng(png);
		assert.deepEqual([width, height], [44, 36]);
		for (const at of [0, width - 1, (height - 1) * width, height * width - 1]) assert.equal(data[at * 4 + 3], 0, `${line.slice(0, 12)} corner ${at}`);
		let drawn = 0;
		for (let i = 3; i < data.length; i += 4) if (data[i]) drawn++;
		assert.ok(drawn > 100, `${line.slice(0, 12)}: ${drawn} pixels drawn`);
	}
});

test('live: the tray set, one ICO per state × theme, 16 / 24 / 32 px each, in the same one browser', { skip: LIVE }, () => {
	const dir = mkdtempSync(join(tmpdir(), 'menubar-icon-tray-'));
	try {
		const r = run(CHROMIUM, '--tray', dir);
		assert.equal(r.status, 0, r.stderr);
		assert.equal(r.stdout.trim(), `TRAY_ICONS=${dir}`);
		assert.equal(readdirSync(dir).length, STATES.length * TRAY_THEMES.length);
		for (const theme of TRAY_THEMES) for (const state of STATES) {
			const ico = readFileSync(join(dir, `${state}-${theme.name}.ico`));
			assert.deepEqual([ico.readUInt16LE(4), ico[6], ico[22], ico[38]], [3, 16, 24, 32], `${state}-${theme.name}`);
		}
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});
