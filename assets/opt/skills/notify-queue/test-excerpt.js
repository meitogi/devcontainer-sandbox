#!/usr/bin/env node
// test-excerpt.js — assertions for hook.js excerpt + decode helpers.
//
// Run: `node .devcontainer/skills/notify-queue/test-excerpt.js`
// Exits 0 on success, throws + non-zero on failure.

const assert = require('assert')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { excerptV1, excerptV2, decodeUnicodeEscapes, buildLine, resolveLaunchUrl, readLatestFocus, readPendingPermsTail } = require('./hook')

// 1. The reported mojibake : `\uXXXX` literals in a Recap line.
const reported =
	'Some prior text.\n\n**Recap** — Sources cit\\u00e9es, ' +
	'niveau de confiance d\\u00e9clar\\u00e9'
const out = excerptV2(reported)
assert.ok(out.includes('citées'),  `expected "citées" — got: ${out}`)
assert.ok(out.includes('déclaré'), `expected "déclaré" — got: ${out}`)
assert.ok(!out.includes('\\u'),    `unexpected "\\u" — got: ${out}`)

// 2. Raw UTF-8 must pass through untouched.
const ok = '**Recap** — Tests passants, é and — preserved'
assert.strictEqual(excerptV2(ok), 'Tests passants, é and — preserved')

// 3. V1 fallback also decodes.
const v1in = 'First usable line with caf\\u00e9 inside'
assert.ok(excerptV1(v1in).includes('café'),
	`V1 expected "café" — got: ${excerptV1(v1in)}`)

// 4. Conservative : escaped backslash before `u00e9` is left alone.
//    JS literal `'\\\\u00e9'` is the 6-char string `\\u00e9`.
assert.strictEqual(decodeUnicodeEscapes('\\\\u00e9'), '\\\\u00e9')

// 5. Other backslash sequences are not touched.
assert.strictEqual(decodeUnicodeEscapes('line1\\nline2'), 'line1\\nline2')
assert.strictEqual(decodeUnicodeEscapes('a\\\\b'),        'a\\\\b')

// 6. Surrogate pair (emoji) decodes to the right codepoint.
assert.strictEqual(decodeUnicodeEscapes('\\uD83D\\uDE00'), '😀')

// --- buildLine — session 8 sender + notif_id fields ---
//
// The daemon reads `line.sender` and `line.notif_id` from every queue
// line and threads them into `notif send --sender X --id Y`. Missing
// either would silently make `notif remove` unable to dismiss the
// banner later, so both must land on every event class.

const SID = '11111111-2222-3333-4444-555555555555'

const stop = buildLine('stop', {
	session_id:            SID,
	last_assistant_message: '**Recap** — Ok',
})
assert.strictEqual(stop.sender, 'default', 'stop.sender defaults to "default"')
assert.match(stop.notif_id, /^stop-11111111-\d+$/,
	`stop.notif_id shape: ${stop.notif_id}`)

const notif = buildLine('notification', {
	session_id:        SID,
	notification_type: 'permission_prompt',
	message:           'hi',
})
assert.strictEqual(notif.sender, 'default')
assert.match(notif.notif_id, /^notification-11111111-\d+$/)

const perm = buildLine('permission_request', {
	session_id: SID,
	tool_name:  'Bash',
	tool_input: { command: 'ls' },
})
assert.strictEqual(perm.sender, 'default')
assert.match(perm.notif_id, /^permission_request-11111111-\d+$/)
assert.deepStrictEqual(perm.tool_input, { command: 'ls' }, 'tool_input passes through')

const replied = buildLine('user_replied', { session_id: SID })
assert.strictEqual(replied.sender, 'default')
assert.match(replied.notif_id, /^user_replied-11111111-\d+$/)

// notif_id changes across invocations even for the same session/event —
// Date.now() ticks at millisecond resolution and the two calls straddle
// at least one tick under any realistic test scheduler.
const a = buildLine('stop', { session_id: SID, last_assistant_message: 'x' })
// Busy-wait until the clock ticks so uniqueness holds even on machines
// with a coarse Date.now (some CI runners round to 4 ms).
const t0 = Date.now()
while (Date.now() === t0) { /* spin briefly */ }
const b = buildLine('stop', { session_id: SID, last_assistant_message: 'x' })
assert.notStrictEqual(a.notif_id, b.notif_id, 'notif_id must be unique per invocation')

// --- resolveLaunchUrl — session-1 producer-launchurl ---
//
// Tested end-to-end via injectable historyDir + cachePath so we don't
// touch the real /tmp cache or ~/.vscode-server state. Each subtest
// gets its own tmpdir + tmpcache.

const REAL_HEX = '7b22686f737450617468223a222f566f6c756d65732f446174612f6465762f64' // truncated but valid hex
const REAL_AUTHORITY = 'dev-container+' + REAL_HEX
const ENTRIES_JSON = JSON.stringify({
	version: 1,
	resource: `vscode-remote://dev-container%2B${REAL_HEX}/workspace/foo.txt`,
	entries: [{ id: 'a.txt', timestamp: 123 }],
})

function tmpDir() {
	return fs.mkdtempSync(path.join(os.tmpdir(), 'notify-queue-test-'))
}

// 7. Cache hit → returns cached authority as-is, no scan needed.
{
	const dir = tmpDir()
	const cache = path.join(dir, 'cache')
	fs.writeFileSync(cache, REAL_AUTHORITY)
	const emptyHistory = path.join(dir, 'empty-history')
	fs.mkdirSync(emptyHistory)
	const url = resolveLaunchUrl(emptyHistory, cache)
	assert.strictEqual(url, `vscode://vscode-remote/${REAL_AUTHORITY}/workspace`,
		`cache hit expected — got: ${url}`)
}

// 8. Cache miss + populated history → extracts authority, writes cache.
{
	const dir = tmpDir()
	const cache = path.join(dir, 'cache')
	const history = path.join(dir, 'history')
	fs.mkdirSync(path.join(history, '-abcdef01'), { recursive: true })
	fs.writeFileSync(path.join(history, '-abcdef01', 'entries.json'), ENTRIES_JSON)
	const url = resolveLaunchUrl(history, cache)
	assert.strictEqual(url, `vscode://vscode-remote/${REAL_AUTHORITY}/workspace`,
		`scan expected — got: ${url}`)
	assert.strictEqual(fs.readFileSync(cache, 'utf8'), REAL_AUTHORITY,
		'cache should be written on successful scan')
}

// resolveAuthority has THREE layers: cache (L1), history scan (L2), and
// reconstruction from HOST_WORKSPACE_PATH (L3). Any test asserting "returns
// null" must neutralise L3, or it asserts nothing but the shape of the machine
// it runs on: tests 9 and 10 passed where the variable is unset and failed
// inside a devcontainer, which always sets it. L3 has its own test below.
function withoutHostPath(fn) {
	const saved = process.env.HOST_WORKSPACE_PATH
	delete process.env.HOST_WORKSPACE_PATH
	try {
		fn()
	} finally {
		if (saved !== undefined) process.env.HOST_WORKSPACE_PATH = saved
	}
}

// 9. Cache miss + empty history + no env → null.
withoutHostPath(() => {
	const dir = tmpDir()
	const cache = path.join(dir, 'cache')
	const history = path.join(dir, 'history')
	fs.mkdirSync(history)
	const url = resolveLaunchUrl(history, cache)
	assert.strictEqual(url, null, `empty history should return null — got: ${url}`)
	assert.strictEqual(fs.existsSync(cache), false,
		'cache should not be written on scan miss')
})

// 10. Cache miss + non-existent history dir + no env → null.
withoutHostPath(() => {
	const dir = tmpDir()
	const cache = path.join(dir, 'cache')
	const url = resolveLaunchUrl(path.join(dir, 'does-not-exist'), cache)
	assert.strictEqual(url, null, `missing history dir should return null — got: ${url}`)
})

// 11. Malformed cache → falls through to scan.
{
	const dir = tmpDir()
	const cache = path.join(dir, 'cache')
	fs.writeFileSync(cache, 'garbage-not-an-authority')
	const history = path.join(dir, 'history')
	fs.mkdirSync(path.join(history, '-abcdef01'), { recursive: true })
	fs.writeFileSync(path.join(history, '-abcdef01', 'entries.json'), ENTRIES_JSON)
	const url = resolveLaunchUrl(history, cache)
	assert.strictEqual(url, `vscode://vscode-remote/${REAL_AUTHORITY}/workspace`,
		`malformed cache should re-scan — got: ${url}`)
	assert.strictEqual(fs.readFileSync(cache, 'utf8'), REAL_AUTHORITY,
		'cache should be overwritten with valid authority')
}

// 12. Empty cache file → falls through to scan.
{
	const dir = tmpDir()
	const cache = path.join(dir, 'cache')
	fs.writeFileSync(cache, '')
	const history = path.join(dir, 'history')
	fs.mkdirSync(path.join(history, '-abcdef01'), { recursive: true })
	fs.writeFileSync(path.join(history, '-abcdef01', 'entries.json'), ENTRIES_JSON)
	const url = resolveLaunchUrl(history, cache)
	assert.strictEqual(url, `vscode://vscode-remote/${REAL_AUTHORITY}/workspace`,
		`empty cache should re-scan — got: ${url}`)
}

// 13. Subdir with entries.json that has no authority is skipped ;
//     scan continues into the next subdir.
{
	const dir = tmpDir()
	const cache = path.join(dir, 'cache')
	const history = path.join(dir, 'history')
	fs.mkdirSync(path.join(history, '-00000001'), { recursive: true })
	fs.mkdirSync(path.join(history, '-00000002'), { recursive: true })
	fs.writeFileSync(path.join(history, '-00000001', 'entries.json'),
		JSON.stringify({ version: 1, resource: 'file:///tmp/x' }))
	fs.writeFileSync(path.join(history, '-00000002', 'entries.json'), ENTRIES_JSON)
	const url = resolveLaunchUrl(history, cache)
	assert.strictEqual(url, `vscode://vscode-remote/${REAL_AUTHORITY}/workspace`,
		`should skip non-matching entries.json — got: ${url}`)
}

// 13b. L3 — both earlier layers miss, but HOST_WORKSPACE_PATH is set, so the
//      authority is reconstructed from env and cached. This layer had no test
//      at all, which is exactly why tests 9/10 could assert "no fallback"
//      against a resolver that has one.
{
	const dir = tmpDir()
	const cache = path.join(dir, 'cache')
	const history = path.join(dir, 'history')
	fs.mkdirSync(history)
	const saved = process.env.HOST_WORKSPACE_PATH
	process.env.HOST_WORKSPACE_PATH = '/Volumes/Data/dev/demo-project'
	try {
		const url = resolveLaunchUrl(history, cache)
		assert.ok(url && url.startsWith('vscode://vscode-remote/dev-container+'),
			`L3 should reconstruct from env — got: ${url}`)
		const hex = url.slice('vscode://vscode-remote/dev-container+'.length).replace('/workspace', '')
		const payload = JSON.parse(Buffer.from(hex, 'hex').toString('utf8'))
		assert.strictEqual(payload.hostPath, '/Volumes/Data/dev/demo-project',
			'reconstructed payload should carry the host path it was given')
		assert.strictEqual(fs.readFileSync(cache, 'utf8'), `dev-container+${hex}`,
			'L3 should write its result to the cache')
	} finally {
		if (saved === undefined) delete process.env.HOST_WORKSPACE_PATH
		else process.env.HOST_WORKSPACE_PATH = saved
	}
}

// --- readLatestFocus — session 4 focus-aware-delivery ---
//
// hook.js reads pending-perms.jsonl (written by the extension patch
// `outbound-action-injector.py`) tail-first and returns the most recent
// `focused` boolean. buildLine attaches it as `line.focused` on every
// dispatch event so the daemon can debounce banners when the host VS
// Code window is focused.

function pendingPermsFixture(lines) {
	const dir = tmpDir()
	const file = path.join(dir, 'pending-perms.jsonl')
	fs.writeFileSync(file, lines.map(l => JSON.stringify(l)).join('\n') + '\n')
	return file
}

// 13. Tail-first scan — returns the LAST entry's focused, not the first.
{
	const file = pendingPermsFixture([
		{ ts: '2026-07-12T10:00:00Z', focused: true,  active: true },
		{ ts: '2026-07-12T10:01:00Z', focused: false, active: false },
	])
	assert.strictEqual(readLatestFocus(file), false, 'latest entry (focused:false) wins')
}

// 14. Skips entries without a `focused` field (session_boot markers, etc).
{
	const file = pendingPermsFixture([
		{ ts: '2026-07-12T10:00:00Z', focused: true },
		{ ts: '2026-07-12T10:01:00Z', ev: 'session_boot' },
	])
	assert.strictEqual(readLatestFocus(file), true, 'session_boot marker skipped, focused:true from prior entry returned')
}

// 15. Missing file → null (fresh boot before the extension patch runs).
{
	const dir = tmpDir()
	assert.strictEqual(readLatestFocus(path.join(dir, 'does-not-exist.jsonl')), null,
		'missing pending-perms.jsonl → null (fail-open at daemon side)')
}

// 16. Empty file → null.
{
	const dir = tmpDir()
	const file = path.join(dir, 'empty.jsonl')
	fs.writeFileSync(file, '')
	assert.strictEqual(readLatestFocus(file), null, 'empty file → null')
}

// 17. Malformed JSON lines are skipped ; the last valid focused entry wins.
{
	const dir = tmpDir()
	const file = path.join(dir, 'malformed.jsonl')
	fs.writeFileSync(file, '{"focused":true}\n{not json at all\n{"focused":false\n')
	// Line 3 truncated ; line 2 not JSON ; only line 1 parses → true.
	assert.strictEqual(readLatestFocus(file), true, 'malformed lines skipped')
}

// 18. buildLine attaches line.focused when pending-perms yields a value.
{
	const file = pendingPermsFixture([
		{ ts: '2026-07-12T10:00:00Z', focused: true, active: true },
	])
	const stopLine = buildLine('stop', { session_id: SID, last_assistant_message: 'x' }, file)
	assert.strictEqual(stopLine.focused, true, 'stop.focused = latest pending-perms focused')

	const permLine = buildLine('permission_request', {
		session_id: SID, tool_name: 'Bash', tool_input: { command: 'ls' },
	}, file)
	assert.strictEqual(permLine.focused, true, 'permission_request.focused = latest pending-perms focused')
}

// 19. buildLine omits line.focused when pending-perms has no snapshot.
{
	const dir = tmpDir()
	const empty = path.join(dir, 'empty.jsonl')
	fs.writeFileSync(empty, '')
	const stopLine = buildLine('stop', { session_id: SID, last_assistant_message: 'x' }, empty)
	assert.strictEqual('focused' in stopLine, false, 'focused omitted when snapshot absent')
}

// 20. user_replied never reads pending-perms — it's a pure cancel signal.
{
	const file = pendingPermsFixture([{ ts: '2026-07-12T10:00:00Z', focused: true }])
	const replied = buildLine('user_replied', { session_id: SID }, file)
	assert.strictEqual('focused' in replied, false, 'user_replied never carries focused')
}

// --- readPendingPermsTail + buildLine.tool_use_id — session 5 smoke fix ---
//
// The Claude Code PermissionRequest hook payload does not carry the
// ext-side requestId that outbound-action-injector.py expects on the
// ack path. Sourced from pending-perms.jsonl instead : latest record
// with `settled:false`, matching sessionId, non-empty requestId wins.

const REQ_ID = 'cfa581dae6fc206ce21ce8ad3bf8d7a8'

// 21. readPendingPermsTail returns both focused and requestId in one scan.
{
	const file = pendingPermsFixture([
		{ ts: '2026-07-12T10:00:00Z', sessionId: SID, requestId: REQ_ID, focused: true, settled: false },
	])
	const t = readPendingPermsTail(file, SID)
	assert.strictEqual(t.focused,   true,   'tail focused = latest boolean')
	assert.strictEqual(t.requestId, REQ_ID, 'tail requestId = latest settled:false matching sid')
}

// 22. readPendingPermsTail ignores settled:true records for requestId.
{
	const file = pendingPermsFixture([
		{ ts: '2026-07-12T10:00:00Z', sessionId: SID, requestId: REQ_ID, focused: false, settled: false },
		{ ts: '2026-07-12T10:00:05Z', sessionId: SID, requestId: REQ_ID, focused: false, settled: true, outcome: 'allow' },
	])
	const t = readPendingPermsTail(file, SID)
	assert.strictEqual(t.requestId, null, 'settled:true → requestId not returned (perm already resolved)')
	assert.strictEqual(t.focused,   false, 'focused still resolves from either record')
}

// 23. readPendingPermsTail filters by sid — non-matching sessions ignored.
{
	const file = pendingPermsFixture([
		{ ts: '2026-07-12T10:00:00Z', sessionId: 'other-sid', requestId: 'other-req', focused: true, settled: false },
	])
	const t = readPendingPermsTail(file, SID)
	assert.strictEqual(t.requestId, null, 'requestId for a different sessionId is not returned')
}

// 24. buildLine attaches line.tool_use_id from pending-perms.requestId.
{
	const file = pendingPermsFixture([
		{ ts: '2026-07-12T10:00:00Z', sessionId: SID, requestId: REQ_ID, focused: true, settled: false },
	])
	const perm = buildLine('permission_request', {
		session_id: SID, tool_name: 'Bash', tool_input: { command: 'ls' },
	}, file)
	assert.strictEqual(perm.tool_use_id, REQ_ID,
		'permission_request.tool_use_id = latest pending-perms requestId (settled:false, matching sid)')
}

// 25. buildLine omits line.tool_use_id when pending-perms has no matching entry.
{
	const dir = tmpDir()
	const empty = path.join(dir, 'empty.jsonl')
	fs.writeFileSync(empty, '')
	const perm = buildLine('permission_request', {
		session_id: SID, tool_name: 'Bash', tool_input: { command: 'ls' },
	}, empty)
	assert.strictEqual('tool_use_id' in perm, false,
		'tool_use_id omitted when pending-perms absent (daemon drops Allow button)')
}

// 26. buildLine ignores payload.tool_use_id — pending-perms is the only source.
//     (Guards against a future Claude Code version adding tool_use_id in the
//      hook payload : it would be the model-side `toolu_XXX`, wrong namespace.)
{
	const file = pendingPermsFixture([
		{ ts: '2026-07-12T10:00:00Z', sessionId: SID, requestId: REQ_ID, focused: true, settled: false },
	])
	const perm = buildLine('permission_request', {
		session_id: SID, tool_name: 'Bash', tool_input: { command: 'ls' },
		tool_use_id: 'toolu_01ABCDEFGH',
	}, file)
	assert.strictEqual(perm.tool_use_id, REQ_ID,
		'ext requestId wins even when payload provides its own tool_use_id')
}

// 27. The JSON floor. An agent asked to answer with "ONE JSON object and
//     nothing else" — the orchestration fix planner is, by contract — used to
//     have its whole blob rendered as a desktop banner body. A first usable
//     line that is machine output yields nothing rather than that.
{
	const blob = '{"units": [{"id": "login-rate-limit-key", "tier": "B", "owns": ["services/api/src/routes/auth.ts"]}]}'
	assert.strictEqual(excerptV2(blob), '', 'a JSON answer must not become a notification body')
	assert.strictEqual(excerptV1('[{"finding": 1}]'), '', 'a JSON array is machine output too')
	assert.strictEqual(excerptV1('```json\n{"a":1}\n```\nAnd then some prose.'),
		'And then some prose.',
		'a fenced blob is skipped by the fence rule, and the prose after it still wins')
	// A Recap still wins over the floor : it is the authoritative body, and it
	// is prose by construction.
	assert.strictEqual(excerptV2('{"a":1}\n\n**Recap** — Plan written, 4 units'),
		'Plan written, 4 units')
	// And prose that merely mentions a brace is not machine output.
	assert.strictEqual(excerptV1('The payload {"a":1} is what it sends.'),
		'The payload {"a":1} is what it sends.')
}

// 28. A machine-spawned session writes nothing here at all. Measured before
//     the marker existed : one fan-out of 51 headless sessions put thousands
//     of tool_started / tool_finished lines and a Stop banner per session into
//     this queue, burying the notification the human was waiting on. The hook
//     is executed as a child, because what is under test is the early return
//     in main(), not a helper.
{
	const { execFileSync } = require('child_process')
	const sid = 'spawned-hook-guard-test'
	const queued = path.join('/workspace/.devcontainer/notify/queue', `${sid}.jsonl`)
	try { fs.unlinkSync(queued) } catch (_) {}
	execFileSync(process.execPath, [path.join(__dirname, 'hook.js'), 'stop'], {
		input: JSON.stringify({ session_id: sid, last_assistant_message: 'STATUS: done' }),
		env: { ...process.env, NOTIFY_SUPPRESS_SESSION: 'wave/session-3-foo' },
	})
	assert.strictEqual(fs.existsSync(queued), false,
		'a machine-spawned session wrote into the human notification queue')

	// …and without the marker the same call still queues, so the guard is the
	// marker and not a dead hook.
	execFileSync(process.execPath, [path.join(__dirname, 'hook.js'), 'stop'], {
		input: JSON.stringify({ session_id: sid, last_assistant_message: 'All good.' }),
		env: { ...process.env, NOTIFY_SUPPRESS_SESSION: '' },
	})
	assert.strictEqual(fs.existsSync(queued), true, 'a human session must still be queued')
	const line = JSON.parse(fs.readFileSync(queued, 'utf8').trim().split('\n').pop())
	assert.strictEqual(line.last_message_excerpt, 'All good.')
	fs.unlinkSync(queued)
}

console.log('test-excerpt.js — all assertions passed')
