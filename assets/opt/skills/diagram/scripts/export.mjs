#!/usr/bin/env node
// Export .excalidraw → SVG + PNG @2x, rendu dark.
//
// Usage :
//   node export.mjs <fichier.excalidraw | dir> [--out <dir>] [--scale 2]
//                   [--bg <color> | --transparent] [--svg-only] [--light]
//
// Sort <nom>.svg et <nom>@<scale>x.png à côté de la source, ou dans --out.
//
// Le dark n'est PAS un jeu de couleurs : c'est un filtre de rendu
// `invert(93%) hue-rotate(180deg)` posé sur le <svg> racine, fond compris
// (cf. KNOWLEDGE.md L14). On ne touche donc jamais au `viewBackgroundColor`
// des sources — leur #ffffff devient 255×0,07 = 17,85 ≈ #121212, le noir de
// canvas canonique d'Excalidraw. Écrire #000000 dans le fichier donnerait
// #ededed, soit du blanc.

import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { createRequire, registerHooks } from 'node:module'
import { basename, dirname, extname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const USAGE = `Export .excalidraw → SVG + PNG @2x, rendu dark.

  node export.mjs <fichier.excalidraw | dir> [options]

  --out <dir>        écrire ailleurs qu'à côté de la source
  --scale <n>        facteur du PNG (défaut 2)
  --bg <color>       fond opaque composité APRÈS le filtre dark
  --transparent      pas de fond du tout
  --svg-only         ne pas rasteriser
  --light            désactiver le rendu dark`

// Le bundle Excalidraw est construit pour un bundler, pas pour Node. Trois
// incompatibilités, trois hooks in-thread — ça vaut mieux qu'un patch de
// node_modules. jsdom et sharp, chargés à la demande plus bas, traversent donc
// ces hooks — sans conséquence : `resolve` ne fait que retenter avec `.js` sur
// ERR_MODULE_NOT_FOUND, et `load` ne court-circuite que le CJS sous
// `/@excalidraw/`.
registerHooks({
	// `roughjs/bin/rough` : import sans extension, que seul un bundler résout.
	resolve(specifier, context, nextResolve) {
		try {
			return nextResolve(specifier, context)
		} catch (err) {
			if (err.code !== 'ERR_MODULE_NOT_FOUND' || extname(specifier)) throw err
			return nextResolve(`${specifier}.js`, context)
		}
	},
	load(url, context, nextLoad) {
		// `open-color/open-color.json` : importé sans `with { type: 'json' }`.
		if (url.startsWith('file:') && url.endsWith('.json')) {
			return { format: 'json', source: readFileSync(fileURLToPath(url), 'utf8'), shortCircuit: true }
		}
		const result = nextLoad(url, context)
		// `@excalidraw/laser-pointer` : CJS dont cjs-module-lexer ne voit pas les
		// exports nommés. On require pour de vrai et on réexporte les clés
		// observées — l'inférence statique est le problème, pas le module.
		//
		// Restreint aux paquets `@excalidraw/*` À DESSEIN : appliqué à tout le
		// graphe, le require anticipé casse sur les cycles de @babel/runtime que
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

// Résolu, jamais construit à la main : `import.meta.resolve` suit exactement les
// mêmes conditions d'export que le `await import()` plus bas, alors qu'un
// `dist/prod` en dur pointerait sur le mauvais bundle sous `--conditions=development`
// — `fontRanges()` scraperait alors à vide et les `unicode-range` seraient perdus.
// Les dépendances sont locales au skill (cf. son package.json) : un chemin relatif
// au CWD, lui, ne marchait que lancé depuis la racine du dépôt.
//
// C'est aussi le préflight des dépendances du skill : rien n'est importé
// statiquement depuis node_modules, donc cette résolution est le premier point
// où leur absence se voit — et elle donne un message plutôt qu'une stack.
let PKG
try {
	PKG = dirname(fileURLToPath(import.meta.resolve('@excalidraw/excalidraw')))
} catch {
	console.error('dépendances du skill /diagram absentes — installe-les avec :')
	console.error('    npm install --prefix .devcontainer/skills/diagram')
	process.exit(1)
}
const FONTS = join(PKG, 'fonts')

// ── DOM ───────────────────────────────────────────────────────────────────

/**
 * Pose les globals dont le bundle Excalidraw a besoin au niveau module.
 *
 * `measureText` est une heuristique : jsdom n'implémente pas de canvas 2D et
 * node-canvas est un binaire natif qu'on refuse. Les éléments texte portent
 * déjà leur `width`/`height` calculés par l'app, donc cette mesure ne sert
 * qu'aux chemins de recalcul — un ratio approché suffit, un 0 casserait le
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

	// API FontFace — absente de jsdom, et le chemin de rendu du texte la
	// construit avant même d'inliner quoi que ce soit : sans ce stub,
	// `exportToSvg` lève « FontFace is not defined » et rend un SVG sans le
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
 * Table `chemin woff2 → unicode-range`, lue dans le bundle Excalidraw.
 *
 * L'inlining natif (`exportToSvg` sans `skipInliningFonts`) échoue sous jsdom :
 * il perd les descripteurs et lève « Couldn't transform font-face to css » sur
 * chaque subset. Plutôt que de ré-inventer le découpage, on relit la métadonnée
 * d'upstream — les `unicode-range` sont indispensables, une famille servie en
 * plusieurs subsets sans eux ne garde que le dernier déclaré.
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

// Xiaolai est le repli CJK : 209 subsets, 13 Mo. On ne l'embarque pas — les
// diagrammes de ce repo sont latins, et l'inclure ferait un SVG de 17 Mo.
const SKIP_FAMILIES = ['Xiaolai', 'Segoe UI Emoji']

/**
 * Les règles `@font-face` des familles réellement citées par le markup.
 * @param {string} markup - le SVG rendu.
 * @returns {string} le contenu CSS à injecter, éventuellement vide.
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
		// On énumère les FICHIERS, pas la table des plages : les familles livrées
		// en un seul woff2 (Lilita One, Virgil, Cascadia) n'ont pas de descripteur
		// `unicodeRange` et étaient sinon ignorées sans bruit — le texte retombait
		// alors sur la police par défaut du moteur.
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
 * Prépare le markup pour l'écriture ou la rasterisation.
 * @param {string} markup - le SVG rendu par exportToSvg.
 * @param {object} opts
 * @param {number} opts.factor - multiplicateur de width/height (viewBox conservé).
 * @param {string | null} opts.background - fond opaque, injecté hors filtre.
 * @param {string} opts.faces - règles @font-face à injecter.
 * @param {boolean} opts.stripFilter - retirer le filtre dark du <svg> racine.
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

// Matrice hue-rotate(180deg) des Filter Effects : A + cosθ·B + sinθ·C, soit
// A − B à 180°. Chaque ligne somme à 1, d'où l'invariance des gris.
const HUE_180 = [
	[-0.574, 1.43, 0.144],
	[0.426, 0.43, 0.144],
	[0.426, 1.43, -0.856],
]

/**
 * Applique `invert(93%) hue-rotate(180deg)` sur des pixels bruts.
 *
 * Pourquoi ici plutôt que dans le SVG : librsvg applique les filtres en
 * **linearRGB** (le défaut SVG 1.1) là où les navigateurs appliquent les
 * raccourcis CSS en sRGB, et il ignore `color-interpolation-filters:sRGB` posé
 * sur l'élément filtré. Résultat, un fond à #4b4b4b au lieu de #121212
 * (255 → 0,07 linéaire → 1,055×0,07^(1/2,4)−0,055 = 0,293 → 75) et toutes les
 * couleurs délavées d'autant. Le fichier .svg garde son filtre — les
 * navigateurs le rendent juste — mais le PNG est filtré ici, en sRGB, exact.
 *
 * L'ordre suit la liste CSS : invert d'abord, hue-rotate ensuite.
 * @param {Buffer} data - pixels entrelacés.
 * @param {number} channels - 3 (RGB) ou 4 (RGBA) ; l'alpha n'est pas touché.
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
		// +0,5 : l'écriture dans le Buffer tronque, et le navigateur arrondit —
		// sans ça le fond sort à #111111 au lieu de #121212 (17,85 → 17).
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
// que le firewall bloque. Aucune conséquence — `fontFaces()` réinjecte les
// @font-face depuis le bundle local — mais deux pavés de stderr par export
// laissent croire à un échec. On tait ce message précis, pas console.error en bloc.
const consoleError = console.error
console.error = (...args) => {
	if (typeof args[0] === 'string' && args[0].startsWith('Failed to fetch font family')) return
	consoleError(...args)
}

// Le bundle est minifié sur une seule ligne : une erreur d'évaluation non
// attrapée fait recracher plusieurs Mo de source par Node. On garde le message.
let exportToSvg
try {
	;({ exportToSvg } = await import('@excalidraw/excalidraw'))
} catch (err) {
	console.error(`chargement de @excalidraw/excalidraw impossible :\n  ${err.message.split('\n')[0]}`)
	process.exit(1)
}

// `sharp` seulement si on rasterise : il vient de la RACINE du dépôt, pas du
// skill (son postinstall y répare les binaires natifs des deux architectures du
// bind mount — une copie locale n'aurait que celle du côté qui a installé). Donc
// `--svg-only` doit marcher sans lui, et son absence mérite mieux qu'un
// ERR_MODULE_NOT_FOUND levé avant la première ligne utile.
let sharp
if (!svgOnly) {
	try {
		;({ default: sharp } = await import('sharp'))
	} catch {
		console.error('sharp introuvable — il est résolu par remontée vers la racine du dépôt.')
		console.error('  Lance `npm install` à la racine, ou exporte en --svg-only.')
		process.exit(1)
	}
}

const files = collect(inputs)
if (files.length === 0) {
	console.error('aucun .excalidraw en entrée')
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
			// density 72 = 1 px SVG → 1 px device : le facteur est déjà porté par
			// width/height, un density 96 le multiplierait par 96/72 en plus.
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
