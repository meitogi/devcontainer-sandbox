// cdp-proxy.test.mjs — the policy as pure checks, then the proxy in front of a
// real Chromium when one answers. That part skips otherwise: point
// AGENT_BROWSER_TEST_CDP at a DevTools port (host:port) whose browser shows a
// page on one of the test origins below.
//
//   node --test /opt/devcontainer/base/skills/agent-browser/host/cdp-proxy.test.mjs
import assert from 'node:assert/strict';
import test from 'node:test';
import vm from 'node:vm';
import { allowedWorker, check, checkBrowser, originMatcher, pac, parseOrigin, parseOrigins, parseReach, resolverRules, serve } from './cdp-proxy.mjs';

const ORIGINS = 'https://localhost:7310 https://localhost:7331 https://*.robrowser.localhost:7316 http://localhost:5173 https://game.example.com';
const REACH = 'relay.example.com:8787 stun.l.google.com';
const origins = parseOrigins(ORIGINS);
const allowed = originMatcher(origins);

test('origin grammar: scheme://host[:port], wildcard host, default ports, refusals', () => {
	assert.deepEqual(parseOrigin('https://localhost:7310'), { protocol: 'https:', wildcard: false, host: 'localhost', port: '7310', text: 'https://localhost:7310' });
	assert.equal(parseOrigin('https://*.robrowser.localhost:7316').wildcard, true);
	assert.equal(parseOrigin('https://game.example.com').port, '443');
	assert.equal(parseOrigin('http://localhost').port, '80');
	assert.equal(parseOrigin('wss://relay.example.com').port, '443');
	for (const bad of ['localhost:7310', 'https://localhost:7310/', 'https://localhost:7310/path', 'file:///etc', 'https://', 'https://*', '*.localhost', 'https://a b', 'https://localhost:70000x']) {
		assert.throws(() => parseOrigin(bad), bad);
	}
	assert.throws(() => parseOrigins(''), /AGENT_BROWSER_ORIGINS is empty/);
	assert.throws(() => parseOrigins(undefined), /AGENT_BROWSER_ORIGINS is empty/);
	assert.equal(parseOrigins('https://a.test, https://b.test\n https://c.test').length, 3);
	assert.deepEqual(parseReach(' relay.example.com:8787  STUN.l.google.com '), ['relay.example.com:8787', 'stun.l.google.com']);
});

test('allowed URLs: the configured origins only', () => {
	for (const url of [
		'https://localhost:7310/',
		'https://localhost:7310/applications/pwa/index.html',
		'https://localhost:7331/client.js',
		'https://hpbar-855.robrowser.localhost:7316/',
		'https://a.b.robrowser.localhost:7316/x',
		'http://localhost:5173/',
		'https://game.example.com/',
		'https://game.example.com:443/play'
	]) {
		assert.ok(allowed(url), url);
	}
	for (const url of [
		'https://localhost:7300/',
		'https://localhost:7321/',
		'http://localhost:7310/',
		'https://localhost/',
		'http://localhost:5174/',
		'file:///Users/me/.ssh/id_ed25519',
		'https://example.com/',
		'https://robrowser.localhost:7316/',
		'https://x.robrowser.localhost.evil.com:7316/',
		'https://localhost:7310.evil.com/',
		'https://game.example.com.evil.com/',
		'https://relay.example.com:8787/',
		'wss://relay.example.com:8787/',
		'chrome://settings/',
		'about:blank',
		undefined,
		42
	]) {
		assert.ok(!allowed(url), String(url));
	}
});

test('pac: allowed origins and reach hosts DIRECT, nothing else', () => {
	const text = pac(origins, parseReach(REACH));
	const ctx = { dnsDomainIs: (h, d) => h.endsWith(d) };
	vm.runInNewContext(text, ctx);
	const route = url => ctx.FindProxyForURL(url, new URL(url).hostname);
	for (const url of [
		'https://localhost:7310/',
		'https://localhost:7331/',
		'https://pr-1.robrowser.localhost:7316/',
		'http://localhost:5173/',
		'https://game.example.com/',
		'https://game.example.com:443/',
		'wss://relay.example.com:8787/',
		'https://stun.l.google.com/'
	]) {
		assert.equal(route(url), 'DIRECT', url);
	}
	for (const url of ['https://localhost:7300/', 'https://github.com/', 'https://example.com/', 'http://localhost/', 'https://relay.example.com:9999/', 'http://game.example.com/']) {
		assert.match(route(url), /^PROXY 127\.0\.0\.1:9$/, url);
	}
});

test('resolver rules: everything NOTFOUND but the allowed and reach hosts', () => {
	const rules = resolverRules(origins, parseReach(REACH));
	assert.ok(rules.startsWith('MAP * ~NOTFOUND'), rules);
	for (const n of ['localhost', '127.0.0.1', '*.robrowser.localhost', 'game.example.com', 'relay.example.com', 'stun.l.google.com']) {
		assert.ok(rules.includes(`EXCLUDE ${n}`), n);
	}
	assert.equal(rules.split('EXCLUDE localhost').length, 2, 'localhost listed once');
	assert.ok(!rules.includes('8787'), 'no port in a resolver rule');
});

test('what drives or inspects the page passes', () => {
	for (const msg of [
		{ id: 1, method: 'Runtime.evaluate', params: { expression: '1+1' } },
		{ id: 2, method: 'Page.captureScreenshot', params: { format: 'png' } },
		{ id: 3, method: 'Page.startScreencast', params: {} },
		{ id: 4, method: 'Page.screencastFrameAck', params: { sessionId: 1 } },
		{ id: 5, method: 'Page.navigate', params: { url: 'https://localhost:7310/' } },
		{ id: 6, method: 'Page.reload' },
		{ id: 7, method: 'Network.enable' },
		{ id: 8, method: 'Input.dispatchMouseEvent', params: { type: 'mousePressed', x: 1, y: 1 } },
		{ id: 9, method: 'Emulation.setDeviceMetricsOverride', params: {} },
		{ id: 10, method: 'Target.getTargets' },
		{ id: 11, method: 'Page.createIsolatedWorld', params: { frameId: 'x' } },
		{ id: 12, method: 'Input.dispatchDragEvent', params: { type: 'drop', data: { items: [] } } },
		{ id: 13, method: 'Security.setIgnoreCertificateErrors', params: { ignore: true } },
		{ id: 14, method: 'Input.dispatchKeyEvent', params: { type: 'keyDown', key: 'ArrowUp' } }
	]) {
		assert.equal(check(msg, {}, allowed), null, msg.method);
	}
});

// visual-loop's player harness (lib/player.mjs) needs nothing beyond DOMAINS :
// its shims ride Page.addScriptToEvaluateOnNewDocument, the video comes back
// through Runtime.evaluate (base64 chunks) — IO stays refused, below.
test("the player harness's commands pass", () => {
	for (const msg of [
		{ id: 1, method: 'Page.addScriptToEvaluateOnNewDocument', params: { source: 'window.__player = {}' } },
		{ id: 2, method: 'Input.dispatchKeyEvent', params: { type: 'rawKeyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 } },
		{ id: 3, method: 'Input.dispatchKeyEvent', params: { type: 'keyUp', key: 'a', code: 'KeyA' } },
		{ id: 4, method: 'Runtime.evaluate', params: { expression: 'window.__player.recDrain()', awaitPromise: true, returnByValue: true } },
		{ id: 5, method: 'Page.captureScreenshot', params: { format: 'png', fromSurface: false } },
		{ id: 6, method: 'Page.startScreencast', params: { format: 'jpeg', quality: 80, everyNthFrame: 1 } },
		{ id: 7, method: 'Page.screencastFrameAck', params: { sessionId: 3 } },
		{ id: 8, method: 'Page.stopScreencast' }
	]) {
		assert.equal(check(msg, {}, allowed), null, msg.method);
	}
});

test('what reaches the host or another origin is refused', () => {
	for (const msg of [
		{ id: 1, method: 'Browser.getVersion' },
		{ id: 2, method: 'Browser.setDownloadBehavior', params: { behavior: 'allow', downloadPath: '/Users' } },
		{ id: 3, method: 'Target.createTarget', params: { url: 'file:///etc/passwd' } },
		{ id: 4, method: 'Target.attachToTarget', params: { targetId: 'x', flatten: true } },
		{ id: 5, method: 'Target.attachToBrowserTarget' },
		{ id: 6, method: 'DOM.setFileInputFiles', params: { files: ['/Users/me/.ssh/id_ed25519'] } },
		{ id: 7, method: 'Page.setDownloadBehavior', params: { behavior: 'allow' } },
		{ id: 8, method: 'Page.navigate', params: { url: 'file:///Users/me/' } },
		{ id: 9, method: 'Page.navigate', params: { url: 'https://example.com/' } },
		{ id: 10, method: 'Page.navigateToHistoryEntry', params: { entryId: 1 } },
		{ id: 11, method: 'Network.loadNetworkResource', params: { url: 'file:///etc/hosts' } },
		{ id: 12, method: 'Fetch.enable' },
		{ id: 13, method: 'IO.read', params: { handle: 'x' } },
		{ id: 14, method: 'Storage.clearDataForOrigin', params: { origin: '*' } },
		{ id: 15, method: 'SystemInfo.getProcessInfo' },
		{ id: 16, method: 'Page.createIsolatedWorld', params: { frameId: 'x', grantUniveralAccess: true } },
		{ id: 17, method: 'Input.dispatchDragEvent', params: { type: 'drop', data: { files: ['/Users/me/x'] } } },
		{ id: 18, method: 'Runtime.evaluate', sessionId: 'another-target', params: { expression: '1' } },
		{ id: 19 },
		null
	]) {
		assert.ok(check(msg, {}, allowed), JSON.stringify(msg));
	}
});

test("the page's workers: auto-attached, then checked like the page", () => {
	const sessions = { 'w-1': true };
	for (const msg of [
		{ id: 1, method: 'Target.setAutoAttach', params: { autoAttach: true, waitForDebuggerOnStart: false, flatten: true } },
		{ id: 2, method: 'Runtime.enable', sessionId: 'w-1' },
		{ id: 3, method: 'Runtime.evaluate', sessionId: 'w-1', params: { expression: '1' } },
		{ id: 4, method: 'Target.detachFromTarget', params: { sessionId: 'w-1' } }
	]) {
		assert.equal(check(msg, sessions, allowed), null, JSON.stringify(msg));
	}
	for (const msg of [
		{ id: 1, method: 'Target.setAutoAttach', params: { autoAttach: true, waitForDebuggerOnStart: false } },
		{ id: 2, method: 'Target.setAutoAttach', params: { autoAttach: true, flatten: false } },
		{ id: 3, method: 'Target.detachFromTarget', params: { sessionId: 'not-ours' } },
		{ id: 4, method: 'Runtime.evaluate', sessionId: 'not-ours', params: { expression: '1' } },
		{ id: 5, method: 'Target.sendMessageToTarget', params: { sessionId: 'w-1', message: '{}' } },
		{ id: 6, method: 'Target.exposeDevToolsProtocol', params: { targetId: 'x' } },
		{ id: 7, method: 'Target.setDiscoverTargets', params: { discover: true } },
		{ id: 8, method: 'Target.createTarget', sessionId: 'w-1', params: { url: 'file:///etc/passwd' } },
		{ id: 9, method: 'Browser.getVersion', sessionId: 'w-1' },
		{ id: 10, method: 'Network.loadNetworkResource', sessionId: 'w-1', params: { url: 'file:///etc/hosts' } }
	]) {
		assert.ok(check(msg, sessions, allowed), JSON.stringify(msg));
	}
	for (const info of [
		{ type: 'worker', url: 'https://localhost:7310/src/Core/ThreadEventHandler.js' },
		{ type: 'worker', url: 'blob:https://hpbar-855.robrowser.localhost:7316/0b5c-4e' }
	]) {
		assert.ok(allowedWorker(info, allowed), info.url);
	}
	for (const info of [
		{ type: 'iframe', url: 'https://localhost:7310/' },
		{ type: 'service_worker', url: 'https://localhost:7310/sw.js' },
		{ type: 'worker', url: 'https://example.com/w.js' },
		{ type: 'worker', url: 'blob:https://example.com/0b5c' },
		{ type: 'page', url: 'https://localhost:7310/' },
		undefined
	]) {
		assert.ok(!allowedWorker(info, allowed), JSON.stringify(info));
	}
});

test('the browser door: Target.* on allowed targets, Storage.clear*, nothing else browser-level', () => {
	const known = { T1: true };
	const sessions = { 'p-1': true, 'w-1': true };
	for (const msg of [
		{ id: 1, method: 'Target.getTargets' },
		{ id: 2, method: 'Target.attachToTarget', params: { targetId: 'T1', flatten: true } },
		{ id: 3, method: 'Target.activateTarget', params: { targetId: 'T1' } },
		{ id: 4, method: 'Target.closeTarget', params: { targetId: 'T1' } },
		{ id: 5, method: 'Target.createTarget', params: { url: 'http://localhost:5173/' } },
		{ id: 6, method: 'Target.detachFromTarget', params: { sessionId: 'p-1' } },
		{ id: 7, method: 'Storage.clearCookies' },
		{ id: 8, method: 'Storage.clearDataForOrigin', params: { origin: 'https://localhost:7310', storageTypes: 'all' } },
		// attached sessions are checked like a page
		{ id: 9, method: 'Runtime.evaluate', sessionId: 'p-1', params: { expression: '1' } },
		{ id: 10, method: 'Security.enable', sessionId: 'p-1' },
		{ id: 11, method: 'Target.setAutoAttach', sessionId: 'p-1', params: { autoAttach: true, flatten: true } },
		{ id: 12, method: 'Runtime.evaluate', sessionId: 'w-1', params: { expression: '1' } }
	]) {
		assert.equal(checkBrowser(msg, known, sessions, allowed), null, JSON.stringify(msg));
	}
	for (const msg of [
		{ id: 1, method: 'Target.attachToTarget', params: { targetId: 'T2', flatten: true } },
		{ id: 2, method: 'Target.attachToTarget', params: { targetId: 'T1' } },
		{ id: 3, method: 'Target.activateTarget', params: { targetId: 'T2' } },
		{ id: 4, method: 'Target.closeTarget', params: { targetId: 'T2' } },
		{ id: 5, method: 'Target.createTarget', params: { url: 'about:blank' } },
		{ id: 6, method: 'Target.createTarget', params: { url: 'file:///etc/passwd' } },
		{ id: 7, method: 'Target.createTarget', params: { url: 'https://example.com/' } },
		{ id: 8, method: 'Target.setAutoAttach', params: { autoAttach: true, flatten: true } },
		{ id: 9, method: 'Target.setDiscoverTargets', params: { discover: true } },
		{ id: 10, method: 'Target.attachToBrowserTarget' },
		{ id: 11, method: 'Target.detachFromTarget', params: { sessionId: 'not-ours' } },
		{ id: 12, method: 'Browser.getVersion' },
		{ id: 13, method: 'Browser.setDownloadBehavior', params: { behavior: 'allow', downloadPath: '/Users' } },
		{ id: 14, method: 'Storage.clearDataForOrigin', params: { origin: 'https://example.com' } },
		{ id: 15, method: 'Storage.clearDataForOrigin', params: { origin: '*' } },
		{ id: 16, method: 'Runtime.evaluate', params: { expression: '1' } },
		{ id: 17, method: 'Page.navigate', params: { url: 'https://localhost:7310/' } },
		{ id: 18, method: 'Runtime.evaluate', sessionId: 'not-ours', params: { expression: '1' } },
		{ id: 19, method: 'SystemInfo.getInfo' },
		{ id: 20 },
		null
	]) {
		assert.ok(checkBrowser(msg, known, sessions, allowed), JSON.stringify(msg));
	}
});

const CDP = process.env.AGENT_BROWSER_TEST_CDP || '';
const live = CDP
	? await fetch(`http://${CDP}/json/list`)
			.then(r => r.json())
			.then(l => l.some(t => t.type === 'page' && allowed(t.url)))
			.catch(() => false)
	: false;

test('in front of a real Chromium', { skip: !live && 'no agent page on AGENT_BROWSER_TEST_CDP' }, async t => {
	const server = serve({ listen: '127.0.0.1:9339', upstream: CDP, origins: ORIGINS });
	await new Promise(r => server.once('listening', r));
	t.after(() => server.close());
	const base = 'http://127.0.0.1:9339';

	const version = await (await fetch(`${base}/json/version`)).json();
	assert.ok(version.Browser, 'version answered');
	assert.equal(version.webSocketDebuggerUrl, 'ws://127.0.0.1:9339/devtools/browser/agent', 'the browser socket is the proxy door');

	const list = await (await fetch(`${base}/json/list`)).json();
	assert.ok(list.length > 0, 'the agent page is listed');
	assert.ok(list.every(p => allowed(p.url)), 'only allowed pages');
	assert.ok(list[0].webSocketDebuggerUrl.startsWith('ws://127.0.0.1:9339/devtools/page/'), 'socket through the proxy');

	for (const path of ['/json/new?file:///etc/passwd', '/json/close/x', '/json/protocol', '/devtools/inspector.html']) {
		assert.equal((await fetch(base + path)).status, 403, path);
	}

	const open = async url => {
		const ws = new WebSocket(url);
		await new Promise((resolve, reject) => {
			ws.onopen = resolve;
			ws.onerror = reject;
		});
		t.after(() => ws.close());
		let id = 0;
		const pending = {};
		const events = [];
		ws.onmessage = e => {
			const m = JSON.parse(e.data);
			if (m.id && pending[m.id]) pending[m.id](m);
			else if (m.method) events.push(m);
		};
		const send = (method, params, sessionId) =>
			new Promise(resolve => {
				pending[++id] = resolve;
				ws.send(JSON.stringify({ id, method, params, sessionId }));
			});
		return { ws, send, events };
	};

	// --- the page door, as before
	const page = await open(list[0].webSocketDebuggerUrl);
	assert.equal((await page.send('Runtime.evaluate', { expression: '6*7', returnByValue: true })).result.result.value, 42);
	const shot = await page.send('Page.captureScreenshot', { format: 'png' });
	assert.ok(shot.result.data.length > 1000, 'screenshot through the page door');
	for (const [method, params] of [
		['Browser.getVersion', {}],
		['Target.createTarget', { url: 'file:///etc/passwd' }],
		['Page.navigate', { url: 'https://example.com/' }],
		['DOM.setFileInputFiles', { files: ['/etc/passwd'], nodeId: 1 }]
	]) {
		const r = await page.send(method, params);
		assert.match(r.error && r.error.message, /refused by cdp-proxy/, method);
	}

	// --- the browser door, the way visual-loop's cdp.mjs uses it
	const browser = await open(version.webSocketDebuggerUrl);
	const targets = await browser.send('Target.getTargets');
	assert.ok(targets.result.targetInfos.length > 0, 'targets listed');
	assert.ok(targets.result.targetInfos.every(ti => allowed(ti.url) || ti.type === 'worker'), 'only allowed targets listed');
	const pageTarget = targets.result.targetInfos.find(ti => ti.type === 'page');
	const attach = await browser.send('Target.attachToTarget', { targetId: pageTarget.targetId, flatten: true });
	assert.ok(attach.result && attach.result.sessionId, 'attached with flatten');
	const sid = attach.result.sessionId;
	assert.equal((await browser.send('Runtime.evaluate', { expression: '6*7', returnByValue: true }, sid)).result.result.value, 42, 'evaluated in the attached session');
	assert.equal((await browser.send('Security.setIgnoreCertificateErrors', { ignore: true }, sid)).error, undefined, 'Security passes on a session');
	assert.equal((await browser.send('Target.activateTarget', { targetId: pageTarget.targetId })).error, undefined, 'activate an allowed target');
	for (const [method, params, s] of [
		['Browser.getVersion', {}, undefined],
		['Target.attachToTarget', { targetId: 'nope', flatten: true }, undefined],
		['Target.attachToTarget', { targetId: pageTarget.targetId }, undefined],
		['Target.createTarget', { url: 'about:blank' }, undefined],
		['Target.createTarget', { url: 'file:///etc/passwd' }, undefined],
		['Target.setAutoAttach', { autoAttach: true, flatten: true }, undefined],
		['Runtime.evaluate', { expression: '1' }, undefined],
		['Runtime.evaluate', { expression: '1' }, 'not-ours'],
		['Page.navigate', { url: 'https://example.com/' }, sid]
	]) {
		const r = await browser.send(method, params, s);
		assert.match(r.error && r.error.message, /refused by cdp-proxy/, `${method} ${s || ''}`);
	}
	assert.equal((await browser.send('Target.detachFromTarget', { sessionId: sid })).error, undefined, 'detach our own session');

	const browserSocket = await fetch(`${base}/devtools/browser/x`, { headers: { Connection: 'Upgrade', Upgrade: 'websocket' } }).catch(e => e);
	assert.ok(browserSocket instanceof Error || browserSocket.status === 403, 'any other browser socket refused');
});
