#!/usr/bin/env node
// Pixel probing for the 1:1 visual loop — the same three questions come back
// every session : where is an edge, how big is a glyph's ink, what colour is it
// really. Doing it by hand means a fresh `node -e` blob each time, and every blob
// re-invents the two traps CLAUDE-project #visual-1to1 warns about (corner radii
// pulling an edge inward, antialiasing dragging a mean colour).
//
// Every coordinate in and out is in REFERENCE units, not device pixels : pass
// --scale 2 for a 2x capture and you can compare a Figma dump's numbers directly.
//
//   pixel.mjs edges --img a.png --axis v --at 160
//   pixel.mjs runs  --img a.png --axis h --at 398 --from 140 --to 340
//   pixel.mjs ink   --img a.png --rect 24,88,300,108
//   pixel.mjs cmp   --a ours.png --b ref.png --axis v --at 10
//
// Threshold guide : 250 finds structure (borders, fills, section rules) ; 210
// finds ink (text, icons) without catching a #f5f5f5 band.

import { basename } from 'node:path'
import sharp from 'sharp'

const HELP = `pixel.mjs <edges|runs|ink|cmp> [options]

  edges  boundaries where the scanline crosses the threshold
  runs   contiguous inked spans, with the colour each one ends on
  ink    bounding box, dominant colour and darkest pixel inside a rect
  cmp    runs for two images side by side, with the delta of each boundary.
         Pairs them BY INDEX : trustworthy on structure (borders, rules), noise
         on a row of glyphs, where one extra serif shifts every later pair.

  --img <path>          image to probe                      (edges|runs|ink)
  --a <path> --b <path> the two images to compare           (cmp)
  --axis v|h            scan down a column (v) or across a row (h)
  --at <n>              the column x, or the row y
  --from <n> --to <n>   bounds along the scan            (default: whole image)
  --rect x0,y0,x1,y1    rectangle to measure                 (ink)
  --crop <spec>         cut --img / --a down first, in reference units :
                        right:<w> for a drawer, left:<w>, x,y,w,h, or none.
                        Same spec as ab-shot, so a capture is probed where it
                        lies — no intermediate file. --b is left alone ; it is
                        already the reference element.
  --threshold <n>       "inked" below this luminance        (default 250 / 210)
  --invert              "inked" ABOVE it instead — a white glyph on a brand
                        fill, a knob on a rail, light text on a button
  --scale <n>           device pixels per reference unit       (default 2)
`

function parse(argv) {
	const o = { scale: 2 }
	// From 0, not 1 : the subcommand is skipped by the `--` test below anyway, and
	// starting at 1 swallowed a bare `--help`.
	for (let i = 0; i < argv.length; i++) {
		const k = argv[i]
		if (!k.startsWith('--')) continue
		const v = argv[i + 1]
		o[k.slice(2)] = v === undefined || v.startsWith('--') ? true : (i++, v)
	}
	return o
}

// The capture is the whole viewport ; the element under test is a corner of it.
// Cropping here rather than in a temp file keeps every coordinate below in the
// element's own frame, which is the frame the mockup is written in.
function cropSpec(spec, meta, scale) {
	if (!spec || spec === 'none') return null
	const s = String(spec)
	if (s.startsWith('right:')) {
		const w = Number(s.slice(6)) * scale
		return { left: meta.width - w, top: 0, width: w, height: meta.height }
	}
	if (s.startsWith('left:')) {
		const w = Number(s.slice(5)) * scale
		return { left: 0, top: 0, width: w, height: meta.height }
	}
	const [x, y, w, h] = s.split(',').map(n => Number(n) * scale)
	return { left: x, top: y, width: w, height: h }
}

async function load(path, scale, crop) {
	const region = crop ? cropSpec(crop, await sharp(path).metadata(), scale) : null
	const pipeline = region ? sharp(path).extract(region) : sharp(path)
	const { data, info } = await pipeline.raw().toBuffer({ resolveWithObject: true })
	const { width: W, height: H, channels: C } = info
	return {
		name: basename(path),
		w: W / scale,
		h: H / scale,
		// (x, y) in reference units → [r, g, b]
		px(x, y) {
			const i = (Math.round(y * scale) * W + Math.round(x * scale)) * C
			return [data[i], data[i + 1], data[i + 2]]
		},
		lum(x, y) {
			const [r, g, b] = this.px(x, y)
			return (r + g + b) / 3
		},
		scale,
	}
}

// Contiguous inked spans along one scanline, in reference units.
function runs(img, axis, at, from, to, threshold, invert) {
	const step = 1 / img.scale
	const out = []
	let open = null
	for (let p = from; p < to; p += step) {
		const [x, y] = axis === 'v' ? [at, p] : [p, at]
		if (invert ? img.lum(x, y) > threshold : img.lum(x, y) < threshold) {
			if (open) open.end = p
			else open = { start: p, end: p, colour: img.px(x, y).join(',') }
		} else if (open) {
			out.push(open)
			open = null
		}
	}
	if (open) out.push(open)
	return out
}

function ink(img, [x0, y0, x1, y1], threshold, invert) {
	const step = 1 / img.scale
	let minX = Infinity
	let minY = Infinity
	let maxX = -1
	let maxY = -1
	let darkest = null
	let darkestLum = invert ? -1 : 999
	const hist = {}
	for (let y = y0; y < y1; y += step)
		for (let x = x0; x < x1; x += step) {
			const l = img.lum(x, y)
			if (invert ? l <= threshold : l >= threshold) continue
			if (x < minX) minX = x
			if (x > maxX) maxX = x
			if (y < minY) minY = y
			if (y > maxY) maxY = y
			const p = img.px(x, y)
			const key = p.join(',')
			hist[key] = (hist[key] || 0) + 1
			if (invert ? l > darkestLum : l < darkestLum) {
				darkestLum = l
				darkest = key
			}
		}
	if (maxX < 0) return null
	// Dominant beats mean : antialiasing drags a mean towards the background, and
	// the darkest pixel alone is one sample. The mode is the fill the designer set.
	const ranked = Object.entries(hist).sort((a, b) => b[1] - a[1])
	return {
		x: [minX, maxX + step],
		y: [minY, maxY + step],
		w: +(maxX - minX + step).toFixed(2),
		h: +(maxY - minY + step).toFixed(2),
		dominant: ranked[0][0],
		darkest,
		samples: ranked.slice(0, 3).map(([c, n]) => `${c} ×${n}`),
	}
}

const hex = csv => `#${csv.split(',').map(n => (+n).toString(16).padStart(2, '0')).join('')}`
const fmt = r => `${r.start}..${+(r.end + 1 / 2).toFixed(2)}`

const o = parse(process.argv.slice(2))
const cmd = process.argv[2]
if (!cmd || o.help || cmd === 'help') {
	process.stdout.write(HELP)
	process.exit(0)
}

const scale = Number(o.scale)
const axis = o.axis === 'h' ? 'h' : 'v'
const threshold = Number(o.threshold ?? (cmd === 'ink' ? 210 : 250))
const invert = !!o.invert

if (cmd === 'ink') {
	const img = await load(o.img, scale, o.crop)
	const rect = String(o.rect).split(',').map(Number)
	const r = ink(img, rect, threshold, invert)
	if (!r) {
		console.log(`${img.name}: nothing above threshold ${threshold} in ${o.rect}`)
		process.exit(0)
	}
	console.log(`${img.name}  rect ${o.rect}  threshold ${threshold}`)
	console.log(`  x        ${r.x[0]}..${r.x[1]}   (w ${r.w})`)
	console.log(`  y        ${r.y[0]}..${r.y[1]}   (h ${r.h})`)
	console.log(`  dominant ${hex(r.dominant)}   ${invert ? 'lightest' : 'darkest'} ${hex(r.darkest)}`)
	console.log(`  top 3    ${r.samples.join('  ')}`)
	process.exit(0)
}

if (cmd === 'cmp') {
	const [a, b] = await Promise.all([load(o.a, scale, o.crop), load(o.b, scale)])
	const from = Number(o.from ?? 0)
	const to = Number(o.to ?? (axis === 'v' ? Math.min(a.h, b.h) : Math.min(a.w, b.w)))
	const ra = runs(a, axis, Number(o.at), from, to, threshold, invert)
	const rb = runs(b, axis, Number(o.at), from, to, threshold, invert)
	console.log(`${axis === 'v' ? 'column x' : 'row y'} = ${o.at}   threshold ${threshold}`)
	console.log(`${'#'.padStart(3)}  ${a.name.padEnd(22)} ${b.name.padEnd(22)} delta`)
	for (let i = 0; i < Math.max(ra.length, rb.length); i++) {
		const x = ra[i]
		const y = rb[i]
		const d = x && y ? (+(y.start - x.start).toFixed(2)).toString() : '—'
		console.log(
			`${String(i).padStart(3)}  ${(x ? fmt(x) : '—').padEnd(22)} ${(y ? fmt(y) : '—').padEnd(22)} ${d.padStart(6)}`,
		)
	}
	process.exit(0)
}

// edges | runs
const img = await load(o.img, scale, o.crop)
const from = Number(o.from ?? 0)
const to = Number(o.to ?? (axis === 'v' ? img.h : img.w))
const found = runs(img, axis, Number(o.at), from, to, threshold, invert)
console.log(`${img.name}  ${axis === 'v' ? 'column x' : 'row y'} = ${o.at}  threshold ${threshold}`)
if (cmd === 'edges') console.log(found.map(r => r.start).join(' '))
else for (const r of found) console.log(`  ${fmt(r).padEnd(20)} ${hex(r.colour)}`)
