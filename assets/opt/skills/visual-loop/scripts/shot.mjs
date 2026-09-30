#!/usr/bin/env node
// `wtf claude live shot` — the only screenshot entry point.
//
// It exists so that EVERY command that drives the human's Chromium sits behind
// one permission (`wtf claude live *`), with the same lock as probe.mjs and
// sweep.mjs. There is no separate top-level `wtf shot` any more.
//
// The one behaviour it adds : --url is a flag here, matching probe and sweep,
// where cdp.mjs takes the page as a positional. Everything else is forwarded
// untouched, so `cdp.mjs shot --help` remains the reference.
//
//   shot.mjs --url '…/?panel=demo-patient-panel' --login --device desktop \
//            --scale 2 --out .tmp/shots/panel.png

import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

// Resolved from this file rather than from the cwd. Baked, these siblings live at
// /opt/devcontainer/base/skills/visual-loop/scripts/ while the human stands in a
// project directory, so a cwd-relative spawn silently targeted a project copy when
// one existed and died with ENOENT when it did not.
const CDP = fileURLToPath(new URL('./cdp.mjs', import.meta.url))

const argv = process.argv.slice(2)
if (argv.includes('--help') || !argv.length) {
	process.stdout.write('shot.mjs --url <url> [any flag of `node /opt/devcontainer/base/skills/visual-loop/scripts/cdp.mjs shot`]\n\n')
	execFileSync('node', [CDP, 'shot', '--help'], { stdio: 'inherit' })
	process.exit(0)
}

const i = argv.indexOf('--url')
if (i < 0) {
	console.error('shot.mjs: --url is required')
	process.exit(1)
}
const url = argv[i + 1]
const rest = argv.filter((_, n) => n !== i && n !== i + 1)

// The reference DPR by default : at 1x a 1.2px stroke covers no pixel fully, so
// an icon reads grey 190 against a reference's 121 — a pure artefact, and the
// single most expensive mistake of the visual loop.
if (!rest.includes('--scale')) rest.push('--scale', '2')
if (!rest.includes('--out') && !rest.includes('-o')) rest.push('--out', '.tmp/shots/shot.png')

execFileSync('node', [CDP, 'shot', url, ...rest], { stdio: 'inherit' })
