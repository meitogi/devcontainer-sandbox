// In-page half of the player harness. NOT a module : lib/player.mjs reads this
// file and registers `(<this function>)(<config>)` with
// Page.addScriptToEvaluateOnNewDocument, so it runs in every new document
// BEFORE the page's own scripts. Everything it exposes hangs off
// `window.__player`, which the harness drives through Runtime.evaluate.
//
//   frames(n)          resolves after n animation frames (input timing in frames)
//   fpsStart/fpsStop   rAF intervals → { frames, seconds, avg, min, p95, … }
//   pad(i, patch)      the virtual gamepads (config.gamepad) — standard mapping
//   recStart/recDrain/recStop   MediaRecorder on the canvas + the Web Audio tap
//
// Nothing here knows the page under test.
;(cfg => {
	if (window.__player) return
	const P = (window.__player = { version: 1 })

	// ── frames ─────────────────────────────────────────────────────────────
	P.frames = n =>
		new Promise(res => {
			let k = 0
			const f = () => (++k >= n ? res(k) : requestAnimationFrame(f))
			requestAnimationFrame(f)
		})

	// ── fps : rAF timestamps in the page, never the sidecar's clock ────────
	let stamps = null
	const tick = t => {
		if (stamps) stamps.push(t)
		requestAnimationFrame(tick)
	}
	requestAnimationFrame(tick)
	P.fpsStart = () => {
		stamps = []
		return true
	}
	// p95 is the frame rate at the 95th-percentile frame TIME — the slow tail,
	// what a stutter looks like ; min is the single slowest frame.
	P.fpsStop = () => {
		const s = stamps ?? []
		stamps = null
		const n = s.length - 1
		if (n < 1) return { frames: 0, seconds: 0, avg: 0, min: 0, p95: 0, p95FrameMs: 0, maxFrameMs: 0 }
		const dts = []
		for (let i = 1; i <= n; i++) dts.push(s[i] - s[i - 1])
		const span = s[n] - s[0]
		const sorted = dts.sort((a, b) => a - b)
		const p95FrameMs = sorted[Math.min(n - 1, Math.ceil(n * 0.95) - 1)]
		const maxFrameMs = sorted[n - 1]
		const r = x => Math.round(x * 10) / 10
		return {
			frames: n,
			seconds: r(span / 1000),
			avg: r((n * 1000) / span),
			min: r(1000 / maxFrameMs),
			p95: r(1000 / p95FrameMs),
			p95FrameMs: r(p95FrameMs),
			maxFrameMs: r(maxFrameMs),
		}
	}

	// ── virtual gamepads ───────────────────────────────────────────────────
	// navigator.getGamepads() returns fresh snapshots on every call, as Chrome
	// does : a game that keeps the object from last frame must not see it move.
	// A pad appears on its first input (or connect), with a `gamepadconnected`
	// event — a real browser also exposes a pad only once a button is pressed.
	if (cfg.gamepad) {
		const pads = [null, null, null, null]
		const blank = i => ({
			id: 'player-harness virtual pad (STANDARD GAMEPAD Vendor: 0000 Product: 0000)',
			index: i,
			mapping: 'standard',
			axes: [0, 0, 0, 0],
			buttons: Array.from({ length: 17 }, () => 0),
			timestamp: performance.now(),
		})
		const snap = p => ({
			id: p.id,
			index: p.index,
			connected: true,
			mapping: p.mapping,
			timestamp: p.timestamp,
			axes: p.axes.slice(),
			buttons: p.buttons.map(v => ({ pressed: v > 0.5, touched: v > 0, value: v })),
			vibrationActuator: null,
		})
		const fire = (type, p) => {
			const ev = new Event(type)
			Object.defineProperty(ev, 'gamepad', { value: snap(p) })
			window.dispatchEvent(ev)
		}
		Navigator.prototype.getGamepads = function getGamepads() {
			return pads.map(p => (p ? snap(p) : null))
		}
		P.padConnect = i => {
			if (!pads[i]) {
				pads[i] = blank(i)
				fire('gamepadconnected', pads[i])
			}
			return true
		}
		P.padDisconnect = i => {
			const p = pads[i]
			if (p) {
				pads[i] = null
				fire('gamepaddisconnected', p)
			}
			return true
		}
		// patch : { buttons: { index: value }, axes: { index: value } }
		P.pad = (i, patch) => {
			P.padConnect(i)
			const p = pads[i]
			for (const k in patch.buttons ?? {}) p.buttons[k] = patch.buttons[k]
			for (const k in patch.axes ?? {}) p.axes[k] = patch.axes[k]
			p.timestamp = performance.now()
			return true
		}
	}

	// ── Web Audio tap ──────────────────────────────────────────────────────
	// Whatever the page connects to a context's destination is also connected
	// to one MediaStreamAudioDestinationNode per context, so the recorder gets
	// the page's mix without the page knowing. Patched before load because a
	// game wires its graph once, at start.
	const taps = []
	if (typeof AudioNode !== 'undefined' && typeof AudioDestinationNode !== 'undefined') {
		const connect = AudioNode.prototype.connect
		const disconnect = AudioNode.prototype.disconnect
		const tapOf = ctx => {
			if (typeof ctx.createMediaStreamDestination !== 'function') return null // OfflineAudioContext
			let t = taps.find(x => x.ctx === ctx)
			if (!t) {
				t = { ctx, node: ctx.createMediaStreamDestination() }
				taps.push(t)
			}
			return t.node
		}
		AudioNode.prototype.connect = function (dest, ...rest) {
			const r = connect.call(this, dest, ...rest)
			if (dest instanceof AudioDestinationNode) {
				const tap = tapOf(dest.context)
				if (tap) connect.call(this, tap, rest[0] ?? 0)
			}
			return r
		}
		AudioNode.prototype.disconnect = function (...args) {
			const r = disconnect.apply(this, args)
			if (args[0] instanceof AudioDestinationNode) {
				const tap = tapOf(args[0].context)
				// Mirror the overload : disconnect(dest, output[, input]) cuts that
				// output's edge only (the tap has a single input).
				try {
					if (tap) args.length > 1 ? disconnect.call(this, tap, args[1]) : disconnect.call(this, tap)
				} catch {}
			}
			return r
		}
	}
	P.audioContexts = () => taps.map(t => t.ctx.state)

	// ── recorder ───────────────────────────────────────────────────────────
	let rec = null
	const MIMES = [
		'video/mp4;codecs=avc1.42E01E,mp4a.40.2',
		'video/webm;codecs=vp9,opus',
		'video/webm;codecs=vp8,opus',
		'video/webm',
	]
	const biggestCanvas = () => {
		let best = null
		for (const c of document.querySelectorAll('canvas')) if (!best || c.width * c.height > best.width * best.height) best = c
		return best
	}
	// null when nothing to record from — the harness then falls back to the
	// CDP screencast (silent).
	P.recStart = (o = {}) => {
		if (rec) throw new Error('a recording is already running')
		if (typeof MediaRecorder === 'undefined') return null
		const canvas = o.selector ? document.querySelector(o.selector) : biggestCanvas()
		if (!canvas || typeof canvas.captureStream !== 'function') return null
		const tracks = canvas.captureStream(o.fps ?? 60).getVideoTracks()
		// One context : its tap's track as is. Several : mixed in a context of
		// our own (a MediaStream track belongs to one recorder input only).
		let mixer = null
		if (taps.length === 1) tracks.push(...taps[0].node.stream.getAudioTracks())
		else if (taps.length > 1) {
			mixer = new AudioContext()
			const out = mixer.createMediaStreamDestination()
			for (const t of taps) mixer.createMediaStreamSource(t.node.stream).connect(out)
			tracks.push(...out.stream.getAudioTracks())
		}
		const mimeType = MIMES.find(m => MediaRecorder.isTypeSupported(m)) ?? ''
		const mr = new MediaRecorder(new MediaStream(tracks), {
			mimeType,
			videoBitsPerSecond: o.videoBitsPerSecond ?? 4_000_000,
		})
		const r = (rec = { mr, chunks: [], mixer, stopped: null, audio: tracks.length > 1 })
		mr.ondataavailable = e => e.data.size && r.chunks.push(e.data)
		r.stopped = new Promise(res => {
			mr.onstop = res
		})
		mr.start(o.timeslice ?? 1000)
		return { mimeType: mr.mimeType, audio: r.audio, canvas: `${canvas.width}x${canvas.height}`, contexts: taps.length }
	}
	// The chunks recorded since the last drain, as one base64 string — pulled
	// by the harness during the recording so the page never holds the video.
	P.recDrain = async () => {
		const r = rec
		if (!r) return ''
		const parts = r.chunks.splice(0)
		if (parts.length === 0) return ''
		const url = await new Promise((res, rej) => {
			const fr = new FileReader()
			fr.onload = () => res(fr.result)
			fr.onerror = () => rej(fr.error)
			fr.readAsDataURL(new Blob(parts))
		})
		return url.slice(url.indexOf(',') + 1)
	}
	P.recStop = async () => {
		const r = rec
		if (!r) return ''
		if (r.mr.state !== 'inactive') r.mr.stop()
		await r.stopped
		const tail = await P.recDrain()
		r.mixer?.close()
		rec = null
		return tail
	}
})
