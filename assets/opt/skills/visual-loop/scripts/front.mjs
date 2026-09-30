#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────
// WHAT THIS FILE DOES
//   Finds the app tab in the human's Chromium and makes it the FRONT tab of
//   its window, then proves it worked by reading document.visibilityState back.
//   A pre-run step for `wtf claude live e2e` and friends.
//
//   WHY IT EXISTS, and why it is the ONLY thing here that activates anything.
//   cdp.mjs checks the front tab exactly once, at attach (:666-669), and
//   openSession hard-defaults `activate: false` (:1311) — nothing in the
//   toolchain raises or focuses, deliberately. That is right for a capture, and
//   it has one sharp edge for a long stateful run : a tab that is hidden when
//   the run starts costs the whole run (exit 9, nothing executed), and a tab
//   that goes hidden MID-run is worse — Chrome throttles a background tab's
//   timers, the app's 5 s sync pull drops to roughly once a minute, and every
//   wait on the mirror times out. Measured, not assumed : a session-7b suite
//   run failed three scenarios on « no new document row » with nothing at all
//   wrong with the upload.
//
//   ⚠️ THIS ONE DOES TAKE THE FRONT, which is exactly what the rest of the
//   toolchain refuses to do — so it is a separate, explicit, opt-in command
//   rather than a flag on e2e. It activates a TAB within its window
//   (Target.activateTarget). On some platforms that also raises the window ;
//   that is the cost, it is why this is not automatic, and it is why the run
//   itself still never activates anything.
//
// USAGE
//   wtf claude live front                 # activate the app tab
//   wtf claude live front -- --match data # …the one whose url contains "data"
//   wtf claude live front -- --check      # report only, activate nothing
// ─────────────────────────────────────────────────────────────────────

import { APP_HOST, connect, evaluate, fetchBrowserWsUrl, readLock, resolveEndpoint, warnBeforeActivating } from './cdp.mjs'
import { BOLD, DIM, GREEN, RED, RESET, YELLOW } from '../lib/colors.mjs'

const args = process.argv.slice(2)
const flag = (name, fallback = '') => {
	const i = args.indexOf(`--${name}`)
	return i === -1 ? fallback : (args[i + 1] ?? '')
}
const checkOnly = args.includes('--check')
const match = flag('match')

const isApp = url => {
	try {
		return new URL(url).hostname.endsWith(APP_HOST)
	} catch {
		return false
	}
}

/**
 * The whole run, as one function : every early exit is a `return <code>`
 * instead of a `process.exit()`, so `finally { conn.close() }` below actually
 * runs on every path — `process.exit()` inside a try/catch skips its own
 * `finally`, which is why the socket used to leak on all but the one success
 * path that fell off the end of the try block.
 * @returns {Promise<number>}
 */
async function main() {
	if (args.includes('--help')) {
		process.stdout.write(`front.mjs [--match <substring>] [--check]

  --match   pick the app tab whose url contains this substring
  --check   report which tab is front and exit ; activate nothing
`)
		return 0
	}

	// Never fight a run in progress : activating a tab under a live suite would
	// background the one it is driving, which is the very failure this prevents.
	const held = readLock()
	if (held) {
		process.stderr.write(`${RED}front:${RESET} another session holds the browser (${held.owner ?? 'unknown'}). Wait for it, or re-run.\n`)
		return 10
	}

	let conn
	try {
		conn = await connect(await fetchBrowserWsUrl(await resolveEndpoint()))
	} catch (err) {
		process.stderr.write(`${RED}front:${RESET} ${err?.message ?? err}\n`)
		process.stderr.write(`${DIM}Needs \`wtf claude browser\` running on the HOST.${RESET}\n`)
		return 3
	}

	try {
		// ⚠️ MIRROR attachPage's choice exactly (cdp.mjs:634-638) : it takes the
		// FIRST page target whose hostname ends with APP_HOST, in Target.getTargets
		// order — NOT the visible one, and not the most recently used.
		//
		// Getting this wrong is not theoretical, it is the bug this comment replaces.
		// The first version asked « is ANY app tab visible ? », answered yes, and
		// no-opped — while the driver attached to a DIFFERENT, hidden app tab and
		// died on exit 9 one second later. With two tabs open on the app, « already
		// visible » and « the tab the run will drive » are simply different questions.
		const { targetInfos } = await conn.send('Target.getTargets')
		const pages = targetInfos.filter(t => t.type === 'page' && !t.url.startsWith('devtools://'))
		const app = pages.filter(t => isApp(t.url) && (match ? t.url.includes(match) : true))

		if (app.length === 0) {
			process.stderr.write(`${RED}front:${RESET} no tab on ${APP_HOST}${match ? ` matching "${match}"` : ''}.\n`)
			for (const t of pages) process.stderr.write(`${DIM}  open: ${t.url}${RESET}\n`)
			return 9
		}

		// Without --match, the driver ignores every app tab but the first. Say so
		// loudly : the extra ones are invisible to the run and are exactly how the
		// « I clicked the tab and it still says hidden » loop happens.
		if (app.length > 1 && !match) {
			process.stdout.write(`${YELLOW}front${RESET} ${app.length} tabs on ${APP_HOST}. The driver only ever attaches to the FIRST (cdp.mjs:636), so that is the one being activated:\n`)
			for (const [i, t] of app.entries()) process.stdout.write(`${DIM}  ${i === 0 ? '→' : ' '} ${t.url}${RESET}\n`)
			process.stdout.write(`${DIM}  Close the others, or pass --match <substring>.${RESET}\n`)
		}

		/** Which tab each candidate reports itself to be, before anything is touched. */
		const visibility = async targetId => {
			const { sessionId } = await conn.send('Target.attachToTarget', { targetId, flatten: true })
			const state = await evaluate(conn, sessionId, `(async () => document.visibilityState)()`).catch(() => 'unknown')
			await conn.send('Target.detachFromTarget', { sessionId }).catch(() => {})
			return state
		}

		// THE tab the run will drive, and the only one whose visibility matters.
		const target = app[0]
		const before = await visibility(target.targetId)

		// Already good ? Say so and touch nothing — the whole point is to activate as
		// rarely as possible.
		if (before === 'visible') {
			process.stdout.write(`${GREEN}front${RESET} already visible ${DIM}${target.url}${RESET}\n`)
			return 0
		}

		if (checkOnly) {
			process.stdout.write(`${YELLOW}front${RESET} the tab the driver would attach to reads ${before} ${DIM}${target.url}${RESET}\n`)
			return 9
		}
		// ⚠️ NOTHING ACTIVATES SILENTLY. This is the only command in the toolchain
		// that takes the human's window, and the window is theirs — being yanked out
		// of whatever they were doing, with no warning, is the complaint this banner
		// answers. It prints BEFORE the call and waits, so the alert always precedes
		// the steal instead of explaining it afterwards.
		const graceMs = Number(flag('grace', '')) || 5_000
		await warnBeforeActivating(target.url, `that tab reads "${before}" and is the one the driver attaches to`, graceMs)
		await conn.send('Target.activateTarget', { targetId: target.targetId })

		// Prove it, rather than assume the command took : activateTarget resolves
		// whether or not the tab actually came forward.
		const after = await visibility(target.targetId)
		if (after !== 'visible') {
			process.stderr.write(`${RED}front:${RESET} activated ${target.url} but it still reads ${after}.\n`)
			process.stderr.write(`${DIM}A MINIMISED window reads hidden too — leave it open, behind your editor.${RESET}\n`)
			return 9
		}
		process.stdout.write(`${GREEN}${BOLD}front${RESET} ${target.url} ${DIM}is now the front tab of its window${RESET}\n`)
		return 0
	} catch (err) {
		process.stderr.write(`${RED}front:${RESET} ${err?.message ?? err}\n`)
		return 1
	} finally {
		conn.close()
	}
}

process.exit(await main())
