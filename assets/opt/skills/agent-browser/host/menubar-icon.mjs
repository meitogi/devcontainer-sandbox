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
 *   node menubar-icon.mjs <svg> <letters> <chromium> [--sheet <out.html>]
 *
 * prints ICON_RUNNING=<base64> … ICON_STRAY=<base64>, one per line. --sheet also
 * writes the four ×6 on a light and a dark band, to check that both read.
 */
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { crc32 } from 'node:zlib';

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

function render(chromium, svgFile, pngFile, profile) {
	const r = spawnSync(chromium, [
		'--headless', '--disable-gpu', '--hide-scrollbars', '--no-first-run', '--no-default-browser-check',
		'--force-device-scale-factor=1', '--default-background-color=00000000', `--window-size=${W},${H}`,
		`--user-data-dir=${profile}`, `--screenshot=${pngFile}`, pathToFileURL(svgFile).href,
	], { encoding: 'utf8', timeout: 30000 });
	if (r.status !== 0) throw new Error(`Chromium exited ${r.status ?? r.signal}: ${(r.stderr || '').trim().split('\n').pop()}`);
	return readFileSync(pngFile);
}

export function sheet(pngs) {
	const imgs = pngs.map((p) => `<img src="data:image/png;base64,${p.toString('base64')}">`).join('');
	return `<!doctype html><meta charset="utf-8"><title>menu-bar icon</title><style>
body{margin:0}div{display:flex;gap:48px;padding:24px 32px}img{width:${W * 3}px;height:${H * 3}px;image-rendering:pixelated}
.light{background:#ececec}.dark{background:#282828}.dark img{filter:invert(1)}
</style><div class="light">${imgs}</div><div class="dark">${imgs}</div>`;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
	const [svgPath, letters, chromium] = process.argv.slice(2);
	const s = process.argv.indexOf('--sheet');
	if (!svgPath || !letters || !chromium) {
		console.error('usage: node menubar-icon.mjs <svg> <letters> <chromium> [--sheet <out.html>]');
		process.exit(2);
	}
	const tmp = mkdtempSync(join(tmpdir(), 'menubar-icon-'));
	try {
		const svg = withLetters(readFileSync(svgPath, 'utf8'), letters);
		const pngs = [];
		for (const state of STATES) {
			const file = join(tmp, `${state}.svg`);
			writeFileSync(file, stateSvg(svg, state));
			pngs.push(withPhys(render(chromium, file, join(tmp, `${state}.png`), join(tmp, 'profile'))));
		}
		if (s > 0) writeFileSync(process.argv[s + 1], sheet(pngs));
		STATES.forEach((state, i) => console.log(`ICON_${state.toUpperCase()}=${pngs[i].toString('base64')}`));
	} catch (e) {
		console.error(e.message);
		process.exitCode = 1;
	} finally {
		rmSync(tmp, { recursive: true, force: true });
	}
}
