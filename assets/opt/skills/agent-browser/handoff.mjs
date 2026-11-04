#!/usr/bin/env node
/**
 * handoff.mjs — the container half of `agent-browser handoff` : the host's
 * agent browser becomes a real window for the user, and this process waits
 * until they give it back. Run by bin/agent-browser, never directly :
 *
 *   AB_SELF=<agent-browser> AB_INSTANCE=<letter> AB_HOST_CTL=<dir> node handoff.mjs [url] [--say <text>]
 *
 * 1. the visual-loop lock of the instance's endpoint is taken — the same file
 *    cdp.mjs derives, so a script run meanwhile gets exit 10, and a handoff
 *    asked while a script runs gets exit 10 too ;
 * 2. `agent-browser _window [url]` asks the supervisor for the window (no url :
 *    the page shown) ;
 * 3. a banner with the request and a « Done » button is injected over the
 *    proxy (Page.addScriptToEvaluateOnNewDocument : it survives navigation ;
 *    the window title would not — every page sets its own) ;
 * 4. it waits : the supervisor removes `window` when the user closes the window ;
 *    « Done » and SIGINT / SIGTERM send `handback`. Exit 0 once headless again.
 *
 * Exit codes : 0 handed back · 2 usage · 3 the host browser went away · 10 the
 * browser is held by another session · what `agent-browser _window` exited with.
 */
import { spawnSync } from 'node:child_process';
import { readFileSync, lstatSync } from 'node:fs';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';

const CDP = await import(new URL('../visual-loop/scripts/cdp.mjs', import.meta.url).href);
const { acquireLock, connect, fetchBrowserWsUrl, resolveEndpoint } = CDP;

const SELF = process.env.AB_SELF || 'agent-browser';
const INSTANCE = process.env.AB_INSTANCE || 'a';
const HOST_CTL = process.env.AB_HOST_CTL || '';
const BINDING = '__agentBrowserDone';
// cdp.mjs asks `agent-browser route` for this instance : the lock file is the one every script derives.
process.env.CDP_INSTANCE = INSTANCE;
const GONE_S = 10; // no heartbeat from the host for that long : the browser went away

function usage(why) {
	process.stderr.write(`✗ ${why}\nusage: agent-browser [-i <letter>] handoff [url] [--say "<what the user should do>"]\n`);
	process.exit(2);
}

let url = '';
let say = '';
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
	if (argv[i] === '--say') {
		if (i + 1 >= argv.length) usage('--say needs a text');
		say = argv[++i];
	} else if (argv[i].startsWith('--say=')) say = argv[i].slice(6);
	else if (argv[i].startsWith('-')) usage(`unknown option ${argv[i]}`);
	else if (!url) url = argv[i];
	else usage(`one url at most (${url}, ${argv[i]})`);
}

// A control file's content, never through a symlink ; '' when absent.
function readCtl(name) {
	const p = join(HOST_CTL, name);
	try {
		if (!lstatSync(p).isFile()) return '';
		return readFileSync(p, 'utf8').trim();
	} catch {
		return '';
	}
}
const beatAge = () => {
	const b = Number(readCtl('heartbeat'));
	return b ? Math.floor(Date.now() / 1000) - b : Infinity;
};
const ab = (...args) => spawnSync(SELF, ['-i', INSTANCE, ...args], { encoding: 'utf8' });

/** The banner, as a source run in every document of the window : idempotent, in a shadow root. */
function bannerSource(text) {
	return `(() => {
	const show = () => {
		if (!document.documentElement || document.getElementById('agent-browser-handoff')) return;
		const host = document.createElement('div');
		host.id = 'agent-browser-handoff';
		host.style.cssText = 'all: initial; position: fixed; top: 8px; left: 50%; transform: translateX(-50%); z-index: 2147483647;';
		const root = host.attachShadow({ mode: 'closed' });
		root.innerHTML = '<style>div{font:14px/1.4 -apple-system,system-ui,sans-serif;background:#1d1d1f;color:#fff;border-radius:10px;padding:10px 12px;display:flex;gap:10px;align-items:center;box-shadow:0 4px 16px #0006;max-width:70vw}span{white-space:pre-wrap}button{font:inherit;border:0;border-radius:6px;padding:4px 10px;cursor:pointer}.done{background:#34c759;color:#000}.hide{background:#3a3a3c;color:#fff}</style><div><b>Agent</b><span></span><button class="done">Done</button><button class="hide">Hide</button></div>';
		root.querySelector('span').textContent = ${JSON.stringify(text || 'The agent browser is yours — click Done when finished.')};
		root.querySelector('.done').onclick = () => { root.querySelector('div').textContent = 'Handing back…'; window.${BINDING} && window.${BINDING}('done'); };
		root.querySelector('.hide').onclick = () => host.remove();
		document.documentElement.appendChild(host);
	};
	if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', show, { once: true });
	else show();
})()`;
}

let handedBack = false;
function handback(why) {
	if (handedBack) return;
	handedBack = true;
	process.stdout.write(`handoff: ${why} — handing back\n`);
	const r = ab('handback');
	process.stdout.write(r.stdout);
	process.stderr.write(r.stderr);
}

// Before acquireLock : these run first, the lock's own handlers (release,
// re-raise) after them.
for (const sig of ['SIGINT', 'SIGTERM']) process.once(sig, () => handback(`${sig} received`));

const ep = await resolveEndpoint().catch(e => {
	process.stderr.write(`✗ ${e.message}\n`);
	process.exit(e.code ?? 3);
});
if (ep.agent && ep.agent.side !== 'host') usage(`instance ${INSTANCE} answers from the ${ep.agent.side} — no window there ; the host browser is needed (agent-browser status)`);
await acquireLock(`agent-browser handoff — the user has the window${say ? ` : ${say}` : ''}`, 0).catch(e => {
	process.stderr.write(`✗ ${e.message}\n`);
	process.exit(e.code ?? 1);
});

const asked = ab('_window', ...(url ? [url] : []));
process.stdout.write(asked.stdout);
process.stderr.write(asked.stderr);
if (asked.status !== 0) process.exit(asked.status ?? 1);
const nonce = readCtl('window');
if (!nonce) {
	process.stderr.write('✗ the host answered but wrote no `window` : its kit predates handoff — re-extract the kit and re-run host-agent install on the host\n');
	ab('handback');
	process.exit(1);
}
process.stdout.write(`handoff: the window is the user's${say ? ` — ${say}` : ''}
  ends on « Done » in the banner, on closing the window, or on agent-browser${INSTANCE === 'a' ? '' : ` -i ${INSTANCE}`} handback
`);
spawnSync('notify', ['send', say || 'The agent browser is yours — click Done in its banner when finished.', '--title', 'Agent browser — your turn'], { stdio: 'ignore' });

// The banner on the window's page, re-attached when its socket closes.
let conn = null;
async function banner() {
	try {
		const c = await connect(await fetchBrowserWsUrl(ep));
		const { targetInfos } = await c.send('Target.getTargets');
		const page = targetInfos.find(t => t.type === 'page');
		if (!page) return c.close();
		const { sessionId } = await c.send('Target.attachToTarget', { targetId: page.targetId, flatten: true });
		c.on('Runtime.bindingCalled', p => p.name === BINDING && handback('the user clicked Done'));
		await c.send('Runtime.addBinding', { name: BINDING }, sessionId);
		await c.send('Page.addScriptToEvaluateOnNewDocument', { source: bannerSource(say) }, sessionId);
		await c.send('Runtime.evaluate', { expression: bannerSource(say) }, sessionId);
		conn = c;
	} catch {
		conn = null;
	}
}

let goneSince = 0;
for (;;) {
	if (readCtl('window') !== nonce) break;
	if (beatAge() > 5) {
		goneSince ||= Date.now();
		if (Date.now() - goneSince > GONE_S * 1000) {
			process.stderr.write(`✗ no heartbeat from the host for ${GONE_S}s — the host browser went away during the handoff\n`);
			process.exit(3);
		}
	} else goneSince = 0;
	// A socket the proxy closed (the page went, a restart) answers nothing : attach again.
	if (conn && !(await conn.send('Target.getTargets', {}, undefined, 2000).then(() => true, () => false))) conn = null;
	if (!handedBack && !conn) await banner();
	await sleep(1000);
}
try {
	conn?.close();
} catch {}
process.stdout.write(`handed back: ${ab('route').stdout.trim() || 'no route'}\n`);
process.exit(0);
