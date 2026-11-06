// cdp.test.mjs — the endpoint cdp.mjs drives : the agent browser by default
// (`agent-browser route`, a stub here), CDP_HOST / CDP_PORT when set ; the lock
// follows it ; exit 3 keeps its code and its hint. Each case in a child process,
// since the route is asked once per process. No browser needed.
//
//   node --test /opt/devcontainer/base/skills/visual-loop/lib/cdp.test.mjs
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test, { after } from 'node:test'
import { fileURLToPath } from 'node:url'

const HERE = fileURLToPath(new URL('../scripts/', import.meta.url))
const TMP = mkdtempSync(join(tmpdir(), 'cdp-test-'))
after(() => rmSync(TMP, { recursive: true, force: true }))
const LOG = join(TMP, 'agent-browser.log')
// The stub : `route` answers STUB_ROUTE (or exits 3 like the real one when
// nothing answers), every call is logged.
writeFileSync(
	join(TMP, 'agent-browser'),
	`#!/bin/sh
echo "$*" >>"${LOG}"
for v; do verb=$v; [ "$v" = route ] || [ "$v" = up ] && break; done
case $verb in
	route)
		[ "$STUB_ROUTE" = none ] && { echo "✗ no agent browser a answers" >&2; exit 3; }
		echo "$STUB_ROUTE" ;;
	up) echo "host: running 1 x" ;;
esac
`,
)
chmodSync(join(TMP, 'agent-browser'), 0o755)

function run(args, env) {
	rmSync(LOG, { force: true })
	const e = { ...process.env, PATH: `${TMP}:${process.env.PATH}`, CDP_LOCK_DIR: join(TMP, 'locks'), NO_COLOR: '1', ...env }
	for (const k of ['CDP_HOST', 'CDP_PORT', 'CDP_INSTANCE']) if (!(k in env)) delete e[k]
	const r = spawnSync(process.execPath, args, { env: e, encoding: 'utf8', timeout: 30000 })
	return { ...r, log: existsSync(LOG) ? readFileSync(LOG, 'utf8') : '' }
}
const resolveIn = env =>
	run(['--input-type=module', '-e', `import { resolveEndpoint, lockFile } from '${HERE}cdp.mjs'
const ep = await resolveEndpoint(); console.log(JSON.stringify({ ...ep, lock: lockFile() }))`], env)

test('CDP_* unset : the agent browser route is the endpoint, instance a, the lock is its own', () => {
	const r = resolveIn({ STUB_ROUTE: 'host running 127.0.0.1 19999' })
	assert.equal(r.status, 0, r.stderr)
	const ep = JSON.parse(r.stdout)
	assert.equal(ep.httpBase, 'http://127.0.0.1:19999')
	assert.deepEqual(ep.agent, { side: 'host', state: 'running', host: '127.0.0.1', port: 19999 })
	assert.match(ep.lock, /\/\.cdp-lock-127\.0\.0\.1-19999\.json$/)
	assert.equal(r.log.trim(), '-i a route')
})

test('CDP_INSTANCE picks the agent browser instance', () => {
	const r = resolveIn({ STUB_ROUTE: 'host idle 127.0.0.1 19998', CDP_INSTANCE: 'b' })
	assert.equal(r.status, 0, r.stderr)
	assert.match(JSON.parse(r.stdout).lock, /-19998\.json$/)
	assert.equal(r.log.trim(), '-i b route')
})

test('CDP_HOST / CDP_PORT set : that browser, the agent browser never asked', () => {
	const r = resolveIn({ STUB_ROUTE: 'host running 127.0.0.1 19999', CDP_HOST: '127.0.0.1', CDP_PORT: '19222' })
	assert.equal(r.status, 0, r.stderr)
	const ep = JSON.parse(r.stdout)
	assert.equal(ep.agent, null)
	assert.match(ep.lock, /\/\.cdp-lock-127\.0\.0\.1-19222\.json$/)
	assert.equal(r.log, '')
})

test('nothing answers (agent-browser exit 3) : shot exits 3, the hint names agent-browser status and host-agent.sh start', () => {
	const r = run([`${HERE}cdp.mjs`, 'shot', '--url', 'http://localhost:5173/', '--out', join(TMP, 'a.png')], { STUB_ROUTE: 'none' })
	assert.equal(r.status, 3, r.stderr)
	assert.match(r.stderr, /no agent browser a answers/)
	assert.match(r.stderr, /agent-browser status/)
	assert.match(r.stderr, /host-agent\.sh" start/)
	assert.doesNotMatch(r.stderr, /wtf /)
})

test('a Windows host (host-os wsl / gitbash) : the hint names host-agent.ps1 start in PowerShell, not the bash line', () => {
	for (const os of ['wsl', 'gitbash']) {
		writeFileSync(join(TMP, 'host-os'), `${os}\n`)
		const r = run([`${HERE}cdp.mjs`, 'shot', '--url', 'http://localhost:5173/', '--out', join(TMP, 'a.png')], { STUB_ROUTE: 'none', CDP_HOST_OS_FILE: join(TMP, 'host-os') })
		assert.equal(r.status, 3, r.stderr)
		assert.match(r.stderr, /powershell -ExecutionPolicy Bypass -File "\$KIT\\host-agent\.ps1" start/, os)
		assert.doesNotMatch(r.stderr, /host-agent\.sh/, os)
	}
	writeFileSync(join(TMP, 'host-os'), 'mac\n')
	const mac = run([`${HERE}cdp.mjs`, 'shot', '--url', 'http://localhost:5173/', '--out', join(TMP, 'a.png')], { STUB_ROUTE: 'none', CDP_HOST_OS_FILE: join(TMP, 'host-os') })
	assert.match(mac.stderr, /host-agent\.sh" start/)
})

test('route not running : agent-browser up <url> first ; then unreachable is exit 3 with the agent hint', () => {
	const r = run([`${HERE}cdp.mjs`, 'shot', '--url', 'http://localhost:5173/', '--out', join(TMP, 'a.png')], { STUB_ROUTE: 'sidecar stopped 127.0.0.1 1' })
	assert.equal(r.status, 3, r.stderr)
	assert.deepEqual(r.log.trim().split('\n'), ['-i a route', '-i a up http://localhost:5173/'])
	assert.match(r.stderr, /agent browser's route \(sidecar, running\) is not listening/)
	assert.match(r.stderr, /host-agent\.sh" start/)
})

test('captures : from the compositor surface on the host agent browser only (headless on the GPU, false is flat grey)', () => {
	const surfaceIn = env =>
		run(['--input-type=module', '-e', `import { resolveEndpoint, capturesFromSurface, capture } from '${HERE}cdp.mjs'
const ep = await resolveEndpoint(); const sent = []
const conn = { surface: capturesFromSurface(ep), send: async (m, p) => (sent.push(p.fromSurface), { data: '' }) }
await capture(conn, 's', { out: '${join(TMP, 'surface.png')}' }); console.log(JSON.stringify(sent))`], env)
	for (const [env, want] of [
		[{ STUB_ROUTE: 'host running 127.0.0.1 19999' }, [true]],
		[{ STUB_ROUTE: 'sidecar running 127.0.0.1 19323' }, [false]],
		[{ CDP_HOST: '127.0.0.1', CDP_PORT: '9222' }, [false]],
	]) {
		const r = surfaceIn(env)
		assert.equal(r.status, 0, r.stderr)
		assert.deepEqual(JSON.parse(r.stdout), want, JSON.stringify(env))
	}
})

test('e2e.mjs : a CdpError keeps its code (3), not a blanket 1', () => {
	const suite = join(TMP, 'suite.mjs')
	writeFileSync(suite, "export const meta = { url: 'http://localhost:5173/', login: false }\nexport default async () => {}\n")
	const r = run([`${HERE}e2e.mjs`, '--suite', suite], { STUB_ROUTE: 'none' })
	assert.equal(r.status, 3, r.stderr)
	assert.match(r.stderr, /host-agent\.sh" start/)
})

// CDP_LOGIN_HEADERS : the login fetch carries the project's headers (a CSRF gate
// that answers 403 to a write without a custom header), and nothing else does.
const loginIn = (code, env = {}) =>
	run(['--input-type=module', '-e', `import { loginExpression, loginHeaders } from '${HERE}cdp.mjs'
${code}`], env)

test('CDP_LOGIN_HEADERS : parsed into the login fetch headers, JSON-encoded ; unset : none of it', () => {
	const r = loginIn(`const h = loginHeaders()
console.log(JSON.stringify({ h, expr: loginExpression('a@b.c', 'p', '{origin}/login', h) }))`, { CDP_LOGIN_HEADERS: 'x-version: cdp-driver ; X-Quote: say "hi"' })
	assert.equal(r.status, 0, r.stderr)
	const { h, expr } = JSON.parse(r.stdout)
	assert.deepEqual(h, { 'x-version': 'cdp-driver', 'X-Quote': 'say "hi"' })
	assert.match(expr, /"x-version":"cdp-driver"/)
	assert.match(expr, /"X-Quote":"say \\"hi\\""/)
	assert.match(expr, /"Content-Type":"application\/json"/)
	const bare = loginIn(`console.log(loginExpression('a@b.c', 'p', '{origin}/login', loginHeaders()))`, {})
	assert.equal(bare.status, 0, bare.stderr)
	assert.doesNotMatch(bare.stdout, /x-version|X-Quote/)
	assert.match(bare.stdout, /"Accept":"application\/json"/)
})

test('CDP_LOGIN_HEADERS : a malformed pair is exit 2 naming it, never dropped', () => {
	for (const bad of ['x-version', 'x version: 1', ': v', 'ok: 1; x_y: 2']) {
		const r = loginIn(`try { loginHeaders() } catch (e) { console.error(e.message); process.exit(e.code) }`, { CDP_LOGIN_HEADERS: bad })
		assert.equal(r.status, 2, `${bad} → ${r.status} ${r.stderr}`)
		assert.match(r.stderr, /CDP_LOGIN_HEADERS/)
	}
	const r = loginIn(`try { loginHeaders() } catch (e) { console.error(e.message); process.exit(e.code) }`, { CDP_LOGIN_HEADERS: 'ok: 1; x_y: 2' })
	assert.match(r.stderr, /x_y: 2/)
})

test('CDP_LOGIN_HEADERS : the built expression, run as the page would, passes a 403-without-header gate', () => {
	// The page's side, minus the browser : node's fetch and a location.origin.
	// The stub is the symptems gate — any non-GET without x-version is a 403.
	const stub = `import { createServer } from 'node:http'
const srv = createServer((req, res) => {
	const ok = req.headers['x-version'] !== undefined
	res.writeHead(ok ? 200 : 403, { 'Content-Type': 'application/json' })
	res.end(JSON.stringify(ok ? { user: 'a@b.c' } : { error: 'missing x-version' }))
}).listen(0, '127.0.0.1')
await new Promise(r => srv.once('listening', r))
globalThis.location = { origin: 'http://127.0.0.1:' + srv.address().port }
const r = await eval(loginExpression('a@b.c', 'p', '{origin}/api/auth/login', loginHeaders()))
console.log(JSON.stringify(r)) ; srv.close()`
	const a = loginIn(stub, { CDP_LOGIN_HEADERS: 'x-version: test' })
	assert.equal(a.status, 0, a.stderr)
	const withH = JSON.parse(a.stdout)
	assert.deepEqual([withH.ok, withH.status], [true, 200])
	const without = JSON.parse(loginIn(stub, {}).stdout)
	assert.deepEqual([without.ok, without.status, without.body.error], [false, 403, 'missing x-version'])
})
