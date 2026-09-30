#!/usr/bin/env node
// Drive a host Chromium over the DevTools Protocol — screenshot the running
// app, log in, and read real values back out of the page.
//
// Zero dependencies : Node 24 ships a global `WebSocket` and CDP is just JSON
// over one. That is not a stylistic choice — the devcontainer firewall blocks
// playwright / puppeteer on the registry and every Chromium CDN, and the repo
// bans per-platform native binaries (see #npm-optional-deps).
//
// The browser runs on the HOST (`wtf claude browser`, windowed), this script runs in
// the container and reaches it through the `host:9222` direct-TCP allowance.
//
// USAGE (shorthand)  : `wtf claude live shot -- --url '<app-url>' --out .tmp/shots/app.png --login`
//                      (a project wrapper — see the skill's Dogfood shorthand section)
// USAGE (direct)   : `node /opt/devcontainer/base/skills/visual-loop/scripts/cdp.mjs shot <url> --out <path> [--login]`
//                    `node /opt/devcontainer/base/skills/visual-loop/scripts/cdp.mjs login [--email …] [--password …]`
//                    `node /opt/devcontainer/base/skills/visual-loop/scripts/cdp.mjs eval '<js>'`
//
// Two behaviours that look like bugs but are deliberate :
//   - the viewport override is left in place on exit, so a follow-up
//     `eval 'getComputedStyle(…)'` measures the same viewport that was just
//     captured. That is the whole point of the loop ;
//   - `login` always reloads the document. Setting the cookie is not enough —
//     see the block comment on doLogin().
//
// Two refusals, both of which mean "the world is not ready", never "this is
// broken" :
//   - the tab is not the front tab of its window (exit 9) — a hidden tab stops
//     painting, so a capture would be a frozen frame. The WINDOW may sit behind
//     anything ; see assertFrontTab ;
//   - another session holds the browser (exit 10) — there is one tab and every
//     tool navigates it. Wait and re-run ; see the lock section.

import { lookup } from 'node:dns/promises'
import { mkdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs'
import { isIP } from 'node:net'
import { hostname } from 'node:os'
import { dirname, resolve } from 'node:path'
import { setTimeout as sleep } from 'node:timers/promises'
import { fileURLToPath } from 'node:url'
import { BOLD, DIM, GREEN, RED, RESET, YELLOW } from '../lib/colors.mjs'
import { env, need } from '../lib/config.mjs'

// ── constants ─────────────────────────────────────────────────────────────

const DEFAULT_HOST = 'host.docker.internal'
const DEFAULT_PORT = 9222
const DEFAULT_WIDTH = 1440
const DEFAULT_HEIGHT = 900

// Named viewports, because "does it still work on a laptop" is a question that
// gets asked on every UI change and nobody remembers the numbers. These are
// VIEWPORT sizes, not screen sizes : a maximised window on a 1080p display
// leaves ~950px once the browser chrome is subtracted, and a 13-14" laptop ~800.
// `macbook` is a recent MacBook (1512x982 screen) running the browser
// full-screen : 789px of viewport once the chrome is subtracted. It is the
// shortest of the three and therefore the one that decides whether a modal's
// max-height cap engages — capture it before declaring anything "fits".
const DEVICES = {
	desktop: { width: 1920, height: 950 },
	laptop: { width: 1440, height: 800 },
	macbook: { width: 1512, height: 789 },
}
// No defaults. A credential baked into a public image is a trap shaped like a
// convenience, and a guessed origin is measured silently rather than refused.
// Every one of these is resolved lazily at the point of use, never here:
// front.mjs and e2e.mjs import from this module, and a refusal at module scope
// would stop an unconfigured project from even printing --help.
const DEFAULT_EMAIL = env('CDP_EMAIL')
const DEFAULT_PASSWORD = env('CDP_PASSWORD')
const APP_URL = env('CDP_APP_URL')
const APP_HOST = env('CDP_APP_HOST') ?? (APP_URL ? (URL.parse(APP_URL)?.hostname ?? undefined) : undefined)

const HTTP_TIMEOUT_MS = 5000 // /json/version probe — one LAN hop, fail fast
const CMD_TIMEOUT_MS = 15000 // any single CDP command
const LOAD_TIMEOUT_MS = 30000 // navigation + load event
const RENDER_TIMEOUT_MS = 10000 // the DOM predicate poll
const POLL_INTERVAL_MS = 100
const SETTLE_MS = 400 // Naive UI's drawer slide is ~300ms

const EXIT_OK = 0
const EXIT_FAIL = 1
const EXIT_USAGE = 2 // repo convention : 2 is CLI misuse
const EXIT_UNREACHABLE = 3
const EXIT_NAV = 4
const EXIT_TIMEOUT = 5
const EXIT_AUTH = 6
const EXIT_EVAL = 7
const EXIT_PROTOCOL = 8
const EXIT_HIDDEN = 9 // the target tab is backgrounded — nothing rendered can be trusted
const EXIT_LOCKED = 10 // another session holds the browser ; wait and retry

// Two copies of the same file, and the difference between them is diagnostic.
// BAKED is what actually governs iptables : .devcontainer/Dockerfile COPYs the
// firewall tree into the image, so init-firewall.sh reads from /etc and never
// sees an edit made in the workspace. SOURCE is what a human just edited.
// BAKED ≠ SOURCE therefore means "edited but not rebuilt yet".
const ALLOW_FILE_BAKED = '/etc/devcontainer-firewall/ports.txt'
const ALLOW_FILE_SOURCE = env('CDP_FIREWALL_PORTS') ?? '/workspace/.devcontainer/firewall/ports.txt'
// Written by .devcontainer/initialize.sh, the only code that runs on the host.
// From in here the kernel only tells us the hypervisor, not the host OS — see
// scripts/install-cross-arch-natives.mjs, which reads the same marker.
const HOST_OS_FILE = env('CDP_HOST_OS_FILE') ?? '/workspace/.devcontainer/tmp/logs/host-os'

// Keyed on the ENDPOINT the lock guards, never on the checkout. The previous
// repo-relative path (.tmp/cdp/.cdp-lock.json) broke under git worktrees : wtf
// runs each worktree's own copy of this file, so every worktree derived its own
// lock file and excluded nothing — while all of them navigated the one browser.
// /tmp is container-wide, so every session pointing at the same host:port now
// contends on the same file whatever directory it runs from. The suffix keeps
// two DISTINCT endpoints from serialising each other ; CDP_LOCK_DIR relocates
// the directory (tests, mainly — so they never touch a live session's lock).
const LOCK_DIR = process.env.CDP_LOCK_DIR || '/tmp/cdp'
const LOCK_FILE = resolve(LOCK_DIR, `.cdp-lock-${process.env.CDP_HOST || DEFAULT_HOST}-${process.env.CDP_PORT || DEFAULT_PORT}.json`)
// The crash window, NOT the hold limit. A healthy run refreshes every
// LOCK_BEAT_MS and keeps the lock for as long as it needs — a 20-minute e2e
// suite included. Sizing this off the longest suite is the mistake the
// heartbeat exists to avoid ; it only bounds how long a `kill -9` wedges.
const LOCK_TTL_MS = 60_000
const LOCK_BEAT_MS = 20_000
const LOCK_POLL_MS = 2000 // --wait re-check interval

const USE_COLOR = process.stdout.isTTY && process.env.NO_COLOR !== '1'
const C = USE_COLOR
	? { bold: BOLD, dim: DIM, green: GREEN, red: RED, yellow: YELLOW, reset: RESET }
	: { bold: '', dim: '', green: '', red: '', yellow: '', reset: '' }

/**
 * The predicate polled by waitForRender(), evaluated in the page.
 *
 * `Page.loadEventFired` is structurally insufficient for this app :
 * `the app's root component` wraps its whole template in
 * `<template v-if="auth.status === 'ready'">`, and `status` only leaves
 * `'idle'` once `onMounted(() => auth.init())` has completed an `/auth/me`
 * round-trip. So there is a real window — one HTTPS round-trip wide — where
 * the document is loaded, `#app` exists, and it is empty.
 *
 * Returns a *diagnosis*, never a bare boolean : on timeout the last `why` is
 * what says whether the app never mounted, never authenticated, or is still
 * loading fonts. `view` doubles as a machine-checkable read of the auth state
 * — `'layout'` proves the session cookie took, with no cookie inspection.
 */
/** The element that proves the APP is up. Any other selector takes the generic arm. */
const APP_ROOT = env('CDP_APP_ROOT') ?? '#app'

/**
 * Built per capture rather than fixed, because this tool is not only pointed at
 * the app : the orchestration web UI mounts `<main id="view">` and has no `#app`
 * at all, so the app arm below would time out on a page that rendered perfectly.
 * `#app` (the default) keeps the auth-state read — `view` is what proves the
 * session cookie took, with no cookie inspection. Any other selector gets the
 * same liveness checks minus that app-specific arm.
 * @param {string} selector
 * @returns {string} JS evaluated in the page
 */
function renderPredicate(selector) {
	const shared = `
	if (root.getBoundingClientRect().height < 8) return { ok: false, why: 'root rendered with zero height' }
	if (document.fonts && document.fonts.status !== 'loaded') return { ok: false, why: 'webfonts still loading' }
	for (const img of document.images) if (!img.complete) return { ok: false, why: 'images still loading' }`

	// The auth-aware arm needs to know which child means "signed in" and which means
	// "signed out". Both keys or neither: one alone cannot tell the two states apart,
	// and a half-configured probe would report an auth state it never measured.
	const mounted = env('CDP_AUTH_MOUNTED')
	const anon = env('CDP_AUTH_ANON')

	if (selector !== APP_ROOT || !mounted || !anon) {
		const sel = JSON.stringify(selector)
		return `(() => {
	const root = document.querySelector(${sel})
	if (!root) return { ok: false, why: 'no element matching ' + ${sel} + ' — the page never mounted, or the wrong URL' }${shared}
	return { ok: true, view: ${sel} }
})()`
	}

	const sel = JSON.stringify(selector)
	const m = JSON.stringify(mounted)
	const a = JSON.stringify(anon)
	return `(() => {
	const app = document.querySelector(${sel})
	if (!app) return { ok: false, why: 'no element matching ' + ${sel} + ' — dev-server error page, or the wrong URL' }
	const root = app.querySelector(${a} + ', ' + ${m})
	if (!root) return { ok: false, why: 'app mounted but nothing rendered — the auth probe has not settled' }${shared}
	return { ok: true, view: root.matches(${m}) ? 'authenticated' : 'anonymous' }
})()`
}

// ── errors ────────────────────────────────────────────────────────────────

/** An error that already carries the exit code the CLI should die with. */
class CdpError extends Error {
	/**
	 * @param {string} message
	 * @param {number} code - one of the EXIT_* constants.
	 */
	constructor(message, code) {
		super(message)
		this.name = 'CdpError'
		this.code = code
	}
}

// ── lock ──────────────────────────────────────────────────────────────────

// There is ONE debug Chromium and ONE tab, and every tool here navigates it.
// Two sessions overlapping is not a slowdown, it is silent wrong data : a shot
// fired mid-suite navigates the tab out from under it, a viewport override from
// one session resizes what the other is measuring, and `fresh: true` — which
// e2e passes unconditionally — sends Storage.clearCookies BROWSER-WIDE and logs
// the other session out. None of that raises an error anywhere ; it just
// produces numbers that are wrong.
//
// Advisory, deliberately. It guards the realistic case — several Claude
// sessions in one devcontainer, each in its own checkout or worktree, all
// driving the same host:9222 — and it cannot see the human driving that
// browser by hand, or a sibling research container with its own /tmp. .figma-lock.json has exactly the same
// property and has been worth having. Do not read it as a hard mutex.
//
// The two halves come from the two precedents already in the repo : the message
// shape and the refuse-don't-wait policy from figma.mjs, the mtime-as-heartbeat
// liveness from .devcontainer/notify/lib/lockfile.js. Not lockfile.js's
// always-replace policy — evicting a live holder is right for a daemon slot and
// catastrophic for a suite twelve minutes into a run.

/** Best-effort JSON read — a missing or corrupt lock is not an error, it is "no lock". */
function readLockFile() {
	try {
		return JSON.parse(readFileSync(LOCK_FILE, 'utf8'))
	} catch {
		return null
	}
}

/** Our identity in the lock file. `pid` alone is meaningless across containers. */
function lockSelf() {
	return { pid: process.pid, host: hostname() }
}

/**
 * The lock currently in force, or null when there is none or it has gone stale.
 *
 * Staleness is an absolute `expires` written by the holder's heartbeat, not a
 * liveness probe : `process.kill(pid, 0)` answers about THIS container's
 * process table, and the holder may be in another one.
 * @returns {object|null}
 */
function readLock() {
	const lock = readLockFile()
	return lock?.expires > Date.now() ? lock : null
}

/**
 * Refuse, in the shape figma.mjs established : what was refused and for how
 * long, the forensic line, then `→` bullets ending in the manual escape hatch.
 *
 * The reader is an AGENT, so the first bullet is an instruction and not a
 * diagnosis. Fail fast rather than block by default : a Bash call that sits
 * silent for twenty minutes hits the tool timeout and reads as a hang, and the
 * caller can neither report progress nor do anything else meanwhile.
 * @param {object} lock
 * @returns {CdpError}
 */
function lockedError(lock) {
	const ageS = Math.max(0, Math.round((Date.now() - Date.parse(lock.at)) / 1000))
	const age = ageS >= 60 ? `${Math.floor(ageS / 60)}m ${ageS % 60}s` : `${ageS}s`
	return new CdpError(
		`the browser is held by another session — \`${lock.owner}\`, started ${age} ago on ${lock.host}.
  ${C.dim}pid ${lock.pid} · claimed ${lock.at} · expires ${new Date(lock.expires).toISOString()}${C.reset}
  → WAIT and re-run this exact command. An e2e suite runs 1-20 min ; a shot or
    probe frees it in seconds.
  → do NOT run a second browser command in parallel — both would navigate the
    same tab, and the readings of BOTH would be wrong.
  → the holder refreshes its claim every ${LOCK_BEAT_MS / 1000}s. If that process died the lock
    goes stale on its own at the time above and the next command takes it.
  → --wait-lock <seconds> blocks here until it frees instead of failing.
  → delete ${LOCK_FILE} only if you are certain no session is running.`,
		EXIT_LOCKED,
	)
}

/**
 * Take the browser lock, or throw {@link lockedError}.
 *
 * `flag: 'wx'` is O_EXCL — it throws EEXIST if the file exists, and that is the
 * whole mutex. Zero dependency, matching this file and every script beside it.
 * The stale path is a delete-then-retry rather than an overwrite, so two racing
 * waiters cannot both believe they took it.
 * @param {string} owner - the argv that is claiming it, for the refusal message.
 * @param {number} waitMs - how long to keep retrying ; 0 fails fast.
 * @returns {Promise<() => void>} release, safe to call more than once.
 */
async function acquireLock(owner, waitMs) {
	const deadline = Date.now() + waitMs
	const self = lockSelf()
	mkdirSync(dirname(LOCK_FILE), { recursive: true })

	for (;;) {
		const claim = { ...self, owner, at: new Date().toISOString(), expires: Date.now() + LOCK_TTL_MS }
		try {
			writeFileSync(LOCK_FILE, `${JSON.stringify(claim, null, 2)}\n`, { flag: 'wx' })
			return startHeartbeat(self)
		} catch (err) {
			if (err?.code !== 'EEXIST') throw err
		}

		const held = readLock()
		if (!held) {
			// Expired. Drop it and loop : whoever wins the next `wx` owns it, and
			// the loser sees EEXIST again rather than clobbering the winner.
			try {
				unlinkSync(LOCK_FILE)
			} catch {
				/* another waiter got there first — fine, retry */
			}
			continue
		}
		if (Date.now() >= deadline) throw lockedError(held)
		await sleep(Math.min(LOCK_POLL_MS, Math.max(0, deadline - Date.now())))
	}
}

/**
 * Keep the claim fresh, and hand back a release that only ever deletes OUR
 * lock. Blind unlink would let a session that just stole an expired lock have
 * it deleted by the previous holder's late exit.
 * @param {{pid: number, host: string}} self
 * @returns {() => void}
 */
function startHeartbeat(self) {
	let released = false
	const beat = setInterval(() => {
		const lock = readLockFile()
		if (lock?.pid !== self.pid || lock.host !== self.host) return
		lock.expires = Date.now() + LOCK_TTL_MS
		try {
			writeFileSync(LOCK_FILE, `${JSON.stringify(lock, null, 2)}\n`)
		} catch {
			/* a lock we cannot refresh will go stale on its own — not worth dying for */
		}
	}, LOCK_BEAT_MS)
	// unref so the timer never keeps the process alive past its work.
	beat.unref()

	const release = () => {
		if (released) return
		released = true
		clearInterval(beat)
		const lock = readLockFile()
		if (lock?.pid !== self.pid || lock.host !== self.host) return
		try {
			unlinkSync(LOCK_FILE)
		} catch {
			/* already gone */
		}
	}
	process.on('exit', release)
	// SIGINT/SIGTERM do not run `exit` handlers on their own. Re-raise with the
	// handler removed so the caller still sees a signal death, not exit 0.
	for (const sig of ['SIGINT', 'SIGTERM']) {
		process.once(sig, () => {
			release()
			process.kill(process.pid, sig)
		})
	}
	return release
}

// ── transport ─────────────────────────────────────────────────────────────

/**
 * Resolve the CDP endpoint to a **literal IP**.
 *
 * Chrome's anti-DNS-rebinding guard rejects any request whose `Host` header is
 * a DNS name — only `localhost` and IP literals pass, everything else gets a
 * 403 `Host header is specified and is not an IP address or localhost`.
 * `host.docker.internal` is a DNS name, so it is turned into an address here,
 * once, before anything touches the wire. family:4 on purpose — an AAAA answer
 * would produce `http://[::1]:9222` style URLs for nothing.
 * @returns {Promise<{ip: string, port: number, httpBase: string}>}
 */
async function resolveEndpoint() {
	const host = process.env.CDP_HOST || DEFAULT_HOST
	const port = Number(process.env.CDP_PORT || DEFAULT_PORT)
	if (isIP(host)) return { ip: host, port, httpBase: `http://${host}:${port}` }
	try {
		const { address } = await lookup(host, { family: 4 })
		return { ip: address, port, httpBase: `http://${address}:${port}` }
	} catch (err) {
		throw new CdpError(`cannot resolve ${host} : ${err.code ?? err.message}`, EXIT_UNREACHABLE)
	}
}

/**
 * Swap the authority of a CDP websocket URL for our resolved endpoint, keeping
 * the path (which carries the browser/target uuid) untouched.
 *
 * Chrome fills `webSocketDebuggerUrl` with whatever host it believes it serves
 * on — `localhost:9222` normally, `0.0.0.0:9222` with
 * `--remote-debugging-address=0.0.0.0`. Both are useless from inside the
 * container : `localhost` is the container itself, `0.0.0.0` is not an address
 * you connect to. **Only the path is trustworthy ; the authority is always
 * replaced.**
 * @param {string} wsUrl
 * @param {{ip: string, port: number}} ep
 * @returns {string}
 */
function rewriteCdpHost(wsUrl, ep) {
	const u = new URL(wsUrl)
	u.protocol = 'ws:'
	u.host = `${ep.ip}:${ep.port}`
	return u.href
}

/**
 * Does this allowlist file grant `host:<port>` ? `null` when the file cannot be
 * read at all, which is a different answer from "read it, port absent".
 * @param {string} file
 * @param {{ip: string, port: number}} ep
 * @returns {boolean | null}
 */
function allowsPort(file, ep) {
	try {
		const rules = readFileSync(file, 'utf8')
			.split('\n')
			.map(l => l.split('#')[0].replace(/\s/g, ''))
			.filter(Boolean)
		return rules.includes(`host:${ep.port}`) || rules.includes(`${ep.ip}:${ep.port}`)
	} catch {
		return null
	}
}

/**
 * The host OS, as recorded by initialize.sh — 'mac' | 'linux' | 'wsl' |
 * 'gitbash', or '' when the marker is missing (an older container that has not
 * been rebuilt since the marker was introduced).
 * @returns {string}
 */
function hostOs() {
	try {
		return readFileSync(HOST_OS_FILE, 'utf8').trim()
	} catch {
		return ''
	}
}

/**
 * ECONNREFUSED here is ambiguous, so explain both causes and rank them.
 *
 * The container's egress firewall REJECTs instantly when `host:9222` is absent
 * from ports.txt, and a Chromium that simply is not running looks
 * identical on the wire. The errno cannot discriminate — so read the allowlist,
 * which is the one side of the question observable from in here.
 * @param {{ip: string, port: number}} ep
 * @param {unknown} err
 * @returns {string}
 */
function unreachableHint(ep, err) {
	const code = err?.cause?.code ?? err?.code ?? err?.name ?? 'unknown'
	const baked = allowsPort(ALLOW_FILE_BAKED, ep)
	const source = allowsPort(ALLOW_FILE_SOURCE, ep)
	const head = `cannot reach the CDP endpoint at ${ep.ip}:${ep.port} (${code})`

	if (baked === false && source === true) {
		return `${head}
  → host:${ep.port} is allowed in .devcontainer/firewall/ports.txt but NOT in the
    image's baked copy (${ALLOW_FILE_BAKED}). The edit has not been applied yet.
  → Rebuild Container. Re-running init-firewall.sh is NOT enough — it recompiles from the
    baked copy and will not see your edit.`
	}
	if (baked === false) {
		return `${head}
  → the devcontainer firewall does not allow host:${ep.port}. Add it to
    .devcontainer/firewall/ports.txt, then Rebuild Container.`
	}
	if (code === 'TimeoutError' || code === 'ETIMEDOUT') {
		return `${head}
  → the connection hung rather than being refused, so the DevTools endpoint is not listening
    on an address this container can reach. scripts/browser.mjs narrows the bind (D1) — it
    binds loopback on mac/linux and the WSL2 NAT gateway on Windows, instead of 0.0.0.0.
  → if that guess is wrong for your host, widen it and relaunch :
    SYMPTEMS_CDP_ADDRESS=0.0.0.0 wtf claude browser`
	}
	// On WSL2 the browser is a *Windows* process, so "not listening" has a second,
	// much more common cause than on mac : chrome.exe is running and visible, but
	// the Windows firewall is dropping 9222. Saying "run wtf claude browser" to someone
	// looking at an open browser window sends them the wrong way.
	if (hostOs() === 'wsl') {
		return `${head}
  → the firewall allows it, so nothing is answering on the Windows side.
  → if the Chromium window IS open, Windows Firewall is blocking chrome.exe on ${ep.port} —
    re-run \`wtf claude browser\` in the WSL2 shell and answer the prompt (private networks only).
  → otherwise run \`wtf claude browser\` on the HOST, in the WSL2 shell (it needs a window).
  → HUMAN ACTION : this cannot be done from the container. If you are an agent, relay the
    line above and WAIT — do not retry, and do not try to launch it yourself.`
	}
	return `${head}
  → the firewall allows it, so Chromium is not listening. Run \`wtf claude browser\` on the HOST
    (it needs a window ; it cannot run in this container).
  → HUMAN ACTION : this cannot be done from the container. If you are an agent, relay the
    line above and WAIT — do not retry, and do not try to launch it yourself.`
}

/**
 * Read /json/version and return the browser-level websocket URL, rewritten to
 * the literal-IP endpoint.
 * @param {{ip: string, port: number, httpBase: string}} ep
 * @returns {Promise<string>}
 */
async function fetchBrowserWsUrl(ep) {
	let res
	try {
		res = await fetch(`${ep.httpBase}/json/version`, { signal: AbortSignal.timeout(HTTP_TIMEOUT_MS) })
	} catch (err) {
		throw new CdpError(unreachableHint(ep, err), EXIT_UNREACHABLE)
	}
	if (!res.ok) {
		const body = (await res.text()).trim().slice(0, 200)
		// A 403 mentioning the Host header means the rewrite above was skipped
		// somewhere. Surface the body verbatim so it is recognised in seconds.
		throw new CdpError(`CDP /json/version → HTTP ${res.status} : ${body}`, EXIT_UNREACHABLE)
	}
	const info = await res.json()
	if (!info.webSocketDebuggerUrl) throw new CdpError('no webSocketDebuggerUrl in /json/version', EXIT_UNREACHABLE)
	return rewriteCdpHost(info.webSocketDebuggerUrl, ep)
}

/**
 * Open the websocket and return a minimal RPC surface. One socket for
 * everything : target routing rides on the flat `sessionId` field, so there is
 * never a second connection to manage.
 * @param {string} wsUrl
 * @returns {Promise<{send: Function, on: Function, waitFor: Function, close: Function}>}
 */
async function connect(wsUrl) {
	const ws = new WebSocket(wsUrl)
	const pending = new Map() // id → {method, resolve, reject, timer}
	const listeners = new Map() // method → Set<fn>
	let nextId = 0
	let dead = null

	await new Promise((res, rej) => {
		ws.addEventListener('open', res, { once: true })
		ws.addEventListener('error', () => rej(new CdpError(`websocket connect failed : ${wsUrl}`, EXIT_UNREACHABLE)), {
			once: true,
		})
	})

	ws.addEventListener('message', ev => {
		const msg = JSON.parse(ev.data)
		if (msg.id !== undefined) {
			const p = pending.get(msg.id)
			if (!p) return
			pending.delete(msg.id)
			clearTimeout(p.timer)
			if (msg.error) p.reject(new CdpError(`${p.method} : ${msg.error.message} (${msg.error.code})`, EXIT_PROTOCOL))
			else p.resolve(msg.result)
			return
		}
		// In flatten mode events carry `sessionId` at the top level too, so
		// handlers can ignore traffic coming from another target.
		for (const fn of listeners.get(msg.method) ?? []) fn(msg.params, msg.sessionId)
	})

	ws.addEventListener('error', () => {})
	ws.addEventListener('close', () => {
		dead = new CdpError('the browser closed the devtools connection', EXIT_UNREACHABLE)
		for (const p of pending.values()) {
			clearTimeout(p.timer)
			p.reject(dead)
		}
		pending.clear()
	})

	/**
	 * Send one CDP command. `sessionId` is omitted for browser-level domains
	 * (Target.*) and set for everything page-level.
	 * @param {string} method
	 * @param {object} [params]
	 * @param {string} [sessionId]
	 * @param {number} [timeoutMs]
	 * @returns {Promise<object>}
	 */
	const send = (method, params = {}, sessionId = undefined, timeoutMs = CMD_TIMEOUT_MS) =>
		new Promise((res, rej) => {
			if (dead) {
				rej(dead)
				return
			}
			const id = ++nextId
			const timer = setTimeout(() => {
				pending.delete(id)
				rej(new CdpError(`${method} timed out after ${timeoutMs}ms`, EXIT_TIMEOUT))
			}, timeoutMs)
			pending.set(id, { method, resolve: res, reject: rej, timer })
			ws.send(JSON.stringify(sessionId ? { id, method, params, sessionId } : { id, method, params }))
		})

	/**
	 * Register an event handler ; returns its own unsubscribe function.
	 * @param {string} method
	 * @param {(params: object, sessionId: string) => void} fn
	 * @returns {() => void}
	 */
	const on = (method, fn) => {
		if (!listeners.has(method)) listeners.set(method, new Set())
		listeners.get(method).add(fn)
		return () => listeners.get(method)?.delete(fn)
	}

	/**
	 * Promise for the next occurrence of an event.
	 *
	 * **Subscribe first, act second.** Create this promise BEFORE sending the
	 * command that triggers it : `Page.loadEventFired` regularly lands before
	 * `Page.navigate` resolves, and an await-then-subscribe ordering then hangs
	 * until the timeout for no reason at all.
	 * @param {string} method
	 * @param {string} [sessionId]
	 * @param {number} [timeoutMs]
	 * @returns {Promise<object>}
	 */
	const waitFor = (method, sessionId = undefined, timeoutMs = LOAD_TIMEOUT_MS) =>
		new Promise((res, rej) => {
			let timer
			const off = on(method, (params, sid) => {
				if (sessionId && sid !== sessionId) return
				clearTimeout(timer)
				off()
				res(params)
			})
			timer = setTimeout(() => {
				off()
				rej(new CdpError(`timed out after ${timeoutMs}ms waiting for ${method}`, EXIT_TIMEOUT))
			}, timeoutMs)
		})

	return { send, on, waitFor, close: () => ws.close() }
}

/**
 * Refuse a target that is not the front tab of its window.
 *
 * `fromSurface: false` (see cmdShot) bought back the WINDOW ; it buys nothing
 * for the TAB. A backgrounded tab reports visibilityState 'hidden', the
 * renderer stops rAF, CSS animations freeze and every `visibilitychange`
 * listener takes its hidden branch — the capture then comes back as a paused
 * frame and gets measured as if it were live, which reads as a rendering bug
 * and is not one. `hasFocus()` is the OTHER thing entirely and is false in
 * normal operation : both readings go into the message so that nobody "fixes"
 * this by raising the window, which is precisely what is NOT required.
 *
 * Only 'visible' passes. An unreadable answer is not a state worth trusting.
 * Pure — exported for the unit test, the only place this can be checked
 * without a browser.
 * @param {{visibility: string, focus: boolean, url: string}} state
 * @returns {void}
 */
function assertFrontTab(state) {
	if (state?.visibility === 'visible') return
	throw new CdpError(
		`the target tab is not the front tab of its window — document.visibilityState : ${state?.visibility ?? 'unreadable'}
  → in the debug Chromium, click the tab on ${state?.url ?? 'the app'} so it is the FRONTMOST TAB of ITS window.
  → the WINDOW may stay behind your editor : hasFocus ${state?.focus} is the normal, supported state. Do NOT
    "fix" this by raising or focusing the window. A MINIMISED window reads hidden too — leave it open, behind.
  → why this is fatal : a hidden tab stops painting, so the capture would be a paused frame and every
    measurement taken from it stale.`,
		EXIT_HIDDEN,
	)
}

/**
 * Print the "about to take your window" banner and wait out the grace
 * period — the one warning every activating command in this toolchain shows
 * BEFORE it steals the human's window, so the alert always precedes the
 * steal instead of explaining it afterwards. Exported so `front.mjs` and
 * `e2e.mjs` (the only two callers that ever activate a tab) share one
 * wording instead of drifting, which they already had.
 * @param {string} url - the tab being activated.
 * @param {string} detail - one line explaining WHY, specific to the caller.
 * @param {number} graceMs - wait before returning ; `<= 0` skips the wait.
 * @returns {Promise<void>}
 */
async function warnBeforeActivating(url, detail, graceMs) {
	process.stdout.write(
		`\n${YELLOW}${BOLD}⚠  ABOUT TO TAKE YOUR WINDOW${RESET}\n` +
			`${DIM}   ${url}${RESET}\n` +
			`${DIM}   ${detail}${RESET}\n` +
			`${DIM}   ${Math.round(graceMs / 1000)} s to Ctrl-C — \`--grace 0\` skips this wait${RESET}\n\n`,
	)
	if (graceMs > 0) await sleep(graceMs)
}

/**
 * Pick the tab to drive and attach a flat session to it.
 *
 * **Reuse over Target.createTarget**, deliberately : `eval` is useless on a
 * fresh tab (`an in-page seeding helper` is installed on the app page), the
 * browser is windowed on purpose so the user watches this tab, and a new tab
 * per run piles up tabs while re-paying the whole boot cost every time.
 * @param {{send: Function}} conn
 * @returns {Promise<{targetId: string, sessionId: string, frameId: string}>}
 */
async function attachPage(conn, { activate = false, requireVisible = true } = {}) {
	const { targetInfos } = await conn.send('Target.getTargets')
	const pages = targetInfos.filter(t => t.type === 'page' && !t.url.startsWith('devtools://'))
	const preferred = APP_HOST ? pages.find(t => URL.parse(t.url)?.hostname.endsWith(APP_HOST)) : undefined
	const targetId =
		(preferred ?? pages[0])?.targetId ?? (await conn.send('Target.createTarget', { url: 'about:blank' })).targetId

	// Activation is NOT needed to capture : cmdShot rasterises with
	// `fromSurface: false`, which works on a window nobody is looking at. The
	// parameter survives for the one case where FOCUS ITSELF is under test —
	// :focus-visible, a caret, an IME, Input.dispatchKeyEvent into a field that
	// expects focus first — and a call site that passes it should say so in a
	// comment, because raising the window costs the human their screen
	// mid-sentence. It is one half of a pair : either we bring the tab to the
	// front, or we demand that it already is (the guard below).
	if (activate) await conn.send('Target.activateTarget', { targetId })

	// flatten:true → the session is addressed by a top-level `sessionId` on every
	// message, both directions, over this same socket. Without it each command
	// has to be tunnelled through Target.sendMessageToTarget and unwrapped out of
	// Target.receivedMessageFromTarget — same result, twice the JSON, deprecated.
	const { sessionId } = await conn.send('Target.attachToTarget', { targetId, flatten: true })

	// Settled HERE, once, before any navigation or login — and never in
	// evaluate(). A suite that opens a second tab (Target.createTarget, straight
	// on the connection, see plans/<plan>/suites/) legitimately backgrounds this
	// one mid-run, so a per-read check would fail on its own harness. Attaching
	// happens before any scenario, which is what makes one shot safe. Skipped
	// when `activate` is set : that arm brings the tab to the front by
	// construction and checking now would only race the visibilitychange.
	// Cheap on purpose — one round-trip, before the domain enables, so a wrong
	// tab costs a second rather than a full render wait.
	if (requireVisible && !activate) {
		const probe = '({ visibility: document.visibilityState, focus: document.hasFocus(), url: location.href })'
		assertFrontTab(await evaluate(conn, sessionId, probe))
	}

	await conn.send('Page.enable', {}, sessionId)
	await conn.send('Network.enable', {}, sessionId)
	// Independent of the launch flag : docker/proxy/dev.crt is a mkcert cert
	// whose root CA belongs to another machine, so without this every capture is
	// a Chrome interstitial instead of the app.
	await conn.send('Security.enable', {}, sessionId)
	await conn.send('Security.setIgnoreCertificateErrors', { ignore: true }, sessionId)

	const { frameTree } = await conn.send('Page.getFrameTree', {}, sessionId)
	return { targetId, sessionId, frameId: frameTree.frame.id }
}

// ── page helpers ──────────────────────────────────────────────────────────

/**
 * Turn a Runtime.exceptionDetails into something readable. A non-Error
 * rejection stringifies to `undefined` through the usual paths, which is
 * exactly the unreadable outcome to avoid.
 * @param {object} details
 * @returns {string}
 */
function describeException(details) {
	const ex = details?.exception
	return ex?.description ?? ex?.value ?? details?.text ?? 'unknown in-page exception'
}

/**
 * Evaluate an expression in the page and return its value.
 * @param {{send: Function}} conn
 * @param {string} sid
 * @param {string} expression
 * @returns {Promise<unknown>}
 */
async function evaluate(conn, sid, expression) {
	const r = await conn.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }, sid)
	if (r.exceptionDetails) throw new CdpError(describeException(r.exceptionDetails), EXIT_EVAL)
	return r.result?.value
}

/**
 * Record the HTTP status of the **main document** response.
 *
 * A dev-server that is down is otherwise invisible : HAProxy answers 503 with a
 * well-formed HTML page (docker/proxy/error503.http), the load event fires on
 * schedule, and the capture is a pixel-perfect error page. Filtering on the
 * main frame id keeps subframes and XHRs out of it.
 * @param {{on: Function}} conn
 * @param {string} sid
 * @param {string} frameId
 * @returns {{status: number, url: string}}
 */
function trackDocumentStatus(conn, sid, frameId) {
	const seen = { status: 0, url: '' }
	conn.on('Network.responseReceived', (p, s) => {
		if (s !== sid || p.type !== 'Document' || p.frameId !== frameId) return
		seen.status = p.response.status // last one wins : redirect chains
		seen.url = p.response.url
	})
	return seen
}

/**
 * Turn a main-document HTTP status into something actionable.
 * @param {number} status
 * @param {string} url
 * @returns {string}
 */
function explainHttp(status, url) {
	if (status === 503) {
		return `${url} → 503. HAProxy is up but the rspack dev-server behind it is not.
  → run \`wtf dev\` on the HOST (it needs docker + tmux, neither exists in this container).`
	}
	if (status === 404) {
		return `${url} → 404. historyApiFallback did not match — check the route's path shape.`
	}
	return `${url} → HTTP ${status}.`
}

/**
 * Poll the render predicate until it reports ok, then let the page settle.
 * @param {{send: Function}} conn
 * @param {string} sid
 * @param {{timeoutMs: number, settleMs: number}} o
 * @returns {Promise<{ok: true, view: string}>}
 */
async function waitForRender(conn, sid, o) {
	const predicate = renderPredicate(o.ready ?? APP_ROOT)
	const deadline = Date.now() + o.timeoutMs
	let why = 'never evaluated'
	while (Date.now() < deadline) {
		const r = await evaluate(conn, sid, predicate)
		if (r?.ok) {
			// Naive UI animates : the drawer slides in over ~300ms and n-modal fades.
			// A settle beat is cheaper and far more robust than trying to detect the
			// end of a CSS transition.
			await sleep(o.settleMs)
			return r
		}
		why = r?.why ?? 'predicate returned nothing'
		await sleep(POLL_INTERVAL_MS)
	}
	throw new CdpError(`the page never rendered within ${o.timeoutMs}ms — last check : ${why}`, EXIT_TIMEOUT)
}

/**
 * Navigate and wait for the load event, failing loudly on net-stack errors and
 * on any main-document status >= 400.
 * @param {{send: Function, waitFor: Function, on: Function}} conn
 * @param {string} sid
 * @param {string} frameId
 * @param {string} url
 * @returns {Promise<void>}
 */
async function navigate(conn, sid, frameId, url) {
	const doc = trackDocumentStatus(conn, sid, frameId)
	const loaded = conn.waitFor('Page.loadEventFired', sid) // subscribe first
	const r = await conn.send('Page.navigate', { url }, sid)
	// Checked before awaiting the load event : on a net-stack failure that event
	// never fires, and waiting 30s for it hides the real cause.
	if (r.errorText) throw new CdpError(`navigation failed : ${r.errorText} (${url})`, EXIT_NAV)
	await loaded
	if (doc.status >= 400) throw new CdpError(explainHttp(doc.status, doc.url || url), EXIT_NAV)
}

/**
 * Reload the current document and wait for the load event.
 * @param {{send: Function, waitFor: Function}} conn
 * @param {string} sid
 * @returns {Promise<void>}
 */
async function reload(conn, sid) {
	const loaded = conn.waitFor('Page.loadEventFired', sid)
	await conn.send('Page.reload', {}, sid)
	await loaded
}

// ── login ─────────────────────────────────────────────────────────────────

/**
 * Build the in-page login expression.
 *
 * It MUST run in a page already on the app origin : the `sess` cookie is
 * `Domain=<your app host>; SameSite=lax; httpOnly`, so from about:blank the
 * request is an opaque cross-site fetch, the Set-Cookie is dropped, and you get
 * a cheerful 200 with no session.
 *
 * The body is written so it **can never reject** — every failure mode (network
 * error, TLS refusal, non-JSON body, 401, 422) comes back as a structured
 * value. Credentials are interpolated through JSON.stringify, never
 * concatenation, so a password containing a quote cannot break the parse.
 * @param {string} email
 * @param {string} password
 * @returns {string}
 */
function loginExpression(email, password, template) {
	return `(async () => {
	// Where the app POSTs credentials differs per stack — a subdomain for one,
	// a path prefix on the same origin for another — so it is configuration, not
	// a regex to be guessed. '{origin}' is substituted here, inside the page,
	// because only the page knows its own location.origin.
	const api = ${JSON.stringify(template)}.replace('{origin}', location.origin)
	try {
		const res = await fetch(api, {
			method: 'POST',
			credentials: 'include',
			headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
			body: JSON.stringify(${JSON.stringify({ email, password })}),
		})
		const text = await res.text()
		let body = null
		try {
			body = text ? JSON.parse(text) : null
		} catch (parseErr) {
			body = { error: 'non-JSON response', raw: text.slice(0, 300) }
		}
		return { ok: res.ok, status: res.status, body: body, api: api }
	} catch (e) {
		return { ok: false, status: 0, body: { error: String((e && e.message) || e) }, api: api }
	}
})()`
}

/**
 * Log in, four acts, none of them droppable :
 *   1. be on the app origin — navigate there if the tab is elsewhere ;
 *   2. POST from inside the page, so the BROWSER stores the httpOnly cookie
 *      (we never see it and never need to) ;
 *   3. **full document reload** — the app's root component calls
 *      `auth.init()` once, from onMounted(), and init() early-returns unless
 *      `status === 'idle'` (the app's auth store). Setting a cookie
 *      on a live page therefore changes exactly nothing on screen ; only a new
 *      document re-runs the /auth/me probe that flips isAuthenticated ;
 *   4. wait for render and read back which view came up.
 *
 * Idempotent : already authenticated (view === 'layout') → the POST is skipped.
 * @param {{send: Function, waitFor: Function, on: Function}} conn
 * @param {string} sid
 * @param {string} frameId
 * @param {{email: string, password: string, wait: number, settle: number}} o
 * @returns {Promise<{view: string, skipped: boolean, api?: string}>}
 */
async function doLogin(conn, sid, frameId, o) {
	const here = await evaluate(conn, sid, 'location.href')
	if (!APP_HOST || !URL.parse(String(here ?? ''))?.hostname.endsWith(APP_HOST)) {
		await navigate(conn, sid, frameId, need(APP_URL, 'CDP_APP_URL', 'the URL of the app under test, e.g. https://app.localhost:5173/', 'url'))
	}
	let rendered = await waitForRender(conn, sid, { timeoutMs: o.wait, settleMs: 0 })
	if (rendered.view === 'layout') return { view: 'layout', skipped: true }

	const r = await evaluate(conn, sid, loginExpression(
			o.email,
			o.password,
			need(env('CDP_LOGIN_URL'), 'CDP_LOGIN_URL', "the endpoint your app POSTs credentials to — '{origin}' is replaced with the page's own origin, e.g. {origin}/api/auth/login", 'login-url'),
		))
	if (!r?.ok) {
		const msg = r?.body?.error ?? 'no response'
		if (r?.status === 0) {
			throw new CdpError(
				`the page could not reach the API at ${r?.api} : ${msg}
  → is \`wtf dev\` running on the host ?`,
				EXIT_NAV,
			)
		}
		if (r?.status === 401) {
			throw new CdpError(
				`login refused (401) : ${msg}
  → the seeded credentials are admin@test.test / password (0000_create_users.sql).`,
				EXIT_AUTH,
			)
		}
		if (r?.status === 422) {
			const issues = (r?.body?.issues ?? []).map(i => `${i.path?.[0]?.key ?? '?'}: ${i.message}`).join(', ')
			throw new CdpError(`invalid login payload (422) : ${msg}${issues ? ` — ${issues}` : ''}`, EXIT_AUTH)
		}
		throw new CdpError(`the API answered ${r?.status} : ${msg}`, EXIT_NAV)
	}

	await reload(conn, sid)
	rendered = await waitForRender(conn, sid, { timeoutMs: o.wait, settleMs: o.settle })
	if (rendered.view !== 'layout') {
		throw new CdpError(
			`login returned 200 but the app still shows the ${rendered.view} view — the session cookie did not stick`,
			EXIT_AUTH,
		)
	}
	return { view: 'layout', skipped: false, api: r.api }
}

// ── commands ──────────────────────────────────────────────────────────────

/**
 * Navigate, optionally log in, then write a PNG.
 *
 * Order matters : metrics are overridden BEFORE navigating because the authenticated shell
 * has a viewport-width `isMobile` branch, so overriding after load risks
 * capturing the mobile layout or a mid-recompute frame.
 * @param {{send: Function, waitFor: Function, on: Function}} conn
 * @param {string} sid
 * @param {string} frameId
 * @param {object} o
 * @returns {Promise<object>}
 */
async function cmdShot(conn, sid, frameId, o) {
	await conn.send(
		'Emulation.setDeviceMetricsOverride',
		{ width: o.width, height: o.height, deviceScaleFactor: o.scale, mobile: false },
		sid,
	)

	// Login FIRST, then navigate once. doLogin is self-sufficient — it only moves
	// the tab when it is off-origin, and skips the POST when the layout is already
	// up — so the target URL is loaded exactly once. Doing it the other way round
	// loaded the deep link, threw it away on the login reload, and loaded it
	// again : three renders and a visible double flash for the human watching the
	// headed browser.
	const login = o.login ? await doLogin(conn, sid, frameId, o) : null
	await navigate(conn, sid, frameId, o.url)
	const rendered = await waitForRender(conn, sid, { timeoutMs: o.wait, settleMs: o.settle, ready: o.ready })

	// --before : put the page into a state no url can express — a drawer opened
	// by a click, a hover, a style override for an A/B. It runs HERE, after the
	// render predicate and before the capture, so that navigation and mutation
	// stay in ONE invocation : a mutation issued as a separate `eval` call would
	// be applied to whatever page the tab happens to be on by then, which is the
	// staleness trap this tool exists to close. Settle again afterwards, since
	// what it triggers is usually an animation (a drawer slide is ~300ms).
	if (o.before) {
		await evaluate(conn, sid, o.before)
		await sleep(o.settle)
	}

	// `fromSurface: false` is what makes a capture possible WITHOUT stealing the
	// window. The default (true) grabs the OS compositor surface, which only
	// exists for a painted, foreground window — that was the entire reason this
	// used to call Target.activateTarget here. Rasterising from the renderer
	// instead works on an unfocused window ; verified at both
	// `captureBeyondViewport` settings, full fidelity, and on a browser launched
	// WITHOUT any anti-backgrounding flags — so this line stands on its own.
	//
	// The trade-off is that OS-level chrome and overlays are excluded, which for
	// capturing an app's own UI is the wanted behaviour. If a capture ever needs
	// the real compositor output (video, some GPU paths), flip it back.
	//
	// ⚠️ Still required : the target must be the ACTIVE TAB in its window.
	// Window occlusion is handled ; tab backgrounding is not — a hidden tab has
	// visibilityState 'hidden', which stops rAF and freezes animations, and the
	// capture then returns a paused frame that looks like a rendering bug.
	// Enforced at attach (assertFrontTab), once, so by the time we get here the
	// tab was painting.
	//
	// If a --full capture ever comes back clipped, the fix is not a CDP mystery :
	// Page.getLayoutMetrics → cssContentSize.height → re-issue the metrics
	// override at that height → capture → restore.
	const shot = await conn.send(
		'Page.captureScreenshot',
		{ format: 'png', fromSurface: false, captureBeyondViewport: Boolean(o.full) },
		sid,
		LOAD_TIMEOUT_MS,
	)
	const buf = Buffer.from(shot.data, 'base64')
	mkdirSync(dirname(o.out), { recursive: true })
	writeFileSync(o.out, buf)
	return { out: o.out, bytes: buf.length, view: rendered.view, width: o.width, height: o.height, full: !!o.full, login }
}

/**
 * Evaluate arbitrary JS in the page and return its value.
 * @param {{send: Function}} conn
 * @param {string} sid
 * @param {object} o
 * @returns {Promise<object>}
 */
async function cmdEval(conn, sid, o) {
	return { value: await evaluate(conn, sid, o.expression) }
}

// ── cli ───────────────────────────────────────────────────────────────────

const USAGE = `cdp.mjs — drive a host Chromium over the DevTools Protocol.

  node /opt/devcontainer/base/skills/visual-loop/scripts/cdp.mjs shot <url> --out <path> [options]
  node /opt/devcontainer/base/skills/visual-loop/scripts/cdp.mjs login [--email <e>] [--password <p>]
  node /opt/devcontainer/base/skills/visual-loop/scripts/cdp.mjs eval <js>
  node /opt/devcontainer/base/skills/visual-loop/scripts/cdp.mjs reset

Options
  --out <path>       PNG destination (required by shot ; parent dirs created)
  --device <name>    viewport preset — ${Object.entries(DEVICES)
		.map(([k, v]) => `${k} (${v.width}x${v.height})`)
		.join(', ')}.
                     --width / --height still win when given explicitly.
  --width <n>        viewport width, default ${DEFAULT_WIDTH}
  --height <n>       viewport height, default ${DEFAULT_HEIGHT}
  --full             capture the whole page, not just the viewport
  --scale <n>        device pixel ratio, default 1. Use 2 to compare against a
                     Figma export : those render at 2x, and a 1.2px stroke has
                     no fully-covered pixel at 1x, so stroke weight and colour
                     read lighter than they are.
  --login            log in first, then capture (idempotent)
  --email <e>        default ${DEFAULT_EMAIL ?? '(unset - set CDP_EMAIL in .devcontainer/.env)'}
  --password <p>     default ${DEFAULT_PASSWORD ? '(set via CDP_PASSWORD)' : '(unset - set CDP_PASSWORD in .devcontainer/.env)'}
  --ready <selector> element whose presence means "rendered", default ${APP_ROOT}. The
                     default also reads the app's auth state. Point it elsewhere to
                     capture a page that is not the app — the orchestration web UI
                     needs \`--ready '#view'\`, having no #app to wait for.
  --wait <ms>        render-predicate timeout, default ${RENDER_TIMEOUT_MS}
  --settle <ms>      pause after render, default ${SETTLE_MS} (drawer/modal animation)
  --before <js>      JS to run after render and before capture, for a state no url
                     can express — open a drawer with a click, inject a style
                     override for an A/B. Same invocation as the navigation on
                     purpose : a separate \`eval\` would hit whatever page the tab
                     has drifted to. Settles again afterwards.
  --wait-lock <s>    seconds to wait for the browser lock, default 0 (refuse at
                     once). There is one browser and one tab : a second session
                     running now would navigate it out from under this one.
  --json             one JSON blob on stdout, no human output
  --                 stop flag parsing (use for \`eval -- '-1'\`)

Environment
  CDP_HOST           default ${DEFAULT_HOST}
  CDP_PORT           default ${DEFAULT_PORT}
  CDP_LOCK_DIR       browser-lock directory, default /tmp/cdp — shared by every
                     checkout, because the lock guards the endpoint, not the repo

\`reset\` clears the viewport emulation that \`shot\` deliberately leaves behind —
run it when you are done measuring, otherwise the window keeps rendering at the
captured size and anything taller than the real window looks cropped. It is the
one command exempt from the front-tab check, being the undo for exactly that.

The app tab must be the FRONTMOST TAB of its window ; the window itself may sit
behind your editor. A background tab stops painting and every reading off it is
stale, so that is refused rather than measured.

Requires \`wtf dev\` AND \`wtf claude browser\` running on the HOST.
A deep link into an authenticated-only view renders nothing while logged out —
the authenticated shell only mounts once authenticated, and the query string is kept but
acted on by nobody — so always pass --login with one.
\`eval 'an in-page seeding helper()'\` likewise needs a logged-in page : the sync
store is only initialised from the authenticated shell.
`

/**
 * Hand-rolled argv parsing — the repo does not use node:util parseArgs.
 * @param {string[]} argv
 * @returns {object}
 */
function parseArgs(argv) {
	const o = {
		cmd: '',
		url: '',
		out: '',
		expression: '',
		before: '',
		width: DEFAULT_WIDTH,
		height: DEFAULT_HEIGHT,
		full: false,
		login: false,
		email: DEFAULT_EMAIL,
		password: DEFAULT_PASSWORD,
		wait: RENDER_TIMEOUT_MS,
		settle: SETTLE_MS,
		scale: 1,
		device: '',
		// The element whose presence means "rendered". Default #app is the app ;
		// point it elsewhere to capture a page that is not the app.
		ready: APP_ROOT,
		json: false,
		// Milliseconds spent waiting for the browser lock. 0 = refuse at once,
		// which is the right default for an agent : the refusal tells it to come
		// back, and a silent twenty-minute block would just hit a tool timeout.
		// Named --wait-lock because --wait is already the render timeout.
		wait_lock: 0,
	}
	const positionals = []
	const seen = new Set()
	const values = {
		'--out': 'out',
		'--email': 'email',
		'--password': 'password',
		'--device': 'device',
		'--before': 'before',
		'--ready': 'ready',
	}
	const numbers = {
		'--width': 'width',
		'--height': 'height',
		'--wait': 'wait',
		'--settle': 'settle',
		'--scale': 'scale',
	}
	let rest = false

	for (let i = 2; i < argv.length; i++) {
		const a = argv[i]
		if (!rest) seen.add(a)
		if (rest) {
			positionals.push(a)
		} else if (a === '--') {
			rest = true
		} else if (values[a]) {
			o[values[a]] = argv[++i]
		} else if (numbers[a]) {
			o[numbers[a]] = Number(argv[++i])
		} else if (a === '--wait-lock') {
			o.wait_lock = Number(argv[++i]) * 1000
		} else if (a === '--full') {
			o.full = true
		} else if (a === '--login') {
			o.login = true
		} else if (a === '--json') {
			o.json = true
		} else if (a === '--help' || a === '-h') {
			process.stdout.write(USAGE)
			process.exit(EXIT_OK)
		} else if (a.startsWith('-')) {
			process.stderr.write(`unknown arg: ${a}\n`)
			process.exit(EXIT_USAGE)
		} else {
			positionals.push(a)
		}
	}

	// A preset only fills in what was not asked for explicitly, so
	// `--device laptop --width 1280` narrows a laptop rather than being ignored.
	if (o.device) {
		const d = DEVICES[o.device]
		if (d) {
			if (!seen.has('--width')) o.width = d.width
			if (!seen.has('--height')) o.height = d.height
		}
	}
	o.cmd = positionals[0] ?? ''
	if (o.cmd === 'shot') o.url = positionals[1] ?? ''
	if (o.cmd === 'eval') o.expression = positionals.slice(1).join(' ')
	return o
}

/**
 * Validate the parsed options, exiting 2 on misuse.
 * @param {object} o
 * @returns {void}
 */
function validate(o) {
	const bad = m => {
		process.stderr.write(`${m}\n\n${USAGE}`)
		process.exit(EXIT_USAGE)
	}
	if (!o.cmd) bad('missing subcommand')
	if (!['shot', 'login', 'eval', 'reset'].includes(o.cmd)) bad(`unknown subcommand: ${o.cmd}`)
	if (o.cmd === 'shot' && !o.url) bad('shot needs a <url>')
	if (o.cmd === 'shot' && !o.out) bad('shot needs --out <path>')
	if (o.cmd === 'eval' && !o.expression) bad('eval needs a <js> expression')
	if (o.device && !DEVICES[o.device]) bad(`unknown --device: ${o.device} (known: ${Object.keys(DEVICES).join(', ')})`)
	for (const k of ['width', 'height', 'wait', 'settle']) {
		if (!Number.isFinite(o[k])) bad(`--${k} must be a number`)
	}
}

/**
 * Human-readable rendering of a command result.
 * @param {string} cmd
 * @param {object} out
 * @returns {void}
 */
function report(cmd, out) {
	if (cmd === 'shot') {
		const kb = Math.round(out.bytes / 1024)
		const auth = out.login ? (out.login.skipped ? ' (already logged in)' : ' (logged in)') : ''
		process.stdout.write(
			`${C.green}✓${C.reset} ${out.out} ${C.dim}(${kb} KB, ${out.width}×${out.height}${out.full ? ', full page' : ''}, view: ${out.view}${auth})${C.reset}\n`,
		)
		return
	}
	if (cmd === 'login') {
		const how = out.skipped ? 'already authenticated' : 'authenticated'
		process.stdout.write(`${C.green}✓${C.reset} ${how} ${C.dim}(view: ${out.view})${C.reset}\n`)
		return
	}
	if (cmd === 'reset') {
		process.stdout.write(
			`${C.green}✓${C.reset} viewport emulation cleared ${C.dim}(the window now renders at its own ${out.inner.w}×${out.inner.h})${C.reset}\n`,
		)
		return
	}
	process.stdout.write(`${JSON.stringify(out.value, null, 2)}\n`)
}

/**
 * Drop the viewport emulation and hand the tab back to the human.
 *
 * `shot` deliberately leaves `Emulation.setDeviceMetricsOverride` in place so a
 * follow-up `eval 'getComputedStyle(…)'` measures the very viewport that was
 * captured. The cost is that the window then renders at the emulated size rather
 * than its own : a 900px-tall override inside an 857px-tall window hides 43px
 * under the edge, and everything looks cropped and off-centre while the page is
 * in fact fine. This is the undo.
 * @param {{send: Function}} conn
 * @param {string} sid
 * @returns {Promise<{cleared: true, inner: object}>}
 */
async function cmdReset(conn, sid) {
	// Take ownership before releasing. An override survives the session that set
	// it — `shot` closes its websocket and the emulation stays on the target — and
	// `clearDeviceMetricsOverride` from a fresh session is then a no-op, because
	// this session holds no override to clear. Setting one first makes it ours,
	// and clearing ours drops the target back to the real window. Verified : a
	// bare clear left innerHeight at the captured 600, this restores it.
	await conn.send(
		'Emulation.setDeviceMetricsOverride',
		{ width: 0, height: 0, deviceScaleFactor: 0, mobile: false },
		sid,
	)
	await conn.send('Emulation.clearDeviceMetricsOverride', {}, sid)
	const inner = await evaluate(conn, sid, 'JSON.stringify({w: innerWidth, h: innerHeight})')
	return { cleared: true, inner: JSON.parse(String(inner ?? '{}')) }
}

async function main() {
	const o = parseArgs(process.argv)
	validate(o)

	const ep = await resolveEndpoint()
	// Reachability is settled BEFORE the lock : a browser that is not running is
	// the human's problem to fix and must not leave a claim behind for them.
	const wsUrl = await fetchBrowserWsUrl(ep)
	const release = await acquireLock(`cdp ${o.cmd}`, o.wait_lock)
	const conn = await connect(wsUrl)
	try {
		// Nothing here needs the window raised : captures go through
		// `fromSurface: false` (see cmdShot) and every other command reads the DOM,
		// which a background WINDOW serves fine. A background TAB does not, hence
		// the visibility guard — waived for `reset` alone, which is the undo for
		// the viewport override : it reads no rendered pixel, and refusing to hand
		// the tab back because the human has already switched tabs is exactly
		// backwards.
		const { targetId, sessionId, frameId } = await attachPage(conn, {
			activate: false,
			requireVisible: o.cmd !== 'reset',
		})
		o.targetId = targetId
		let out
		switch (o.cmd) {
			case 'shot': {
				out = await cmdShot(conn, sessionId, frameId, o)
				break
			}
			case 'login': {
				out = await doLogin(conn, sessionId, frameId, o)
				break
			}
			case 'reset': {
				out = await cmdReset(conn, sessionId)
				break
			}
			default: {
				out = await cmdEval(conn, sessionId, o)
				break
			}
		}
		if (o.json) process.stdout.write(`${JSON.stringify(out, null, 2)}\n`)
		else report(o.cmd, out)
	} finally {
		conn.close()
		release()
	}
}

// Only when RUN, never when imported. The primitives above (connect, evaluate,
// navigate, doLogin…) are the reusable half — a harness that needs one socket
// held across many steps cannot go through the CLI, which opens and closes a
// connection per invocation. Without this guard, importing the module would
// run the CLI and exit the importer's process.
if (process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
	main()
		.then(() => process.exit(EXIT_OK))
		.catch(err => {
			// Errors go to stderr even under --json, so the single stdout blob is never
			// half a JSON document.
			process.stderr.write(`${C.red}cdp:${C.reset} ${err?.message ?? err}\n`)
			process.exit(err instanceof CdpError ? err.code : EXIT_FAIL)
		})
}

export { APP_HOST, assertFrontTab, connect }
export { evaluate, fetchBrowserWsUrl, lockedError, readLock, reload, resolveEndpoint }
export { warnBeforeActivating }

/**
 * One connected, attached, logged-in page session — the entry point for any
 * multi-step harness. Mirrors main()'s wiring exactly, minus the command
 * dispatch, so the two cannot drift.
 * @returns {Promise<{conn: object, sid: string, frameId: string, close: () => void}>}
 */
export async function openSession({
	url = APP_URL,
	email = DEFAULT_EMAIL,
	password = DEFAULT_PASSWORD,
	wait = 15000,
	settle = 250,
	activate = false,
	fresh = false,
	owner = 'openSession',
	waitLock = 0,
} = {}) {
	// Reachability first, so a browser that is not running never leaves a claim
	// behind for the human to clean up.
	const wsUrl = await fetchBrowserWsUrl(await resolveEndpoint())
	// A harness holds this for minutes and `fresh` below clears cookies
	// BROWSER-WIDE, so overlapping with another session is not a slowdown, it is
	// that session being logged out mid-scenario. Held for the whole life of the
	// returned handle and dropped by close().
	const release = await acquireLock(owner, waitLock)
	let conn
	try {
		conn = await connect(wsUrl)
	} catch (err) {
		release()
		throw err
	}
	try {
		const { sessionId, frameId } = await attachPage(conn, { activate })
		// `fresh` exists because doLogin is a no-op when a session already exists
		// (it returns `{skipped:true}` the moment it sees the layout). Asking for
		// a SPECIFIC account therefore silently keeps whoever was logged in —
		// which shows up as an empty app rather than as an auth error, because a
		// user with no data legitimately syncs nothing. Dropping the cookies
		// first is what makes the requested identity actually take.
		// Storage.clearCookies, not Network.clearBrowserCookies : the latter is
		// session-scoped and needs Network.enable first, so at browser level it
		// answers -32601 "wasn't found". This one is browser-wide by design.
		if (fresh) await conn.send('Storage.clearCookies')
		// The cookie is only half the identity : the app keeps a persistent
		// client mirror per ORIGIN, and it outlives both the cookie and the
		// server database. An agent slot re-seeded by `wtf claude server reset`
		// mints NEW random practice / user ids, so a stale mirror hands the
		// suite the union of both seeds — observed as a duplicated row that the
		// server has only once, and as records that no longer exist. Scoped to the target origin on
		// purpose : browser-wide would wipe the human's own app state.
		// Sent on the PAGE session, not at browser level (where it answers
		// -32603), and best-effort : an origin the browser has never visited
		// has nothing to clear, which must not abort a run. `storageTypes` is
		// spelled out — 'all' is rejected by this build.
		if (fresh) {
			const origin = URL.parse(url)?.origin
			if (origin) {
				try {
					await conn.send('Storage.clearDataForOrigin', { origin, storageTypes: 'indexeddb,local_storage,websql,cache_storage,service_workers,file_systems' }, sessionId)
				} catch (err) {
					process.stderr.write(`${YELLOW}could not clear the client mirror for ${origin} (${err.message}) — a stale mirror can carry rows from a previous seed${RESET}\n`)
				}
			}
		}
		await navigate(conn, sessionId, frameId, url)
		await doLogin(conn, sessionId, frameId, { wait, settle, email, password })
		return {
			conn,
			sid: sessionId,
			frameId,
			close: () => {
				conn.close()
				release()
			},
		}
	} catch (err) {
		conn.close()
		release()
		throw err
	}
}
