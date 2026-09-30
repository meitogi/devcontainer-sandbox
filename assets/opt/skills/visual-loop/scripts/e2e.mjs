#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────
// WHAT THIS FILE DOES
//   Drives a SUITE of stateful browser scenarios against the human's real
//   Chromium over CDP, holding one socket across every step. That is the
//   whole reason it exists rather than `wtf claude live probe` : probe
//   re-navigates before each read, and these scenarios upload, then watch,
//   then click.
//
//   It is a DRIVER and nothing else. The scenarios live per rollout plan,
//   under plans/<plan>/suites/, because they are scoped to one session and
//   die with it — same status as the fixtures and the smoke scripts beside
//   them. Only this file is committed. When a real, permanent E2E layer
//   exists, its suites move into the repo ; until then they stay plan
//   material.
//
//   DRIVES THE BROWSER, but never raises the window (cdp.mjs captures with
//   fromSurface:false and attaches without activating). It does upload real
//   records to the dev database, and openSession({fresh}) clears cookies
//   BROWSER-WIDE — which is why it takes the cdp.mjs lock for the whole run
//   and a concurrent `wtf claude live shot` is refused with exit 10 rather
//   than allowed to navigate the tab out from under a scenario.
//
//   The human's app TAB must be frontmost in its window for the run (a
//   background tab stops painting) ; the WINDOW may sit behind anything.
//
//   THE ONE REMAINING FOCUS-STEALER, and it is in the suites, not here : a
//   scenario that opens a second tab with `Target.createTarget` gets a
//   FOREGROUNDED one, which backgrounds the tab the suite is driving. This
//   Chromium build does accept `background: true` (verified against
//   /json/protocol — stable, not experimental, alongside an experimental
//   `focus`). Do NOT reach for it reflexively : a background tab is
//   visibilityState 'hidden', so any scenario whose POINT is that a second
//   tab keeps receiving live updates would then be testing the opposite of
//   what it claims. Use it only where the second tab is incidental, and say
//   so at the call site. The cdp.mjs front-tab guard runs once at attach,
//   before any scenario, so it never fires on this.
//
//   A suite exports:
//     export const meta = { url, email, password, ready, bridge, seeded, health }
//
//   bridge  name of an in-page function that runs SQL and returns rows, e.g.
//           'sqliteQuery'. ctx.query refuses without it rather than guessing.
//   seeded  in-page expression that turns true once the first data has landed.
//   health  async ctx => {} precondition, checked once before any scenario.
//           Its SQL is yours — the driver ships no schema.
//     export default async ctx => { await ctx.scenario('ID', async () => …) }
//
// USAGE
//   wtf claude live e2e -- --suite plans/<plan>/suites/<name>.mjs
//   wtf claude live e2e -- --suite … --only S6-SSE,S6-SPINNER
//   wtf claude live e2e -- --suite … --json
// ─────────────────────────────────────────────────────────────────────

import { readFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
import { resolve } from 'node:path'
import { BOLD, DIM, GREEN, RED, RESET, YELLOW } from '../lib/colors.mjs'
import { evaluate, openSession, reload as cdpReload, warnBeforeActivating } from './cdp.mjs'

const args = process.argv.slice(2)
const flag = (name, fallback) => {
	const i = args.indexOf(`--${name}`)
	return i === -1 ? fallback : args[i + 1]
}
const asJson = args.includes('--json')
const suitePath = flag('suite', '')
const only = flag('only', '')
	.split(',')
	.map(s => s.trim())
	.filter(Boolean)
// `--set k=v` repeated : whatever a suite wants, without editing the suite.
const extra = {}
for (let i = 0; i < args.length; i++) {
	if (args[i] !== '--set') continue
	const [k, ...rest] = String(args[i + 1] ?? '').split('=')
	if (k) extra[k] = rest.join('=')
}

if (suitePath === '' || args.includes('--help')) {
	process.stdout.write(`e2e.mjs --suite <path> [--only A,B] [--json] [--set k=v …]

  --suite    a module exporting { meta, default(ctx) } — conventionally
             plans/<plan>/suites/<name>.mjs
  --only     run just these scenario ids
  --set      arbitrary key=value, reaches the suite as ctx.args
  --activate bring the app tab to the front before attaching, instead of
             demanding it already is. TAKES THE FRONT — opt in when a run keeps
             dying on exit 9 because the browser window sits fully covered.
`)
	process.exit(suitePath === '' ? 2 : 0)
}

const results = []

async function main() {
	const mod = await import(pathToFileURL(resolve(suitePath)).href)
	const meta = mod.meta ?? {}
	if (typeof mod.default !== 'function') throw new Error(`${suitePath} has no default export function`)

	const url = flag('url', meta.url)
	if (!url) throw new Error(`${suitePath} declares no meta.url and none was passed with --url`)
	// Expose the RESOLVED url to the suite : a scenario that opens a second
	// tab must land on the same stack as the first, and `meta.url` stops
	// being that stack the moment --url overrides it. An explicit
	// `--set url=…` still wins.
	if (extra.url === undefined) extra.url = url
	if (!asJson) process.stdout.write(`\n${BOLD}E2E${RESET} ${DIM}${suitePath} → ${url}${RESET}\n\n`)

	// ⚠️ NOTHING ACTIVATES SILENTLY — the window is the human's. Warned BEFORE
	// the call, with a grace period, so the alert precedes the steal rather than
	// explaining it afterwards. `wtf claude live front` prints the same banner.
	if (args.includes('--activate')) {
		const graceMs = Number(flag('grace', '')) || 5_000
		await warnBeforeActivating(url, '--activate : once, at attach. Nothing later in the run touches focus.', graceMs)
	}

	const ctx = await openSession({
		url,
		email: flag('email', meta.email),
		password: flag('password', meta.password),
		// OPT-IN, and it is the one place in this toolchain that takes the front.
		//
		// `wtf claude live front` exists to do this as a pre-run step, and for a
		// short capture that is enough. It is NOT enough here, because the two are
		// separate processes: Chrome marks a page `hidden` when its window is
		// fully OCCLUDED, not merely unfocused, so front reads `visible`, the
		// human's editor comes back over the window, and attach lands on a hidden
		// tab a second later. Measured — three runs died that way, one of them
		// after front had just reported `visible`.
		//
		// Activating inside this process, immediately before attach, is the only
		// arrangement with no window for occlusion to return. attachPage skips its
		// front-tab guard when this is set, by construction (cdp.mjs:661-668).
		activate: args.includes('--activate'),
		// doLogin no-ops when ANY session exists, so asking for a specific
		// account silently keeps whoever was already there — which surfaces as
		// an empty app, not as an auth error.
		fresh: true,
		// cdp.mjs waits for a QUIET page, and a grid of document cards is never
		// quiet at 15 s : every card pulls a thumbnail, so the more the dev
		// database accumulates the longer the first paint settles. A suite
		// landing straight on a data-heavy page needs the longer leash.
		wait: Number(flag('wait', '')) || 45_000,
	})

	const js = expression => evaluate(ctx.conn, ctx.sid, `(async () => { ${expression} })()`)

	const until = async (label, expression, timeoutMs = 20_000, everyMs = 400) => {
		const deadline = Date.now() + timeoutMs
		let last
		while (Date.now() < deadline) {
			last = await js(`return ${expression}`)
			if (last) return last
			await new Promise(r => setTimeout(r, everyMs))
		}
		throw new Error(`timed out after ${Math.round(timeoutMs / 1000)}s waiting for ${label} (last: ${JSON.stringify(last)})`)
	}

	const query = sql => {
		if (!meta.bridge)
			throw new Error(
				"this suite's meta has no `bridge` — ctx.query needs the name of an in-page" +
					" function that runs SQL and returns rows, e.g. `bridge: 'sqliteQuery'`." +
					' Guessing a global fails as a TypeError from inside an eval, which is a' +
					' stack rather than a diagnosis.',
			)
		return js(`return await window[${JSON.stringify(meta.bridge)}](${JSON.stringify(sql)})`)
	}

	try {
		if (meta.ready) await until('the page to be ready', meta.ready, 20_000)
		// A fresh login starts on an EMPTY mirror : the shell renders at once, the
		// first pull lands a second or two later. Asserting in between reads zero
		// rows and blames the seed. The expression is the suite's — only it knows
		// what "the data has arrived" means for its own schema.
		if (meta.seeded) await until('the first sync pull', meta.seeded, 30_000)
		else
			console.log(
				`${DIM}   no meta.seeded — a scenario reading zero rows may be racing the first sync${RESET}`,
			)

		// Preconditions, checked ONCE and loudly. This is the expensive lesson : a
		// wedged worker used to fail every pipeline scenario on its own timeout, one
		// after another, for twenty minutes. The framing stays here ; the assertion
		// is the suite's, being business schema rather than a path.
		if (meta.health) await meta.health({ js, query, until })

		await mod.default({
			scenario: makeScenario(only),
			js,
			until,
			query,
			fail: msg => {
				throw new Error(msg)
			},
			skip: reason => {
				throw new Skipped(reason)
			},
			reload: () => cdpReload(ctx.conn, ctx.sid),
			conn: ctx.conn,
			sid: ctx.sid,
			// `js` is bound to the suite's own tab. A suite that opens a second
			// target (cdp.mjs:657 anticipates exactly that) gets a session id
			// back and has nothing to run against it — `conn` and `sid` without
			// this are half a tool.
			evaluate,
			args: extra,
			readFixture: path => readFileSync(resolve(path)),
		})
	} finally {
		ctx.close()
	}
}

/**
 * Thrown by ctx.skip(). A third outcome is not bureaucracy : some properties
 * are only OPPORTUNISTICALLY observable from outside the app — a state the
 * worker leaves in milliseconds, say — and both other answers would be lies.
 * PASS would claim an observation nobody made ; FAIL would blame the product
 * for the harness's vantage point.
 */
class Skipped extends Error {}

function makeScenario(filter) {
	return async (id, fn) => {
		if (filter.length && !filter.includes(id)) return
		try {
			const detail = await fn()
			results.push({ id, ok: true, detail: detail ?? '' })
			if (!asJson) process.stdout.write(`  ${GREEN}PASS${RESET}  ${BOLD}${id}${RESET} ${DIM}${detail ?? ''}${RESET}\n`)
		} catch (err) {
			const detail = err?.message ?? String(err)
			if (err instanceof Skipped) {
				results.push({ id, ok: null, detail })
				if (!asJson) process.stdout.write(`  ${YELLOW}SKIP${RESET}  ${BOLD}${id}${RESET} ${DIM}${detail}${RESET}\n`)
				return
			}
			results.push({ id, ok: false, detail })
			if (!asJson) process.stdout.write(`  ${RED}FAIL${RESET}  ${BOLD}${id}${RESET} ${DIM}${detail}${RESET}\n`)
		}
	}
}

let code = 1
try {
	await main()
	const passed = results.filter(r => r.ok === true).length
	const skipped = results.filter(r => r.ok === null).length
	const failed = results.filter(r => r.ok === false).length
	code = failed === 0 ? 0 : 1
	if (asJson) process.stdout.write(`${JSON.stringify({ passed, failed, skipped, results }, null, 2)}\n`)
	else {
		const tone = failed === 0 ? GREEN : RED
		const skipText = skipped ? ` · ${skipped} skip` : ''
		process.stdout.write(`\n${tone}${BOLD}${passed} pass · ${failed} fail${skipText}${RESET}  of ${results.length}\n`)
	}
} catch (err) {
	process.stderr.write(`${RED}e2e:${RESET} ${err?.message ?? err}\n`)
	if (/unreachable|ECONNREFUSED|resolve/i.test(String(err?.message))) {
		process.stderr.write(`${DIM}Needs \`wtf claude browser\` running on the HOST.${RESET}\n`)
	}
}
process.exit(code)
