#!/usr/bin/env node
// notify-queue/hook.js — single dispatcher for the 4 hook events
// (Stop, Notification, PermissionRequest, UserPromptSubmit).
//
// Reads the Claude Code hook JSON payload on stdin, writes one
// best-effort JSONL line to .devcontainer/notify-queue/<sid>.jsonl
// for the host-side daemon (session 2+) to consume.
//
// Always exits 0 with empty stdout — observational only, never
// blocks or alters Claude behavior.

const fs = require('fs')
const path = require('path')

const QUEUE_DIR = '/workspace/.devcontainer/notify/queue'
const MAX_EXCERPT = 200

// Session 4 : pending-perms.jsonl is written by the VS Code extension patch
// `outbound-action-injector.py` at every tool_use permission cycle, with a
// `vscode.window.state` snapshot (`focused` / `active`). The container-side
// hook reads the latest snapshot to propagate the host window-focus state
// into every queue event — the daemon uses it to debounce banners when the
// user is engaged in VS Code. Trade-off : snapshots only refresh on
// permission cycles (~one every few tool_uses) ; between cycles the value
// is stale but still the best signal we have from the container side.
const PENDING_PERMS_PATH = '/workspace/.devcontainer/logs/claude-code-vscode-ext-pending-perms.jsonl'
const PENDING_PERMS_TAIL_BYTES = 64 * 1024

const ARG_TO_EVENT = {
	stop: 'stop',
	notification: 'notification',
	permission_request: 'permission_request',
	user_prompt_submit: 'user_replied',
	// PreToolUse fires the instant the tool STARTS — i.e. right after the
	// user clicked Allow on the permission dialog. Best signal to cancel
	// a pending permission timer (PostToolUse arrives later, after the
	// tool also finished — useless for slow tools).
	pre_tool_use:  'tool_started',
	// PostToolUse fires when the tool COMPLETES. Kept as a secondary
	// cancel signal in case PreToolUse is skipped for some reason.
	post_tool_use: 'tool_finished'
}

function truncate(str, max) {
	if (typeof str !== 'string') return ''
	if (str.length <= max) return str
	return str.slice(0, max - 1) + '…'
}

// Decode literal `\uXXXX` JSON-style escapes that a model may emit
// instead of raw UTF-8. Conservative: only `\u` followed by exactly
// 4 hex digits, and not preceded by another `\` (so `\\u00e9` — an
// escaped backslash before a `u00e9` literal — is left alone).
// Surrogate pairs decode correctly because each half is replaced
// independently and JS re-joins them in the result string.
function decodeUnicodeEscapes(s) {
	if (typeof s !== 'string') return s
	return s.replace(/(?<!\\)\\u([0-9a-fA-F]{4})/g,
		(_, hex) => String.fromCharCode(parseInt(hex, 16)))
}

// V2 : look for an explicit `**Recap** — <summary>` line near the end
// of the reply. Convention documented in CLAUDE-dev.md §14. Accepts
// em-dash (—), en-dash (–), or hyphen (-) as the separator. If the
// recap is present, that's the authoritative notif body. Otherwise
// fall back to the V1 heuristic.
function excerptV2(msg) {
	if (typeof msg !== 'string' || !msg) return ''
	const m = msg.match(/\*\*Recap\*\*\s*[—–-]\s*(.+?)\s*$/im)
	if (m && m[1]) return truncate(decodeUnicodeEscapes(m[1].trim()), MAX_EXCERPT)
	return excerptV1(msg)
}

// A line that is machine output, not a sentence. Measured : the
// orchestration fix planner is asked for "ONE JSON object and nothing
// else", so `{"units": [{"id": "…` became the body of a desktop
// banner; a review axis ends on `- **File** : services/…:144` for the
// same reason. Any turn ending on a JSON block has this defect, which
// is why the floor lives in the excerpt path and not in one caller.
function looksMachine(line) {
	if (line.startsWith('{') || line.startsWith('[')) return true
	// A bare JSON scalar or fragment — cheap parse, only ever on the
	// first candidate line, so this is not on any hot path.
	try {
		const value = JSON.parse(line)
		return typeof value === 'object' || typeof value === 'number' || typeof value === 'boolean'
	} catch {
		return false
	}
}

// V1 heuristic: extract a short, readable excerpt from a Claude
// markdown reply. Skip headers, code fences, tables, HTML comments,
// and any first line that is machine output rather than prose.
// Strip the first usable line's basic markdown syntax.
function excerptV1(msg) {
	if (typeof msg !== 'string' || !msg) return ''
	const lines = msg.split('\n')
	let inFence = false
	for (let raw of lines) {
		const line = raw.trim()
		if (!line) continue
		if (line.startsWith('```')) { inFence = !inFence; continue }
		if (inFence) continue
		if (line.startsWith('#')) continue
		if (line.startsWith('|')) continue
		if (line.startsWith('<!--')) continue
		if (looksMachine(line)) return ''
		// strip markdown: links, bold, italic, inline code
		let clean = line
			.replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
			.replace(/\*\*([^*]+)\*\*/g, '$1')
			.replace(/\*([^*]+)\*/g, '$1')
			.replace(/`([^`]+)`/g, '$1')
			.trim()
		if (clean) return truncate(decodeUnicodeEscapes(clean), MAX_EXCERPT)
	}
	return ''
}

function readStdin() {
	try {
		const buf = fs.readFileSync(0, 'utf8')
		return JSON.parse(buf)
	} catch {
		return null
	}
}

// Read Claude Code's session name from the transcript JSONL at
// `transcript_path` (one of the hook payload fields).
//
// Three candidates, in priority order (highest wins) :
//   1. `"customTitle": "DOING - ..."` — the user-edited title (set via
//      the Claude Code VS Code extension's tab rename). Most authoritative.
//   2. `"aiTitle": "Build macOS host notification daemon"` — auto-generated
//      by Claude at session start and refined after analysis turns.
//   3. `"slug": "session-1-shimmying-manatee"` — friendly auto-stub
//      present on every transcript line.
//
// Scan surface : we read the TAIL (256 KB) for customTitle (always
// re-emitted on every subsequent line once set) + recent aiTitle, AND
// the HEAD (64 KB) as a fallback for aiTitle — Claude Code writes
// aiTitle sparsely (sometimes only a handful of times per session,
// with the first occurrence typically within the first ~30 KB). A
// tail-only scan misses sessions where the transcript grew past
// 256 KB without rewriting aiTitle, falling back to slug incorrectly.
const TRANSCRIPT_TAIL_BYTES = 256 * 1024
const TRANSCRIPT_HEAD_BYTES =  64 * 1024

function readSessionName(transcriptPath) {
	if (!transcriptPath || typeof transcriptPath !== 'string') return ''
	let fd
	try {
		const stat = fs.statSync(transcriptPath)
		if (stat.size <= 0) return ''
		fd = fs.openSync(transcriptPath, 'r')

		const tailSize  = Math.min(stat.size, TRANSCRIPT_TAIL_BYTES)
		const tailStart = Math.max(0, stat.size - tailSize)
		const tailBuf   = Buffer.alloc(tailSize)
		fs.readSync(fd, tailBuf, 0, tailSize, tailStart)
		const tail = tailBuf.toString('utf8')

		// 1. customTitle — always re-emitted on every subsequent line.
		const custom = lastMatch(tail, /"customTitle"\s*:\s*"([^"]+)"/g)
		if (custom) return custom

		// 2. aiTitle — try tail, then head if missed (sparse writes).
		let ai = lastMatch(tail, /"aiTitle"\s*:\s*"([^"]+)"/g)
		if (!ai && tailStart > 0) {
			const headSize = Math.min(tailStart, TRANSCRIPT_HEAD_BYTES)
			const headBuf  = Buffer.alloc(headSize)
			fs.readSync(fd, headBuf, 0, headSize, 0)
			ai = lastMatch(headBuf.toString('utf8'),
				/"aiTitle"\s*:\s*"([^"]+)"/g)
		}
		if (ai) return ai

		// 3. Slug — legit fallback only before the first aiTitle is written.
		return lastMatch(tail, /"slug"\s*:\s*"([^"]+)"/g) || ''
	} catch (_) { return '' }
	finally { if (fd !== undefined) try { fs.closeSync(fd) } catch (_) {} }
}

// Last capture group of a global regex, or '' if none matched.
function lastMatch(text, re) {
	let last = ''
	for (const m of text.matchAll(re)) if (m[1]) last = m[1]
	return last
}

// Resolve the container's `vscode-remote://` launch URL, so downstream
// consumers can `open` it without any cross-container authority
// lookup. The authority string (`dev-container+<hex>`) encodes the
// host workspace path + Docker context — the container can scavenge
// it from VS Code's own local history instead of recomputing it (it
// doesn't know `localDocker` / `settings.context` first-hand).
//
// Three layers, ranked by ground-truth fidelity :
//   L1. `<QUEUE_DIR>/.authority` — written by the Claude Code
//       extension's authority-writer patch at activation, sourced from
//       `vscode.workspace.workspaceFolders[0].uri.authority` (VS Code's
//       own API, 100% correct). Bind-mounted (visible from host for
//       debug) ; rewritten on every extension activation.
//   L2. History scan — enumerate
//       ~/.vscode-server/data/User/History/*/entries.json for
//       `dev-container%2B[0-9a-f]+`. Fallback when the patch hasn't
//       fired yet (very early hook fires) or is uninstalled. All
//       entries in one session share the authority — first match wins.
//   L3. Reconstruct — bit-exact rebuild from HOST_WORKSPACE_PATH env.
//       Matches what the Dev Containers extension emits on macOS /
//       Windows Docker Desktop. Two env overrides for atypical setups
//       (Linux plain daemon, Podman) : DEVCONTAINER_DOCKER_CONTEXT
//       (default "desktop-linux") and DEVCONTAINER_LOCAL_DOCKER
//       (default "false"). Bit-exact reconstruction is required — VS
//       Code's URL handler compares authority strings verbatim.
//
// Returns full URL (`vscode://vscode-remote/<authority>/workspace`) or
// null. If all three layers fail, the daemon gets no launchUrl and the
// body-click becomes a no-op (session 2's contract).
const AUTHORITY_CACHE = path.join(QUEUE_DIR, '.authority')
const AUTHORITY_PREFIX = 'dev-container+'
const HISTORY_DIR = process.env.HOME
	? path.join(process.env.HOME, '.vscode-server/data/User/History')
	: null

function resolveLaunchUrl(historyDir = HISTORY_DIR, cachePath = AUTHORITY_CACHE) {
	try {
		const authority = resolveAuthority(historyDir, cachePath)
		return authority ? `vscode://vscode-remote/${authority}/workspace` : null
	} catch { return null }
}

function resolveAuthority(historyDir, cachePath) {
	// L1 — extension-written cache.
	try {
		const cached = fs.readFileSync(cachePath, 'utf8').trim()
		if (cached.startsWith(AUTHORITY_PREFIX) &&
			/^[0-9a-fA-F]+$/.test(cached.slice(AUTHORITY_PREFIX.length))) {
			return cached
		}
	} catch { /* miss — fall through */ }

	// L2 — History scan.
	if (historyDir) {
		let entries
		try { entries = fs.readdirSync(historyDir) } catch { entries = [] }
		const rx = /dev-container%2B([0-9a-fA-F]+)/
		for (const dir of entries) {
			const p = path.join(historyDir, dir, 'entries.json')
			let content
			try { content = fs.readFileSync(p, 'utf8') } catch { continue }
			const m = content.match(rx)
			if (!m) continue
			const authority = AUTHORITY_PREFIX + m[1].toLowerCase()
			try { fs.writeFileSync(cachePath, authority) } catch { /* best-effort */ }
			return authority
		}
	}

	// L3 — reconstruction from env.
	const reconstructed = reconstructAuthority()
	if (reconstructed) {
		try { fs.writeFileSync(cachePath, reconstructed) } catch { /* best-effort */ }
		return reconstructed
	}
	return null
}

// Bit-exact rebuild of the `dev-container+<hex>` authority from the
// container-side env. Shape reference : URI.toJSON in vscode core
// (src/vs/base/common/uri.ts) — configFile key order is `$mid → fsPath
// → _sep? → external → path → scheme`. `_sep: 1` is emitted only when
// the fsPath uses backslash separators (Windows host). Outer payload
// order (hostPath, localDocker, settings, configFile) matches what the
// closed-source Dev Containers extension emits, verified against a
// captured ground truth (see docstring on resolveAuthority).
function reconstructAuthority() {
	const hostPath = process.env.HOST_WORKSPACE_PATH
	if (!hostPath) return null
	const isWinHost = /^[A-Za-z]:[\\/]/.test(hostPath)
	const sep = isWinHost ? '\\' : '/'
	const cfg = hostPath + sep + '.devcontainer' + sep + 'devcontainer.json'
	const configFile = { $mid: 1, fsPath: cfg }
	if (isWinHost) configFile._sep = 1
	const cfgUri = isWinHost ? cfg.replace(/\\/g, '/') : cfg
	configFile.external = 'file://' + (isWinHost ? '/' : '') + cfgUri
	configFile.path = (isWinHost ? '/' : '') + cfgUri
	configFile.scheme = 'file'
	const payload = {
		hostPath,
		localDocker: process.env.DEVCONTAINER_LOCAL_DOCKER === 'true',
		settings: { context: process.env.DEVCONTAINER_DOCKER_CONTEXT || 'desktop-linux' },
		configFile,
	}
	const hex = Buffer.from(JSON.stringify(payload), 'utf8').toString('hex')
	return AUTHORITY_PREFIX + hex
}

// Scan the tail of pending-perms.jsonl for two pieces of state:
//
//   - `focused`  — latest boolean seen, any session (drives daemon debounce).
//   - `requestId` — latest ext-side `requestId` from a `settled:false` record
//     whose `sessionId` matches the caller-provided sid (drives daemon's
//     `--on-action Allow:file:…` binding for permission_request events).
//
// Both are extracted from a single backward tail-scan. Returns
// `{ focused, requestId }` with either field null when not found (fresh boot
// before the first perm cycle, file absent, parse failure, no matching sid).
//
// Why sourced from pending-perms and not the Claude Code hook payload : the
// `PermissionRequest` hook doesn't provide the ext's `requestId` (its
// `tool_use_id`, if present, would be the model-side `toolu_XXX`, which is a
// disjoint ID space from the ext's channel-level requestId that
// `outbound-action-injector.py` expects on the ack path).
//
// Reads at most PENDING_PERMS_TAIL_BYTES from the end of the file : one entry
// per perm cycle keeps the working set small, and the extension patch wipes
// the file on every container start so it never accumulates across boots.
function readPendingPermsTail(pendingPath = PENDING_PERMS_PATH, sid = null, tailBytes = PENDING_PERMS_TAIL_BYTES) {
	let fd
	try {
		const stat = fs.statSync(pendingPath)
		if (stat.size <= 0) return { focused: null, requestId: null }
		fd = fs.openSync(pendingPath, 'r')
		const size  = Math.min(stat.size, tailBytes)
		const start = Math.max(0, stat.size - size)
		const buf   = Buffer.alloc(size)
		fs.readSync(fd, buf, 0, size, start)
		const text  = buf.toString('utf8')
		const lines = text.split('\n')
		let focused = null
		let requestId = null
		// Once a record matching the caller's sid is seen with a boolean
		// `settled`, its state is the "current" perm state — a `settled:true`
		// closes out any earlier `settled:false` for the same request. So
		// the first hit backward that carries `settled` for our sid decides
		// whether requestId is emitted or not.
		let permDecidedForSid = false
		for (let i = lines.length - 1; i >= 0; i--) {
			const raw = lines[i].trim()
			if (!raw) continue
			let evt
			try { evt = JSON.parse(raw) } catch { continue }
			if (focused === null && typeof evt.focused === 'boolean') {
				focused = evt.focused
			}
			if (!permDecidedForSid
				&& typeof evt.settled === 'boolean'
				&& (!sid || evt.sessionId === sid)) {
				permDecidedForSid = true
				if (evt.settled === false
					&& typeof evt.requestId === 'string' && evt.requestId) {
					requestId = evt.requestId
				}
			}
			if (focused !== null && permDecidedForSid) break
		}
		return { focused, requestId }
	} catch { return { focused: null, requestId: null } }
	finally { if (fd !== undefined) try { fs.closeSync(fd) } catch (_) {} }
}

// Backward-compat wrapper — session 4 shipped `readLatestFocus` in the public
// export ; kept as a thin shim over `readPendingPermsTail` so existing callers
// and tests don't have to migrate. New code should call the tail directly.
function readLatestFocus(pendingPath = PENDING_PERMS_PATH, tailBytes = PENDING_PERMS_TAIL_BYTES) {
	return readPendingPermsTail(pendingPath, null, tailBytes).focused
}

function buildLine(eventName, payload, pendingPath = PENDING_PERMS_PATH) {
	const sid = payload.session_id
	if (!sid) return null

	const line = {
		ts: new Date().toISOString(),
		sid,
		event: eventName
	}

	// Sender + notif_id — v0.2 additions consumed by the notifier
	// (via `notif send --sender X --id Y`) so the daemon can later
	// dismiss the exact banner on cancel events via `notif remove`.
	// Sender is always `default` in v0.2 ; per-event routing (claude
	// vs npm-script vs …) is a future extension. notif_id is unique
	// per hook invocation — millisecond-resolution Date.now() crossed
	// with the 8-char sid and the event class.
	line.sender = 'default'
	line.notif_id = `${eventName}-${sid.slice(0, 8)}-${Date.now()}`

	// Attach Claude Code's session name (aiTitle from the transcript,
	// falls back to the auto-generated slug). Absent when no transcript.
	const name = readSessionName(payload.transcript_path)
	if (name) line.session_name = name

	// Attach the container's vscode-remote launch URL when resolvable
	// (see resolveLaunchUrl). Absent on fresh boot before VS Code has
	// written any history file — daemon body-click no-ops in that
	// window (session 2 contract).
	const launchUrl = resolveLaunchUrl()
	if (launchUrl) line.launchUrl = launchUrl

	// Attach the latest host window-focus snapshot and — for permission
	// events — the ext's pending requestId, both sourced from pending-perms.jsonl
	// via a single backward tail-scan. user_replied is a pure cancel signal
	// and needs neither. Absent field → daemon treats as "not focused" and
	// fires immediately ; missing requestId → daemon drops the Allow button
	// (no way to route the ack).
	let pending = { focused: null, requestId: null }
	if (eventName !== 'user_replied') {
		pending = readPendingPermsTail(pendingPath, sid)
		if (pending.focused !== null) line.focused = pending.focused
	}

	if (eventName === 'stop') {
		line.last_message_excerpt = excerptV2(payload.last_assistant_message)
	} else if (eventName === 'notification') {
		line.notification_type = payload.notification_type || ''
		line.message = truncate(payload.message || '', MAX_EXCERPT)
	} else if (eventName === 'permission_request') {
		// tool_use_id is the ext-side `requestId` (see readPendingPermsTail
		// docstring) — the daemon writes it as `requestId` on the outbound
		// tool_permission_response, which is what outbound-action-injector.py
		// matches against pending permissions. Sourced from pending-perms
		// only ; the Claude Code hook payload does not carry it.
		if (pending.requestId) line.tool_use_id = pending.requestId
		line.tool_name = payload.tool_name || ''
		// Pass-through: emit tool_input verbatim as an object. Any
		// formatting (per-tool summary, truncation, JSON pretty-print)
		// is the consumer's job — keeps the hook stable when consumers
		// evolve or new tools need a custom render.
		if (payload.tool_input !== undefined) line.tool_input = payload.tool_input
	}
	// user_replied carries no extra fields — the event itself is the signal.

	return line
}

// Spawn a detached node child that tails the transcript looking for a
// "user clicked Cancel" pattern. The child runs ~60 s and exits silently
// if no cancel is detected. When detected, it appends a `tool_cancelled`
// event to the queue so the daemon can cancel the pending perm timer.
//
// Necessary because Claude Code has no "PermissionDenied" hook —
// PostToolUse doesn't fire on Cancel since the tool never runs.
function spawnCancelTailer(sid, transcriptPath) {
	if (!sid || !transcriptPath) return
	try {
		const { spawn } = require('child_process')
		const child = spawn(process.argv[0], [
			path.join(__dirname, 'tail-cancel.js'),
			sid,
			transcriptPath
		], { detached: true, stdio: 'ignore' })
		child.unref()
	} catch { /* swallow */ }
}

function main() {
	try {
		// A machine-spawned session is not a human's. It inherits these hooks
		// like any other session, so a fan-out — wave-run.sh, an orchestration
		// daemon, any headless batch — writes thousands of tool_started /
		// tool_finished lines into this queue plus a Stop banner per worker,
		// and buries the notification the human was actually waiting on. The
		// spawner owns its own progress reporting ; this keeps the queue for
		// the sessions the human is sitting in front of.
		if (process.env.NOTIFY_SUPPRESS_SESSION) return
		const arg = process.argv[2] || ''
		const eventName = ARG_TO_EVENT[arg]
		if (!eventName) return
		const payload = readStdin()
		if (!payload) return

		fs.mkdirSync(QUEUE_DIR, { recursive: true })

		const line = buildLine(eventName, payload)
		if (!line) return
		const file = path.join(QUEUE_DIR, `${line.sid}.jsonl`)
		fs.appendFileSync(file, JSON.stringify(line) + '\n')

		// Permission dialog opened → start tailing for a Cancel decision.
		if (eventName === 'permission_request') {
			spawnCancelTailer(line.sid, payload.transcript_path)
		}
	} catch {
		// swallow — emitter must never break Claude
	}
}

if (require.main === module) main()

module.exports = { excerptV1, excerptV2, decodeUnicodeEscapes, buildLine, resolveLaunchUrl, readLatestFocus, readPendingPermsTail, AUTHORITY_CACHE, PENDING_PERMS_PATH }
