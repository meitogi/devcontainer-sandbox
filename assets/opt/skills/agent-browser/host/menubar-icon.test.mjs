// menubar-icon.test.mjs — the SVG edits and the PNG stamp as pure checks. The
// rendering itself needs the host's Chromium and is not run here.
//
//   node --test /opt/devcontainer/base/skills/agent-browser/host/menubar-icon.test.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { deflateSync } from 'node:zlib';
import { STATES, stateSvg, withLetters, withMark, withPhys } from './menubar-icon.mjs';

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
