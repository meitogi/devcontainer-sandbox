#!/usr/bin/env node
// headless-parity.mjs — what a site can see of the agent browser, headless then
// windowed, the two reports diffed. Run in the CONTAINER, the host browser up on
// a page of the project's origins (the page shown is the one probed) :
//
//   node packages/devcontainer-sandbox/test/host/headless-parity.mjs [-i <letter>]
//
// 1. headless : the probe evaluated in the page (the visual-loop lock taken, as
//    any script) ;
// 2. `agent-browser handoff` : the same page in a real window for a few
//    seconds — nothing for the user to do, the banner says so — probed again
//    (the handoff holds the lock : this read goes around it, a measurement) ;
// 3. `agent-browser handback`, then every field that differs, printed.
//
// Both reports go to .devcontainer/tmp/agent-browser-checks/parity-<epoch>.json.
// Exit 0 when nothing differs but what is listed in EXPECTED, 1 otherwise.
import { spawn, spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';

// The tree's cdp.mjs, like the tree's agent-browser the live check puts first on PATH.
const CDP = await import(new URL('../../assets/opt/skills/visual-loop/scripts/cdp.mjs', import.meta.url).href);
const { acquireLock, connect, fetchBrowserWsUrl, resolveEndpoint } = CDP;
const i = process.argv.indexOf('-i');
const INSTANCE = i > 0 ? process.argv[i + 1] : process.env.AGENT_BROWSER_INSTANCE || 'a';
process.env.CDP_INSTANCE = INSTANCE;
const ab = (...a) => spawnSync('agent-browser', ['-i', INSTANCE, ...a], { encoding: 'utf8' });

// Differences a window cannot help having : where it sits on the screen, and the
// screen it is on (headless has none — its screen is the window size).
const EXPECTED = { 'window.screenX': 1, 'window.screenY': 1 };

const PROBE = `(async () => {
	const n = navigator, s = screen;
	const gl = (() => { try { const c = document.createElement('canvas').getContext('webgl'); const e = c.getExtension('WEBGL_debug_renderer_info'); return { vendor: c.getParameter(e.UNMASKED_VENDOR_WEBGL), renderer: c.getParameter(e.UNMASKED_RENDERER_WEBGL) }; } catch (e) { return String(e); } })();
	const permissions = {};
	for (const name of ['notifications', 'geolocation', 'camera', 'microphone', 'clipboard-read']) { try { permissions[name] = (await n.permissions.query({ name })).state; } catch { permissions[name] = 'n/a'; } }
	const uad = n.userAgentData ? { brands: n.userAgentData.brands, mobile: n.userAgentData.mobile, platform: n.userAgentData.platform, high: await n.userAgentData.getHighEntropyValues(['architecture', 'bitness', 'fullVersionList', 'model', 'platformVersion', 'wow64']) } : null;
	const worker = await new Promise(r => { try { const w = new Worker(URL.createObjectURL(new Blob(['postMessage({ ua: navigator.userAgent, brands: navigator.userAgentData && navigator.userAgentData.brands })'], { type: 'text/javascript' }))); w.onmessage = e => { r(e.data); w.terminate(); }; w.onerror = () => r('worker refused (CSP?)'); setTimeout(() => r('timeout'), 3000); } catch (e) { r(String(e)); } });
	return {
		userAgent: n.userAgent, userAgentData: uad, webdriver: n.webdriver,
		plugins: [...n.plugins].map(p => p.name), mimeTypes: n.mimeTypes.length, pdfViewerEnabled: n.pdfViewerEnabled,
		languages: n.languages, language: n.language, hardwareConcurrency: n.hardwareConcurrency, deviceMemory: n.deviceMemory, maxTouchPoints: n.maxTouchPoints,
		screen: { width: s.width, height: s.height, availWidth: s.availWidth, availHeight: s.availHeight, colorDepth: s.colorDepth, pixelDepth: s.pixelDepth },
		window: { outerWidth, outerHeight, innerWidth, innerHeight, devicePixelRatio, screenX, screenY },
		webgl: gl, notification: typeof Notification === 'undefined' ? 'n/a' : Notification.permission, permissions,
		timezone: Intl.DateTimeFormat().resolvedOptions().timeZone, chrome: typeof window.chrome === 'object' ? Object.keys(window.chrome).sort() : null,
		colorScheme: matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light', visibility: document.visibilityState, worker,
	};
})()`;

async function probe(ep) {
	const conn = await connect(await fetchBrowserWsUrl(ep));
	try {
		const { targetInfos } = await conn.send('Target.getTargets');
		const page = targetInfos.find(t => t.type === 'page');
		if (!page) throw new Error('no page on an allowed origin in the agent browser — agent-browser up <url> first');
		const { sessionId } = await conn.send('Target.attachToTarget', { targetId: page.targetId, flatten: true });
		const r = await conn.send('Runtime.evaluate', { expression: PROBE, awaitPromise: true, returnByValue: true }, sessionId, 20000);
		if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
		return { url: page.url, ...r.result.value };
	} finally {
		conn.close();
	}
}

function flat(o, prefix = '', out = {}) {
	for (const k in o) {
		const v = o[k];
		const key = prefix ? `${prefix}.${k}` : k;
		if (v && typeof v === 'object' && !Array.isArray(v)) flat(v, key, out);
		else out[key] = JSON.stringify(v);
	}
	return out;
}

const ep = await resolveEndpoint();
if (ep.agent?.side !== 'host') {
	console.error(`✗ instance ${INSTANCE} is not on the host (${ep.agent?.side ?? 'explicit CDP_HOST'}) — the window needs the host browser`);
	process.exit(2);
}
const release = await acquireLock('headless-parity (headless read)', 0);
console.log('1/3 headless : probing the page shown');
const headless = await probe(ep);
release();

console.log('2/3 windowed : a handoff for a few seconds — nothing to do in the window');
const handoff = spawn('agent-browser', ['-i', INSTANCE, 'handoff', '--say', 'Parity probe — nothing to do, this window closes by itself in a few seconds'], { stdio: ['ignore', 'pipe', 'inherit'] });
let said = '';
handoff.stdout.on('data', d => (said += d));
for (let t = 0; !/the window is the user's/.test(said); t++) {
	if (t > 60 || handoff.exitCode !== null) {
		console.error(`✗ the handoff did not start :\n${said}`);
		process.exit(1);
	}
	await sleep(500);
}
await sleep(4000); // the page reloads in the window, and its scripts settle
let windowed;
try {
	windowed = await probe(ep);
} finally {
	console.log('3/3 handback');
	process.stdout.write(ab('handback').stdout);
	await new Promise(r => (handoff.exitCode !== null ? r() : handoff.on('exit', r)));
}

const a = flat(headless);
const b = flat(windowed);
const diffs = [];
for (const k of [...new Set([...Object.keys(a), ...Object.keys(b)])].sort()) {
	if (a[k] !== b[k]) diffs.push({ field: k, headless: a[k], windowed: b[k], expected: !!EXPECTED[k] });
}
const dir = resolve('.devcontainer/tmp/agent-browser-checks');
mkdirSync(dir, { recursive: true });
const file = resolve(dir, `parity-${Date.now()}.json`);
writeFileSync(file, `${JSON.stringify({ instance: INSTANCE, headless, windowed, diffs }, null, 2)}\n`);
console.log(`\nprobed ${headless.url}\nuser-agent      : ${headless.userAgent}\nbrands headless : ${JSON.stringify(headless.userAgentData?.brands)}\nbrands windowed : ${JSON.stringify(windowed.userAgentData?.brands)}\n`);
for (const d of diffs) console.log(`${d.expected ? '  (expected) ' : '  DIFFERS    '}${d.field}\n      headless ${d.headless}\n      windowed ${d.windowed}`);
const bad = diffs.filter(d => !d.expected);
console.log(`\n${bad.length ? `FAIL — ${bad.length} unexplained difference(s)` : 'PASS — nothing differs but the window\'s place'} · ${file}`);
process.exit(bad.length ? 1 : 0);
