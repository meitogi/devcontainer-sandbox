// The player harness against test/player/game.html — every step kind once,
// asserted on the page's own log rather than on pixels. Run by
// test/agent-browser-live.sh through the agent-browser proxy :
//
//   node …/visual-loop/scripts/e2e.mjs --suite test/player/game.suite.mjs --proofs <dir>
export const meta = {
	url: 'http://localhost:5173/game.html',
	ready: 'Array.isArray(window.__log)',
	login: false,
	player: { gamepad: true },
}

export default async ctx => {
	const log = () => ctx.js('return window.__log')
	// The frame of the first log line matching re, or a failure naming the log.
	const at = (lines, re) => {
		const hit = lines.find(l => re.test(l))
		if (!hit) ctx.fail(`no line matching ${re} in : ${lines.join(' / ')}`)
		return Number(hit.split(' ')[0])
	}

	await ctx.scenario('KEYS', async () => {
		await ctx.press('ArrowUp', { frames: 4 })
		await ctx.hold('Space')
		await ctx.frames(3)
		await ctx.release('Space')
		await ctx.press('a')
		await ctx.press('Enter', { ms: 50 })
		await ctx.waitFor(`window.__log.some(l => l.endsWith('keyup "Enter" Enter 13'))`, { timeout: 5000 })
		const l = await log()
		const held = at(l, /keyup "ArrowUp" ArrowUp 38$/) - at(l, /keydown "ArrowUp" ArrowUp 38$/)
		if (held < 4) ctx.fail(`ArrowUp held ${held} frames, wanted >= 4`)
		const space = at(l, /keyup " " Space 32$/) - at(l, /keydown " " Space 32$/)
		if (space < 3) ctx.fail(`Space held ${space} frames, wanted >= 3`)
		at(l, /keydown "a" KeyA 65$/)
		at(l, /keydown "Enter" Enter 13$/)
		return `ArrowUp ${held} frames, Space ${space} frames, a, Enter`
	})

	await ctx.scenario('PADS', async () => {
		await ctx.pad(0).press('cross', { frames: 3 })
		await ctx.pad(1).stick('left', 1, -0.5, { frames: 3 })
		await ctx.pad(1).hold('start')
		await ctx.frames(2)
		await ctx.pad(1).release('start')
		await ctx.frames(2)
		const l = await log()
		at(l, /gamepadconnected 0 standard$/)
		at(l, /gamepadconnected 1 standard$/)
		at(l, /pads 0:10000000000000000:0,0,0,0 /)
		at(l, /pads 0:0{17}:0,0,0,0 1:0{17}:1,-0\.5,0,0 /)
		at(l, /pads 0:0{17}:0,0,0,0 1:0{9}10{7}:0,0,0,0 /)
		const n = await ctx.js('return navigator.getGamepads().length')
		if (n !== 4) ctx.fail(`getGamepads() has ${n} slots, wanted 4`)
		const end = l.at(-1)
		if (!/pads 0:0{17}:0,0,0,0 1:0{17}:0,0,0,0 - -$/.test(end)) ctx.fail(`pads not back to rest : ${end}`)
		return 'pad 0 cross, pad 1 left stick + start, both back to rest'
	})

	await ctx.scenario('SHOT', async () => {
		const p = await ctx.shot('canvas')
		if (!(p.bytes > 1000)) ctx.fail(`PNG of ${p.bytes} bytes`)
		return `${p.file} ${p.bytes} bytes`
	})

	await ctx.scenario('RECORD', async () => {
		const p = await ctx.record('sound', async () => {
			await ctx.press('Enter')
			await ctx.frames(120)
		})
		if (!p.audio) ctx.fail(`recorded without an audio track (${p.mimeType})`)
		if (!(p.bytes > 10_000)) ctx.fail(`video of ${p.bytes} bytes`)
		return `${p.file} ${p.mimeType} ${p.seconds}s ${p.bytes} bytes, audio`
	})

	await ctx.scenario('SCREENCAST', async () => {
		const p = await ctx.record('silent', () => ctx.frames(60), { screencast: true })
		if (!(p.frames > 0)) ctx.fail('no screencast frame')
		return `${p.file} ${p.frames} frames (${p.mimeType})`
	})

	await ctx.scenario('FPS', async () => {
		const p = await ctx.fps({ ms: 2000, label: 'sidecar (Mesa, not a reference)' })
		if (!(p.avg > 0 && p.min > 0 && p.p95 > 0 && p.frames > 0)) ctx.fail(JSON.stringify(p))
		return `avg ${p.avg} min ${p.min} p95 ${p.p95} over ${p.frames} frames`
	})
}
