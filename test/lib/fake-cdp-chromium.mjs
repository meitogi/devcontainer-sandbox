#!/usr/bin/env node
// A Chromium that answers DevTools on --remote-debugging-port, for the host
// supervisor's handoff, brands and graceful-stop tests (test/agent-browser.test.sh).
// One page, on the URL after `--`. Writes its arguments to $FAKE_ARGS (one per
// line) and every CDP command it gets to $FAKE_LOG ("<method> <sessionId|-> <params>").
// $FAKE_CTL holds switches the test drops in :
//   no-pages    /json/list and Target.getTargets answer no page (the user closed the window, macOS)
//   click-done  the page calls the binding it was given (the user clicked « Done ») — once
//   url         the page is on that URL now (the agent, or the user, navigated)
// `--version` prints a version, like the real one.
import fs from 'node:fs';
import http from 'node:http';
import crypto from 'node:crypto';
import path from 'node:path';

const argv = process.argv.slice(2);
if (argv[0] === '--version') {
	process.stdout.write('Chromium 159.0.7390.54 \n');
	process.exit(0);
}
fs.writeFileSync(process.env.FAKE_ARGS, `${argv.join('\n')}\n`);
const port = Number((argv.find(a => a.startsWith('--remote-debugging-port=')) || '=0').split('=')[1]);
let url = argv[argv.indexOf('--') + 1] || 'about:blank';
const headless = argv.includes('--headless=new');
const ctl = name => path.join(process.env.FAKE_CTL, name);
const log = line => fs.appendFileSync(process.env.FAKE_LOG, `${line}\n`);
const pages = () => {
	if (fs.existsSync(ctl('url'))) url = fs.readFileSync(ctl('url'), 'utf8').trim();
	return fs.existsSync(ctl('no-pages')) ? [] : [{ id: 'P1', type: 'page', url }];
};

const frame = text => {
	const b = Buffer.from(text, 'utf8');
	const head = b.length < 126 ? Buffer.from([0x81, b.length]) : b.length < 65536 ? Buffer.from([0x81, 126, b.length >> 8, b.length & 255]) : null;
	if (!head) {
		const h = Buffer.alloc(10);
		h[0] = 0x81;
		h[1] = 127;
		h.writeBigUInt64BE(BigInt(b.length), 2);
		return Buffer.concat([h, b]);
	}
	return Buffer.concat([head, b]);
};

const server = http.createServer((req, res) => {
	const p = req.url.split('?')[0];
	if (p === '/json/version') {
		res.end(JSON.stringify({ Browser: `${headless ? 'HeadlessChrome' : 'Chrome'}/159.0.7390.54`, webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/browser/B` }));
	} else if (p === '/json/list' || p === '/json') {
		res.end(JSON.stringify(pages().map(t => ({ ...t, title: 't', webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/page/${t.id}` }))));
	} else {
		res.writeHead(404).end();
	}
});

let sid = 0;
const bound = []; // [socket, sessionId, name]
server.on('upgrade', (req, socket) => {
	const accept = crypto.createHash('sha1').update(`${req.headers['sec-websocket-key']}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest('base64');
	socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
	const say = m => socket.writable && socket.write(frame(JSON.stringify(m)));
	let buf = Buffer.alloc(0);
	socket.on('data', d => {
		buf = Buffer.concat([buf, d]);
		for (;;) {
			if (buf.length < 2) return;
			const op = buf[0] & 15;
			let len = buf[1] & 127;
			let at = 2;
			if (len === 126) {
				len = buf.readUInt16BE(2);
				at = 4;
			} else if (len === 127) {
				len = Number(buf.readBigUInt64BE(2));
				at = 10;
			}
			if (buf.length < at + 4 + len) return;
			const mask = buf.subarray(at, at + 4);
			const body = Buffer.from(buf.subarray(at + 4, at + 4 + len));
			for (let i = 0; i < body.length; i++) body[i] ^= mask[i % 4];
			buf = buf.subarray(at + 4 + len);
			if (op === 8) return socket.end();
			if (op !== 1) continue;
			const { id, method, params = {}, sessionId } = JSON.parse(body.toString('utf8'));
			log(`${method} ${sessionId || '-'} ${JSON.stringify(params)}`);
			const result = {};
			if (method === 'Target.getTargets') result.targetInfos = pages().map(t => ({ targetId: t.id, type: t.type, url: t.url, attached: false }));
			if (method === 'Target.attachToTarget') result.sessionId = `S${++sid}`;
			if (method === 'Runtime.evaluate') result.result = { type: 'undefined' };
			if (method === 'Page.addScriptToEvaluateOnNewDocument') result.identifier = '1';
			if (method === 'Runtime.addBinding') bound.push([say, sessionId, params.name]);
			if (method === 'Page.navigate') url = params.url;
			if (method === 'Target.setAutoAttach' && !sessionId) {
				for (const t of pages()) say({ method: 'Target.attachedToTarget', params: { sessionId: `A${++sid}`, targetInfo: { targetId: t.id, type: t.type, url: t.url }, waitingForDebugger: false } });
			}
			say({ id, result, ...(sessionId ? { sessionId } : {}) });
			if (method === 'Browser.close') setTimeout(() => process.exit(0), 50);
		}
	});
	socket.on('error', () => {});
});

setInterval(() => {
	if (!fs.existsSync(ctl('click-done')) || !bound.length) return;
	fs.rmSync(ctl('click-done'));
	for (const [say, sessionId, name] of bound) say({ method: 'Runtime.bindingCalled', params: { name, payload: 'done', executionContextId: 1 }, sessionId });
}, 200);
server.listen(port, '127.0.0.1');
process.on('SIGTERM', () => process.exit(0));
