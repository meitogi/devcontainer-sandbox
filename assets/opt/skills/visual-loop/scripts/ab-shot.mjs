#!/usr/bin/env node
// Side-by-side of a capture and its Figma reference, for `Read`-ing back.
//
// Three things this gets right that a hand-rolled composite keeps getting wrong :
//   - BOTH sides at the same device scale. A 2x reference against a 1x capture
//     makes a 1.2px stroke read grey 190 where the reference reads 121, and the
//     whole comparison is an artefact (CLAUDE-project #visual-1to1).
//   - The crop. A panel is the rightmost 720 CSS px of a 1920 viewport ; passing
//     `--crop right:720` beats counting device pixels by hand every time.
//   - A colour bar per side instead of a caption. The container has no fonts, so
//     any text baked into the image renders as boxes.
//
//   ab-shot.mjs --ours .tmp/shots/panel.png --ref design/panel.png \
//               --crop right:720 --out plans/<slug>/shots/panel-vs-figma.png
//
// Then `Read` the --out path. Blue bar = ours, orange bar = the reference.

import { mkdir } from 'node:fs/promises'
import { dirname } from 'node:path'
import sharp from 'sharp'

const HELP = `ab-shot.mjs --ours <png> --ref <png> --out <png> [options]

  --crop <spec>   what to keep of --ours, in REFERENCE units :
                    right:<w>        rightmost w  (a drawer / panel)
                    left:<w>         leftmost w
                    x,y,w,h          explicit box (a popin)
                    none             the whole capture          (default)
  --ref-crop <sp> same, for --ref. A Figma render is not always the bare element
                  — a modal comes out sitting on its scrim, on a canvas wider
                  than itself, and comparing that against a cropped capture
                  measures the canvas.
  --detail <box>  x,y,w,h in reference units, cut from BOTH sides after --crop.
                  For a control rather than a page — a checkbox, a segment, a
                  field's prefix. Stacks and magnifies by default, because that
                  is the only way a 1px radius or a stroke weight is visible.
  --zoom <n>      nearest-neighbour magnification    (default 6 with --detail)
  --scale <n>     device pixels per reference unit in BOTH images  (default 2)
  --gap <n>       gutter between the two sides, device px          (default 24)
  --side-by-side  place them left/right                            (default)
  --stacked       place them top/bottom — better for a wide, short element
`

const OURS_BAR = '#2563eb'
const REF_BAR = '#ea580c'
const BAR = 14

function parse(argv) {
	const o = {}
	for (let i = 0; i < argv.length; i++) {
		const k = argv[i]
		if (!k.startsWith('--')) continue
		const v = argv[i + 1]
		o[k.slice(2)] = v === undefined || v.startsWith('--') ? true : (i++, v)
	}
	return o
}

const o = parse(process.argv.slice(2))
if (o.help || !o.ours || !o.ref || !o.out) {
	process.stdout.write(HELP)
	process.exit(o.help ? 0 : 1)
}

const scale = Number(o.scale ?? 2)
const gap = Number(o.gap ?? 24)

// Crops are expressed in reference units so they match the numbers already in the
// plan ("the panel is 720 wide"), never in device pixels.
function region(spec, meta) {
	const s = spec && spec !== 'none' ? String(spec) : null
	if (!s) return null
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

const cut = async (path, spec) => {
	const r = region(spec, await sharp(path).metadata())
	return (r ? sharp(path).extract(r) : sharp(path)).png().toBuffer()
}

let ours = await cut(o.ours, o.crop)
let ref = await cut(o.ref, o['ref-crop'])

// A detail is the same box out of both sides, magnified. Nearest-neighbour on
// purpose : a smoothed upscale invents the very edge you are trying to read.
if (o.detail) {
	const [x, y, w, h] = String(o.detail).split(',').map(n => Number(n) * scale)
	const box = { left: x, top: y, width: w, height: h }
	const zoom = Number(o.zoom ?? 6)
	const grow = img => sharp(img).extract(box).resize({ width: w * zoom, kernel: 'nearest' }).png().toBuffer()
	;[ours, ref] = await Promise.all([grow(ours), grow(ref)])
}

const [mo, mr] = await Promise.all([sharp(ours).metadata(), sharp(ref).metadata()])

if (mo.width !== mr.width) {
	// Not fatal — the two often differ by a border pixel — but a big gap means the
	// crop or the scale is wrong, and every measurement taken after it is fiction.
	const pct = Math.abs(mo.width - mr.width) / mr.width
	const line = `widths differ: ours ${mo.width}, ref ${mr.width}`
	if (pct > 0.02) {
		console.error(`ab-shot: ${line} — check --crop and --scale before trusting this`)
		process.exit(1)
	}
	console.error(`ab-shot: ${line} (within 2 %, continuing)`)
}

const bar = colour => sharp({ create: { width: 1, height: 1, channels: 3, background: colour } })

// A detail crop is wide and short, so stacking is what makes the two edges
// comparable — but --side-by-side still wins if asked for.
const stacked = o.stacked || (!!o.detail && !o['side-by-side'])
const width = stacked ? Math.max(mo.width, mr.width) : mo.width + gap + mr.width
const height = stacked ? mo.height + mr.height + gap + BAR * 2 : Math.max(mo.height, mr.height) + BAR
const refLeft = stacked ? 0 : mo.width + gap
const refTop = stacked ? mo.height + BAR + gap : 0

await mkdir(dirname(o.out), { recursive: true })
await sharp({ create: { width, height, channels: 3, background: '#ffffff' } })
	.composite([
		{ input: await bar(OURS_BAR).resize(mo.width, BAR).png().toBuffer(), left: 0, top: 0 },
		{ input: ours, left: 0, top: BAR },
		{ input: await bar(REF_BAR).resize(mr.width, BAR).png().toBuffer(), left: refLeft, top: refTop },
		{ input: ref, left: refLeft, top: refTop + BAR },
	])
	.png()
	.toFile(o.out)

console.log(`${o.out}  ${width}×${height}  blue = ours (${mo.width}×${mo.height}), orange = ref (${mr.width}×${mr.height})`)
