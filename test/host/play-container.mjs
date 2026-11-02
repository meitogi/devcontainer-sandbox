#!/usr/bin/env node
// play-container.mjs — the container's half of the agent browser's channel,
// played on the host by the host checks (mac-check.sh, windows-vm-check.ps1):
// no Docker needed to prove the supervisor and its proxy answer.
//
//   node play-container.mjs serve <port>
//       a page on http://localhost:<port>/ until killed — the allowed origin ;
//       its root is #app, what visual-loop's cdp.mjs waits for before a shot
//   node play-container.mjs drive <channel> <url> [--timeout <s>]
//       up <url> → state running, the proxy's /json/version and /json/list
//       (the page listed), down → state stopped. One line per step, ok or
//       FAILED ; every wait says where it is. Exit 0 all ok, 1 otherwise.
//
// The channel is what `agent-browser` writes and reads: `cmd` (temp file
// renamed into place), `state`, `port`, and `../activity` touched.
import { closeSync, openSync, readFileSync, renameSync, utimesSync, writeFileSync } from 'node:fs';
import http from 'node:http';
import { join } from 'node:path';

const [verb, a1, a2] = process.argv.slice(2);
const opt = (name, dflt) => {
	const i = process.argv.indexOf(name);
	return i > 0 ? process.argv[i + 1] : dflt;
};

if (verb === 'serve') {
	http.createServer((req, res) => res.writeHead(200, { 'Content-Type': 'text/html' }).end('<!doctype html><title>agent-browser check</title><div id="app"><h1>agent-browser check</h1></div>'))
		.listen(Number(a1), '127.0.0.1', () => console.log(`  serving http://localhost:${a1}/`));
} else if (verb === 'drive') {
	process.exit(await drive(a1, a2, Number(opt('--timeout', 20))));
} else {
	console.error('usage: play-container.mjs serve <port> | drive <channel> <url> [--timeout <s>]');
	process.exit(2);
}

function read(p) {
	try {
		return readFileSync(p, 'utf8').trim();
	} catch {
		return '';
	}
}

function send(ctl, text) {
	const tmp = join(ctl, `.play.${process.pid}`);
	writeFileSync(tmp, `${text}\n`);
	renameSync(tmp, join(ctl, 'cmd'));
	const activity = join(ctl, '..', 'activity');
	closeSync(openSync(activity, 'a'));
	const now = new Date();
	utimesSync(activity, now, now);
}

// Wait for a state line carrying this nonce, printing where it is every 2 s.
async function waitState(ctl, nonce, word, timeout) {
	const t0 = Date.now();
	let last = 0;
	for (;;) {
		const s = read(join(ctl, 'state')).split(' ');
		if (s[0] === nonce) return s;
		const el = Math.floor((Date.now() - t0) / 1000);
		if (el >= timeout) return null;
		if (el - last >= 2) {
			last = el;
			console.log(`  … waiting for state ${word} (${el}s / ${timeout}s, last: ${s.join(' ') || 'none'})`);
		}
		await new Promise(r => setTimeout(r, 250));
	}
}

async function drive(ctl, url, timeout) {
	const ok = m => console.log(`  ok — ${m}`);
	const ko = m => {
		console.log(`  FAILED — ${m}`);
		return 1;
	};
	const port = read(join(ctl, 'port'));
	if (!/^[0-9]+$/.test(port)) return ko(`no proxy port announced in ${ctl}/port — is the supervisor running?`);
	ok(`the supervisor announces its proxy on ${port}`);

	let nonce = String(Date.now());
	send(ctl, `${nonce} up ${url}`);
	let s = await waitState(ctl, nonce, 'running', timeout);
	if (!s) return ko(`no answer to up within ${timeout}s — the supervisor's log says why`);
	if (s[1] !== 'running') return ko(`up answered ${s.slice(1).join(' ')} — the supervisor's log says why`);
	ok(`up → running, Chromium ${s[2]} on ${s[3]}`);

	const base = `http://127.0.0.1:${port}`;
	let version = null;
	const t0 = Date.now();
	while (!version) {
		try {
			const r = await fetch(`${base}/json/version`, { signal: AbortSignal.timeout(2000) });
			if (r.status === 200) version = await r.json();
		} catch {}
		if (!version) {
			if (Date.now() - t0 > timeout * 1000) return ko(`the proxy at ${base} never answered /json/version`);
			console.log(`  … waiting for the proxy's /json/version (${Math.floor((Date.now() - t0) / 1000)}s / ${timeout}s)`);
			await new Promise(r => setTimeout(r, 1000));
		}
	}
	if (!String(version.webSocketDebuggerUrl).endsWith('/devtools/browser/agent')) return ko(`/json/version's socket is not the proxy's door: ${version.webSocketDebuggerUrl}`);
	ok(`proxy /json/version : ${version.Browser}, browser door ${version.webSocketDebuggerUrl}`);

	let pages = [];
	const t1 = Date.now();
	while (!pages.some(p => p.url.startsWith(url))) {
		try {
			pages = await (await fetch(`${base}/json/list`, { signal: AbortSignal.timeout(2000) })).json();
		} catch {}
		if (pages.some(p => p.url.startsWith(url))) break;
		if (Date.now() - t1 > timeout * 1000) return ko(`/json/list never showed ${url} (it shows: ${pages.map(p => p.url).join(' ') || 'nothing'})`);
		console.log(`  … waiting for the page in /json/list (${Math.floor((Date.now() - t1) / 1000)}s / ${timeout}s)`);
		await new Promise(r => setTimeout(r, 1000));
	}
	ok(`proxy /json/list shows the page ${url}`);

	const refused = await fetch(`${base}/json/protocol`).then(r => r.status, () => 0);
	if (refused !== 403) return ko(`the proxy answered ${refused} to /json/protocol, not 403`);
	ok('proxy refuses /json/protocol (403)');

	nonce = String(Date.now());
	send(ctl, `${nonce} down`);
	s = await waitState(ctl, nonce, 'stopped', timeout);
	if (!s || s[1] !== 'stopped') return ko(`down answered ${s ? s.slice(1).join(' ') : 'nothing'}`);
	ok('down → stopped');
	return 0;
}
