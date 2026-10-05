#!/usr/bin/env node
// Export .excalidraw → SVG + PNG @2x, rendu dark.
//
// Usage :
//   node export.mjs <fichier.excalidraw | dir> [--out <dir>] [--scale 2]
//                   [--bg <color> | --transparent] [--svg-only] [--light]
//
// Emits <name>.svg and <name>@<scale>x.png next to the source, or into --out.
//
// Dark is NOT a colour set: it is a render filter,
// `invert(93%) hue-rotate(180deg)`, applied to the root <svg>, background
// included (see KNOWLEDGE.md L14). So we never touch the sources'
// `viewBackgroundColor` — their #ffffff becomes 255×0.07 = 17.85 ≈ #121212,
// Excalidraw's canonical canvas black. Writing #000000 into the file would
// yield #ededed, i.e. white.

import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { createRequire, registerHooks } from 'node:module'
import { basename, dirname, extname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const USAGE = `Export .excalidraw → SVG + PNG @2x, rendu dark.

  node export.mjs <fichier.excalidraw | dir> [options]

  --out <dir>        write somewhere other than next to the source
  --scale <n>        PNG factor (default 2)
  --bg <color>       opaque background composited AFTER the dark filter
  --transparent      no background at all
  --svg-only         do not rasterise
  --light            disable dark rendering`

// The Excalidraw bundle is built for a bundler, not for Node. Three
// incompatibilités, trois hooks in-thread — ça vaut mieux qu'un patch de
// node_modules. jsdom and sharp, loaded on demand below, therefore pass
// through these hooks — harmlessly: `resolve` only retries with `.js` on
// ERR_MODULE_NOT_FOUND, and `load` only short-circuits CJS under
// `/@excalidraw/`.
registerHooks({
	// `roughjs/bin/rough`: extensionless import, which only a bundler resolves.
	resolve(specifier, context, nextResolve) {
		try {
			return nextResolve(specifier, context)
		} catch (err) {
			if (err.code !== 'ERR_MODULE_NOT_FOUND' || extname(specifier)) throw err
			return nextResolve(`${specifier}.js`, context)
		}
	},
	load(url, context, nextLoad) {
		// `open-color/open-color.json`: imported without `with { type: 'json' }`.
		if (url.startsWith('file:') && url.endsWith('.json')) {
			return { format: 'json', source: readFileSync(fileURLToPath(url), 'utf8'), shortCircuit: true }
		}
		const result = nextLoad(url, context)
		// `@excalidraw/laser-pointer`: CJS whose named exports cjs-module-lexer
		// cannot see. We require for real and re-export the observed keys —
		// static inference is the problem, not the module.
		//
		// Restricted to `@excalidraw/*` packages ON PURPOSE: applied to the whole
		// graph, the eager require breaks on the @babel/runtime cycles that
		// traîne @radix-ui.
		if (result.format !== 'commonjs' || !url.includes('/@excalidraw/')) return result

		const path = fileURLToPath(url)
		const mod = createRequire(url)(path)
		if (mod === null || typeof mod !== 'object') return result
		const named = Object.keys(mod).filter(k => k !== 'default' && /^[A-Za-z_$][\w$]*$/.test(k))
		const source = [
			"import { createRequire } from 'node:module'",
			`const m = createRequire(${JSON.stringify(url)})(${JSON.stringify(path)})`,
			'export default m',
			...named.map(k => `export const ${k} = m[${JSON.stringify(k)}]`),
		].join('\n')
		return { format: 'module', source, shortCircuit: true }
	},
})

// ── args ──────────────────────────────────────────────────────────────────

const argv = process.argv.slice(2)
if (argv.length === 0 || argv.includes('--help')) {
	console.log(USAGE)
	process.exit(0)
}

const VALUED = ['--out', '--scale', '--bg']

function flag(name, fallback) {
	const i = argv.indexOf(name)
	return i === -1 ? fallback : argv[i + 1]
}

const outDir = flag('--out', null)
const rawScale = flag('--scale', '2')
const scale = Number(rawScale)
const bg = flag('--bg', null)
const transparent = argv.includes('--transparent')
const svgOnly = argv.includes('--svg-only')
const dark = !argv.includes('--light')
const inputs = argv.filter((a, i) => !a.startsWith('--') && !VALUED.includes(argv[i - 1]))

if (!Number.isFinite(scale) || scale <= 0) {
	console.error(`--scale invalide : ${rawScale}`)
	process.exit(1)
}

// Resolved, never hand-built: `import.meta.resolve` follows exactly the same
// export conditions as the `await import()` below, whereas a hardcoded
// `dist/prod` would point at the wrong bundle under `--conditions=development`
// — `fontRanges()` would then scrape nothing and the `unicode-range` would be lost.
// The dependencies are local to the skill (see its package.json): a path relative
// to the CWD only worked when run from the repo root.
//
// This is also the skill's dependency preflight: nothing is imported
// statically from node_modules, so this resolution is the first point where
// their absence shows — and it gives a message rather than a stack.
let PKG
try {
	PKG = dirname(fileURLToPath(import.meta.resolve('@excalidraw/excalidraw')))
} catch {
	console.error('/diagram skill dependencies missing — install them with:')
	console.error('    npm install --prefix .devcontainer/skills/diagram')
	process.exit(1)
}
const FONTS = join(PKG, 'fonts')

// ── DOM ───────────────────────────────────────────────────────────────────

/**
 * Sets up the globals the Excalidraw bundle needs at module level.
 *
 * `measureText` is a heuristic: jsdom implements no 2D canvas and node-canvas
 * is a native binary we refuse. Text elements already carry their `width`/
 * `height` as computed by the app, so this measurement only serves the
 * recomputation paths — an approximate ratio is enough, a 0 would break
 * viewBox.
 */
function bootstrapDom() {
	const dom = new JSDOM('<!doctype html><html><body></body></html>', {
		url: 'http://localhost/',
		pretendToBeVisual: true,
	})
	const { window } = dom

	window.HTMLCanvasElement.prototype.getContext = function getContext(kind) {
		if (kind !== '2d') return null
		let font = '20px sans-serif'
		return {
			get font() {
				return font
			},
			set font(v) {
				font = v
			},
			measureText: text => {
				const size = Number.parseFloat(font) || 20
				return {
					width: text.length * size * 0.6,
					actualBoundingBoxAscent: size * 0.8,
					actualBoundingBoxDescent: size * 0.2,
				}
			},
			canvas: { width: 0, height: 0 },
			save() {},
			restore() {},
			scale() {},
			translate() {},
			rotate() {},
			clearRect() {},
			fillRect() {},
			drawImage() {},
			setTransform() {},
			beginPath() {},
			closePath() {},
			fill() {},
			stroke() {},
		}
	}

	// FontFace API — absent from jsdom, and the text render path constructs it
	// before inlining anything at all: without this stub, `exportToSvg` throws
	// « FontFace is not defined » and returns an SVG without the
	// moindre <text>.
	if (!window.document.fonts) {
		window.document.fonts = {
			add() {},
			check: () => true,
			load: async () => [],
			ready: Promise.resolve(),
			values: () => [][Symbol.iterator](),
			forEach() {},
		}
	}
	if (!window.FontFace) {
		window.FontFace = class FontFace {
			constructor(family, source, descriptors) {
				this.family = family
				this.source = source
				this.unicodeRange = descriptors?.unicodeRange ?? 'U+0-10FFFF'
				this.status = 'loaded'
			}
			async load() {
				return this
			}
		}
	}

	const globals = [
		'window', 'document', 'navigator', 'location', 'HTMLElement', 'HTMLCanvasElement',
		'HTMLImageElement', 'Element', 'SVGElement', 'Node', 'NodeList', 'Image', 'DOMParser',
		'XMLSerializer', 'Blob', 'File', 'FileReader', 'getComputedStyle', 'matchMedia',
		'requestAnimationFrame', 'cancelAnimationFrame', 'MutationObserver', 'CustomEvent',
		'Event', 'FontFace', 'devicePixelRatio',
	]
	for (const key of globals) {
		const value = key === 'window' ? window : window[key]
		if (value !== undefined && globalThis[key] === undefined) {
			Object.defineProperty(globalThis, key, { value, writable: true, configurable: true })
		}
	}
	if (!globalThis.ResizeObserver) {
		globalThis.ResizeObserver = class ResizeObserver {
			observe() {}
			unobserve() {}
			disconnect() {}
		}
	}
	if (!globalThis.matchMedia) {
		globalThis.matchMedia = () => ({
			matches: false,
			addEventListener() {},
			removeEventListener() {},
		})
	}
	return window
}

// ── polices ───────────────────────────────────────────────────────────────

/**
 * Table `woff2 path → unicode-range`, read out of the Excalidraw bundle.
 *
 * Native inlining (`exportToSvg` without `skipInliningFonts`) fails under jsdom:
 * it loses the descriptors and throws « Couldn't transform font-face to css » on
 * every subset. Rather than reinventing the split, we re-read upstream's
 * metadata — the `unicode-range` are indispensable, a family served in several
 * subsets without them keeps only the last one declared.
 * @returns {Record<string, string>} chemin relatif `./fonts/…` → unicode-range.
 */
function fontRanges() {
	const src = readdirSync(PKG)
		.filter(f => f.endsWith('.js'))
		.map(f => readFileSync(join(PKG, f), 'utf8'))
		.join('\n')
	const ident = {}
	for (const m of src.matchAll(/var ([A-Za-z_$][\w$]*)="(\.\/fonts\/[^"]+\.woff2)"/g)) ident[m[1]] = m[2]
	const ranges = {}
	for (const m of src.matchAll(/\{uri:([A-Za-z_$][\w$]*),descriptors:\{unicodeRange:"([^"]+)"\}\}/g)) {
		const path = ident[m[1]]
		if (path) ranges[path] = m[2]
	}
	return ranges
}

// Xiaolai is the CJK fallback: 209 subsets, 13 MB. We do not bundle it — this
// repo's diagrams are Latin, and including it would make a 17 MB SVG.
const SKIP_FAMILIES = ['Xiaolai', 'Segoe UI Emoji']

/**
 * The `@font-face` rules of the families actually cited by the markup.
 * @param {string} markup - the rendered SVG.
 * @returns {string} the CSS content to inject, possibly empty.
 */
function fontFaces(markup) {
	const dirs = existsSync(FONTS) ? readdirSync(FONTS) : []
	const ranges = fontRanges()
	const wanted = {}
	for (const m of markup.matchAll(/font-family="([^"]+)"/g)) {
		for (const raw of m[1].split(',')) {
			const family = raw.trim().replace(/^["']|["']$/g, '')
			if (family && !SKIP_FAMILIES.includes(family)) wanted[family] = true
		}
	}

	const css = []
	for (const family in wanted) {
		const key = family.replace(/\s+/g, '').toLowerCase()
		const dir = dirs.find(d => key.startsWith(d.toLowerCase()))
		if (!dir) continue
		// We enumerate the FILES, not the range table: families shipped as a
		// single woff2 (Lilita One, Virgil, Cascadia) have no `unicodeRange`
		// descriptor and were otherwise dropped silently — the text then fell back
		// to the engine's default font.
		for (const name of readdirSync(join(FONTS, dir))) {
			if (extname(name) !== '.woff2') continue
			const b64 = readFileSync(join(FONTS, dir, name)).toString('base64')
			const range = ranges[`./fonts/${dir}/${name}`]
			css.push(
				`@font-face{font-family:"${family}";src:url(data:font/woff2;base64,${b64}) format("woff2");${range ? `unicode-range:${range};` : ''}font-display:swap}`,
			)
		}
	}
	return css.join('')
}

// ── SVG ───────────────────────────────────────────────────────────────────

/**
 * Prepares the markup for writing or rasterisation.
 * @param {string} markup - the SVG rendered by exportToSvg.
 * @param {object} opts
 * @param {number} opts.factor - multiplicateur de width/height (viewBox conservé).
 * @param {string | null} opts.background - fond opaque, injecté hors filtre.
 * @param {string} opts.faces - règles @font-face à injecter.
 * @param {boolean} opts.stripFilter - remove the dark filter from the root <svg>.
 */
function prepareSvg(markup, { factor = 1, background = null, faces = '', stripFilter = false }) {
	let out = markup

	if (stripFilter) out = out.replace(/ filter="[^"]*"/, '')
	if (faces) out = out.replace(/(<style class="style-fonts">)[\s\S]*?(<\/style>)/, `$1${faces}$2`)
	if (factor !== 1) {
		const w = out.match(/\bwidth="([\d.]+)"/)
		const h = out.match(/\bheight="([\d.]+)"/)
		if (w && h) {
			out = out.replace(w[0], `width="${Number(w[1]) * factor}"`).replace(h[0], `height="${Number(h[1]) * factor}"`)
		}
	}
	if (background) {
		const tag = out.match(/<svg\b[^>]*>/)
		if (tag) out = out.replace(tag[0], `${tag[0]}<rect width="100%" height="100%" fill="${background}"/>`)
	}
	return out
}

// The Filter Effects hue-rotate(180deg) matrix: A + cosθ·B + sinθ·C, i.e.
// A − B at 180°. Each row sums to 1, hence greys are invariant.
const HUE_180 = [
	[-0.574, 1.43, 0.144],
	[0.426, 0.43, 0.144],
	[0.426, 1.43, -0.856],
]

/**
 * Applies `invert(93%) hue-rotate(180deg)` to raw pixels.
 *
 * Why here rather than in the SVG: librsvg applies filters in **linearRGB**
 * (the SVG 1.1 default) where browsers apply the CSS shorthands in sRGB, and
 * it ignores `color-interpolation-filters:sRGB` set on the filtered element.
 * Result: a #4b4b4b background instead of #121212
 * (255 → 0.07 linear → 1.055×0.07^(1/2.4)−0.055 = 0.293 → 75) and every colour
 * washed out by as much. The .svg file keeps its filter — browsers render it
 * correctly — but the PNG is filtered here, in sRGB, exactly.
 *
 * The order follows the CSS list: invert first, hue-rotate second.
 * @param {Buffer} data - pixels entrelacés.
 * @param {number} channels - 3 (RGB) or 4 (RGBA); alpha is not touched.
 */
function applyDark(data, channels) {
	const len = data.length
	const [m0, m1, m2] = HUE_180
	for (let i = 0; i < len; i += channels) {
		// invert(93%) : c → c + 0,93×(255 − 2c) = 237,15 − 0,86c
		const r = 237.15 - 0.86 * data[i]
		const g = 237.15 - 0.86 * data[i + 1]
		const b = 237.15 - 0.86 * data[i + 2]
		const nr = m0[0] * r + m0[1] * g + m0[2] * b
		const ng = m1[0] * r + m1[1] * g + m1[2] * b
		const nb = m2[0] * r + m2[1] * g + m2[2] * b
		// +0.5: writing into the Buffer truncates, and the browser rounds —
		// without it the background comes out #111111 instead of #121212 (17.85 → 17).
		data[i] = nr < 0 ? 0 : nr > 254.5 ? 255 : nr + 0.5
		data[i + 1] = ng < 0 ? 0 : ng > 254.5 ? 255 : ng + 0.5
		data[i + 2] = nb < 0 ? 0 : nb > 254.5 ? 255 : nb + 0.5
	}
	return data
}

// ── export ────────────────────────────────────────────────────────────────

function collect(paths) {
	const files = []
	for (const p of paths) {
		const abs = resolve(p)
		if (!existsSync(abs)) {
			console.error(`introuvable : ${p}`)
			process.exit(1)
		}
		if (statSync(abs).isDirectory()) {
			for (const name of readdirSync(abs)) {
				if (extname(name) === '.excalidraw') files.push(join(abs, name))
			}
		} else {
			files.push(abs)
		}
	}
	return files.sort()
}

const { JSDOM } = await import('jsdom')
const window = bootstrapDom()

// `Failed to fetch font family …` : l'inlining natif d'Excalidraw tente esm.sh,
// that the firewall blocks. No consequence — `fontFaces()` re-injects the
// @font-face from the local bundle — but two slabs of stderr per export
// look like a failure. We silence that one message, not console.error wholesale.
const consoleError = console.error
console.error = (...args) => {
	if (typeof args[0] === 'string' && args[0].startsWith('Failed to fetch font family')) return
	consoleError(...args)
}

// The bundle is minified onto a single line: an uncaught evaluation error
// makes Node spew several MB of source. We keep the message.
let exportToSvg
try {
	;({ exportToSvg } = await import('@excalidraw/excalidraw'))
} catch (err) {
	console.error(`chargement de @excalidraw/excalidraw impossible :\n  ${err.message.split('\n')[0]}`)
	process.exit(1)
}

// `sharp` only if we rasterise: it comes from the repo ROOT, not from the
// skill (its postinstall repairs the native binaries for both architectures of
// the bind mount — a local copy would only have the installing side's). So
// `--svg-only` must work without it, and its absence deserves better than an
// ERR_MODULE_NOT_FOUND thrown before the first useful line.
let sharp
if (!svgOnly) {
	try {
		;({ default: sharp } = await import('sharp'))
	} catch {
		console.error('sharp not found — it is resolved by walking up to the repo root.')
		console.error('  Run `npm install` at the root, or export with --svg-only.')
		process.exit(1)
	}
}

const files = collect(inputs)
if (files.length === 0) {
	console.error('no .excalidraw input')
	process.exit(1)
}

let failed = 0
for (const file of files) {
	const name = basename(file, '.excalidraw')
	const dest = outDir ? resolve(outDir) : dirname(file)
	mkdirSync(dest, { recursive: true })

	try {
		const scene = JSON.parse(readFileSync(file, 'utf8'))
		const svgEl = await exportToSvg({
			elements: scene.elements ?? [],
			files: scene.files ?? null,
			appState: {
				...(scene.appState ?? {}),
				exportWithDarkMode: dark,
				exportBackground: !transparent && !bg,
				exportEmbedScene: false,
			},
		})

		const raw = svgEl.outerHTML
		const viewBox = raw.match(/viewBox="([^"]+)"/)?.[1] ?? ''
		const dims = viewBox.split(/\s+/).map(Number)
		if (dims.length !== 4 || dims[2] <= 0 || dims[3] <= 0) {
			console.error(`✗ ${name} — viewBox vide (${viewBox || 'absent'})`)
			failed++
			continue
		}

		const faces = fontFaces(raw)
		writeFileSync(join(dest, `${name}.svg`), prepareSvg(raw, { background: bg, faces }))
		let line = `✓ ${name}.svg  ${dims[2]}×${dims[3]}`

		if (!svgOnly) {
			// density 72 = 1 SVG px → 1 device px: the factor is already carried by
			// width/height; a density of 96 would multiply it by a further 96/72.
			const markup = prepareSvg(raw, { factor: scale, faces, stripFilter: dark })
			const { data, info } = await sharp(Buffer.from(markup), { density: 72 })
				.raw()
				.toBuffer({ resolveWithObject: true })
			if (dark) applyDark(data, info.channels)

			let pipe = sharp(data, { raw: { width: info.width, height: info.height, channels: info.channels } })
			if (bg) pipe = pipe.flatten({ background: bg })
			const png = await pipe.png().toBuffer()
			writeFileSync(join(dest, `${name}@${scale}x.png`), png)
			line += `   ${name}@${scale}x.png  ${info.width}×${info.height}`
		}
		console.log(line)
	} catch (err) {
		console.error(`✗ ${name} — ${err.message}`)
		failed++
	}
}

window.close()
console.log(`\n${files.length - failed}/${files.length} exporté${files.length > 1 ? 's' : ''}${dark ? ' (dark)' : ' (light)'}`)
process.exit(failed > 0 ? 1 : 0)
