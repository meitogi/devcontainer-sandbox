#!/usr/bin/env node
/**
 * host-supervisor.mjs — the host's agent browser, kept by launchd on a Mac and
 * by the Task Scheduler on Windows (host-agent.sh / host-agent.ps1 install), or
 * run in a terminal (… run). It runs from the copy that install makes outside
 * the repository — nothing the container writes may run on the host. The
 * channel is files in $AGENT_BROWSER_CTL (.devcontainer/tmp/agent-browser/host/
 * on the bind mount):
 *
 *   cmd        written by `agent-browser` in the container : "<nonce> up <url>" | "<nonce> restart" | "<nonce> down" | "<nonce> stats"
 *              | "<nonce> window [<url>]" (a real window for the user, on <url> or the page shown)
 *              | "<nonce> handback" (headless again, on the page the window showed)
 *   state      written here : "<nonce> <running|stopped|idle> <pid> <url>"
 *   window     written here while a windowed Chromium lives : the nonce of its
 *              `window` ; removed when it is headless again. The state word stays
 *              `running` : the menu-bar icon, the tray and visual-loop key on it.
 *   stats      written here on `stats` : "<epoch> <cpu ticks> <rss kB> <processes>" (RSS: macOS has no PSS ; the working set on Windows)
 *   port       written here at start : the proxy's port, which `agent-browser`
 *              connects to (install --port may have moved it off the .env's).
 *   heartbeat  written here every second : an epoch. `agent-browser` sends to the
 *              host while it is under 5 s old, to the sidecar otherwise.
 *   flags      optional, read per start — only --disable-frame-rate-limit,
 *              --disable-gpu-vsync and --window-size=W,H ; any other word is
 *              dropped and logged.
 *
 * That directory is the container's too, so it holds data only, read as such:
 *   - a symlink in it is never read nor written through (it could point at any
 *     file of the host) — writes go to a fresh temp file renamed into place;
 *   - the nonce must be digits, the URL on an allowed origin (cdp-proxy.mjs's
 *     own grammar, imported) and passed after `--`, never as a Chromium switch;
 *     a refused URL is not echoed back into `state`;
 *   - logs go to $AGENT_BROWSER_LOGDIR, out of the container's reach.
 *
 * Idle, it only polls: Chromium and its DevTools proxy start on `up` and stop
 * on `down` — and the loop stops them too when the container has gone quiet
 * (idleTooLong), never while windowed. Chromium is restarted if it dies while
 * the wanted state is up, three times at most when it dies right at start. A
 * window ends when the user closes it — Chromium exits (Windows), or no page is
 * left (macOS keeps the app) — or on `handback` : Chromium restarts headless on
 * the last page the window showed on an allowed origin.
 *
 * Headless looks like the window to a site : the same --user-agent (the real
 * Chrome token, from the binary's version) and, over Chromium's own loopback
 * DevTools, the same userAgentData brands on every target (watchTargets). Every
 * stop asks Chromium to close first (Browser.close), so the cookies of a fresh
 * sign-in reach the disk ; a kill only after 5 s.
 *
 * The proxy runs in this process, not as a child: the Task Scheduler stops a
 * task with TerminateProcess, which kills this process and nothing else — a
 * child proxy would outlive it and hold the port. Chromium cannot be in-process,
 * but on Windows node puts what it spawns in a job object that kills it when
 * node dies (libuv's kill-on-close): a terminated supervisor takes its Chromium
 * with it, measured on Windows 11. A Chromium that still holds the profile (one
 * started by hand, say) is found by its command line at the next start and
 * killed as a tree (taskkill /T), like the one `down` stops.
 *
 *   node host-supervisor.mjs [--env <env.json>] [--log]   the supervisor ; --env fills
 *                     what the environment lacks (the Task Scheduler passes none),
 *                     --log writes to $AGENT_BROWSER_LOGDIR/supervisor.log, not stdout
 *   node host-supervisor.mjs find-chromium                the Chromium found (line 1, empty
 *                     when none), then every place looked in, one per line
 *
 * Zero dependencies, node >= 22 (the proxy's built-in WebSocket).
 */
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { X509Certificate, createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { originMatcher, pac, parseOrigins, parseReach, resolverRules, serve } from './cdp-proxy.mjs';

/** "<nonce> <verb> [<url>]" with a digits-only nonce ; null otherwise. */
export function parseCmd(text) {
	const [nonce, verb = '', url = ''] = String(text || '').trim().split(/\s+/);
	if (!/^[0-9]+$/.test(nonce || '')) return null;
	return { nonce, verb, url };
}

/**
 * What one look at `cmd` means. text: the file's content, null when it is gone,
 * undefined when it could not be read this time (a writer or a scanner holding
 * it, on Windows) — no news, `seen` kept: a reset would make the next good read
 * look new, and the last command would run twice. handled: the nonce last
 * answered, read back from `state` at start, so a restarted supervisor never
 * runs again what it already answered.
 */
export function nextCmd({ text, seen, handled }) {
	if (text === undefined || text === seen) return { run: null, seen, ignored: false };
	if (text === null) return { run: null, seen: '', ignored: false };
	const c = parseCmd(text);
	if (!c) return { run: null, seen: text, ignored: text.trim() !== '' };
	return { run: c.nonce === handled ? null : c, seen: text, ignored: false };
}

/** The bench's switches from `flags`, and nothing else. */
export function filterFlags(text) {
	const pass = [];
	const dropped = [];
	for (const w of String(text || '').split(/\s+/).filter(Boolean)) {
		if (w === '--disable-frame-rate-limit' || w === '--disable-gpu-vsync' || /^--window-size=[0-9]{2,4},[0-9]{2,4}$/.test(w)) pass.push(w);
		else dropped.push(w);
	}
	return { pass, dropped };
}

// A path with `<prefix>*` segments, expanded like a shell glob (sorted) ; the
// pattern itself when nothing matches — listed as such in « looked in ».
function expand(p, readdir, sep) {
	const parts = p.split(sep);
	let found = [parts[0]];
	for (const part of parts.slice(1)) {
		const star = part.indexOf('*');
		if (star < 0) {
			found = found.map(f => f + sep + part);
			continue;
		}
		const head = part.slice(0, star);
		found = found.flatMap(f => readdir(f).filter(n => n.startsWith(head)).sort().map(n => f + sep + n));
	}
	return found.length ? found : [p];
}

/**
 * Chromium or Chrome, wherever it lives: an explicit path, the kit's own
 * download, the known places — Chromium builds first (apps, Playwright's and
 * Puppeteer's caches, `npx @puppeteer/browsers install chromium --path
 * ~/.cache/puppeteer` included), then Chrome, Chrome for Testing, Edge — the
 * PATH names, then Spotlight on a Mac. Windows: Chrome (stable, Beta, Dev,
 * Canary), Chromium (installers, Scoop), the caches, Brave, then Edge (always
 * installed, a Chromium with DevTools), PATH, then the registry's App Paths.
 * `tried` is one line per place looked at — what « not found » prints.
 */
export function findChromium({ platform, env, fs: f, which, mdfind, appPaths = null }) {
	const own = env.AGENT_BROWSER_CHROMIUM || '';
	const tried = [`AGENT_BROWSER_CHROMIUM (.devcontainer/.env): ${own || 'unset'}`];
	let candidates;
	let names;
	if (platform === 'win32') {
		const w = path.win32.join;
		const local = env.LOCALAPPDATA || '';
		const user = env.USERPROFILE || '';
		const pptr = w(user, '.cache', 'puppeteer');
		const scoop = env.SCOOP || w(user, 'scoop');
		const pf = env.ProgramFiles || 'C:\\Program Files';
		const pf86 = env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)';
		candidates = [
			w(local, 'agent-browser', 'chromium', 'chrome-win', 'chrome.exe'),
			w(pf, 'Google', 'Chrome', 'Application', 'chrome.exe'),
			w(pf86, 'Google', 'Chrome', 'Application', 'chrome.exe'),
			w(local, 'Google', 'Chrome', 'Application', 'chrome.exe'),
			w(pf, 'Google', 'Chrome Beta', 'Application', 'chrome.exe'),
			w(pf, 'Google', 'Chrome Dev', 'Application', 'chrome.exe'),
			w(local, 'Google', 'Chrome Beta', 'Application', 'chrome.exe'),
			w(local, 'Google', 'Chrome Dev', 'Application', 'chrome.exe'),
			w(local, 'Google', 'Chrome SxS', 'Application', 'chrome.exe'),
			w(local, 'Chromium', 'Application', 'chrome.exe'),
			w(pf, 'Chromium', 'Application', 'chrome.exe'),
			w(pf86, 'Chromium', 'Application', 'chrome.exe'),
			w(scoop, 'apps', 'chromium', 'current', 'chrome.exe'),
			w(scoop, 'apps', 'ungoogled-chromium', 'current', 'chrome.exe'),
			w(scoop, 'apps', 'googlechrome', 'current', 'chrome.exe'),
			...expand(w(local, 'ms-playwright', 'chromium-*', 'chrome-win*', 'chrome.exe'), f.readdir, '\\'),
			...expand(w(pptr, 'chromium', 'win*', 'chrome-win', 'chrome.exe'), f.readdir, '\\'),
			...expand(w(pptr, 'chrome', 'win*', 'chrome-win*', 'chrome.exe'), f.readdir, '\\'),
			w(pf, 'BraveSoftware', 'Brave-Browser', 'Application', 'brave.exe'),
			w(local, 'BraveSoftware', 'Brave-Browser', 'Application', 'brave.exe'),
			w(pf, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
			w(pf86, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
		];
		names = ['chrome', 'chromium', 'brave', 'msedge'];
	} else {
		const home = env.HOME || '';
		const cft = 'Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
		candidates = [
			`${home}/Library/Application Support/agent-browser/chromium/Chromium.app/Contents/MacOS/Chromium`,
			'/Applications/Chromium.app/Contents/MacOS/Chromium',
			`${home}/Applications/Chromium.app/Contents/MacOS/Chromium`,
			...expand(`${home}/Library/Caches/ms-playwright/chromium-*/chrome-mac*/Chromium.app/Contents/MacOS/Chromium`, f.readdir, '/'),
			...expand(`${home}/.cache/ms-playwright/chromium-*/chrome-linux*/chrome`, f.readdir, '/'),
			...expand(`${home}/.cache/puppeteer/chromium/mac*/chrome-mac/Chromium.app/Contents/MacOS/Chromium`, f.readdir, '/'),
			...expand(`${home}/.cache/puppeteer/chromium/linux*/chrome-linux/chrome`, f.readdir, '/'),
			'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
			`${home}/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`,
			`/Applications/${cft}`,
			...expand(`${home}/Library/Caches/ms-playwright/chromium-*/chrome-mac*/${cft}`, f.readdir, '/'),
			...expand(`${home}/.cache/puppeteer/chrome/mac*/chrome-mac*/${cft}`, f.readdir, '/'),
			...expand(`${home}/.cache/puppeteer/chrome/linux*/chrome-linux*/chrome`, f.readdir, '/'),
			'/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
		];
		names = ['chromium', 'chromium-browser', 'google-chrome', 'google-chrome-stable', 'microsoft-edge', 'microsoft-edge-stable'];
	}
	let chromium = own && f.executable(own) ? own : '';
	for (const c of candidates) {
		tried.push(c);
		if (!chromium && f.executable(c)) chromium = c;
	}
	tried.push(`PATH: ${names.join(' ')}`);
	for (const n of names) {
		const c = which(n);
		if (!chromium && c && f.executable(c)) chromium = c;
	}
	if (mdfind) {
		tried.push('Spotlight: org.chromium.Chromium');
		if (!chromium) {
			for (const app of mdfind()) {
				const c = `${app}/Contents/MacOS/Chromium`;
				if (f.executable(c)) {
					chromium = c;
					break;
				}
			}
		}
	}
	if (appPaths) {
		tried.push(`Registry: App Paths ${APP_PATHS.join(' ')}`);
		if (!chromium) chromium = appPaths().find(c => f.executable(c)) || '';
	}
	return { chromium, tried };
}

// The executables Windows' App Paths may register, in the search's order.
export const APP_PATHS = ['chrome.exe', 'brave.exe', 'msedge.exe'];

/**
 * The path in a `reg query "<key>\\App Paths\\<exe>" /ve` answer: the value
 * after REG_SZ / REG_EXPAND_SZ (the « (Default) » label is localised), its
 * %VAR% expanded from env, quotes dropped ; '' when there is none.
 */
export function regDefault(out, env) {
	const m = /\bREG_(?:EXPAND_)?SZ\s+(.+?)\s*$/m.exec(String(out || ''));
	if (!m) return '';
	return m[1].replace(/^"|"$/g, '').replace(/%([^%]+)%/g, (all, k) => env[k] ?? all);
}

/** Trust exactly the dev cert's key — never the blanket --ignore-certificate-errors. */
export function spkiOf(pem) {
	const der = new X509Certificate(pem).publicKey.export({ type: 'spki', format: 'der' });
	return createHash('sha256').update(der).digest('base64');
}

/**
 * The flags. The window size is in CSS pixels at scale 1: 1280x800 is a
 * 1280x657 canvas, not Retina's 2560x1426. Headless (the default) runs on the
 * GPU too — Metal on a Mac ; AGENT_BROWSER_WINDOW=1 opens a real window on
 * every start, `window` (a handoff) on this one. `ua`: the --user-agent, the
 * same both ways. --use-mock-keychain on a Mac : no « Chromium Safe Storage »
 * prompt, ever — the cookies are encrypted with Chromium's fixed mock key, so
 * at rest the profile is protected by its file permissions only.
 *
 * What the browser may reach is the project's AGENT_BROWSER_ORIGINS (+ _REACH),
 * held at three levels, all generated from that one list by cdp-proxy.mjs:
 *   - the PAC: allowed origins and reach hosts DIRECT, everything else to a
 *     proxy that does not exist;
 *   - --host-resolver-rules: every other name fails to resolve (covers what a
 *     PAC does not: WebRTC, prefetch);
 *   - DevTools on the loopback only (AGENT_BROWSER_CDP_PORT), the container
 *     reaching it through the proxy (AGENT_BROWSER_PROXY_PORT), which refuses
 *     what touches the host's disk or another origin.
 */
export function chromiumFlags({ platform, env, profile, pac: pacText, rules, spki, window = (env.AGENT_BROWSER_WINDOW || '0') === '1', ua = '' }) {
	const flags = [
		`--user-data-dir=${profile}`,
		'--no-first-run',
		'--no-default-browser-check',
		`--window-size=${env.AGENT_BROWSER_SIZE || '1280,800'}`,
		'--force-device-scale-factor=1',
		'--disable-renderer-backgrounding',
		'--disable-background-timer-throttling',
		'--disable-backgrounding-occluded-windows',
		'--disable-background-networking',
		'--disable-component-update',
		'--disable-sync',
		'--no-pings',
		// A data: URL — Chromium no longer takes a file:// PAC. <-loopback> sends
		// localhost through the list too (otherwise always direct).
		`--proxy-pac-url=data:application/x-ns-proxy-autoconfig;base64,${Buffer.from(pacText).toString('base64')}`,
		'--proxy-bypass-list=<-loopback>',
		`--host-resolver-rules=${rules}`,
		// WebRTC host candidates as plain addresses, not mDNS names (….local) the
		// resolver rules above cannot resolve : without it, two pages of the
		// allowed origins (two tabs, or two instances) never pair directly.
		'--disable-features=WebRtcHideLocalIpsWithMdns',
	];
	if ((env.AGENT_BROWSER_AUDIO || 'off') !== 'on') flags.push('--mute-audio');
	if (spki) flags.push(`--ignore-certificate-errors-spki-list=${spki}`);
	if (platform === 'darwin') flags.push('--use-mock-keychain');
	if (ua) flags.push(`--user-agent=${ua}`);
	if (!window) {
		flags.push('--headless=new');
		if (platform === 'darwin') flags.push('--use-angle=metal');
	}
	return flags;
}

/** The major version in `<binary> --version` (« Chromium 159.0.7390.54 », « Google Chrome 159.… ») ; '' when none. */
export function majorFromVersion(text) {
	const m = /(?:^|\s)(\d{2,4})\.\d+\.\d+\.\d+(?:\s|$)/.exec(String(text || ''));
	return m ? m[1] : '';
}

/** Windows: chrome.exe prints no --version ; its version is the folder beside it (« 159.0.7390.54 »). */
export function majorFromDir(entries) {
	const v = entries.filter(n => /^\d+\.\d+\.\d+\.\d+$/.test(n)).sort((a, b) => Number(b.split('.')[0]) - Number(a.split('.')[0]))[0];
	return v ? v.split('.')[0] : '';
}

/** Which browser a binary is, by its path : the brand a window of it announces besides Chromium. */
export function brandOf(binary) {
	if (/Google Chrome for Testing/i.test(binary)) return 'Google Chrome for Testing';
	if (/Google[\\/ ]Chrome|Google Chrome/i.test(binary)) return 'Google Chrome';
	if (/msedge|Microsoft Edge/i.test(binary)) return 'Microsoft Edge';
	if (/brave/i.test(binary)) return 'Brave';
	return 'Chromium';
}

/**
 * The user-agent a window of this binary announces — Chrome's reduced string
 * (frozen OS part, major.0.0.0), Edge's token after it — never HeadlessChrome.
 */
export function userAgentFor({ platform, major, brand = 'Chromium' }) {
	const os = platform === 'darwin' ? 'Macintosh; Intel Mac OS X 10_15_7' : platform === 'win32' ? 'Windows NT 10.0; Win64; x64' : 'X11; Linux x86_64';
	const edge = brand === 'Microsoft Edge' ? ` Edg/${major}.0.0.0` : '';
	return `Mozilla/5.0 (${os}) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${major}.0.0.0 Safari/537.36${edge}`;
}

/**
 * userAgentData as a window of this binary reports it : Chromium, its own
 * brand when it is not Chromium, and the « GREASE » brand Chromium derives from
 * the major version (embedder_support's GetGreasedUserAgentBrandVersion :
 * characters and version picked by the seed, the order a permutation of it).
 * `full`: the full version (Browser.getVersion's product). Headless reports
 * HeadlessChrome here, whatever --user-agent says.
 */
export function uaMetadata({ platform, arch, full, brand = 'Chromium', platformVersion = '' }) {
	const major = String(full).split('.')[0];
	const seed = Number(major);
	const chars = [' ', '(', ':', '-', '.', '/', ')', ';', '=', '?', '_'];
	const grease = { brand: `Not${chars[seed % chars.length]}A${chars[(seed + 1) % chars.length]}Brand`, version: ['8', '99', '24'][seed % 3] };
	const own = [{ brand: 'Chromium', version: major }];
	if (brand !== 'Chromium') own.push({ brand, version: major });
	const orders = own.length === 1 ? [[0, 1], [1, 0]] : [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]];
	const order = orders[seed % orders.length];
	const list = [grease, ...own];
	const brands = [];
	const fullVersionList = [];
	for (let i = 0; i < list.length; i++) {
		const b = list[i];
		brands[order[i]] = b;
		fullVersionList[order[i]] = { brand: b.brand, version: b === grease ? `${b.version}.0.0.0` : full };
	}
	return {
		brands,
		fullVersionList,
		fullVersion: full,
		platform: platform === 'darwin' ? 'macOS' : platform === 'win32' ? 'Windows' : 'Linux',
		platformVersion,
		architecture: arch === 'arm64' || arch === 'arm' ? 'arm' : 'x86',
		model: '',
		mobile: false,
		bitness: '64',
		wow64: false,
	};
}

/**
 * Whether a windowed start is over : Chromium gone (Windows quits with its last
 * window), or DevTools answered and no page is left (macOS keeps the app with
 * no window). `pages` null = DevTools did not answer : no news.
 */
export function windowOver({ alive, pages }) {
	return !alive || (Array.isArray(pages) && pages.length === 0);
}

/** The page a headless restart goes back to : the first page on an allowed origin, else the previous one. */
export function lastPage(pages, allowed, previous) {
	for (const t of pages || []) if (allowed(t.url)) return t.url;
	return previous;
}

/** ps's cputime, [[dd-]hh:]mm:ss.cc (macOS) or [[dd-]hh:]mm:ss (Linux), as 1/100 s ticks. */
export function parsePsTime(t) {
	const f = t.split(/[-:.]/).map(Number);
	let n = f.length;
	const dot = t.includes('.');
	const c = dot ? f[n - 1] : 0;
	if (dot) n--;
	const sec = f[n - 1];
	const m = f[n - 2] || 0;
	const h = n > 2 ? f[n - 3] : 0;
	const d = n > 3 ? f[n - 4] : 0;
	return (((d * 24 + h) * 60 + m) * 60 + sec) * 100 + c;
}

/** CPU ticks, RSS (kB) and count of the processes whose command line carries the profile. */
export function statsFromPs(text, profile) {
	let ticks = 0;
	let rss = 0;
	let n = 0;
	for (const line of text.split('\n')) {
		const m = line.trim().match(/^(\S+)\s+(\d+)\s+(.*)$/);
		if (!m || !m[3].includes(profile)) continue;
		ticks += parsePsTime(m[1]);
		rss += Number(m[2]);
		n++;
	}
	return { ticks, rss, n };
}

/** The same from Win32_Process as JSON (an object when one process, an array otherwise). */
export function statsFromCim(json, profile) {
	const want = profile.toLowerCase();
	let time = 0;
	let bytes = 0;
	let n = 0;
	for (const p of [].concat(JSON.parse(json) ?? [])) {
		if (!String(p.CommandLine ?? '').toLowerCase().includes(want)) continue;
		time += Number(p.KernelModeTime) + Number(p.UserModeTime);
		bytes += Number(p.WorkingSetSize);
		n++;
	}
	return { ticks: Math.floor(time / 100000), rss: Math.floor(bytes / 1024), n };
}

/** The pids among [{pid, cmd}] that run on exactly this profile (paths are case-blind on Windows). */
export function orphansOf(list, profile, platform) {
	const fold = s => (platform === 'win32' ? s.toLowerCase() : s);
	const needle = fold(`--user-data-dir=${profile}`);
	const pids = [];
	for (const { pid, cmd } of list) {
		const c = fold(String(cmd ?? ''));
		const i = c.indexOf(needle);
		if (i < 0) continue;
		const next = c[i + needle.length];
		if (next === undefined || next === ' ' || next === '"') pids.push(pid);
	}
	return pids;
}

/** env.json (the Task Scheduler's stand-in for a plist's EnvironmentVariables): its string AGENT_BROWSER_* values. */
export function readEnvFile(text) {
	const j = JSON.parse(text);
	const out = {};
	for (const k in j) {
		const v = j[k];
		if (typeof v === 'string' && (k === 'NODE' || /^AGENT_BROWSER_[A-Z0-9_]+$/.test(k))) out[k] = v;
	}
	return out;
}

/**
 * The container's command touches `activity` on every call ; `hold` carries an
 * epoch until which the browser must stay up whatever happens. No activity for
 * idleS and no hold → Chromium off, even if the container was stopped or
 * rebuilt meanwhile.
 */
export function idleTooLong({ now, started, activity = 0, hold = 0, idleS }) {
	if (hold > now) return false;
	return now - Math.max(activity, started) >= idleS;
}

// ── the supervisor ──────────────────────────────────────────────────────────

const epoch = () => Math.floor(Date.now() / 1000);
const pause = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

function stamp() {
	const d = new Date();
	const p = n => String(n).padStart(2, '0');
	return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

const hostFs = {
	executable(p) {
		try {
			fs.accessSync(p, fs.constants.X_OK);
			return fs.statSync(p).isFile();
		} catch {
			return false;
		}
	},
	readdir(d) {
		try {
			return fs.readdirSync(d);
		} catch {
			return [];
		}
	},
};

function which(name) {
	const exe = process.platform === 'win32' ? `${name}.exe` : name;
	for (const dir of (process.env.PATH || '').split(path.delimiter)) {
		if (dir && hostFs.executable(path.join(dir, exe))) return path.join(dir, exe);
	}
	return '';
}

function hostChromium(env) {
	const mdfind = process.platform === 'darwin' && which('mdfind')
		? () => {
				try {
					return execFileSync('mdfind', ["kMDItemCFBundleIdentifier == 'org.chromium.Chromium'"], { encoding: 'utf8' }).split('\n').filter(Boolean);
				} catch {
					return [];
				}
			}
		: null;
	const appPaths = process.platform === 'win32'
		? () => {
				const found = [];
				for (const exe of APP_PATHS) {
					for (const root of ['HKCU', 'HKLM']) {
						try {
							const c = regDefault(execFileSync('reg.exe', ['query', `${root}\\Software\\Microsoft\\Windows\\CurrentVersion\\App Paths\\${exe}`, '/ve'], { encoding: 'utf8', windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'] }), process.env);
							if (c) found.push(c);
						} catch {}
					}
				}
				return found;
			}
		: null;
	return findChromium({ platform: process.platform, env, fs: hostFs, which, mdfind, appPaths });
}

// A plain file's content, at most `max` bytes: null when it is missing, a link
// or not a file — never read through a symlink (O_NOFOLLOW where the OS has it,
// lstat on Windows, where junctions count too) ; undefined when it could not
// be read this time (Windows: a sharing violation while someone holds it).
function readPlain(p, max = 65536) {
	let fd;
	try {
		if (fs.constants.O_NOFOLLOW) {
			fd = fs.openSync(p, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
		} else {
			if (!fs.lstatSync(p).isFile()) return null;
			fd = fs.openSync(p, 'r');
		}
		if (!fs.fstatSync(fd).isFile()) return null;
		const buf = Buffer.alloc(max);
		return buf.subarray(0, fs.readSync(fd, buf, 0, max, 0)).toString('utf8');
	} catch (e) {
		return ['ENOENT', 'ENOTDIR', 'ELOOP', 'EISDIR'].includes(e.code) ? null : undefined;
	} finally {
		if (fd !== undefined) fs.closeSync(fd);
	}
}

// Every process with its command line: ps, or Win32_Process (no wmic: gone from 24H2).
function processes(fields) {
	if (process.platform === 'win32') {
		const out = execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', `Get-CimInstance Win32_Process | Select-Object ${fields} | ConvertTo-Json -Compress`], { encoding: 'utf8', windowsHide: true, maxBuffer: 64 << 20 });
		return out.trim() || '[]';
	}
	return execFileSync('ps', ['-A', '-o', 'time=,rss=,command='], { encoding: 'utf8', maxBuffer: 64 << 20 });
}

function killTree(pid) {
	if (process.platform === 'win32') spawnSync('taskkill', ['/T', '/F', '/PID', String(pid)], { windowsHide: true, stdio: 'ignore' });
	else process.kill(pid, 'SIGTERM');
}

// The binary's major version, for --user-agent : '' when it cannot be told.
function chromiumMajor(chromium) {
	if (process.platform === 'win32') return majorFromDir(hostFs.readdir(path.dirname(chromium)));
	try {
		return majorFromVersion(execFileSync(chromium, ['--version'], { encoding: 'utf8', timeout: 10000, stdio: ['ignore', 'pipe', 'ignore'] }));
	} catch {
		return '';
	}
}

// What a Mac window reports as userAgentData.platformVersion (« 15.1.0 ») ; '' elsewhere.
function platformVersion() {
	if (process.platform !== 'darwin') return '';
	try {
		const v = execFileSync('sw_vers', ['-productVersion'], { encoding: 'utf8' }).trim().split('.');
		return [v[0], v[1] || '0', v[2] || '0'].join('.');
	} catch {
		return '';
	}
}

/**
 * Chromium's own DevTools, browser-level, on its loopback port — the host's
 * side, never the container's (that one is the proxy). null when it does not
 * answer within `ms`.
 */
async function devtools(port, ms = 1000) {
	let v;
	try {
		v = await (await fetch(`http://127.0.0.1:${port}/json/version`, { signal: AbortSignal.timeout(ms) })).json();
	} catch {
		return null;
	}
	const ws = new WebSocket(v.webSocketDebuggerUrl);
	const ok = await new Promise(r => {
		ws.onopen = () => r(true);
		ws.onerror = () => r(false);
	});
	if (!ok) return null;
	let id = 0;
	const pending = {};
	const handlers = [];
	ws.onmessage = e => {
		const msg = JSON.parse(String(e.data));
		if (msg.id !== undefined) {
			const p = pending[msg.id];
			delete pending[msg.id];
			if (p) p(msg);
		} else {
			for (const h of handlers) h(msg);
		}
	};
	ws.onclose = () => {
		for (const k in pending) pending[k]({ error: { message: 'closed' } });
	};
	return {
		product: String(v.Browser || ''),
		send: (method, params = {}, sessionId) =>
			new Promise(r => {
				if (ws.readyState !== 1) return r({ error: { message: 'closed' } });
				pending[++id] = r;
				ws.send(JSON.stringify(sessionId ? { id, method, params, sessionId } : { id, method, params }));
			}),
		on: h => handlers.push(h),
		close: () => ws.close(),
	};
}

// The page targets Chromium's own DevTools lists ; null when it does not answer.
async function loopbackPages(port) {
	try {
		const list = await (await fetch(`http://127.0.0.1:${port}/json/list`, { signal: AbortSignal.timeout(1000) })).json();
		return list.filter(t => t.type === 'page');
	} catch {
		return null;
	}
}

/**
 * Every target, the ones there and the ones to come, announces `ua` and the
 * window's userAgentData : auto-attach paused at start (waitForDebuggerOnStart),
 * the override set, then resumed. A page loaded before this socket opened (the
 * one on the command line) is reloaded once under the override. No `ua`
 * (AGENT_BROWSER_UA_OVERRIDE=off, no version read) : no override, no reload.
 *
 * `dialogs` (headless) : nobody can answer an alert, a confirm or « leave this
 * page ? », and the page waits on it forever — accepted after DIALOG_MS, which
 * leaves a script that handles its own dialogs the time to do it.
 */
const DIALOG_MS = 1000;
async function watchTargets(dt, { ua, metadata, dialogs }, log) {
	let initial = true;
	dt.on(async msg => {
		if (msg.method === 'Page.javascriptDialogOpening') {
			const { type, message, url } = msg.params;
			setTimeout(async () => {
				const r = await dt.send('Page.handleJavaScriptDialog', { accept: true, promptText: '' }, msg.sessionId);
				if (!r.error) log(`dialog: ${type} « ${String(message).slice(0, 80)} » on ${url} — accepted (headless, nobody to answer)`);
			}, DIALOG_MS);
			return;
		}
		if (msg.method !== 'Target.attachedToTarget') return;
		const { sessionId, targetInfo, waitingForDebugger } = msg.params;
		// Decided now : the answer to setAutoAttach may come while this awaits.
		const loadedBefore = initial && !waitingForDebugger && targetInfo.type === 'page';
		const worker = /worker/.test(targetInfo.type);
		if (ua) await dt.send(worker ? 'Network.setUserAgentOverride' : 'Emulation.setUserAgentOverride', { userAgent: ua, userAgentMetadata: metadata }, sessionId);
		if (!worker) await dt.send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: true, flatten: true }, sessionId);
		if (dialogs && targetInfo.type === 'page') await dt.send('Page.enable', {}, sessionId);
		if (waitingForDebugger) await dt.send('Runtime.runIfWaitingForDebugger', {}, sessionId);
		if (ua && loadedBefore) await dt.send('Page.reload', {}, sessionId);
	});
	const r = await dt.send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: true, flatten: true });
	initial = false;
	if (r.error) log(`targets: auto-attach refused (${r.error.message}) — brands and dialogs left as they are`);
}

function supervise(argv) {
	const envIndex = argv.indexOf('--env');
	const fromFile = envIndex >= 0 ? readEnvFile(fs.readFileSync(argv[envIndex + 1], 'utf8')) : {};
	const env = { ...fromFile };
	for (const k in process.env) if (process.env[k] !== undefined && process.env[k] !== '') env[k] = process.env[k];
	for (const k of ['AGENT_BROWSER_PROFILE', 'AGENT_BROWSER_LOGDIR', 'AGENT_BROWSER_CTL', 'AGENT_BROWSER_ORIGINS']) {
		if (!env[k]) {
			console.error(`host-supervisor: ${k} is not set — set by host-agent (install or run)`);
			process.exit(1);
		}
	}
	const PROFILE = env.AGENT_BROWSER_PROFILE;
	const LOGDIR = env.AGENT_BROWSER_LOGDIR;
	const CTL = env.AGENT_BROWSER_CTL;
	const ORIGINS = env.AGENT_BROWSER_ORIGINS;
	const REACH = env.AGENT_BROWSER_REACH || '';
	const SIZE = env.AGENT_BROWSER_SIZE || '1280,800';
	const CDP_PORT = env.AGENT_BROWSER_CDP_PORT || '9323';
	const PROXY_PORT = env.AGENT_BROWSER_PROXY_PORT || '9223';
	// 127.0.0.1 is what Docker Desktop (macOS, Windows) reaches as host.docker.internal.
	// A Linux Docker Engine reaches the docker0 address instead — see the TODO in
	// the skill: AGENT_BROWSER_PROXY_BIND=0.0.0.0 (or that address) there.
	const PROXY_BIND = env.AGENT_BROWSER_PROXY_BIND || '127.0.0.1';
	const CERT = env.AGENT_BROWSER_CERT || '';
	const IDLE_S = Number(env.AGENT_BROWSER_IDLE_S || 360);
	// off : Chromium's own user-agent and brands — to measure what they are, never to run with.
	const UA_OVERRIDE = (env.AGENT_BROWSER_UA_OVERRIDE || 'on') !== 'off';
	const ROOT = env.AGENT_BROWSER_ROOT || '';
	const win = process.platform === 'win32';

	fs.mkdirSync(LOGDIR, { recursive: true });
	const toFile = argv.includes('--log');
	const log = msg => {
		const line = `${stamp()} [host-supervisor] ${msg}\n`;
		if (toFile) fs.appendFileSync(path.join(LOGDIR, 'supervisor.log'), line);
		else process.stdout.write(line);
	};
	// Under the Task Scheduler nothing reads stderr: a crash goes to the log too.
	if (toFile) {
		process.on('uncaughtException', e => {
			log(`crashed: ${e.stack || e}`);
			process.exit(1);
		});
	}
	const proxyLog = (...a) => fs.appendFileSync(path.join(LOGDIR, 'cdp-proxy.log'), `${new Date().toISOString()} [cdp-proxy] ${a.join(' ')}\n`);

	let allowed = () => false;
	try {
		allowed = originMatcher(parseOrigins(ORIGINS));
	} catch (e) {
		log(`the origin list is unusable: ${e.message} — every up is refused`);
	}

	const ctlIsDir = () => {
		try {
			return fs.lstatSync(CTL).isDirectory();
		} catch {
			return false;
		}
	};
	const get = name => readPlain(path.join(CTL, name));
	// Write a control file without ever following a link the container left there.
	const put = (name, text) => {
		if (!ctlIsDir()) return false;
		const tmp = path.join(CTL, `.put.${process.pid}.${Math.random().toString(36).slice(2)}`);
		try {
			fs.writeFileSync(tmp, `${text}\n`, { flag: 'wx' });
			// Windows refuses a rename over a file a reader holds open: a few tries.
			for (let i = 0; ; i++) {
				try {
					fs.renameSync(tmp, path.join(CTL, name));
					return true;
				} catch (e) {
					if (i >= 9 || !['EPERM', 'EBUSY', 'EACCES'].includes(e.code)) throw e;
					pause(20);
				}
			}
		} catch {
			fs.rmSync(tmp, { force: true });
			return false;
		}
	};
	const removePlain = name => {
		const p = path.join(CTL, name);
		try {
			if (!fs.lstatSync(p).isSymbolicLink()) fs.rmSync(p, { force: true });
		} catch {}
	};

	let child = null;
	let proxy = null;
	let sockets = [];
	let url = '';
	let wanted = 'down';
	let nonce = '-';
	let now = 'idle';
	let started = 0;
	let driven = 0; // the last request or message the proxy got from the container
	let quickExits = 0;
	// A handoff : this start is windowed, `windowNonce` the cmd that asked for it.
	let windowed = false;
	let windowNonce = '';
	// A page seen since the window opened : before its first tab exists, DevTools
	// can list none — not the user closing it.
	let windowPaged = false;
	let dt = null;
	const majors = {};

	const pid = () => (child && child.pid) || '';
	const alive = () => !!child && child.pid !== undefined && child.exitCode === null && child.signalCode === null && !child.failed;

	// The processes on this profile, with the command line: Windows has no
	// SingletonLock symlink to read the holder from.
	const onProfile = () => {
		const list = [].concat(JSON.parse(processes('ProcessId,CommandLine')) ?? []).map(p => ({ pid: p.ProcessId, cmd: p.CommandLine }));
		return orphansOf(list, PROFILE, 'win32');
	};

	function holder() {
		if (win) return onProfile()[0] ?? '';
		let h = '';
		try {
			h = fs.readlinkSync(path.join(PROFILE, 'SingletonLock')).replace(/^.*-/, '');
			process.kill(Number(h), 0);
		} catch {
			return '';
		}
		return h;
	}

	// Downloads stay inside the profile, never in ~/Downloads.
	function prefs() {
		const downloads = path.join(PROFILE, 'downloads');
		fs.mkdirSync(path.join(PROFILE, 'Default'), { recursive: true });
		fs.mkdirSync(downloads, { recursive: true });
		const p = path.join(PROFILE, 'Default', 'Preferences');
		if (!fs.existsSync(p)) {
			fs.writeFileSync(p, `${JSON.stringify({ download: { default_directory: downloads, prompt_for_download: false }, savefile: { default_directory: downloads } })}\n`);
		}
	}

	function start() {
		if (!url || !allowed(url)) {
			log(`refused up: ${url} is not on an allowed origin (${ORIGINS})`);
			return false;
		}
		const { chromium, tried } = hostChromium(env);
		if (!chromium) {
			log(`Chromium not found — looked in: ${tried.join(' · ')} — host-agent install-chromium, or AGENT_BROWSER_CHROMIUM=/path in .devcontainer/.env, then host-agent install`);
			return false;
		}
		// Another Chromium on this profile holds it: ours would abort at once,
		// every time. A stale SingletonLock (dead pid) Chromium takes over by itself.
		const h = holder();
		if (h) {
			log(`refused up: Chromium ${h} already runs on ${PROFILE} — stop it first`);
			return false;
		}
		prefs();
		majors[chromium] ??= UA_OVERRIDE ? chromiumMajor(chromium) : '';
		const major = majors[chromium];
		if (UA_OVERRIDE && !major) log(`user-agent: no version read from ${chromium} — Chromium's own user-agent this start`);
		const brand = brandOf(chromium);
		const ua = major ? userAgentFor({ platform: process.platform, major, brand }) : '';
		let flags;
		try {
			const origins = parseOrigins(ORIGINS);
			const reach = parseReach(REACH);
			flags = chromiumFlags({ platform: process.platform, env, profile: PROFILE, pac: pac(origins, reach), rules: resolverRules(origins, reach), spki: CERT ? spkiOf(fs.readFileSync(CERT)) : '', ua, ...(windowed ? { window: true } : {}) });
		} catch (e) {
			log(`refused up: the origin list is unusable (${e.message})`);
			return false;
		}
		const extra = filterFlags(get('flags') || '');
		for (const w of extra.dropped) log(`flags: dropped ${w}`);
		const out = fs.openSync(path.join(LOGDIR, 'chromium.log'), 'a');
		// DevTools on the loopback only: the container gets the proxy.
		// windowsHide would start a window hidden : only a headless one gets it.
		child = spawn(chromium, [...flags, ...extra.pass, '--remote-debugging-address=127.0.0.1', `--remote-debugging-port=${CDP_PORT}`, '--', url], { stdio: ['ignore', out, out], windowsHide: !windowed });
		fs.closeSync(out);
		const c = child;
		c.on('error', e => {
			c.failed = true;
			log(`Chromium did not start: ${e.message}`);
		});
		started = epoch();
		watch(c, ua, brand, major, !windowed);
		proxy = serve({ listen: `${PROXY_BIND}:${PROXY_PORT}`, upstream: `127.0.0.1:${CDP_PORT}`, origins: ORIGINS, downloadRoot: ROOT, log: proxyLog, onClient: () => { driven = epoch(); } });
		proxy.on('connection', s => {
			sockets.push(s);
			s.on('close', () => {
				sockets = sockets.filter(x => x !== s);
			});
		});
		proxy.on('error', e => log(`proxy: ${e.message}`));
		log(`up: Chromium ${pid()} on ${url} (${SIZE}${windowed ? ', a window for the user' : ''}), proxy on ${PROXY_BIND}:${PROXY_PORT}`);
		return true;
	}

	// The brands of the window, and headless the dialogs nobody can answer, on
	// every target of Chromium `c`, over its own DevTools — up within seconds of
	// the start, or never (a fake, a crash).
	async function watch(c, ua, brand, major, dialogs) {
		let d = null;
		for (let i = 0; i < 40 && !d && child === c && alive(); i++) {
			d = await devtools(CDP_PORT, 500);
			if (!d) await sleepMs(250);
		}
		if (!d) return;
		if (child !== c) return d.close();
		dt = d;
		const full = (/\/([0-9.]+)$/.exec(d.product) || [])[1] || `${major}.0.0.0`;
		await watchTargets(d, { ua, metadata: uaMetadata({ platform: process.platform, arch: process.arch, full, brand, platformVersion: platformVersion() }), dialogs }, log);
	}

	async function stop() {
		const c = child;
		if (proxy) {
			proxy.close();
			for (const s of sockets) s.destroy();
			sockets = [];
			proxy = null;
		}
		if (c && alive()) {
			const gone = new Promise(r => c.once('exit', r));
			// Closed as a user would quit it, so a fresh sign-in's cookies reach
			// the disk (Chromium writes them every ~30 s) ; killed after 5 s.
			const d = dt || (await devtools(CDP_PORT, 500));
			if (d) d.send('Browser.close');
			const closed = d && (await Promise.race([gone.then(() => true), sleepMs(5000).then(() => false)]));
			if (!closed) {
				try {
					killTree(c.pid);
				} catch {}
				// A Chromium that ignores TERM for 5 s is killed.
				const late = setTimeout(() => alive() && c.kill('SIGKILL'), 5000);
				await gone;
				clearTimeout(late);
			}
		}
		if (dt) dt.close();
		dt = null;
		if (c) log('down');
		child = null;
	}

	// Headless again on the page the window showed last.
	async function endWindow(why) {
		if (alive()) url = lastPage(await loopbackPages(CDP_PORT), allowed, url);
		log(`window: ${why} — headless again on ${url}`);
		await stop();
		windowed = false;
		if (start()) state('running');
		else {
			wanted = 'down';
			state('stopped');
		}
	}

	function state(word) {
		now = word;
		// `window` first : whoever sees the state answered reads it next.
		if (windowed && word === 'running') put('window', windowNonce);
		else removePlain('window');
		put('state', `${nonce} ${word} ${pid() || '-'} ${url && allowed(url) ? url : '-'}`);
	}

	// CPU time (as 1/100 s ticks, like the sidecar's) and RSS of Chromium and its
	// helpers — the processes whose command line carries this profile.
	function stats() {
		let s = { ticks: 0, rss: 0, n: 0 };
		try {
			s = win ? statsFromCim(processes('KernelModeTime,UserModeTime,WorkingSetSize,CommandLine'), PROFILE) : statsFromPs(processes(), PROFILE);
		} catch (e) {
			log(`stats: ${e.message}`);
		}
		put('stats', `${epoch()} ${s.ticks} ${s.rss} ${s.n}`);
	}

	function idle() {
		let activity = driven;
		try {
			const st = fs.lstatSync(path.join(CTL, '..', 'activity'));
			if (st.isFile()) activity = Math.max(activity, Math.floor(st.mtimeMs / 1000));
		} catch {}
		const h = (readPlain(path.join(CTL, '..', 'hold'), 12) || '').trim();
		return idleTooLong({ now: epoch(), started, activity, hold: /^[0-9]+$/.test(h) ? Number(h) : 0, idleS: IDLE_S });
	}

	// One loop does everything, signals included: a signal only asks it to quit
	// and cuts its sleep short.
	let quit = false;
	let wake = () => {};
	const sleepMs = ms => new Promise(r => setTimeout(r, ms));
	const sleep = ms => new Promise(r => {
		const t = setTimeout(r, ms);
		wake = () => {
			clearTimeout(t);
			r();
		};
	});
	// SIGHUP: what Windows sends when the console goes (CTRL_CLOSE_EVENT).
	for (const sig of ['SIGTERM', 'SIGINT', 'SIGHUP']) {
		process.on(sig, () => {
			quit = true;
			wake();
		});
	}

	async function loop() {
		if (!ctlIsDir()) {
			log(`${CTL} is not a plain directory — refusing`);
			await sleep(30000);
			process.exit(1);
		}
		// A Chromium left on our profile by a supervisor the Task Scheduler
		// terminated: the profile is ours alone, so it goes.
		if (win) {
			for (const p of onProfile()) {
				log(`killed Chromium ${p} on ${PROFILE}, left by a previous run`);
				killTree(p);
			}
		}
		put('port', PROXY_PORT);
		// The nonce last answered, from our own state: a restart (launchd, the
		// Task Scheduler) must not answer it again.
		const before = parseCmd(`${(get('state') || '').split(' ')[0]} x`);
		let handled = before ? before.nonce : '-';
		nonce = handled;
		let seen = get('cmd');
		for (let i = 0; seen === undefined && i < 20; i++) {
			pause(50);
			seen = get('cmd');
		}
		seen = seen || '';
		state('idle');
		log(`polling ${CTL} (origins: ${ORIGINS})`);
		while (!quit) {
			put('heartbeat', String(epoch()));
			const next = nextCmd({ text: get('cmd'), seen, handled });
			seen = next.seen;
			if (next.ignored) log('ignored a cmd without a numeric nonce');
			const c = next.run;
			if (c) {
				nonce = c.nonce;
				handled = c.nonce;
				switch (c.verb) {
					case 'up':
						await stop();
						url = c.url;
						windowed = false;
						wanted = 'up';
						if (start()) state('running');
						else {
							wanted = 'down';
							state('stopped');
						}
						break;
					case 'restart':
						await stop();
						if (wanted === 'up' && start()) state('running');
						else state('stopped');
						break;
					case 'down':
						await stop();
						windowed = false;
						wanted = 'down';
						state('stopped');
						break;
					case 'window': {
						// On the page shown when no URL is given : the handoff must not lose it.
						const to = c.url || lastPage(alive() ? await loopbackPages(CDP_PORT) : null, allowed, url);
						await stop();
						url = to;
						windowed = true;
						windowNonce = c.nonce;
						windowPaged = false;
						wanted = 'up';
						if (start()) state('running');
						else {
							windowed = false;
							wanted = 'down';
							state('stopped');
						}
						break;
					}
					case 'handback':
						if (windowed && alive()) await endWindow('handed back');
						else state(now);
						break;
					case 'stats':
						stats();
						state(now);
						break;
				}
			}
			if (wanted === 'up' && windowed) {
				// Where the user is, kept for the headless restart : a closed
				// Chromium (Windows) can no longer say it.
				const pages = alive() ? await loopbackPages(CDP_PORT) : null;
				url = lastPage(pages, allowed, url);
				windowPaged ||= !!(pages && pages.length);
				if (windowOver({ alive: alive(), pages: windowPaged ? pages : null })) await endWindow(alive() ? 'no page left' : 'Chromium closed');
			}
			if (wanted === 'up' && !windowed && alive() && idle()) {
				log(`no activity from the container for ${IDLE_S}s — Chromium off`);
				await stop();
				wanted = 'down';
				state('stopped');
			}
			if (wanted === 'up' && !alive()) {
				// Three deaths within 10 s of their start: it will not come up by itself.
				quickExits = epoch() - started < 10 ? quickExits + 1 : 0;
				await stop();
				if (quickExits >= 3) {
					log('Chromium dies at start — giving up, see chromium.log');
					quickExits = 0;
					wanted = 'down';
					state('stopped');
				} else {
					log('Chromium exited — restarting');
					await sleep(2000);
					if (quit) break;
					if (start()) state('running');
					else {
						wanted = 'down';
						state('stopped');
					}
				}
			}
			await sleep(1000);
		}
		await stop();
		state('stopped');
		removePlain('heartbeat');
		removePlain('port');
		process.exit(0);
	}
	return loop();
}

// pathToFileURL, not `file://${argv[1]}`: the installed copy lives under
// "Application Support", and import.meta.url has that space as %20.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
	if (process.argv[2] === 'find-chromium') {
		const { chromium, tried } = hostChromium(process.env);
		process.stdout.write(`${chromium}\n${tried.join('\n')}\n`);
	} else {
		supervise(process.argv.slice(2));
	}
}
