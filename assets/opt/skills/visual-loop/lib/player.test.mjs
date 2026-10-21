// player.test.mjs — the player harness's pure half : key and button tables, the
// proofs index, and the in-page script run in a vm with stub browser globals
// (virtual pads, fps arithmetic). The browser half — CDP input, the recorder,
// the Web Audio tap — runs in test/agent-browser-live.sh against a real
// Chromium.
//
//   node --test /opt/devcontainer/base/skills/visual-loop/lib/player.test.mjs
import assert from 'node:assert/strict'
import test from 'node:test'
import vm from 'node:vm'
import { buttonIndex, keyInfo, pageScript, renderIndex, slug, stamp } from './player.mjs'

test('keys : DOM key or code to key / code / keyCode / text', () => {
	assert.deepEqual(keyInfo('a'), { key: 'a', code: 'KeyA', keyCode: 65, text: 'a', location: 0 })
	assert.deepEqual(keyInfo('KeyA'), keyInfo('a'))
	assert.equal(keyInfo('A').key, 'A')
	assert.deepEqual(keyInfo('7'), { key: '7', code: 'Digit7', keyCode: 55, text: '7', location: 0 })
	assert.deepEqual(keyInfo('Digit7'), keyInfo('7'))
	assert.deepEqual(keyInfo('Enter'), { key: 'Enter', code: 'Enter', keyCode: 13, text: '\r', location: 0 })
	assert.deepEqual(keyInfo(' '), { key: ' ', code: 'Space', keyCode: 32, text: ' ', location: 0 })
	assert.deepEqual(keyInfo('Space'), keyInfo(' '))
	assert.deepEqual(keyInfo('ArrowUp'), { key: 'ArrowUp', code: 'ArrowUp', keyCode: 38, text: '', location: 0 })
	assert.deepEqual(keyInfo('Up'), keyInfo('ArrowUp'))
	assert.deepEqual(keyInfo('Shift'), { key: 'Shift', code: 'ShiftLeft', keyCode: 16, text: '', location: 1 })
	assert.equal(keyInfo('ControlRight').location, 2)
	assert.equal(keyInfo('F5').keyCode, 116)
	assert.equal(keyInfo('F12').keyCode, 123)
	for (const bad of ['', 'F13', 'Keyaa', 'ArrowNorth', 'é']) assert.throws(() => keyInfo(bad), /unknown key/, bad)
})

test('pad buttons : W3C standard mapping, Xbox / PlayStation / index spellings', () => {
	const expect = { a: 0, cross: 0, b: 1, circle: 1, x: 2, square: 2, y: 3, triangle: 3, l1: 4, R1: 5, lt: 6, r2: 7, select: 8, start: 9, l3: 10, rs: 11, up: 12, 'dpad-down': 13, dpadLeft: 14, right: 15, home: 16, 0: 0, 16: 16 }
	for (const k in expect) assert.equal(buttonIndex(/^\d+$/.test(k) ? Number(k) : k), expect[k], k)
	for (const bad of ['z', 17, -1, 'triggers']) assert.throws(() => buttonIndex(bad), /unknown pad button/, String(bad))
})

test('proofs : slug, run folder stamp, index.md', () => {
	assert.equal(slug('Boot → Menu (pad)'), 'boot-menu-pad')
	assert.equal(slug('///'), 'x')
	assert.equal(stamp(new Date(2026, 9, 21, 9, 5, 3)), '20261021-090503')
	const md = renderIndex({
		suite: 's.mjs',
		url: 'http://localhost:5173/',
		started: 'a',
		finished: 'b',
		userAgent: 'UA',
		passed: 1,
		failed: 1,
		skipped: 0,
		results: [
			{ id: 'MENU', ok: true, detail: 'ok | piped', proofs: [{ kind: 'shot', label: 'menu', file: '01-menu-menu.png', bytes: 1 }, { kind: 'fps', label: 'idle', avg: 59.9, min: 50, p95: 58, frames: 120, seconds: 2 }] },
			{ id: 'LAP', ok: false, detail: 'boom', proofs: [{ kind: 'video', label: 'lap', file: '02-lap-lap.webm', bytes: 9, seconds: 3, mimeType: 'video/webm', audio: true }] },
			{ id: 'CAST', ok: true, detail: '', proofs: [{ kind: 'video', label: 'cast', file: '03-cast-cast.frames', bytes: 0, seconds: 1, mimeType: 'image/jpeg frames', audio: false, fallback: 'screencast' }] },
			{ id: 'NONE', ok: null, detail: 'skipped', proofs: [] },
		],
	})
	assert.match(md, /^# s\.mjs\n/)
	assert.match(md, /\| MENU \| PASS \| ok \\\| piped \|/)
	assert.match(md, /\| NONE \| SKIP \| skipped \|/)
	assert.match(md, /!\[menu\]\(01-menu-menu\.png\)/)
	assert.match(md, /<video src="02-lap-lap\.webm" controls/)
	assert.match(md, /video\/webm, with sound, 3s, 9 bytes/)
	assert.match(md, /\| idle \| 59\.9 \| 50 \| 58 \| 120 \| 2 \|/)
	assert.match(md, /!\[cast\]\(03-cast-cast\.frames\/00000\.jpg\)/)
	assert.doesNotMatch(md, /<video src="03-cast/)
	assert.match(md, /no sound, fallback : screencast/)
	assert.match(md, /## LAP — FAIL/)
	assert.doesNotMatch(md, /## NONE/)
})

// vm objects carry the other realm's prototypes ; deepEqual compares those too.
const plain = x => JSON.parse(JSON.stringify(x))

// The page script with just enough browser to run : rAF driven by hand.
function page(cfg) {
	const raf = []
	const events = []
	class Navigator {}
	const sandbox = {
		Navigator,
		navigator: new Navigator(),
		performance: { now: () => 1 },
		requestAnimationFrame: f => raf.push(f),
		Event: class {
			constructor(type) {
				this.type = type
			}
		},
		dispatchEvent: e => events.push(e),
	}
	sandbox.window = sandbox
	vm.runInNewContext(pageScript(cfg), sandbox)
	const step = t => {
		for (const f of raf.splice(0)) f(t)
	}
	return { P: sandbox.__player, nav: sandbox.navigator, events, step }
}

test('in page : virtual pads — standard mapping, snapshots, connect events', () => {
	const { P, nav, events } = page({ gamepad: true })
	assert.deepEqual(plain(nav.getGamepads()), [null, null, null, null])
	P.pad(1, { buttons: { 0: 1, 6: 0.25 }, axes: { 0: -1 } })
	const [none, p] = nav.getGamepads()
	assert.equal(none, null)
	assert.equal(p.index, 1)
	assert.equal(p.mapping, 'standard')
	assert.equal(p.connected, true)
	assert.equal(p.buttons.length, 17)
	assert.deepEqual(plain(p.buttons[0]), { pressed: true, touched: true, value: 1 })
	assert.deepEqual(plain(p.buttons[6]), { pressed: false, touched: true, value: 0.25 })
	assert.deepEqual(plain(p.axes), [-1, 0, 0, 0])
	assert.deepEqual(events.map(e => [e.type, e.gamepad.index]), [['gamepadconnected', 1]])
	// A snapshot does not move under the game's feet.
	P.pad(1, { buttons: { 0: 0 } })
	assert.equal(p.buttons[0].pressed, true)
	assert.equal(nav.getGamepads()[1].buttons[0].pressed, false)
	P.padDisconnect(1)
	assert.equal(nav.getGamepads()[1], null)
	assert.deepEqual(events.map(e => e.type), ['gamepadconnected', 'gamepaddisconnected'])
})

test('in page : no gamepad config, navigator untouched', () => {
	const { P, nav } = page({})
	assert.equal(nav.getGamepads, undefined)
	assert.equal(P.pad, undefined)
})

test('in page : fps from rAF timestamps — avg, min (slowest frame), p95 (slow tail)', async () => {
	const { P, step } = page({})
	step(0)
	P.fpsStart()
	// 19 frames at 16 ms, one at 50 ms.
	let t = 1000
	step(t)
	for (let i = 0; i < 19; i++) step((t += 16))
	step((t += 50))
	const r = P.fpsStop()
	assert.equal(r.frames, 20)
	assert.equal(r.maxFrameMs, 50)
	assert.equal(r.min, 20)
	assert.equal(r.p95FrameMs, 16)
	assert.equal(r.avg, Math.round((20 * 1000 * 10) / 354) / 10)
	assert.deepEqual(plain(P.fpsStop()), { frames: 0, seconds: 0, avg: 0, min: 0, p95: 0, p95FrameMs: 0, maxFrameMs: 0 })
	// frames(n) resolves after n animation frames.
	let done = false
	const p = P.frames(3).then(() => (done = true))
	step(1)
	step(2)
	await Promise.resolve()
	assert.equal(done, false)
	step(3)
	await p
	assert.equal(done, true)
})
