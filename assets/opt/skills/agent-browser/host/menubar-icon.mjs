#!/usr/bin/env node
/**
 * menubar-icon.mjs — the SwiftBar plugin's four icons, drawn from an SVG at
 * install time. `host-agent.sh install` runs it on the host and writes what it
 * prints into the plugin copy, beside LABEL=.
 *
 * The SVG is the only source: the kit's menubar-icon.svg, or the project's own
 * .devcontainer/agent-browser/menubar-icon.svg. It holds a <text id="letters">
 * (its text is replaced) and one <g> per state, ids running / idle / unloaded /
 * stray, each a 44×36 cell placed by an optional translate(x y). Every state is
 * rasterised by the host's Chromium (headless --screenshot, scale 1, transparent)
 * into a 44×36 PNG, stamped 144 dpi so macOS shows it at 22×18 pt — a template
 * image, one colour plus alpha, tinted by the menu bar.
 *
 * A second instance of the project (b, c…) gets its letter drawn where the dot
 * is (withMark) — by this script, not by the SVG, so a project's own icon tells
 * its instances apart too.
 *
 *   node menubar-icon.mjs <svg> <letters> <chromium> [<instance mark>] [--sheet <out.html>] [--tray <dir>]
 *
 * prints ICON_RUNNING=<base64> … ICON_STRAY=<base64>, one per line. --sheet also
 * writes the four ×6 on a light and a dark band, to check that both read.
 *
 * --tray <dir> is the Windows notification area's set instead (host-agent.ps1
 * install): nothing tints a tray icon, so each state is drawn twice, dark on a
 * light taskbar and light on a dark one, square, at 16, 24 and 32 px (100, 150,
 * 200 % scaling). All of them in ONE Chromium screenshot, cut apart here, each
 * state × theme packed as a PNG-in-ICO: <dir>/<state>-<light|dark>.ico.
 */
import { spawnSync } from 'node:child_process';
import { closeSync, mkdtempSync, openSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { crc32, deflateSync, inflateSync } from 'node:zlib';

export const STATES = ['running', 'idle', 'unloaded', 'stray'];
const W = 44;
const H = 36;
// 144 dpi in pixels per metre, what the pHYs chunk counts in.
const PPM = 5669;

// The SVG with `letters` in #letters. Three letters drop the font size so they
// still fit the tag ; more than that needs a wider tag, an SVG of the project's own.
export function withLetters(svg, letters) {
	if (!/^[A-Za-z0-9]{1,3}$/.test(letters)) throw new Error(`icon letters '${letters}': 1 to 3 letters or digits`);
	const re = /(<text\b[^>]*\bid="letters"[^>]*>)[^<]*(<\/text>)/;
	if (!re.test(svg)) throw new Error('the SVG has no <text id="letters">');
	return svg.replace(re, (_, open, close) => {
		if (letters.length === 3) open = open.replace(/\bfont-size="[^"]*"/, 'font-size="8"');
		return open + letters + close;
	});
}

// The SVG cropped to one state's cell: same document, the root's viewBox moved
// onto it, so the other three fall outside.
export function stateSvg(svg, state) {
	const g = svg.match(new RegExp(`<g\\b[^>]*\\bid="${state}"[^>]*>`));
	if (!g) throw new Error(`the SVG has no <g id="${state}">`);
	const t = g[0].match(/\btransform="translate\(\s*([-\d.]+)[\s,]+([-\d.]+)\s*\)"/);
	const x = t ? t[1] : 0;
	const y = t ? t[2] : 0;
	return svg.replace(/<svg\b[^>]*>/, (open) =>
		open.replace(/\s(width|height|viewBox)="[^"]*"/g, '').replace(/^<svg/, `<svg width="${W}" height="${H}" viewBox="${x} ${y} ${W} ${H}"`));
}

// The instance's letter in place of the dot, on one state's cropped SVG: the
// whole drawing masked by a gap at the dot (38,29 of the cell, the kit's), then
// running = a solid disc with the letter cut out, idle / unloaded = the bare
// letter. stray keeps its « ! » — that warning outranks which instance it is.
export function withMark(svg, state, mark) {
	if (!mark) return svg;
	if (!/^[a-z]$/.test(mark)) throw new Error(`instance mark '${mark}': one letter, b to z`);
	if (state === 'stray') return svg;
	const vb = svg.match(/<svg\b[^>]*\bviewBox="([-\d.]+) ([-\d.]+) /);
	if (!vb) throw new Error('the state SVG has no viewBox');
	const x = Number(vb[1]);
	const y = Number(vb[2]);
	const cx = x + 38;
	const cy = y + 29;
	const cell = `x="${x}" y="${y}" width="${W}" height="${H}"`;
	const letter = (size, fill) =>
		`<text x="${cx}" y="${cy + size * 0.36}" text-anchor="middle" font-family="-apple-system, 'SF Pro Text', 'Helvetica Neue', Arial, sans-serif" font-size="${size}" font-weight="800" fill="${fill}">${mark}</text>`;
	const defs = `<defs><mask id="ab-mark-gap" maskUnits="userSpaceOnUse" ${cell}><rect ${cell} fill="#fff"/><circle cx="${cx}" cy="${cy}" r="7.5" fill="#000"/></mask>` +
		`<mask id="ab-mark-cut" maskUnits="userSpaceOnUse" ${cell}><circle cx="${cx}" cy="${cy}" r="6" fill="#fff"/>${letter(9, '#000')}</mask></defs>`;
	const draw = state === 'running'
		? `<rect ${cell} fill="currentColor" mask="url(#ab-mark-cut)"/>`
		: `<g${state === 'unloaded' ? ' opacity="0.4"' : ''}>${letter(13, 'currentColor')}</g>`;
	return svg.replace(/(<svg\b[^>]*>)([\s\S]*)(<\/svg>\s*)$/, (_, open, body, close) => `${open}${defs}<g mask="url(#ab-mark-gap)">${body}</g>${draw}${close}`);
}

function chunk(type, data) {
	const out = Buffer.alloc(12 + data.length);
	out.writeUInt32BE(data.length, 0);
	out.write(type, 4, 'latin1');
	data.copy(out, 8);
	out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
	return out;
}

// The PNG, checked 44×36 with alpha, its pHYs (if any) replaced by 144 dpi.
export function withPhys(png) {
	if (png.toString('latin1', 1, 4) !== 'PNG' || png.toString('latin1', 12, 16) !== 'IHDR') throw new Error('not a PNG');
	const w = png.readUInt32BE(16);
	const h = png.readUInt32BE(20);
	if (w !== W || h !== H) throw new Error(`rendered ${w}×${h}, expected ${W}×${H}`);
	if (png[25] !== 6) throw new Error(`PNG colour type ${png[25]}, expected 6 (RGBA)`);
	const phys = Buffer.alloc(9);
	phys.writeUInt32BE(PPM, 0);
	phys.writeUInt32BE(PPM, 4);
	phys[8] = 1;
	const parts = [png.subarray(0, 33), chunk('pHYs', phys)];
	for (let at = 33; at < png.length;) {
		const end = at + 12 + png.readUInt32BE(at);
		if (png.toString('latin1', at + 4, at + 8) !== 'pHYs') parts.push(png.subarray(at, end));
		at = end;
	}
	return Buffer.concat(parts);
}

// No pipes to Chromium: on Windows its helpers (the crash reporter) inherit
// them, and spawnSync waits for every holder to let go — until the timeout,
// long after the PNG is written. stderr goes to a file, read when it fails.
function render(chromium, svgFile, pngFile, profile, w = W, h = H) {
	const errFile = `${pngFile}.stderr`;
	const err = openSync(errFile, 'w');
	const r = spawnSync(chromium, [
		'--headless', '--disable-gpu', '--hide-scrollbars', '--no-first-run', '--no-default-browser-check',
		'--force-device-scale-factor=1', '--default-background-color=00000000', `--window-size=${w},${h}`,
		`--user-data-dir=${profile}`, `--screenshot=${pngFile}`, pathToFileURL(svgFile).href,
	], { stdio: ['ignore', 'ignore', err], timeout: 60000, windowsHide: true });
	closeSync(err);
	if (r.status !== 0) {
		// 60 s: a Chromium snapshot starts slowly in a VM (31 s measured on Windows ARM).
		const why = r.error?.code === 'ETIMEDOUT' ? 'did not finish within 60 s' : `exited ${r.status ?? r.signal}`;
		throw new Error(`Chromium ${why}: ${readFileSync(errFile, 'utf8').trim().split('\n').pop()}`);
	}
	return readFileSync(pngFile);
}

// ── the Windows tray set ─────────────────────────────────────────────────────

export const TRAY_SIZES = [16, 24, 32];
// Glyph colour per taskbar theme (HKCU …\Personalize\SystemUsesLightTheme).
export const TRAY_THEMES = [
	{ name: 'light', color: '#1b1b1b' },
	{ name: 'dark', color: '#f2f2f2' },
];

// The root's currentColor: a tray icon is drawn in its final colour.
export function withColor(svg, color) {
	if (!/^#[0-9a-fA-F]{6}$/.test(color)) throw new Error(`'${color}': a #rrggbb colour`);
	return svg.replace(/<svg\b[^>]*>/, (open) => open.replace(/\sstyle="[^"]*"/, '').replace(/^<svg/, `<svg style="color:${color}"`));
}

// Where each theme × size × state goes on the one screenshot: a row per theme
// and size, a column per state, each icon in a square of its size.
export function trayLayout() {
	const col = Math.max(...TRAY_SIZES);
	const cells = [];
	let y = 0;
	for (const theme of TRAY_THEMES) {
		for (const size of TRAY_SIZES) {
			STATES.forEach((state, i) => cells.push({ theme: theme.name, size, state, x: i * col, y }));
			y += size;
		}
	}
	return { width: STATES.length * col, height: y, cells };
}

// The page that screenshot is taken of: each state's SVG as an image, scaled
// into its square (the 44×36 cell centred, aspect kept).
function trayPage(svgs) {
	const { cells } = trayLayout();
	const imgs = cells.map((c) => {
		const color = TRAY_THEMES.find((t) => t.name === c.theme).color;
		const src = `data:image/svg+xml;base64,${Buffer.from(withColor(svgs[c.state], color)).toString('base64')}`;
		return `<img src="${src}" style="left:${c.x}px;top:${c.y}px;width:${c.size}px;height:${c.size}px">`;
	});
	return `<!doctype html><meta charset="utf-8"><style>html,body{margin:0;background:transparent}img{position:absolute}</style>${imgs.join('')}`;
}

// A PNG's RGBA pixels: 8-bit RGBA, not interlaced — what Chromium writes.
export function decodePng(png) {
	if (png.toString('latin1', 1, 4) !== 'PNG') throw new Error('not a PNG');
	const width = png.readUInt32BE(16);
	const height = png.readUInt32BE(20);
	if (png[24] !== 8 || png[25] !== 6 || png[28] !== 0) throw new Error('only 8-bit RGBA, not interlaced');
	const idat = [];
	for (let at = 8; at < png.length;) {
		const len = png.readUInt32BE(at);
		if (png.toString('latin1', at + 4, at + 8) === 'IDAT') idat.push(png.subarray(at + 8, at + 8 + len));
		at += 12 + len;
	}
	const raw = inflateSync(Buffer.concat(idat));
	const stride = width * 4;
	const data = Buffer.alloc(stride * height);
	for (let y = 0; y < height; y++) {
		const f = raw[y * (stride + 1)];
		for (let x = 0; x < stride; x++) {
			const v = raw[y * (stride + 1) + 1 + x];
			const a = x >= 4 ? data[y * stride + x - 4] : 0;
			const b = y ? data[(y - 1) * stride + x] : 0;
			const c = x >= 4 && y ? data[(y - 1) * stride + x - 4] : 0;
			let pred = 0;
			if (f === 1) pred = a;
			else if (f === 2) pred = b;
			else if (f === 3) pred = (a + b) >> 1;
			else if (f === 4) {
				const p = a + b - c;
				const pa = Math.abs(p - a);
				const pb = Math.abs(p - b);
				const pc = Math.abs(p - c);
				pred = pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
			}
			data[y * stride + x] = (v + pred) & 255;
		}
	}
	return { width, height, data };
}

export function encodePng(width, height, rgba) {
	const stride = width * 4;
	const raw = Buffer.alloc((stride + 1) * height);
	for (let y = 0; y < height; y++) rgba.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
	const ihdr = Buffer.alloc(13);
	ihdr.writeUInt32BE(width, 0);
	ihdr.writeUInt32BE(height, 4);
	ihdr[8] = 8;
	ihdr[9] = 6;
	return Buffer.concat([Buffer.from('\x89PNG\r\n\x1a\n', 'latin1'), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}

export function cropPng(png, x, y, w, h) {
	const img = decodePng(png);
	if (x < 0 || y < 0 || x + w > img.width || y + h > img.height) throw new Error(`crop ${x},${y} ${w}×${h} outside ${img.width}×${img.height}`);
	const out = Buffer.alloc(w * h * 4);
	for (let r = 0; r < h; r++) img.data.copy(out, r * w * 4, ((y + r) * img.width + x) * 4, ((y + r) * img.width + x + w) * 4);
	return encodePng(w, h, out);
}

// PNG-in-ICO (Vista and later): a 6-byte header, a 16-byte entry per image,
// then the PNGs unchanged.
export function toIco(pngs) {
	const head = Buffer.alloc(6 + 16 * pngs.length);
	head.writeUInt16LE(0, 0);
	head.writeUInt16LE(1, 2);
	head.writeUInt16LE(pngs.length, 4);
	let offset = head.length;
	pngs.forEach((p, i) => {
		const e = 6 + 16 * i;
		head[e] = p.readUInt32BE(16) >= 256 ? 0 : p.readUInt32BE(16);
		head[e + 1] = p.readUInt32BE(20) >= 256 ? 0 : p.readUInt32BE(20);
		head.writeUInt16LE(1, e + 4);
		head.writeUInt16LE(32, e + 6);
		head.writeUInt32LE(p.length, e + 8);
		head.writeUInt32LE(offset, e + 12);
		offset += p.length;
	});
	return Buffer.concat([head, ...pngs]);
}

function trayIcons(chromium, svgs, dir, tmp) {
	const { width, height, cells } = trayLayout();
	const page = join(tmp, 'tray.html');
	writeFileSync(page, trayPage(svgs));
	const shot = render(chromium, page, join(tmp, 'tray.png'), join(tmp, 'profile'), width, height);
	const got = decodePng(shot);
	if (got.width !== width || got.height !== height) throw new Error(`rendered ${got.width}×${got.height}, expected ${width}×${height}`);
	for (const theme of TRAY_THEMES) {
		for (const state of STATES) {
			const pngs = cells.filter((c) => c.theme === theme.name && c.state === state).map((c) => cropPng(shot, c.x, c.y, c.size, c.size));
			writeFileSync(join(dir, `${state}-${theme.name}.ico`), toIco(pngs));
		}
	}
}

export function sheet(pngs) {
	const imgs = pngs.map((p) => `<img src="data:image/png;base64,${p.toString('base64')}">`).join('');
	return `<!doctype html><meta charset="utf-8"><title>menu-bar icon</title><style>
body{margin:0}div{display:flex;gap:48px;padding:24px 32px}img{width:${W * 3}px;height:${H * 3}px;image-rendering:pixelated}
.light{background:#ececec}.dark{background:#282828}.dark img{filter:invert(1)}
</style><div class="light">${imgs}</div><div class="dark">${imgs}</div>`;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
	const [svgPath, letters, chromium, fourth] = process.argv.slice(2);
	const mark = fourth && !fourth.startsWith('--') ? fourth : '';
	const s = process.argv.indexOf('--sheet');
	const t = process.argv.indexOf('--tray');
	if (!svgPath || !letters || !chromium) {
		console.error('usage: node menubar-icon.mjs <svg> <letters> <chromium> [<instance mark>] [--sheet <out.html>] [--tray <dir>]');
		process.exit(2);
	}
	const tmp = mkdtempSync(join(tmpdir(), 'menubar-icon-'));
	try {
		const svg = withLetters(readFileSync(svgPath, 'utf8'), letters);
		if (t > 0) {
			const svgs = {};
			for (const state of STATES) svgs[state] = withMark(stateSvg(svg, state), state, mark);
			trayIcons(chromium, svgs, process.argv[t + 1], tmp);
			console.log(`TRAY_ICONS=${process.argv[t + 1]}`);
		} else {
			const pngs = [];
			for (const state of STATES) {
				const file = join(tmp, `${state}.svg`);
				writeFileSync(file, withMark(stateSvg(svg, state), state, mark));
				pngs.push(withPhys(render(chromium, file, join(tmp, `${state}.png`), join(tmp, 'profile'))));
			}
			if (s > 0) writeFileSync(process.argv[s + 1], sheet(pngs));
			STATES.forEach((state, i) => console.log(`ICON_${state.toUpperCase()}=${pngs[i].toString('base64')}`));
		}
	} catch (e) {
		console.error(e.message);
		process.exitCode = 1;
	} finally {
		rmSync(tmp, { recursive: true, force: true });
	}
}
