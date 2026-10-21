#!/usr/bin/env node
/**
 * cdp-proxy.mjs — the only DevTools door into the agent browser on the host.
 *
 * Chromium's own DevTools port (127.0.0.1:9323) gives whoever reaches it the
 * whole browser: file:// pages, downloads written anywhere, new targets on any
 * URL. This proxy is what the container talks to instead (host:9223 in the
 * project's firewall/ports.txt). It lets through what inspects or drives a page
 * on an ALLOWED ORIGIN and refuses, by default, everything else:
 *
 *   - HTTP: /json/version (the browser socket in it is the proxy's own door),
 *     /json/list filtered to page targets on an allowed URL; every other path 403.
 *   - WebSocket, two doors:
 *       /devtools/page/<id>      a page target on an allowed URL (as DevTools does);
 *       /devtools/browser/agent  the browser-level door the visual-loop scripts
 *                                need: Target.getTargets answered filtered,
 *                                attach / activate / close only for an allowed
 *                                target, createTarget only for an allowed URL,
 *                                every attached session checked like a page.
 *     The targets are re-read every second and the socket closed the moment an
 *     attached page leaves the allowed list.
 *   - Messages: an allowlist of domains, minus the methods that reach the host's
 *     disk or another origin (check() below). Refusals answer a CDP error and
 *     are logged.
 *   - Workers: Target.setAutoAttach (flatten) on a page attaches its children.
 *     A dedicated worker on an allowed URL gets a session, whose messages go
 *     through the same check(); any other child is detached by the proxy and
 *     never shown.
 *
 * The allowed origins are the project's AGENT_BROWSER_ORIGINS (space-separated
 * `scheme://host[:port]`, host may start with `*.`), plus AGENT_BROWSER_REACH:
 * hosts the page may connect to (a relay, STUN) but never be navigated to. This
 * file is the one implementation of that grammar — the shell sides call its
 * verbs instead of re-reading the list:
 *
 *   node cdp-proxy.mjs serve [--listen 127.0.0.1:9223] [--upstream 127.0.0.1:9323] [--origins "…"] [--reach "…"]
 *   node cdp-proxy.mjs check-url <url> [--origins "…"]      exit 0 allowed, 1 refused
 *   node cdp-proxy.mjs pac [--origins "…"] [--reach "…"]     the proxy auto-config text
 *   node cdp-proxy.mjs resolver-rules [--origins "…"] [--reach "…"]   --host-resolver-rules value
 *
 * Flag > env > hard stop: no origins means exit 2, never "allow everything".
 * Zero dependencies: the server side of the WebSocket is a minimal RFC 6455,
 * the client side Node's own WebSocket (Node >= 22).
 */
import crypto from 'node:crypto';
import http from 'node:http';
import { pathToFileURL } from 'node:url';

const DEFAULT_PORT = { 'http:': '80', 'https:': '443', 'ws:': '80', 'wss:': '443' };

/**
 * Parse one `scheme://host[:port]` pattern. `host` may start with `*.` (one or
 * more labels before the suffix). Throws on anything else: a typo in the
 * allowlist must stop the browser, not widen it.
 */
export function parseOrigin(text) {
	const m = /^(https?|wss?):\/\/(\*\.)?([a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*)(:(\d{1,5}))?$/i.exec(text.trim());
	if (!m) throw new Error(`not an origin (scheme://host[:port], host may start with *.): ${text}`);
	const protocol = `${m[1].toLowerCase()}:`;
	return { protocol, wildcard: !!m[2], host: m[3].toLowerCase(), port: m[8] || DEFAULT_PORT[protocol], text: text.trim() };
}

/** The list, parsed. Empty or missing → an error naming the variable. */
export function parseOrigins(text) {
	const list = String(text || '').trim().split(/[\s,]+/).filter(Boolean);
	if (!list.length) throw new Error('AGENT_BROWSER_ORIGINS is empty — set it in .devcontainer/.env (space-separated scheme://host[:port])');
	return list.map(parseOrigin);
}

const hostMatches = (o, hostname) =>
	o.wildcard ? hostname.endsWith(`.${o.host}`) && hostname.length > o.host.length + 1 : hostname === o.host;

/**
 * `url => boolean` for a parsed origin list. Only http(s) pages count: a
 * `wss://` origin lets the page open that socket (PAC + resolver) but is not a
 * page one may navigate to.
 */
export function originMatcher(origins) {
	const pages = origins.filter(o => o.protocol === 'http:' || o.protocol === 'https:');
	return url => {
		if (typeof url !== 'string') return false;
		let u;
		try {
			u = new URL(url);
		} catch {
			return false;
		}
		if (u.protocol !== 'http:' && u.protocol !== 'https:') return false;
		const port = u.port || DEFAULT_PORT[u.protocol];
		return pages.some(o => o.protocol === u.protocol && o.port === port && hostMatches(o, u.hostname));
	};
}

/** `host[:port]` words the page may reach without being navigable. */
export const parseReach = text => String(text || '').trim().split(/[\s,]+/).filter(Boolean).map(w => w.toLowerCase());

/**
 * The proxy auto-config: the allowed origins and the reach hosts go DIRECT,
 * everything else to a proxy that does not exist (ERR_PROXY_CONNECTION_FAILED).
 * `<-loopback>` in --proxy-bypass-list sends localhost through this too.
 */
export function pac(origins, reach = []) {
	const lines = [];
	for (const o of origins) {
		const ports = o.port === DEFAULT_PORT[o.protocol] ? `(port === '' || port === '${o.port}')` : `port === '${o.port}'`;
		const host = o.wildcard ? `dnsDomainIs(host, '.${o.host}')` : `host === '${o.host}'`;
		lines.push(`\tif (scheme === '${o.protocol.slice(0, -1)}' && ${host} && ${ports}) return 'DIRECT';`);
	}
	for (const r of reach) {
		const [h, p] = r.split(':');
		const host = h.startsWith('*.') ? `dnsDomainIs(host, '${h.slice(1)}')` : `host === '${h}'`;
		lines.push(p ? `\tif (${host} && port === '${p}') return 'DIRECT';` : `\tif (${host}) return 'DIRECT';`);
	}
	return [
		'// generated by cdp-proxy.mjs pac — the only addresses the agent browser may reach',
		'function FindProxyForURL(url, host) {',
		"\tvar scheme = url.substring(0, url.indexOf('://')).toLowerCase();",
		"\tvar hostport = url.substring(url.indexOf('://') + 3).split('/')[0];",
		"\tvar colon = hostport.lastIndexOf(':');",
		"\tvar port = colon < 0 ? '' : hostport.substring(colon + 1);",
		...lines,
		"\treturn 'PROXY 127.0.0.1:9';",
		'}',
		''
	].join('\n');
}

/**
 * --host-resolver-rules: every name fails to resolve except the allowed hosts,
 * so what the PAC does not cover (WebRTC, DNS prefetch) is cut at the resolver.
 */
export function resolverRules(origins, reach = []) {
	const names = ['localhost', '127.0.0.1'];
	for (const o of origins) names.push(o.wildcard ? `*.${o.host}` : o.host);
	for (const r of reach) names.push(r.split(':')[0]);
	const seen = {};
	const out = ['MAP * ~NOTFOUND'];
	for (const n of names) {
		if (seen[n]) continue;
		seen[n] = true;
		out.push(`EXCLUDE ${n}`);
	}
	return out.join(', ');
}

const DOMAINS = [
	'Accessibility',
	'Animation',
	'CSS',
	'Console',
	'DOM',
	'DOMStorage',
	'Debugger',
	'Emulation',
	'HeapProfiler',
	'IndexedDB',
	'Input',
	'Inspector',
	'LayerTree',
	'Log',
	'Memory',
	'Network',
	'Overlay',
	'Page',
	'Performance',
	'Profiler',
	'Runtime',
	'Security'
];

/** Inside an allowed domain, still a way out: the host's files, downloads, other origins. */
const DENIED = {
	'DOM.setFileInputFiles': 'hands the page files from the host',
	'DOM.getFileInfo': 'reads a file path on the host',
	'Page.setDownloadBehavior': 'writes downloads on the host',
	'Page.navigateToHistoryEntry': 'navigation outside the allowed URLs',
	'Network.loadNetworkResource': 'fetches any URL, file:// included',
	'Network.setRequestInterception': 'rewrites requests',
	'Network.continueInterceptedRequest': 'rewrites requests'
};

/** A worker of the page: same-origin script, or a blob: of an allowed origin. */
export const allowedWorker = (info, allowed) =>
	!!info && info.type === 'worker' && allowed(String(info.url).replace(/^blob:/, ''));

/**
 * One command on a page session (the page door, or an attached session of the
 * browser door). null when it may pass, else why not. `sessions`: the
 * sessionIds the proxy let through (attached pages, their workers), as keys.
 * Pure, so the whole policy is testable without a browser.
 */
export function check(msg, sessions = {}, allowed = () => false) {
	if (!msg || typeof msg.method !== 'string') {
		return 'not a CDP command';
	}
	if (msg.sessionId && !sessions[msg.sessionId]) {
		return 'session is not one of this page';
	}
	const { method, params = {} } = msg;
	if (method === 'Target.getTargets') {
		return null;
	}
	// Children of this target only (its workers, its frames) — never another one.
	if (method === 'Target.setAutoAttach') {
		return params.flatten === true ? null : 'auto-attach without flatten routes messages around check()';
	}
	if (method === 'Target.detachFromTarget') {
		return sessions[params.sessionId] ? null : 'not a session of this page';
	}
	if (!DOMAINS.includes(method.split('.')[0])) {
		return `domain ${method.split('.')[0]} is not allowed`;
	}
	if (DENIED[method]) {
		return DENIED[method];
	}
	if (method === 'Page.navigate' && !allowed(params.url)) {
		return `navigation to ${params.url} is outside the allowed origins`;
	}
	if (method === 'Page.createIsolatedWorld' && params.grantUniveralAccess) {
		return 'universal access bypasses the same-origin policy';
	}
	if (method === 'Input.dispatchDragEvent' && params.data && params.data.files && params.data.files.length) {
		return 'drops files from the host into the page';
	}
	return null;
}

/**
 * One command on the browser door WITHOUT a sessionId: browser-level. Only what
 * reaches an allowed target passes; `known` holds the allowed target ids (as
 * keys) at the time of the call. Pure as well.
 */
export function checkBrowser(msg, known = {}, sessions = {}, allowed = () => false) {
	if (!msg || typeof msg.method !== 'string') {
		return 'not a CDP command';
	}
	if (msg.sessionId) {
		return check(msg, sessions, allowed);
	}
	const { method, params = {} } = msg;
	switch (method) {
		case 'Target.getTargets':
			return null;
		case 'Target.attachToTarget':
			if (params.flatten !== true) return 'attach without flatten routes messages around check()';
			return known[params.targetId] ? null : 'not a target on an allowed origin';
		case 'Target.activateTarget':
		case 'Target.closeTarget':
			return known[params.targetId] ? null : 'not a target on an allowed origin';
		case 'Target.createTarget':
			return allowed(params.url) ? null : `a new target on ${params.url} is outside the allowed origins`;
		case 'Target.detachFromTarget':
			return sessions[params.sessionId] ? null : 'not a session of this door';
		case 'Storage.clearCookies':
			// The whole profile's cookies — a profile dedicated to the agent browser.
			return null;
		case 'Storage.clearDataForOrigin':
			return allowed(`${params.origin}/`) ? null : `${params.origin} is not an allowed origin`;
		default:
			return `${method} is browser-level: only Target.* on allowed targets and Storage.clear* pass here`;
	}
}

const log = (...a) => console.log(new Date().toISOString(), '[cdp-proxy]', ...a);

/** One WebSocket frame, server to client: never masked. */
function frame(opcode, payload) {
	const len = payload.length;
	const head = len < 126 ? Buffer.from([0x80 | opcode, len]) : len < 65536 ? Buffer.alloc(4) : Buffer.alloc(10);
	if (len >= 126) {
		head[0] = 0x80 | opcode;
		if (len < 65536) {
			head[1] = 126;
			head.writeUInt16BE(len, 2);
		} else {
			head[1] = 127;
			head.writeBigUInt64BE(BigInt(len), 2);
		}
	}
	return Buffer.concat([head, payload]);
}

/** Minimal RFC 6455 reader: masked client frames, fragmentation, ping, close. */
function reader(onMessage, onClose, socket) {
	let buf = Buffer.alloc(0);
	let parts = [];
	return chunk => {
		buf = Buffer.concat([buf, chunk]);
		for (;;) {
			if (buf.length < 2) return;
			const fin = buf[0] & 0x80;
			const opcode = buf[0] & 0x0f;
			const masked = buf[1] & 0x80;
			let len = buf[1] & 0x7f;
			let off = 2;
			if (len === 126) {
				if (buf.length < 4) return;
				len = buf.readUInt16BE(2);
				off = 4;
			} else if (len === 127) {
				if (buf.length < 10) return;
				len = Number(buf.readBigUInt64BE(2));
				off = 10;
			}
			const maskOff = off;
			if (masked) off += 4;
			if (buf.length < off + len) return;
			const data = Buffer.from(buf.subarray(off, off + len));
			if (masked) {
				for (let i = 0; i < len; i++) data[i] ^= buf[maskOff + (i & 3)];
			}
			buf = buf.subarray(off + len);
			if (opcode === 0x8) {
				onClose();
				return;
			}
			if (opcode === 0x9) {
				socket.write(frame(0xa, data));
				continue;
			}
			if (opcode === 0xa) continue;
			parts.push(data);
			if (fin) {
				onMessage(Buffer.concat(parts).toString('utf8'));
				parts = [];
			}
		}
	};
}

export function serve({ listen = '127.0.0.1:9223', upstream = '127.0.0.1:9323', origins } = {}) {
	const allowed = originMatcher(parseOrigins(origins));
	const [host, port] = listen.split(':');

	async function pages() {
		const list = await (await fetch(`http://${upstream}/json/list`)).json();
		return list.filter(t => t.type === 'page' && allowed(t.url));
	}
	async function browserWs() {
		const v = await (await fetch(`http://${upstream}/json/version`)).json();
		const u = new URL(v.webSocketDebuggerUrl);
		return `ws://${upstream}${u.pathname}`;
	}

	const server = http.createServer(async (req, res) => {
		const path = req.url.split('?')[0];
		try {
			if (req.method === 'GET' && path === '/json/version') {
				const v = await (await fetch(`http://${upstream}/json/version`)).json();
				v.webSocketDebuggerUrl = `ws://${req.headers.host}/devtools/browser/agent`;
				res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify(v));
				return;
			}
			if (req.method === 'GET' && (path === '/json/list' || path === '/json')) {
				const out = (await pages()).map(t => ({
					id: t.id,
					type: t.type,
					title: t.title,
					url: t.url,
					webSocketDebuggerUrl: `ws://${req.headers.host}/devtools/page/${t.id}`
				}));
				res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify(out));
				return;
			}
		} catch (e) {
			res.writeHead(502).end(`upstream: ${e.message}`);
			return;
		}
		log(`refused HTTP ${req.method} ${path}`);
		res.writeHead(403).end('refused by cdp-proxy');
	});

	server.on('upgrade', async (req, socket) => {
		const page = /^\/devtools\/page\/([A-Za-z0-9]+)$/.exec(req.url);
		const browser = req.url === '/devtools/browser/agent';
		let target = null;
		let upUrl = null;
		try {
			if (page) {
				target = (await pages()).find(t => t.id === page[1]) || null;
				if (target) upUrl = `ws://${upstream}/devtools/page/${target.id}`;
			} else if (browser) {
				upUrl = await browserWs();
			}
		} catch {
			upUrl = null;
		}
		if (!upUrl || !req.headers['sec-websocket-key']) {
			log(`refused socket ${req.url}`);
			socket.end('HTTP/1.1 403 Forbidden\r\n\r\n');
			return;
		}
		const accept = crypto
			.createHash('sha1')
			.update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
			.digest('base64');
		socket.write(
			`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`
		);
		const door = browser ? 'browser' : `page ${target.id}`;
		const up = new WebSocket(upUrl);
		const pending = [];
		// sessionId → true for the sessions let through (attached pages, their
		// workers); targetId → true for the allowed targets as last listed;
		// sessionId → targetId for the pages attached on the browser door; ids of
		// the proxy's own detaches, whose answers stay here; ids of the client's
		// attach / getTargets calls, whose answers need a look on the way back.
		const sessions = {};
		const known = {};
		const attached = {};
		const own = {};
		const watchIds = {};
		let ownId = 1e9;
		let closed = false;
		const close = why => {
			if (closed) return;
			closed = true;
			clearInterval(watch);
			if (why) log(`closed ${door}: ${why}`);
			try {
				socket.end(frame(0x8, Buffer.alloc(0)));
			} catch {
				// already gone
			}
			try {
				up.close();
			} catch {
				// already gone
			}
		};
		const refresh = async () => {
			const list = await pages().catch(() => null);
			if (!list) return false;
			for (const k in known) delete known[k];
			for (const t of list) known[t.id] = true;
			return true;
		};
		// The page may navigate itself away: the session ends with the allowed URL.
		const watch = setInterval(async () => {
			if (!(await refresh())) return;
			if (target && !known[target.id]) close('target left the allowed origins');
			for (const sid in attached) {
				if (!known[attached[sid]]) close(`attached target ${attached[sid]} left the allowed origins`);
			}
		}, 1000);
		await refresh();
		up.onopen = () => {
			for (const p of pending.splice(0)) up.send(p);
		};
		up.onmessage = e => {
			const text = String(e.data);
			const msg = JSON.parse(text);
			if (own[msg.id]) {
				delete own[msg.id];
				return;
			}
			if (watchIds[msg.id]) {
				const what = watchIds[msg.id];
				delete watchIds[msg.id];
				if (what.method === 'Target.attachToTarget' && msg.result && msg.result.sessionId) {
					sessions[msg.result.sessionId] = true;
					attached[msg.result.sessionId] = what.targetId;
				}
				if (what.method === 'Target.getTargets' && msg.result && Array.isArray(msg.result.targetInfos)) {
					msg.result.targetInfos = msg.result.targetInfos.filter(t => allowed(t.url) || (t.type === 'worker' && allowedWorker(t, allowed)));
					socket.write(frame(0x1, Buffer.from(JSON.stringify(msg), 'utf8')));
					return;
				}
			}
			if (msg.method === 'Target.attachedToTarget') {
				const { sessionId, targetInfo } = msg.params;
				const ok = allowedWorker(targetInfo, allowed) || (targetInfo.type === 'page' && allowed(targetInfo.url) && (attached[sessionId] || browser));
				if (!ok) {
					log(`detached ${targetInfo.type} ${targetInfo.url}: not a child on an allowed origin`);
					own[++ownId] = true;
					up.send(JSON.stringify({ id: ownId, method: 'Target.detachFromTarget', params: { sessionId } }));
					return;
				}
				sessions[sessionId] = true;
				if (targetInfo.type === 'page') attached[sessionId] = targetInfo.targetId;
			}
			if (msg.method === 'Target.detachedFromTarget') {
				delete sessions[msg.params.sessionId];
				delete attached[msg.params.sessionId];
			}
			// Nothing from a child the proxy did not let through.
			if (msg.sessionId && !sessions[msg.sessionId]) {
				return;
			}
			socket.write(frame(0x1, Buffer.from(text, 'utf8')));
		};
		up.onclose = () => close();
		up.onerror = () => close('upstream error');
		socket.on(
			'data',
			reader(
				async text => {
					let msg;
					try {
						msg = JSON.parse(text);
					} catch {
						msg = null;
					}
					let why;
					if (browser && msg && !msg.sessionId && typeof msg.method === 'string' && msg.method.startsWith('Target.')) {
						// A target created a moment ago is not in the last listing yet.
						await refresh();
					}
					why = browser ? checkBrowser(msg, known, sessions, allowed) : check(msg, sessions, allowed);
					if (why) {
						log(`refused ${msg && msg.method}: ${why}`);
						const err = { id: msg && msg.id, error: { code: -32601, message: `refused by cdp-proxy: ${why}` } };
						socket.write(frame(0x1, Buffer.from(JSON.stringify(err), 'utf8')));
						return;
					}
					if (browser && !msg.sessionId && (msg.method === 'Target.attachToTarget' || msg.method === 'Target.getTargets')) {
						watchIds[msg.id] = { method: msg.method, targetId: msg.params && msg.params.targetId };
					}
					if (up.readyState === 1) up.send(text);
					else pending.push(text);
				},
				() => close(),
				socket
			)
		);
		socket.on('close', () => close());
		socket.on('error', () => close());
	});

	server.listen(Number(port), host, () => log(`listening on ${listen} → ${upstream}`));
	return server;
}

// pathToFileURL, not `file://${argv[1]}`: the installed copy lives under
// "Application Support", and import.meta.url has that space as %20.
if (import.meta.url === pathToFileURL(process.argv[1]).href) {
	const arg = name => {
		const i = process.argv.indexOf(name);
		return i > 0 ? process.argv[i + 1] : undefined;
	};
	const origins = arg('--origins') ?? process.env.AGENT_BROWSER_ORIGINS;
	const reach = parseReach(arg('--reach') ?? process.env.AGENT_BROWSER_REACH);
	const verb = process.argv[2];
	try {
		switch (verb) {
			case 'serve':
				serve({ listen: arg('--listen'), upstream: arg('--upstream'), origins });
				break;
			case 'check-url':
				process.exit(originMatcher(parseOrigins(origins))(process.argv[3]) ? 0 : 1);
				break;
			case 'pac':
				process.stdout.write(pac(parseOrigins(origins), reach));
				break;
			case 'resolver-rules':
				process.stdout.write(resolverRules(parseOrigins(origins), reach) + '\n');
				break;
			default:
				console.error('usage: cdp-proxy.mjs serve|check-url <url>|pac|resolver-rules [--origins "…"] [--reach "…"] [--listen H:P] [--upstream H:P]');
				process.exit(2);
		}
	} catch (e) {
		console.error(`cdp-proxy: ${e.message}`);
		process.exit(2);
	}
}
