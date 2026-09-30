#!/usr/bin/env node
// Take whatever Figma's Export button produced and put it where the plan
// expects it, under the name the plan expects.
//
// WHY THIS EXISTS
// The manual failover (see #visual-1to1 in CLAUDE-project.md) asks a human to
// export a frame by hand, and Figma is unhelpful about it in three ways at once:
//   - it decorates the filename — `Frame 439-2808@2x.png`, spaces and all ;
//   - it hands back a ZIP as soon as the node carries more than one export
//     setting, or more than one node is selected ;
//   - and the container cannot see the host's ~/Downloads anyway, so the human
//     has to drop the artefact into the repo regardless.
// Fighting that with naming discipline puts the burden on the human and fails
// silently when they miss. Accepting whatever came out and normalising it here
// costs one command and cannot be got wrong.
//
// USAGE
//   node /opt/devcontainer/base/skills/visual-loop/scripts/figma-adopt.mjs <source> --out <dir> [--as <name>] [--width <n>]
//     <source>   a .zip, a directory, or a single .png / .json — anywhere in the
//                repo. `.tmp/inbox/` is the conventional drop point.
//     --out      destination directory, default .tmp/design
//     --as       final basename (no extension). Only when the source yields ONE
//                asset ; otherwise names are derived from Figma's own.
//     --width    the frame's width in Figma units, from the JSON dump. Turns the
//                report into a scale check — the only way to catch a 1x export,
//                which is otherwise silent and just makes every stroke read too
//                light in the comparison.
//
// Zero dependencies : `unzip` is in the image, and a PNG's dimensions are four
// big-endian bytes at a fixed offset in the IHDR chunk. Reading them by hand
// keeps this script off `sharp`, which ships per-platform native binaries the
// repo avoids on host+container mounts (see #npm-optional-deps).

import { execFileSync } from 'node:child_process'
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, extname, join, resolve } from 'node:path'
import { BOLD, DIM, GREEN, RED, RESET, YELLOW } from '../lib/colors.mjs'

const EXIT_OK = 0
const EXIT_FAIL = 1
const EXIT_USAGE = 2

const DEFAULT_OUT = '.tmp/design'
const KEEP = new Set(['.png', '.json', '.svg'])

const USE_COLOR = process.stdout.isTTY && process.env.NO_COLOR !== '1'
const c = (code, s) => (USE_COLOR ? `${code}${s}${RESET}` : s)

const USAGE = `figma-adopt.mjs — normalise a manual Figma export into the plan folder.

  node /opt/devcontainer/base/skills/visual-loop/scripts/figma-adopt.mjs <source> [--out <dir>] [--as <name>] [--width <n>]

  <source>     .zip, directory, or a single .png / .json already inside the repo
  --out <dir>  destination, default ${DEFAULT_OUT}
  --as <name>  final basename without extension (single-asset sources only)
  --width <n>  frame width in Figma units — reports the export scale instead of
               just the pixel size, which is how a 1x export gets caught
  --help, -h   this text

Figma decorates names (\`Frame 439-2808@2x.png\`) and zips the result as soon as a
node has several export settings. Drop whatever it gave you into the repo, run
this, and stop caring.
`

function die(code, msg) {
	process.stderr.write(`${c(RED, 'figma-adopt:')} ${msg}\n`)
	process.exit(code)
}

/**
 * Turn Figma's filename into the repo's convention : lowercase, no scale
 * suffix, no spaces or accents, dashes between words.
 * @param {string} file
 * @returns {string}
 */
function slugify(file) {
	const ext = extname(file)
	return (
		basename(file, ext)
			// `@2x`, `@3x`, ` 1`, `-1` — Figma's scale and collision suffixes.
			.replace(/@\d+(\.\d+)?x$/i, '')
			.replace(/[ _]+\d+$/, '')
			.toLowerCase()
			.normalize('NFD')
			.replace(/[̀-ͯ]/g, '')
			.replace(/[^a-z0-9]+/g, '-')
			.replace(/^-|-$/g, '') + ext.toLowerCase()
	)
}

/**
 * A PNG's dimensions, straight out of the IHDR chunk.
 *
 * Layout is fixed by the spec : 8-byte signature, 4-byte chunk length, the
 * 4 ASCII bytes `IHDR`, then width and height as big-endian uint32. No parsing
 * needed, and no image library.
 * @param {string} file
 * @returns {{w: number, h: number} | null}
 */
function pngSize(file) {
	const buf = readFileSync(file, { length: 33 })
	if (buf.length < 24 || buf.toString('ascii', 12, 16) !== 'IHDR') return null
	return { w: buf.readUInt32BE(16), h: buf.readUInt32BE(20) }
}

/** @param {string} dir @returns {string[]} every file below `dir`, recursively. */
function walk(dir) {
	const out = []
	for (const entry of readdirSync(dir, { withFileTypes: true })) {
		// __MACOSX and ._foo are the resource-fork noise every macOS zip carries.
		if (entry.name === '__MACOSX' || entry.name.startsWith('._')) continue
		const full = join(dir, entry.name)
		if (entry.isDirectory()) out.push(...walk(full))
		else out.push(full)
	}
	return out
}

function parseArgs(argv) {
	const o = { source: '', out: DEFAULT_OUT, as: '', width: 0 }
	const values = { '--out': 'out', '--as': 'as' }
	for (let i = 2; i < argv.length; i++) {
		const a = argv[i]
		if (values[a]) o[values[a]] = argv[++i]
		else if (a === '--width') o.width = Number(argv[++i])
		else if (a === '--help' || a === '-h') {
			process.stdout.write(USAGE)
			process.exit(EXIT_OK)
		} else if (a.startsWith('-')) die(EXIT_USAGE, `unknown arg: ${a}\n\n${USAGE}`)
		else o.source = a
	}
	if (!o.source) die(EXIT_USAGE, `missing <source>.\n\n${USAGE}`)
	return o
}

function main() {
	const o = parseArgs(process.argv)
	const source = resolve(o.source)
	if (!existsSync(source)) {
		die(
			EXIT_FAIL,
			`${source} does not exist.
  → the container cannot see the host's ~/Downloads : drag the export into the
    repo first (${c(BOLD, '.tmp/inbox/')} by convention), then point at it.`,
		)
	}

	let scanRoot = source
	let temp = null
	const st = statSync(source)
	if (st.isFile() && extname(source).toLowerCase() === '.zip') {
		temp = mkdtempSync(join(tmpdir(), 'figma-adopt-'))
		try {
			execFileSync('unzip', ['-qq', '-o', source, '-d', temp])
		} catch (err) {
			die(EXIT_FAIL, `could not unzip ${source} : ${err?.message ?? err}`)
		}
		scanRoot = temp
	}

	const assets = (statSync(scanRoot).isDirectory() ? walk(scanRoot) : [scanRoot]).filter(f =>
		KEEP.has(extname(f).toLowerCase()),
	)
	if (!assets.length) die(EXIT_FAIL, `no .png / .json / .svg found in ${source}.`)
	if (o.as && assets.length > 1) {
		die(
			EXIT_USAGE,
			`--as names a single asset, but ${assets.length} were found :
  ${assets.map(a => basename(a)).join('\n  ')}
  → drop --as and let the names be derived, or export one node at a time.`,
		)
	}

	const outDir = resolve(o.out)
	mkdirSync(outDir, { recursive: true })

	const done = []
	for (const asset of assets) {
		const ext = extname(asset).toLowerCase()
		const name = o.as ? `${o.as}${ext}` : slugify(asset)
		const dest = join(outDir, name)
		const overwritten = existsSync(dest)
		copyFileSync(asset, dest)
		done.push({ from: basename(asset), dest, ext, overwritten, bytes: statSync(dest).size })
	}
	if (temp) rmSync(temp, { recursive: true, force: true })

	for (const d of done) {
		const rel = d.dest.replace(`${process.cwd()}/`, '')
		let detail = `${Math.round(d.bytes / 1024)} KB`
		if (d.ext === '.png') {
			const size = pngSize(d.dest)
			if (size) {
				detail = `${size.w}×${size.h}, ${detail}`
				if (o.width) {
					const scale = size.w / o.width
					const clean = Math.abs(scale - Math.round(scale)) < 0.02
					detail += ` — scale ${c(clean && Math.round(scale) >= 2 ? GREEN : YELLOW, scale.toFixed(2))}`
					if (Math.round(scale) < 2) {
						detail += c(YELLOW, ' ⚠ below 2x : strokes will read too light against the reference, re-export at 2x')
					}
				}
			}
		}
		process.stdout.write(
			`${c(GREEN, '✓')} ${rel} ${c(DIM, `(${detail})`)}${d.overwritten ? c(DIM, ' [replaced]') : ''}\n`,
		)
		if (d.from !== basename(d.dest)) process.stdout.write(`  ${c(DIM, `renamed from ${d.from}`)}\n`)
	}
}

main()
