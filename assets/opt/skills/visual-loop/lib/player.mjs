// The player harness, CDP side — what e2e.mjs adds to a suite's ctx when the
// suite declares `meta.player` : keyboard, virtual gamepads, frame-timed holds,
// mid-scenario screenshots, video with sound, an fps meter, and the proofs
// folder they all write to. The in-page half is player-page.js.
//
// Generic on purpose : nothing here knows the page under test. Game state is
// the suite's business (its own `waitFor` expressions).

import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const PAGE_SRC = readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'player-page.js'), 'utf8')

/** The source to register with Page.addScriptToEvaluateOnNewDocument. */
export const pageScript = (cfg = {}) => `${PAGE_SRC.trimEnd()}(${JSON.stringify(cfg)})`

// ── keys ──────────────────────────────────────────────────────────────────

const NAMED = {
	Enter: ['Enter', 13, '\r'],
	Escape: ['Escape', 27],
	Tab: ['Tab', 9],
	Backspace: ['Backspace', 8],
	Delete: ['Delete', 46],
	Insert: ['Insert', 45],
	Home: ['Home', 36],
	End: ['End', 35],
	PageUp: ['PageUp', 33],
	PageDown: ['PageDown', 34],
	ArrowUp: ['ArrowUp', 38],
	ArrowDown: ['ArrowDown', 40],
	ArrowLeft: ['ArrowLeft', 37],
	ArrowRight: ['ArrowRight', 39],
	Space: ['Space', 32, ' ', ' '],
	ShiftLeft: ['ShiftLeft', 16, '', 'Shift', 1],
	ShiftRight: ['ShiftRight', 16, '', 'Shift', 2],
	ControlLeft: ['ControlLeft', 17, '', 'Control', 1],
	ControlRight: ['ControlRight', 17, '', 'Control', 2],
	AltLeft: ['AltLeft', 18, '', 'Alt', 1],
	AltRight: ['AltRight', 18, '', 'Alt', 2],
	MetaLeft: ['MetaLeft', 91, '', 'Meta', 1],
	MetaRight: ['MetaRight', 92, '', 'Meta', 2],
}
// `key` spellings that are not a `code`.
const ALIAS = { ' ': 'Space', Shift: 'ShiftLeft', Control: 'ControlLeft', Ctrl: 'ControlLeft', Alt: 'AltLeft', Meta: 'MetaLeft', Esc: 'Escape', Up: 'ArrowUp', Down: 'ArrowDown', Left: 'ArrowLeft', Right: 'ArrowRight' }
const MODIFIER_BIT = { Alt: 1, Control: 2, Meta: 4, Shift: 8 }

/**
 * A key name — a DOM `key` ('a', 'Enter', 'ArrowUp', ' ') or a `code` ('KeyA',
 * 'Digit1', 'Space', 'F5') — to what Input.dispatchKeyEvent needs. US layout.
 * @param {string} name
 * @returns {{key: string, code: string, keyCode: number, text: string, location: number}}
 */
export function keyInfo(name) {
	const n = ALIAS[name] ?? name
	if (NAMED[n]) {
		const [code, keyCode, text = '', key = code === 'Space' ? ' ' : code, location = 0] = NAMED[n]
		return { key, code, keyCode, text, location }
	}
	let m = /^(?:Key)?([a-zA-Z])$/.exec(n)
	if (m) {
		const up = m[1].toUpperCase()
		// 'KeyA' and 'a' are the unshifted key ; 'A' is the letter as typed with Shift.
		const ch = n.length === 1 ? n : up.toLowerCase()
		return { key: ch, code: `Key${up}`, keyCode: up.charCodeAt(0), text: ch, location: 0 }
	}
	m = /^(?:Digit)?([0-9])$/.exec(n)
	if (m) return { key: m[1], code: `Digit${m[1]}`, keyCode: 48 + Number(m[1]), text: m[1], location: 0 }
	m = /^F([1-9]|1[0-2])$/.exec(n)
	if (m) return { key: n, code: n, keyCode: 111 + Number(m[1]), text: '', location: 0 }
	throw new Error(`unknown key '${name}' — use a DOM key ('a', 'Enter', 'ArrowUp', ' ') or code ('KeyA', 'Digit1', 'Space', 'F5')`)
}

// ── gamepad ───────────────────────────────────────────────────────────────

// W3C "standard" mapping. Xbox, PlayStation and generic names all land here.
const BUTTONS = {
	a: 0, cross: 0, south: 0,
	b: 1, circle: 1, east: 1,
	x: 2, square: 2, west: 2,
	y: 3, triangle: 3, north: 3,
	lb: 4, l1: 4,
	rb: 5, r1: 5,
	lt: 6, l2: 6,
	rt: 7, r2: 7,
	select: 8, back: 8, share: 8,
	start: 9, options: 9,
	ls: 10, l3: 10,
	rs: 11, r3: 11,
	up: 12, dpadup: 12,
	down: 13, dpaddown: 13,
	left: 14, dpadleft: 14,
	right: 15, dpadright: 15,
	home: 16, guide: 16, ps: 16,
}
const STICKS = { left: [0, 1], right: [2, 3] }

/**
 * @param {string|number} name
 * @returns {number} the standard-mapping button index
 */
export function buttonIndex(name) {
	if (Number.isInteger(name) && name >= 0 && name <= 16) return name
	const i = BUTTONS[String(name).toLowerCase().replace(/[^a-z0-9]/g, '')]
	if (i === undefined) throw new Error(`unknown pad button '${name}' — a standard-mapping name (a b x y lb rb lt rt select start ls rs up down left right home, or cross/circle/square/triangle, l1/r1/l2/r2) or an index 0-16`)
	return i
}

// ── proofs ────────────────────────────────────────────────────────────────

/** A filesystem-safe slug. */
export const slug = s => String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'x'

/** `YYYYMMDD-HHMMSS`, local time — the run folder's name. */
export const stamp = (d = new Date()) => {
	const p = n => String(n).padStart(2, '0')
	return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`
}

/**
 * The index of one run, as markdown : results, then per scenario its
 * screenshots inline, its videos as <video> (VS Code's preview plays them) plus
 * a plain link, its fps readings as a table. Paths relative to the run folder.
 * Pure — tested without a browser.
 * @param {object} run - the run.json object
 * @returns {string}
 */
export function renderIndex(run) {
	const mark = r => (r.ok === true ? 'PASS' : r.ok === false ? 'FAIL' : 'SKIP')
	const L = [
		`# ${run.suite}`,
		'',
		`- **URL** : ${run.url}`,
		`- **Started** : ${run.started} — **finished** : ${run.finished ?? '(interrupted)'}`,
		`- **Browser** : ${run.userAgent ?? 'unknown'}`,
		`- **Result** : ${run.passed} pass · ${run.failed} fail · ${run.skipped} skip`,
		'',
		'| Scenario | Result | Detail |',
		'|---|---|---|',
	]
	for (const r of run.results) L.push(`| ${r.id} | ${mark(r)} | ${String(r.detail ?? '').replace(/\|/g, '\\|').replace(/\n/g, ' ')} |`)
	for (const r of run.results) {
		if (!r.proofs?.length) continue
		L.push('', `## ${r.id} — ${mark(r)}`, '')
		const fps = r.proofs.filter(p => p.kind === 'fps')
		for (const p of r.proofs) {
			if (p.kind === 'shot') L.push(`### ${p.label}`, '', `![${p.label}](${p.file})`, '')
			else if (p.kind === 'video') {
				const what = [p.mimeType, p.audio ? 'with sound' : 'no sound', p.fallback ? `fallback : ${p.fallback}` : ''].filter(Boolean).join(', ')
				// A screencast with no ffmpeg to encode it is a folder of JPEGs : its
				// first frame stands in for the player.
				const view = /\.(mp4|webm)$/.test(p.file) ? `<video src="${p.file}" controls width="640"></video>` : `![${p.label}](${p.file}/00000.jpg)`
				L.push(`### ${p.label}`, '', view, '', `[${p.file}](${p.file}) — ${what}, ${p.seconds}s, ${p.bytes} bytes`, '')
			}
		}
		if (fps.length) {
			L.push('| fps | avg | min | p95 | frames | seconds |', '|---|---|---|---|---|---|')
			for (const p of fps) L.push(`| ${p.label} | ${p.avg} | ${p.min} | ${p.p95} | ${p.frames} | ${p.seconds} |`)
			L.push('')
		}
	}
	return `${L.join('\n').trimEnd()}\n`
}

// ── the ctx extension ─────────────────────────────────────────────────────

const sleep = ms => new Promise(r => setTimeout(r, ms))

/**
 * Build the player half of a suite's ctx.
 * @param {object} o
 * @param {{send: Function, on: Function}} o.conn
 * @param {string} o.sid
 * @param {(expr: string) => Promise<unknown>} o.js - e2e's in-page evaluate
 * @param {(conn: object, sid: string, o: object) => Promise<number>} o.capture - cdp.mjs's
 * @param {string} o.dir - the run folder
 * @param {() => object} o.current - the result entry proofs are attached to
 * @param {number} [o.pressFrames] - default press length
 * @returns {object}
 */
export function makePlayer({ conn, sid, js, capture, dir, current, pressFrames = 2 }) {
	const held = {} // code → info, for the modifiers bitmask
	let seq = 0
	const name = (label, ext) => `${String(++seq).padStart(2, '0')}-${slug(current().id)}-${slug(label)}.${ext}`
	const add = proof => {
		current().proofs.push(proof)
		return proof
	}

	const modifiers = () => {
		let m = 0
		for (const c in held) m |= MODIFIER_BIT[held[c].key] ?? 0
		return m
	}
	const frames = n => js(`return await window.__player.frames(${Number(n)})`)
	// A duration is frames (rAF in the page) or ms ; frames win when both.
	const wait = (t, fallbackFrames) => (t?.frames != null ? frames(t.frames) : t?.ms != null ? sleep(t.ms) : frames(fallbackFrames))

	const keyDown = async k => {
		const i = keyInfo(k)
		held[i.code] = i
		await conn.send(
			'Input.dispatchKeyEvent',
			{
				type: i.text ? 'keyDown' : 'rawKeyDown',
				key: i.key,
				code: i.code,
				windowsVirtualKeyCode: i.keyCode,
				nativeVirtualKeyCode: i.keyCode,
				text: i.text || undefined,
				unmodifiedText: i.text || undefined,
				location: i.location,
				modifiers: modifiers(),
			},
			sid,
		)
	}
	const keyUp = async k => {
		const i = keyInfo(k)
		delete held[i.code]
		await conn.send(
			'Input.dispatchKeyEvent',
			{ type: 'keyUp', key: i.key, code: i.code, windowsVirtualKeyCode: i.keyCode, nativeVirtualKeyCode: i.keyCode, location: i.location, modifiers: modifiers() },
			sid,
		)
	}

	const padSet = (i, patch) => js(`return window.__player.pad(${i}, ${JSON.stringify(patch)})`)
	const needPads = () =>
		js('return typeof window.__player?.pad === "function"').then(ok => {
			if (!ok) throw new Error('no virtual gamepad in this page — declare `meta.player = { gamepad: true }` in the suite')
		})
	const pad = i => {
		if (!(Number.isInteger(i) && i >= 0 && i <= 3)) throw new Error(`pad index ${i} — 0 to 3`)
		return {
			connect: () => needPads().then(() => js(`return window.__player.padConnect(${i})`)),
			disconnect: () => needPads().then(() => js(`return window.__player.padDisconnect(${i})`)),
			hold: async (b, value = 1) => {
				await needPads()
				await padSet(i, { buttons: { [buttonIndex(b)]: value } })
			},
			release: b => padSet(i, { buttons: { [buttonIndex(b)]: 0 } }),
			press: async (b, t) => {
				await needPads()
				const bi = buttonIndex(b)
				await padSet(i, { buttons: { [bi]: 1 } })
				await wait(t, pressFrames)
				await padSet(i, { buttons: { [bi]: 0 } })
			},
			// x, y in [-1, 1], y down positive (the standard mapping's sign).
			// With a duration the stick springs back to centre after it.
			stick: async (side, x, y, t) => {
				await needPads()
				const ax = STICKS[side]
				if (!ax) throw new Error(`stick '${side}' — left or right`)
				await padSet(i, { axes: { [ax[0]]: x, [ax[1]]: y } })
				if (t) {
					await wait(t)
					await padSet(i, { axes: { [ax[0]]: 0, [ax[1]]: 0 } })
				}
			},
		}
	}

	const shot = async (label, o = {}) => {
		const file = name(label, 'png')
		const bytes = await capture(conn, sid, { out: join(dir, file), full: o.full })
		return add({ kind: 'shot', label, file, bytes })
	}

	const fps = async (o = {}) => {
		await js('return window.__player.fpsStart()')
		await (o.frames != null ? frames(o.frames) : sleep(o.ms ?? 3000))
		const r = await js('return window.__player.fpsStop()')
		return add({ kind: 'fps', label: o.label ?? 'fps', ...r })
	}

	// In-page MediaRecorder, drained every second while `fn` runs ; the CDP
	// screencast (JPEG frames, no sound) when the page has nothing to record
	// from, or on `{ screencast: true }`.
	const record = async (label, fn, o = {}) => {
		const t0 = Date.now()
		const started = o.screencast ? null : await js(`return window.__player.recStart(${JSON.stringify({ selector: o.selector, fps: o.fps })})`)
		if (!started) return screencast(label, fn, o, t0)
		const ext = started.mimeType.startsWith('video/mp4') ? 'mp4' : 'webm'
		const file = name(label, ext)
		const out = join(dir, file)
		mkdirSync(dir, { recursive: true })
		writeFileSync(out, '')
		// Serialised : a drain still reading when the stop's own drain lands
		// would append its chunks after the tail.
		let draining = Promise.resolve()
		const drain = () => {
			draining = draining.then(async () => {
				const b64 = await js('return await window.__player.recDrain()')
				if (b64) appendFileSync(out, Buffer.from(b64, 'base64'))
			})
			return draining
		}
		const timer = setInterval(drain, o.drainMs ?? 1000)
		let failure
		try {
			await fn?.()
		} catch (err) {
			failure = err // the video of a failing run is the most useful one — keep it
		}
		clearInterval(timer)
		await draining
		const tail = await js('return await window.__player.recStop()')
		if (tail) appendFileSync(out, Buffer.from(tail, 'base64'))
		const bytes = readFileSync(out).length
		const proof = add({ kind: 'video', label, file, bytes, seconds: Math.round((Date.now() - t0) / 100) / 10, mimeType: started.mimeType, audio: started.audio, canvas: started.canvas })
		if (failure) throw failure
		return proof
	}

	const screencast = async (label, fn, o, t0) => {
		const base = name(label, 'frames')
		const fdir = join(dir, base)
		mkdirSync(fdir, { recursive: true })
		const list = []
		const off = conn.on('Page.screencastFrame', (p, s) => {
			if (s !== sid) return
			const f = `${String(list.length).padStart(5, '0')}.jpg`
			writeFileSync(join(fdir, f), Buffer.from(p.data, 'base64'))
			list.push({ f, t: p.metadata?.timestamp ?? Date.now() / 1000 })
			conn.send('Page.screencastFrameAck', { sessionId: p.sessionId }, sid).catch(() => {})
		})
		await conn.send('Page.startScreencast', { format: 'jpeg', quality: 80, everyNthFrame: 1 }, sid)
		let failure
		try {
			await fn?.()
		} catch (err) {
			failure = err
		}
		await conn.send('Page.stopScreencast', {}, sid).catch(() => {})
		off()
		// Frames come at the page's pace, not a fixed rate : each one is held for
		// its own duration (ffmpeg concat demuxer). No ffmpeg on PATH → the
		// frames stay, and the proof says so.
		let file = base
		let mimeType = 'image/jpeg frames'
		const concat = list.map((x, i) => `file '${x.f}'\nduration ${Math.max(0.001, ((list[i + 1]?.t ?? x.t + 1 / 30) - x.t)).toFixed(4)}`).join('\n')
		writeFileSync(join(fdir, 'frames.txt'), `${concat}\n`)
		if (list.length && spawnSync('ffmpeg', ['-version'], { stdio: 'ignore' }).status === 0) {
			const mp4 = name(label, 'mp4')
			const r = spawnSync('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'concat', '-safe', '0', '-i', join(fdir, 'frames.txt'), '-vf', 'pad=ceil(iw/2)*2:ceil(ih/2)*2', '-pix_fmt', 'yuv420p', '-c:v', 'libx264', join(dir, mp4)])
			if (r.status === 0) {
				file = mp4
				mimeType = 'video/mp4 (from screencast)'
			}
		}
		const bytes = file.endsWith('.mp4') ? readFileSync(join(dir, file)).length : 0
		const proof = add({ kind: 'video', label, file, bytes, seconds: Math.round((Date.now() - t0) / 100) / 10, mimeType, audio: false, fallback: 'screencast', frames: list.length })
		if (failure) throw failure
		return proof
	}

	return {
		frames,
		press: async (k, t) => {
			await keyDown(k)
			await wait(t, pressFrames)
			await keyUp(k)
		},
		// Without a duration : down until release(). With one : a long press.
		hold: async (k, t) => {
			await keyDown(k)
			if (t) {
				await wait(t)
				await keyUp(k)
			}
		},
		release: keyUp,
		pad,
		shot,
		fps,
		record,
	}
}

/** Write run.json and index.md into the run folder. */
export function writeRun(dir, run) {
	mkdirSync(dir, { recursive: true })
	writeFileSync(join(dir, 'run.json'), `${JSON.stringify(run, null, 2)}\n`)
	writeFileSync(join(dir, 'index.md'), renderIndex(run))
	return join(dir, 'index.md')
}
