#!/usr/bin/env node
// Computed styles and boxes for a list of selectors, through /opt/devcontainer/base/skills/visual-loop/scripts/cdp.mjs.
//
// This is the "close with numbers" step of CLAUDE-project #visual-1to1, which
// every session ends up hand-writing as an IIFE inside a `cdp.mjs eval` string —
// and which the same two rules keep biting :
//   - re-navigate in the SAME invocation, because the tab may have moved ;
//   - wrap the expression in an IIFE, because evals share the page context and a
//     bare `const` collides with the previous call.
// Both are handled here, so a gap table is one command.
//
//   probe.mjs --url '…/?panel=demo-patient-panel' --login \
//             --origin '.drawer' \
//             --sel '.form-section:first-of-type=paddingBottom,boxShadow' \
//             --sel '.field-row=gridTemplateColumns,gap' \
//             --sel '.field-row__label=fontSize,fontWeight,color'
//
// Each --sel is `<css>=<prop,prop,…>`; drop the `=…` for the box alone. Boxes are
// reported relative to --origin (default: the viewport) so they read as the
// mockup's own coordinates instead of screen ones.

import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

// Resolved from this file rather than from the cwd. Baked, these siblings live at
// /opt/devcontainer/base/skills/visual-loop/scripts/ while the human stands in a
// project directory, so a cwd-relative spawn silently targeted a project copy when
// one existed and died with ENOENT when it did not.
const CDP = fileURLToPath(new URL('./cdp.mjs', import.meta.url))

const HELP = `probe.mjs --url <url> [options] --sel <css>[=<props>] [--sel …]

  --url <url>       page to open (query string included)
  --login           authenticate first — the authenticated shell only mounts logged in, and
                    without it a deep link renders an empty page
  --origin <css>    element the boxes are measured from   (default: viewport)
  --sel <spec>      repeatable. \`.foo=fontSize,gap\` or just \`.foo\`. A bare
                    argument counts as one too, so the selectors can just be
                    listed at the end
  --all             report every match, not just the first
  --device <name>   desktop | laptop | macbook
  --width/--height  viewport override, wins over --device
  --json            raw JSON instead of the table
`

function parse(argv) {
	const o = { sel: [] }
	for (let i = 0; i < argv.length; i++) {
		const k = argv[i]
		// A bare argument is a selector : listing them at the end reads better than
		// repeating --sel, and it is how they arrive through `wtf … -- …`.
		if (!k.startsWith('--')) {
			o.sel.push(k)
			continue
		}
		const v = argv[i + 1]
		const val = v === undefined || v.startsWith('--') ? true : (i++, v)
		if (k === '--sel') o.sel.push(val)
		else o[k.slice(2)] = val
	}
	return o
}

const o = parse(process.argv.slice(2))
if (o.help || !o.url || !o.sel.length) {
	process.stdout.write(HELP)
	process.exit(o.help ? 0 : 1)
}

const specs = o.sel.map(s => {
	const i = String(s).indexOf('=')
	return i < 0
		? { css: String(s), props: [] }
		: { css: String(s).slice(0, i), props: String(s).slice(i + 1).split(',').filter(Boolean) }
})

// Re-navigating in the same invocation is the whole point : `shot` moves the tab,
// and an `eval` issued afterwards may be measuring a different page.
const nav = ['shot', o.url, '--out', '/tmp/probe-nav.png']
if (o.login) nav.push('--login')
for (const k of ['device', 'width', 'height']) if (o[k]) nav.push(`--${k}`, String(o[k]))
execFileSync('node', [CDP, ...nav], { stdio: 'ignore' })

const expression = `(() => {
	const specs = ${JSON.stringify(specs)}
	const originEl = ${o.origin ? `document.querySelector(${JSON.stringify(o.origin)})` : 'null'}
	const o = originEl ? originEl.getBoundingClientRect() : { left: 0, top: 0 }
	const round = n => Math.round(n * 100) / 100
	const out = []
	for (const s of specs) {
		const found = [...document.querySelectorAll(s.css)]
		if (!found.length) { out.push({ css: s.css, missing: true }); continue }
		for (const el of ${o.all ? 'found' : 'found.slice(0, 1)'}) {
			const r = el.getBoundingClientRect()
			const cs = getComputedStyle(el)
			const style = {}
			for (const p of s.props) style[p] = cs[p]
			out.push({
				css: s.css,
				box: { x: round(r.left - o.left), y: round(r.top - o.top), w: round(r.width), h: round(r.height) },
				style,
			})
		}
	}
	return out
})()`

// cdp.mjs JSON-serialises whatever the expression returns, so hand it the array
// itself : stringifying first only buys a second layer of escaping to undo.
const raw = execFileSync('node', [CDP, 'eval', expression], { encoding: 'utf8' })
const rows = JSON.parse(raw)

if (o.json) {
	console.log(JSON.stringify(rows, null, 1))
	process.exit(0)
}

const w = Math.max(...rows.map(r => r.css.length), 10)
console.log(`${'selector'.padEnd(w)}  ${'x'.padStart(8)} ${'y'.padStart(8)} ${'w'.padStart(8)} ${'h'.padStart(8)}   computed`)
console.log('-'.repeat(w + 40))
for (const r of rows) {
	if (r.missing) {
		console.log(`${r.css.padEnd(w)}  ** no match **`)
		continue
	}
	const { x, y, w: bw, h } = r.box
	const style = Object.entries(r.style).map(([k, v]) => `${k}: ${v}`).join(' · ')
	console.log(
		`${r.css.padEnd(w)}  ${String(x).padStart(8)} ${String(y).padStart(8)} ${String(bw).padStart(8)} ${String(h).padStart(8)}   ${style}`,
	)
}
