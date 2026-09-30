#!/usr/bin/env node
// Read exact design values out of a Figma file — the input half of the visual
// design loop (the output half is /opt/devcontainer/base/skills/visual-loop/scripts/cdp.mjs).
//
// The point is to stop eyeballing a mockup PNG. `get` returns the real
// auto-layout, padding, radii, fills and typography of a node, reduced to the
// fields you actually write CSS from and with colors already converted to hex,
// so a value can be diffed against the app's own theme constants as a string
// rather than recomputed by hand.
//
// Zero dependencies : native fetch, token in the X-Figma-Token header.
//
// USAGE (from wtf) : `wtf claude script figma -- ls`
//                    `wtf claude script figma -- get 195-2`
//                    `wtf claude script figma -- png 195-2 --scale 2`
// USAGE (direct)   : `node /opt/devcontainer/base/skills/visual-loop/scripts/figma.mjs <subcommand> [args] [--key <k>] [--json]`
//
// Node ids may be given in either form — the URL shows `195-2`, the API wants
// `195:2` — and any `get`/`png`/`ls` argument may instead be a pasted Figma
// URL, from which both the file key and the node id are extracted.
//
// Requires FIGMA_TOKEN in .devcontainer/.env, and api.figma.com allowed in
// .devcontainer/firewall/domains.local.txt.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { BOLD, DIM, GREEN, RED, RESET, YELLOW } from '../lib/colors.mjs'
import { env } from '../lib/config.mjs'

// ── constants ─────────────────────────────────────────────────────────────

const API = 'https://api.figma.com'
// cwd-anchored, never script-anchored: baked, this file sits under /opt, which is
// read-only. Run figma.mjs from your repo root — a call from a subdirectory writes
// a second .figma-lock.json there, and a lock nobody reads excludes nothing.
const OUT_DIR = env('VISUAL_LOOP_OUT_DIR') ?? join(process.cwd(), '.tmp/design')

const EXIT_OK = 0
const EXIT_FAIL = 1
const EXIT_USAGE = 2 // repo convention : 2 is CLI misuse

const DEFAULT_DEPTH = 2
/**
 * Depth `get` uses when none is given. Without it the API is called with no
 * `depth` param at all, which returns the ENTIRE subtree — the single most
 * expensive request the script can make, as the accidental default. The quota
 * is credit-based and cost tracks payload size, so an unbounded default is how
 * a routine `get` earns a multi-day lock. Raise it explicitly when you need to
 * descend ; that is a deliberate act, not a default.
 */
const DEFAULT_GET_DEPTH = 3
const DEFAULT_SCALE = 2
const PNG_MAGIC = 0x89504e47

/** Backoff between 429 retries, used when Figma sends no `Retry-After`. */
const RETRY_WAITS_MS = [2000, 5000, 15000]
/**
 * Total seconds a command may spend waiting out 429s, across all retries.
 * A budget, not an attempt count, because Figma answers `Retry-After: 60` :
 * three attempts against that header is three minutes of a CLI that looks
 * hung, and buys nothing — the quota window is ~60s, so one reprise is the
 * only one that can succeed.
 */
const RETRY_BUDGET_MS = 70000
/**
 * Minimum gap between two api.figma.com calls. Reactive retry alone is not
 * enough : Figma's quota is a rolling window, so a burst earns a `Retry-After:
 * 60` that no amount of retrying shortens. Spacing the burst is what avoids
 * paying that minute in the first place. Only the API is throttled — the S3
 * render download is a different host and costs no quota.
 */
const MIN_API_GAP_MS = 1000

/**
 * Where the rate-limit lock and the fetch index live. Both sit next to the
 * output they describe, and both are disposable — deleting them costs a
 * refetch, never correctness.
 */
/**
 * Sanity ceiling on a persisted lock, so a corrupt header cannot park the CLI
 * indefinitely. Deliberately generous : the unit is settled, so the header is
 * trusted below this bound.
 *
 * `Retry-After` IS in seconds, including on the `high` tier — measured, not
 * assumed. Two 429s 514s apart reported 396698 then 396183, a decrease of 515
 * for 514 seconds elapsed. A one-per-second countdown toward a fixed deadline
 * can only be seconds, which ruled out the milliseconds reading that would
 * have made the same value a 6.6 minute wait rather than a 4.6 day one.
 */
const LOCK_CAP_MS = 7 * 86400000
const LOCK_FILE = join(OUT_DIR, '.figma-lock.json')
const CACHE_FILE = join(OUT_DIR, '.figma-cache.json')

const ACCENTS = /[̀-ͯ]/g
const NON_SLUG = /[^a-z0-9]+/g
const EDGE_DASH = /^-|-$/g
const HYPHEN = /-/g
const COLON = /:/g
const FILE_KEY_IN_PATH = /\/(?:file|design|proto|board)\/([A-Za-z0-9]+)/

/**
 * Which PAT scope each endpoint family needs. A missing scope surfaces ONLY as
 * HTTP 403, and Figma's 403 body never names the scope — so the mapping has to
 * live here, keyed on the path. It is reasoned, not verified against a live
 * token : a 403 means adjust this table, not that the call is wrong.
 */
const SCOPE_HINTS = [
	[/^\/v1\/teams\/[^/]+\/projects/, 'Projects → "Read team project structure"'],
	[/^\/v1\/projects\//, 'Projects → "Read team project structure", then Files → "Read metadata of files"'],
	[/^\/v1\/files\/[^/]+\/styles/, 'Design systems → "Read components and styles published from individual files"'],
	[/^\/v1\/(files|images)\//, 'Files → "Read the contents of and render images from files"'],
]

/** Figma auto-layout alignment → the flexbox keyword it maps to. */
const ALIGN = {
	MIN: 'flex-start',
	CENTER: 'center',
	MAX: 'flex-end',
	SPACE_BETWEEN: 'space-between',
	BASELINE: 'baseline',
}

/** Node keys copied through verbatim when present. */
const KEEP = [
	'layoutMode',
	'itemSpacing',
	'primaryAxisAlignItems',
	'counterAxisAlignItems',
	'strokeWeight',
	'cornerRadius',
]

const USE_COLOR = process.stdout.isTTY && process.env.NO_COLOR !== '1'

// ── helpers ───────────────────────────────────────────────────────────────

/**
 * Wrap in an ANSI code, or return untouched when stdout is piped or NO_COLOR=1
 * — so `wtf claude script figma -- ls > file` stays clean.
 * @param {string} code - one of the constants from ../lib/colors.mjs
 * @param {string} s
 * @returns {string}
 */
const c = (code, s) => (USE_COLOR ? `${code}${s}${RESET}` : s)

/**
 * Print to stderr and exit. Errors always go to stderr, including under
 * --json, so the single stdout blob is never half a JSON document.
 * @param {number} code
 * @param {string} msg
 * @returns {never}
 */
function die(code, msg) {
	process.stderr.write(`${c(RED, '✗')} ${msg}\n`)
	process.exit(code)
}

/**
 * Trap : Figma URLs carry `123-456`, the REST API only accepts `123:456`. Both
 * forms are accepted on the CLI ; this is the single place that decides.
 * Instance ids (`I123-456;789-012`) normalise correctly under the same rule.
 * @param {string} id
 * @returns {string}
 */
const normalizeId = id => id.replace(HYPHEN, ':')

/**
 * Filename for .tmp/design/. Two things happen here : the id `12:345` becomes
 * `12-345` (the exact inverse of normalizeId — `:` is legal on ext4 but breaks
 * on macOS, and this repo is bind-mounted from a Mac), and the node name is
 * prefixed because `login-panel-12-345.png` beats `12-345.png` once six files
 * sit side by side. The id always stays : two frames are routinely both "Card".
 * @param {string} id
 * @param {string} [name]
 * @returns {string}
 */
function slugify(id, name) {
	const base = (name ?? '')
		.toLowerCase()
		.normalize('NFD')
		.replace(ACCENTS, '')
		.replace(NON_SLUG, '-')
		.replace(EDGE_DASH, '')
		.slice(0, 48)
	return `${base ? `${base}-` : ''}${id.replace(COLON, '-')}`
}

/**
 * Accept a pasted Figma URL wherever a node id is expected, and pull BOTH the
 * file key and the node id out of it. This kills the hyphen/colon trap at its
 * source rather than patching it downstream, and removes the hand-extraction
 * of the file key from the path — the other thing that is easy to get wrong.
 * @param {string} arg
 * @returns {{key?: string, id?: string} | null} null when `arg` is not a URL.
 */
function fromUrl(arg) {
	if (!arg?.startsWith('http')) return null
	const u = URL.parse(arg)
	if (!u) return null
	const nodeId = u.searchParams.get('node-id')
	return { key: FILE_KEY_IN_PATH.exec(u.pathname)?.[1], id: nodeId ? normalizeId(nodeId) : undefined }
}

/**
 * flag > URL > env > hard stop. No silent fallback : a guessed file key
 * surfaces as a 404 two calls later, which is strictly worse than not starting.
 * A `default:` in .wtfcmd.yml arrives as a real flag, so it sits at the top of
 * this chain for free.
 * @param {string | undefined} flag
 * @param {string} envName
 * @param {string} flagName
 * @param {string} how - one line telling the user where to find the value.
 * @returns {string}
 */
function need(flag, envName, flagName, how) {
	const v = flag ?? process.env[envName]
	if (!v) {
		die(
			EXIT_USAGE,
			`missing --${flagName}.
  → pass --${flagName} <value>, or set ${envName} in .devcontainer/.env
  → ${how}`,
		)
	}
	return v
}

// ── api ───────────────────────────────────────────────────────────────────

/**
 * The token, or a hard stop explaining how to get one.
 *
 * Called from main() before any subcommand dispatch, not just lazily from
 * figmaGet : with neither variable set, a `need(--key)` failure would otherwise
 * be reported first, the user would fix the key, re-run, and only then be told
 * the token is missing. One round trip instead of two.
 * @returns {string}
 */
function requireToken() {
	const token = (process.env.FIGMA_TOKEN ?? '').trim()
	if (!token) {
		die(
			EXIT_FAIL,
			`FIGMA_TOKEN is unset or empty.
  → add \`FIGMA_TOKEN=figd_…\` to .devcontainer/.env (gitignored, loaded via env_file),
    then restart the container so the variable reaches this shell.
  → generate it : figma.com → avatar → Settings → Security → Personal access tokens.
    Required scope : Files → "Read the contents of and render images from files".`,
		)
	}
	return token
}

/**
 * The one place that talks to api.figma.com, and the one place that turns an
 * HTTP status into a message. Every status below is broken out on purpose :
 * collapsing them into `if (!res.ok) throw` is what makes a scope problem look
 * like a network problem and costs an hour.
 * @param {string} path - API path starting with `/v1/…`, already encoded.
 * @returns {Promise<any>} parsed JSON body.
 */
const sleep = ms => new Promise(r => setTimeout(r, ms))

/** Seconds → the coarsest unit that still reads as a duration. */
function fmtDuration(s) {
	if (s >= 86400) return `${(s / 86400).toFixed(1)} days`
	if (s >= 3600) return `${(s / 3600).toFixed(1)} h`
	if (s >= 60) return `${Math.round(s / 60)} min`
	return `${s}s`
}

/** Best-effort JSON read — a missing or corrupt sidecar is not an error. */
function readJsonOr(file, fallback) {
	try {
		return JSON.parse(readFileSync(file, 'utf8'))
	} catch {
		return fallback
	}
}

/**
 * The active rate-limit lock, or null when there is none or it has expired.
 *
 * This is the single most valuable guard in the file. Figma's quota escalates
 * when you call during a lock : a burst answered with `Retry-After: 60` was
 * retried into a `type: high` lock with a 398349s (~4.6 day) deadline. Held on
 * disk rather than in memory precisely because the escalation happened across
 * separate command invocations, which share nothing else.
 */
function readLock() {
	const lock = readJsonOr(LOCK_FILE, null)
	return lock?.until > Date.now() ? lock : null
}

function writeLock(seconds, type, path) {
	mkdirSync(OUT_DIR, { recursive: true })
	const held = Math.min(seconds * 1000, LOCK_CAP_MS)
	const lock = {
		until: Date.now() + held,
		stated: seconds,
		capped: held < seconds * 1000,
		type,
		path,
		at: new Date().toISOString(),
	}
	writeFileSync(LOCK_FILE, `${JSON.stringify(lock, null, 2)}\n`)
}

/** Timestamp of the last api.figma.com call, for {@link spaceApiCall}. */
let lastApiCallAt = 0

/**
 * Hold off until MIN_API_GAP_MS has passed since the previous API call. Cheap
 * insurance : a `ls` pays nothing (single call), a `get` + `png` pair pays two
 * seconds, and a burst that would have cost a 60s `Retry-After` no longer
 * happens.
 */
async function spaceApiCall() {
	const since = Date.now() - lastApiCallAt
	if (since < MIN_API_GAP_MS) await sleep(MIN_API_GAP_MS - since)
	lastApiCallAt = Date.now()
}

/**
 * `fetch`, retrying ONLY on 429. Figma rate-limits hard enough that a routine
 * session trips it — a `get` + a `png` on two nodes is four calls and is
 * already enough — so failing outright turns a two-second wait into a manual
 * retry loop for the human.
 *
 * Bounded and always announced : a silent multi-second stall is
 * indistinguishable from a hang, which is the reason the original version
 * refused to retry at all. Every other status is returned untouched, so the
 * caller's status table stays the single place that interprets them.
 * @param {string} url
 * @param {RequestInit} [opts]
 * @param {string} label - what to name in the retry notice (path or hostname).
 * @returns {Promise<Response>}
 */
async function fetchRetrying(url, opts, label) {
	let spent = 0
	for (let i = 0; ; i++) {
		const res = await fetch(url, opts)
		if (res.status !== 429) return res
		// NEVER retry when Figma states a wait. The quota is a credit bucket,
		// and insisting against it escalates the limit tier rather than riding
		// it out — a burst answered with `Retry-After: 60` was retried into a
		// `type: high` lock with a 398349s (~4.6 day) Retry-After. When the
		// server names a number, the only correct move is to surface it and
		// stop. Retry only the header-less case, where a short blip is the
		// likelier explanation than a real quota breach.
		const stated = Number(res.headers.get('retry-after'))
		if (stated > 0) return res
		const wait = RETRY_WAITS_MS[i] ?? RETRY_WAITS_MS.at(-1)
		if (spent + wait > RETRY_BUDGET_MS) return res
		spent += wait
		process.stderr.write(
			`${c(YELLOW, '⚠')} 429 on ${label} ${c(DIM, '(no Retry-After)')} — retrying in ${wait / 1000}s\n`,
		)
		await sleep(wait)
	}
}

async function figmaGet(path) {
	const token = requireToken()
	const lock = readLock()
	if (lock) {
		die(
			EXIT_FAIL,
			`refusing to call the API — a rate-limit lock is still active for ${c(BOLD, fmtDuration(Math.ceil((lock.until - Date.now()) / 1000)))}.
  ${c(DIM, `type ${lock.type ?? '?'} · Retry-After ${lock.stated} at ${lock.at}${lock.capped ? ' · capped' : ''}`)}
  → calling during a lock is what escalates the tier, so this refuses rather
    than asks. Use the plugin at scripts/figma-plugin/ meanwhile — it reads the
    document locally and costs no quota.
  → delete ${LOCK_FILE} if you believe the lock is stale.`,
		)
	}
	let res
	await spaceApiCall()
	try {
		res = await fetchRetrying(`${API}${path}`, { headers: { 'X-Figma-Token': token } }, path)
	} catch (err) {
		die(
			EXIT_FAIL,
			`network error reaching api.figma.com${path}
  ${err?.message ?? err}
  → is api.figma.com in .devcontainer/firewall/domains.local.txt ? (Rebuild Container after editing)`,
		)
	}
	if (res.status === 403) {
		const scope = SCOPE_HINTS.find(([re]) => re.test(path))?.[1] ?? 'unknown — check the scope list in the PAT settings'
		die(
			EXIT_FAIL,
			`403 on ${path}
  ${c(BOLD, 'This is a token SCOPE problem, not a bad token.')} Figma answers 403 — never 401 —
  when a valid PAT lacks a scope, and the body never says which one.
  Likely missing : ${c(YELLOW, scope)}
  → regenerate the PAT with that scope ticked, update .devcontainer/.env, restart the container.
  (same status, other cause : the token's account has no access to this file or team.)`,
		)
	}
	if (res.status === 404) {
		die(
			EXIT_FAIL,
			`404 on ${path}
  → unknown file key / node id / project id. Check the value, and that the token's account can see it.`,
		)
	}
	if (res.status === 429) {
		// Figma's limit is a credit bucket, not a request counter — cost scales
		// with how much of the file a call pulls back, so a handful of deep
		// `get`s on a big file trips it while a hundred shallow ones do not.
		// These two headers are the only way to tell which ceiling was hit and
		// for how long ; Retry-After has been seen in the multi-day range.
		const type = res.headers.get('x-figma-rate-limit-type')
		const after = res.headers.get('retry-after')
		// Persist the deadline so the NEXT invocation refuses to call at all.
		if (Number(after) > 0) writeLock(Number(after), type, path)
		die(
			EXIT_FAIL,
			`429 on ${path}
  ${c(DIM, `limit type: ${type ?? 'not reported'} · retry-after: ${after ?? 'not reported'}`)}
  → still rate-limited after the ${RETRY_BUDGET_MS / 1000}s retry budget.
  → the quota is credit-based, so waiting longer helps less than asking for less :
    lower --depth, target a node id rather than a whole canvas, and reuse the
    JSON already written under .tmp/design/ instead of refetching.`,
		)
	}
	if (!res.ok) die(EXIT_FAIL, `HTTP ${res.status} on ${path}\n  ${(await res.text()).slice(0, 300)}`)
	return res.json()
}

/**
 * Download a render. Deliberately NOT via figmaGet : the URL is a presigned S3
 * link and the PAT must never leave api.figma.com.
 *
 * The first ever run is likely to fail right here — the S3 host varies by
 * region and is not knowable in advance. Printing the hostname IS the discovery
 * mechanism, so every path prints it, success included.
 * @param {string} url
 * @param {string} dest
 * @returns {Promise<number>} bytes written.
 */
async function download(url, dest) {
	const host = new URL(url).hostname
	const blocked = `  → add ${c(BOLD, host)} to .devcontainer/firewall/domains.local.txt, then Rebuild Container.
    (the allowlist is baked into the image — editing without rebuilding changes nothing)`
	let res
	try {
		res = await fetchRetrying(url, undefined, host)
	} catch (err) {
		die(EXIT_FAIL, `could not reach the image host ${c(BOLD, host)}\n  ${err?.message ?? err}\n${blocked}`)
	}
	if (!res.ok) die(EXIT_FAIL, `HTTP ${res.status} downloading from ${c(BOLD, host)}\n${blocked}`)
	const buf = Buffer.from(await res.arrayBuffer())
	// A proxy block can answer 200 with an HTML error page. Check the magic bytes
	// rather than trusting the status, or you write a .png that is really HTML.
	if (buf.length < 8 || buf.readUInt32BE(0) !== PNG_MAGIC) {
		die(
			EXIT_FAIL,
			`${host} answered ${buf.length} bytes that are not a PNG — almost certainly a block page.\n${blocked}`,
		)
	}
	mkdirSync(dirname(dest), { recursive: true })
	writeFileSync(dest, buf)
	return buf.length
}

/**
 * Fetch one or more nodes, reduced server-side by `depth` when given. `geometry`
 * is never requested (it defaults off), so vector paths stay out of the payload.
 * @param {string} key
 * @param {string} ids - already-encoded, comma-joined.
 * @param {number} [depth]
 * @returns {Promise<any>}
 */
function fetchNodes(key, ids, depth) {
	const q = `ids=${ids}${depth ? `&depth=${depth}` : ''}`
	return figmaGet(`/v1/files/${encodeURIComponent(key)}/nodes?${q}`)
}

// ── reduction ─────────────────────────────────────────────────────────────

/** Round to 2dp, or undefined for non-numbers. */
const r2 = v => (typeof v === 'number' ? Math.round(v * 100) / 100 : undefined)

/**
 * Drop undefined / null / empty-array keys. fromEntries rather than `delete`,
 * which biome's recommended set forbids.
 * @param {object} o
 * @returns {object}
 */
const prune = o =>
	Object.fromEntries(Object.entries(o).filter(([, v]) => v != null && !(Array.isArray(v) && v.length === 0)))

/**
 * Figma gives colors as floats 0-1 ; CSS needs hex. Converting is not a
 * preference — `{"r":0.0549…}` still requires arithmetic to be usable, and
 * `#0e7a67` is byte-identical to what the app's own theme constants already
 * contains, so comparing against the theme becomes a string comparison.
 * Alpha is appended only when not fully opaque, keeping the common case 6 digits.
 * @param {{r: number, g: number, b: number, a?: number}} col
 * @param {number} [opacity] - paint-level opacity, multiplied with the channel alpha.
 * @returns {string}
 */
function hex(col, opacity = 1) {
	const ch = v =>
		Math.round(v * 255)
			.toString(16)
			.padStart(2, '0')
	const a = (col.a ?? 1) * opacity
	return `#${ch(col.r)}${ch(col.g)}${ch(col.b)}${a < 1 ? ch(a) : ''}`
}

/**
 * Paint array → something writable in CSS. Solids collapse to a hex string,
 * gradients keep their type plus stop colors, images keep a marker only (the
 * imageRef is worthless without a second call we are not making). Hidden paints
 * are dropped — they do not render, so they are pure noise.
 * @param {any[]} list
 * @returns {any[] | undefined}
 */
function toPaints(list) {
	if (!Array.isArray(list) || list.length === 0) return undefined
	return list
		.filter(p => p.visible !== false)
		.map(p => {
			if (p.type === 'SOLID') return hex(p.color, p.opacity ?? 1)
			if (p.type?.startsWith('GRADIENT')) return { type: p.type, stops: (p.gradientStops ?? []).map(s => hex(s.color)) }
			return { type: p.type }
		})
}

/**
 * Effects → one string each, in CSS box-shadow order (x y blur spread color).
 * @param {any[]} list
 * @returns {string[] | undefined}
 */
function toEffects(list) {
	if (!Array.isArray(list) || list.length === 0) return undefined
	return list
		.filter(e => e.visible !== false)
		.map(e =>
			e.color
				? `${e.type} ${r2(e.offset?.x) ?? 0} ${r2(e.offset?.y) ?? 0} ${e.radius ?? 0}${e.spread ? ` ${e.spread}` : ''} ${hex(e.color)}`
				: `${e.type} ${e.radius ?? 0}`,
		)
}

/**
 * Padding as one CSS-ordered `top right bottom left` string — four separate
 * keys is four lines of noise on every node, one string is scannable.
 * @param {any} n
 * @returns {string | undefined}
 */
function pad(n) {
	const t = n.paddingTop ?? 0
	const r = n.paddingRight ?? 0
	const b = n.paddingBottom ?? 0
	const l = n.paddingLeft ?? 0
	return t || r || b || l ? `${t} ${r} ${b} ${l}` : undefined
}

/**
 * Ready-to-paste flex declaration — the highest-leverage line of the whole
 * reduction, because layoutMode + itemSpacing + padding IS a flex container and
 * pre-translating removes the step where the mapping gets guessed.
 *
 * NOT modelled : layoutWrap, HUG/FILL sizing modes, absolutely-positioned
 * children. When the rendering disagrees with this line, trust `box`.
 * @param {any} n
 * @returns {string}
 */
function flexCss(n) {
	const parts = ['display:flex', `flex-direction:${n.layoutMode === 'VERTICAL' ? 'column' : 'row'}`]
	if (n.itemSpacing) parts.push(`gap:${n.itemSpacing}px`)
	const p = pad(n)
	if (p) {
		parts.push(
			`padding:${p
				.split(' ')
				.map(v => `${v}px`)
				.join(' ')}`,
		)
	}
	if (n.primaryAxisAlignItems)
		parts.push(`justify-content:${ALIGN[n.primaryAxisAlignItems] ?? n.primaryAxisAlignItems}`)
	if (n.counterAxisAlignItems) parts.push(`align-items:${ALIGN[n.counterAxisAlignItems] ?? n.counterAxisAlignItems}`)
	return parts.join('; ')
}

/**
 * One raw Figma node → the subset you can actually write CSS from, recursively.
 *
 * A single frame's raw payload is routinely 1-4 MB, ~95 % of which is vector
 * geometry, constraints, export settings, `blendMode: 'PASS_THROUGH'` on every
 * node, and plugin data. Dropping it is not cosmetic : it is the difference
 * between a file that can be read in one pass and one that cannot.
 *
 * Nested structure is KEPT (that is the layout) ; noise is dropped per node.
 * Invisible children are skipped — they do not render, so they can only mislead.
 * @param {any} node
 * @returns {any}
 */
function reduceNode(node) {
	const b = node.absoluteBoundingBox
	const out = {
		name: node.name,
		id: node.id,
		type: node.type,
		// x/y are kept (absolute) : when layoutMode is NONE they are the only way
		// to recover the spacing the designer eyeballed. w/h are what you code.
		box: b ? { x: r2(b.x), y: r2(b.y), w: r2(b.width), h: r2(b.height) } : undefined,
		padding: pad(node),
		fills: toPaints(node.fills),
		strokes: toPaints(node.strokes),
		effects: toEffects(node.effects),
		style: node.style
			? prune({
					fontFamily: node.style.fontFamily,
					fontSize: node.style.fontSize,
					fontWeight: node.style.fontWeight,
					lineHeightPx: r2(node.style.lineHeightPx),
					letterSpacing: r2(node.style.letterSpacing),
					textAlignHorizontal: node.style.textAlignHorizontal,
					textCase: node.style.textCase,
				})
			: undefined,
		characters: node.characters,
	}
	for (const k of KEEP) if (node[k] !== undefined) out[k] = node[k]
	if (node.layoutMode && node.layoutMode !== 'NONE') out.css = flexCss(node)
	const kids = (node.children ?? []).filter(k => k.visible !== false)
	if (kids.length > 0) out.children = kids.map(reduceNode)
	return prune(out)
}

/**
 * Count nodes in a reduced tree — the one number worth printing in human mode.
 * @param {any} n
 * @returns {number}
 */
const countNodes = n => 1 + (n.children ?? []).reduce((acc, k) => acc + countNodes(k), 0)

// ── ls rendering ──────────────────────────────────────────────────────────

/**
 * name · type · id · w×h, one line per node. The id is the thing you copy into
 * `get` / `png`, so it is the only highlighted column.
 * @param {any} node
 * @param {number} depth
 * @returns {void}
 */
function printTree(node, depth) {
	const b = node.absoluteBoundingBox
	const dims = b ? `${Math.round(b.width)}×${Math.round(b.height)}` : ''
	process.stdout.write(
		`${'  '.repeat(depth)}${c(BOLD, node.name)} ${c(DIM, node.type)}  ${c(YELLOW, node.id)}  ${c(DIM, dims)}\n`,
	)
	for (const child of node.children ?? []) printTree(child, depth + 1)
}

/**
 * Same tree, machine shape. Kept separate from printTree so neither grows an
 * `if (json)` branch.
 * @param {any} node
 * @returns {object}
 */
function jsonTree(node) {
	const b = node.absoluteBoundingBox
	return prune({
		id: node.id,
		name: node.name,
		type: node.type,
		w: b ? Math.round(b.width) : undefined,
		h: b ? Math.round(b.height) : undefined,
		children: (node.children ?? []).map(jsonTree),
	})
}

// ── cli ───────────────────────────────────────────────────────────────────

const USAGE = `figma.mjs — read design values out of a Figma file.

  node /opt/devcontainer/base/skills/visual-loop/scripts/figma.mjs ls [--depth ${DEFAULT_DEPTH}]        page / frame tree, with ids
  node /opt/devcontainer/base/skills/visual-loop/scripts/figma.mjs get <node-id|url>     reduced design JSON → .tmp/design/
  node /opt/devcontainer/base/skills/visual-loop/scripts/figma.mjs png <node-id|url>     reference render   → .tmp/design/
  node /opt/devcontainer/base/skills/visual-loop/scripts/figma.mjs projects --team <id>  discovery helper
  node /opt/devcontainer/base/skills/visual-loop/scripts/figma.mjs files <project-id>    discovery helper, returns file keys

Options
  --key <k>      file key ; defaults to FIGMA_FILE_KEY, or read from a pasted URL
  --team <id>    team id ; defaults to FIGMA_TEAM_ID (projects only)
  --depth <n>    tree depth. 1 = pages, 2 = + top-level frames. Raise to descend.
                 On \`get\` it is passed to the API, so Figma truncates server-side,
                 and it defaults to ${DEFAULT_GET_DEPTH} — omitting it entirely would fetch the
                 whole subtree, which is the most expensive call there is.
  --scale <n>    png render scale, default ${DEFAULT_SCALE}
  --force        refetch even if this key+node+depth is already on disk
  --json         one JSON blob on stdout, no human output
  --help, -h     this text

\`get\` results are cached by key+node+depth, and a 429 writes a lock that makes
the NEXT invocation refuse to call at all — calling during a lock is what
escalates Figma's limit tier. To read the document with no quota cost at all,
use the local plugin in scripts/figma-plugin/.

Node ids are accepted in both forms — the URL shows \`195-2\`, the API wants
\`195:2\`. Any <node-id> may instead be a full Figma URL, in which case the file
key is taken from it too (an explicit --key still wins).

Requires FIGMA_TOKEN in .devcontainer/.env and api.figma.com allowed in
.devcontainer/firewall/domains.local.txt.
`

/**
 * Hand-rolled argv parsing — the repo does not use node:util parseArgs.
 * @param {string[]} argv
 * @returns {object}
 */
function parseArgs(argv) {
	const o = {
		cmd: '',
		key: undefined,
		team: undefined,
		depth: undefined,
		scale: DEFAULT_SCALE,
		json: false,
		force: false,
	}
	const positionals = []
	const values = { '--key': 'key', '--team': 'team' }
	const numbers = { '--depth': 'depth', '--scale': 'scale' }
	let rest = false

	for (let i = 2; i < argv.length; i++) {
		const a = argv[i]
		if (rest) {
			positionals.push(a)
		} else if (a === '--') {
			rest = true
		} else if (values[a]) {
			o[values[a]] = argv[++i]
		} else if (numbers[a]) {
			o[numbers[a]] = Number(argv[++i])
		} else if (a === '--json') {
			o.json = true
		} else if (a === '--force') {
			o.force = true
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

	o.cmd = positionals[0] ?? ''
	o.arg = positionals[1] ?? ''
	// A pasted URL supplies both key and id ; an explicit --key still wins.
	const parsed = fromUrl(o.arg)
	if (parsed) {
		o.key = o.key ?? parsed.key
		o.arg = parsed.id ?? ''
	}
	return o
}

/**
 * `ls` — the page / frame tree, which is how a node id gets found in the first
 * place without asking a human for it.
 * @param {object} o
 * @returns {Promise<void>}
 */
async function cmdLs(o) {
	const key = need(o.key, 'FIGMA_FILE_KEY', 'key', 'the key is the path segment after /design/ in a Figma file URL.')
	const depth = o.depth ?? DEFAULT_DEPTH
	const file = await figmaGet(`/v1/files/${encodeURIComponent(key)}?depth=${depth}`)
	// Iterate document.children, not document — the file node itself is always
	// 0:0 with no box and would only add a useless root line.
	const pages = file.document?.children ?? []
	if (o.json) {
		process.stdout.write(
			`${JSON.stringify({ key, name: file.name, lastModified: file.lastModified, depth, pages: pages.map(jsonTree) }, null, 2)}\n`,
		)
		return
	}
	process.stdout.write(`${c(BOLD, file.name)}  ${c(DIM, `depth ${depth} · key ${key}`)}\n\n`)
	for (const page of pages) printTree(page, 0)
}

/**
 * `get` — the detail pass. Writes the reduced tree and prints a short summary ;
 * the full blob only reaches stdout under --json, because dumping thousands of
 * JSON lines into a terminal is not "human output".
 * @param {object} o
 * @returns {Promise<void>}
 */
async function cmdGet(o) {
	const key = need(o.key, 'FIGMA_FILE_KEY', 'key', 'the key is the path segment after /design/ in a Figma file URL.')
	if (!o.arg) die(EXIT_USAGE, 'get needs a <node-id> (or a Figma URL).')
	const id = normalizeId(o.arg)
	const depth = o.depth ?? DEFAULT_GET_DEPTH

	// Same key + node + depth was already fetched : re-read it off disk. The
	// quota is credit-based, so the cheapest call is the one not made — and a
	// rerun of an identical command is the commonest way to waste credits.
	const cacheKey = `${key}|${id}|${depth}`
	const cache = readJsonOr(CACHE_FILE, {})
	const cached = cache[cacheKey]
	if (cached && !o.force && existsSync(cached)) {
		report(o, key, id, cached, readJsonOr(cached, {}), true)
		return
	}

	if (o.depth === undefined && !o.json) {
		process.stderr.write(`${c(DIM, `depth defaulted to ${depth} — pass --depth to descend further`)}\n`)
	}
	const res = await fetchNodes(key, encodeURIComponent(id), depth)
	const doc = res.nodes?.[id]?.document
	if (!doc) die(EXIT_FAIL, `node ${id} not found in file ${key}.\n  → run \`wtf claude script figma -- ls\` to list the available ids.`)
	const reduced = reduceNode(doc)
	const dest = join(OUT_DIR, `${slugify(id, doc.name)}.json`)
	mkdirSync(OUT_DIR, { recursive: true })
	writeFileSync(dest, `${JSON.stringify(reduced, null, 2)}\n`)
	cache[cacheKey] = dest
	writeFileSync(CACHE_FILE, `${JSON.stringify(cache, null, 2)}\n`)
	report(o, key, id, dest, reduced, false)
}

/**
 * The `get` summary, shared by the fetched and the cached path so the two can
 * never drift apart.
 * @param {object} o
 * @param {string} key
 * @param {string} id
 * @param {string} dest
 * @param {object} reduced
 * @param {boolean} fromCache
 */
function report(o, key, id, dest, reduced, fromCache) {
	if (o.json) {
		process.stdout.write(
			`${JSON.stringify({ key, id, file: dest, nodes: countNodes(reduced), cached: fromCache, design: reduced }, null, 2)}\n`,
		)
		return
	}
	const tag = fromCache ? c(DIM, ' (cached — no API call ; --force to refetch)') : ''
	process.stdout.write(`${c(GREEN, '✓')} ${dest} ${c(DIM, `(${countNodes(reduced)} nodes)`)}${tag}\n`)
	process.stdout.write(`  ${c(BOLD, reduced.name)} ${c(DIM, reduced.type)}  ${c(YELLOW, id)}\n`)
	if (reduced.box) process.stdout.write(`  ${c(DIM, `${reduced.box.w}×${reduced.box.h}`)}\n`)
	if (reduced.css) process.stdout.write(`  ${reduced.css}\n`)
}

/**
 * `png` — the reference render. The extra /nodes call buys the node name for
 * the filename AND validates the id before spending a render on it.
 * @param {object} o
 * @returns {Promise<void>}
 */
async function cmdPng(o) {
	const key = need(o.key, 'FIGMA_FILE_KEY', 'key', 'the key is the path segment after /design/ in a Figma file URL.')
	if (!o.arg) die(EXIT_USAGE, 'png needs a <node-id> (or a Figma URL).')
	const id = normalizeId(o.arg)
	const meta = await fetchNodes(key, encodeURIComponent(id), 1)
	const name = meta.nodes?.[id]?.document?.name
	if (!name) die(EXIT_FAIL, `node ${id} not found in file ${key}.\n  → run \`wtf claude script figma -- ls\` to list the available ids.`)

	const res = await figmaGet(
		`/v1/images/${encodeURIComponent(key)}?ids=${encodeURIComponent(id)}&format=png&scale=${o.scale}`,
	)
	// This endpoint answers 200 with an `err` field, and images[id] can be null
	// when the render failed. res.ok proves nothing here.
	if (res.err) die(EXIT_FAIL, `Figma could not render ${id} : ${res.err}`)
	const url = res.images?.[id]
	if (!url) die(EXIT_FAIL, `Figma returned no image for ${id} — the node may be too large or not renderable.`)

	const dest = join(OUT_DIR, `${slugify(id, name)}.png`)
	const bytes = await download(url, dest)
	const host = new URL(url).hostname
	if (o.json) {
		process.stdout.write(`${JSON.stringify({ key, id, name, file: dest, bytes, scale: o.scale, host }, null, 2)}\n`)
		return
	}
	process.stdout.write(
		`${c(GREEN, '✓')} ${dest} ${c(DIM, `(${Math.round(bytes / 1024)} KB @${o.scale}x from ${host})`)}\n`,
	)
}

/**
 * `projects` / `files` — discovery helpers, only needed when the file key is
 * not already known. With FIGMA_FILE_KEY set they are never on the critical path.
 * @param {object} o
 * @returns {Promise<void>}
 */
async function cmdDiscover(o) {
	if (o.cmd === 'projects') {
		const team = need(
			o.team,
			'FIGMA_TEAM_ID',
			'team',
			'read it off figma.com/files/team/<TEAM_ID>/… — Figma has no list-my-teams endpoint.',
		)
		const res = await figmaGet(`/v1/teams/${encodeURIComponent(team)}/projects`)
		if (o.json) {
			process.stdout.write(`${JSON.stringify(res, null, 2)}\n`)
			return
		}
		for (const p of res.projects ?? []) process.stdout.write(`${c(YELLOW, p.id)}  ${p.name}\n`)
		return
	}
	if (!o.arg) die(EXIT_USAGE, 'files needs a <project-id>.\n  → get one from `wtf claude script figma -- projects --team <id>`.')
	const res = await figmaGet(`/v1/projects/${encodeURIComponent(o.arg)}/files`)
	if (o.json) {
		process.stdout.write(`${JSON.stringify(res, null, 2)}\n`)
		return
	}
	for (const f of res.files ?? []) process.stdout.write(`${c(YELLOW, f.key)}  ${f.name}\n`)
}

async function main() {
	const o = parseArgs(process.argv)
	if (o.cmd) requireToken()
	switch (o.cmd) {
		case 'ls': {
			await cmdLs(o)
			break
		}
		case 'get': {
			await cmdGet(o)
			break
		}
		case 'png': {
			await cmdPng(o)
			break
		}
		case 'projects':
		case 'files': {
			await cmdDiscover(o)
			break
		}
		default: {
			process.stderr.write(o.cmd ? `unknown subcommand: ${o.cmd}\n\n${USAGE}` : USAGE)
			process.exit(o.cmd ? EXIT_USAGE : EXIT_OK)
		}
	}
}

main()
	.then(() => process.exit(EXIT_OK))
	.catch(err => {
		process.stderr.write(`${c(RED, 'figma:')} ${err?.stack ?? err}\n`)
		process.exit(EXIT_FAIL)
	})
