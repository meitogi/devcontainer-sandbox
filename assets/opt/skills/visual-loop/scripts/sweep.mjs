#!/usr/bin/env node
// The end-of-loop viewport sweep : capture the three presets, crop the element
// under test out of each, and lay them out as one contact sheet to `Read`.
//
// CLAUDE-project #visual-1to1 says to iterate on ONE viewport and sweep at the
// end — a second resolution changes what wraps and turns every diff into
// guesswork. This is that end. `macbook` is the shortest and decides whether a
// modal fits, so the sheet also reports, per preset, whether the scrolling
// container actually overflows.
//
//   sweep.mjs --url '…/?panel=demo-patient-panel' --login --crop right:720 \
//             --scroll '.drawer .modal-frame__body' \
//             --out plans/<slug>/shots/panel-viewports.png
//
// Leaves the viewport override in place on purpose, exactly like `wtf claude live shot` —
// run `node /opt/devcontainer/base/skills/visual-loop/scripts/cdp.mjs reset` when you stop measuring, or pass --reset.

import { execFileSync } from 'node:child_process'
import { mkdir } from 'node:fs/promises'
import { dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import sharp from 'sharp'

// Resolved from this file rather than from the cwd. Baked, these siblings live at
// /opt/devcontainer/base/skills/visual-loop/scripts/ while the human stands in a
// project directory, so a cwd-relative spawn silently targeted a project copy when
// one existed and died with ENOENT when it did not.
const CDP = fileURLToPath(new URL('./cdp.mjs', import.meta.url))

const HELP = `sweep.mjs --url <url> --out <png> [options]

  --url <url>       page to open (query string included)
  --out <png>       contact sheet to write
  --login           authenticate first
  --crop <spec>     right:<w> | left:<w> | x,y,w,h | none   (reference units)
  --scroll <css>    container to report overflow for, per preset (both axes)
  --devices <list>  comma separated                 (default desktop,laptop,macbook)
  --scale <n>       capture DPR                                     (default 2)
  --thumb <n>       width of each panel in the sheet, px            (default 480)
  --reset           clear the viewport override when done
`

const PRESETS = { desktop: [1920, 950], laptop: [1440, 800], macbook: [1512, 789] }

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
if (o.help || !o.url || !o.out) {
	process.stdout.write(HELP)
	process.exit(o.help ? 0 : 1)
}

const scale = Number(o.scale ?? 2)
const thumb = Number(o.thumb ?? 480)
const devices = String(o.devices ?? 'desktop,laptop,macbook').split(',')
const bad = devices.filter(d => !PRESETS[d])
if (bad.length) {
	console.error(`sweep: unknown preset ${bad.join(', ')} (known: ${Object.keys(PRESETS).join(', ')})`)
	process.exit(1)
}

const spec = o.crop && o.crop !== 'none' ? String(o.crop) : null
const region = (w, h) => {
	if (!spec) return null
	if (spec.startsWith('right:')) {
		const cw = Number(spec.slice(6)) * scale
		return { left: w * scale - cw, top: 0, width: cw, height: h * scale }
	}
	if (spec.startsWith('left:')) {
		const cw = Number(spec.slice(5)) * scale
		return { left: 0, top: 0, width: cw, height: h * scale }
	}
	const [x, y, cw, ch] = spec.split(',').map(n => Number(n) * scale)
	return { left: x, top: y, width: cw, height: ch }
}

await mkdir('.tmp/shots', { recursive: true })
const panels = []
const overflow = []

for (const d of devices) {
	const [w, h] = PRESETS[d]
	const raw = `.tmp/shots/sweep-${d}.png`
	const args = [CDP, 'shot', o.url, '--device', d, '--scale', String(scale), '--out', raw]
	if (o.login) args.push('--login')
	execFileSync('node', args, { stdio: 'ignore' })

	const r = region(w, h)
	panels.push(await (r ? sharp(raw).extract(r) : sharp(raw)).resize({ width: thumb }).png().toBuffer())

	if (o.scroll) {
		// Same invocation as the capture that is still on screen, so the numbers
		// describe the frame in the sheet and not whatever the tab drifted to.
		// BOTH axes : a grid that overflows sideways is the thing a viewport
		// sweep is run to catch, and height alone cannot answer it.
		const expr = `(() => { const e = document.querySelector(${JSON.stringify(o.scroll)});
			return e ? { client: e.clientHeight, scroll: e.scrollHeight, overflows: e.scrollHeight > e.clientHeight,
				clientW: e.clientWidth, scrollW: e.scrollWidth, overflowsX: e.scrollWidth > e.clientWidth } : { missing: true } })()`
		overflow.push([d, JSON.parse(execFileSync('node', [CDP, 'eval', expr], { encoding: 'utf8' }))])
	}
}

const metas = await Promise.all(panels.map(p => sharp(p).metadata()))
const gutter = 20
const width = metas.reduce((a, m) => a + m.width, 0) + gutter * (panels.length - 1)
const height = Math.max(...metas.map(m => m.height))

let left = 0
const composite = panels.map((input, i) => {
	const at = { input, left, top: 0 }
	left += metas[i].width + gutter
	return at
})

await mkdir(dirname(o.out), { recursive: true })
await sharp({ create: { width, height, channels: 3, background: '#ffffff' } })
	.composite(composite)
	.png()
	.toFile(o.out)

console.log(`${o.out}  ${width}×${height}  ${devices.map((d, i) => `${d} ${PRESETS[d].join('×')} → ${metas[i].width}px`).join(' · ')}`)
for (const [d, r] of overflow) {
	if (r.missing) console.log(`  ${d.padEnd(8)} ${o.scroll} — no match`)
	else
		console.log(
			`  ${d.padEnd(8)} ${o.scroll}  ↕ ${r.client} of ${r.scroll} → ${r.overflows ? 'scrolls' : 'fits'}` +
				`  ↔ ${r.clientW} of ${r.scrollW} → ${r.overflowsX ? 'OVERFLOWS' : 'fits'}`,
		)
}

if (o.reset) execFileSync('node', [CDP, 'reset'], { stdio: 'inherit' })
else console.log('\nviewport override left in place — `node /opt/devcontainer/base/skills/visual-loop/scripts/cdp.mjs reset` when you stop measuring')
