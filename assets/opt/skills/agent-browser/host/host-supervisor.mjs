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
 *   state      written here : "<nonce> <running|stopped|idle> <pid> <url>"
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
 * (idleTooLong). Chromium is restarted if it dies while the wanted state is
 * up, three times at most when it dies right at start.
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
 * PATH names, then Spotlight on a Mac. Windows ends on Edge (always installed,
 * a Chromium with DevTools). `tried` is one line per place looked at — what
 * « not found » prints.
 */
export function findChromium({ platform, env, fs: f, which, mdfind }) {
	const own = env.AGENT_BROWSER_CHROMIUM || '';
	const tried = [`AGENT_BROWSER_CHROMIUM (.devcontainer/.env): ${own || 'unset'}`];
	let candidates;
	let names;
	if (platform === 'win32') {
		const w = path.win32.join;
		const local = env.LOCALAPPDATA || '';
		const pptr = w(env.USERPROFILE || '', '.cache', 'puppeteer');
		const pf = env.ProgramFiles || 'C:\\Program Files';
		const pf86 = env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)';
		candidates = [
			w(local, 'agent-browser', 'chromium', 'chrome-win', 'chrome.exe'),
			w(pf, 'Google', 'Chrome', 'Application', 'chrome.exe'),
			w(pf86, 'Google', 'Chrome', 'Application', 'chrome.exe'),
			w(local, 'Google', 'Chrome', 'Application', 'chrome.exe'),
			w(local, 'Chromium', 'Application', 'chrome.exe'),
			...expand(w(local, 'ms-playwright', 'chromium-*', 'chrome-win*', 'chrome.exe'), f.readdir, '\\'),
			...expand(w(pptr, 'chromium', 'win*', 'chrome-win', 'chrome.exe'), f.readdir, '\\'),
			...expand(w(pptr, 'chrome', 'win*', 'chrome-win*', 'chrome.exe'), f.readdir, '\\'),
			w(pf, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
			w(pf86, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
		];
		names = ['chrome', 'chromium', 'msedge'];
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
	return { chromium, tried };
}

/** Trust exactly the dev cert's key — never the blanket --ignore-certificate-errors. */
export function spkiOf(pem) {
	const der = new X509Certificate(pem).publicKey.export({ type: 'spki', format: 'der' });
	return createHash('sha256').update(der).digest('base64');
}

/**
 * The flags. The window size is in CSS pixels at scale 1: 1280x800 is a
 * 1280x657 canvas, not Retina's 2560x1426. Headless (the default) runs on the
 * GPU too — Metal on a Mac ; AGENT_BROWSER_WINDOW=1 opens a real window.
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
export function chromiumFlags({ platform, env, profile, pac: pacText, rules, spki }) {
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
	if ((env.AGENT_BROWSER_WINDOW || '0') !== '1') {
		flags.push('--headless=new');
		if (platform === 'darwin') flags.push('--use-angle=metal');
	}
	return flags;
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
	return findChromium({ platform: process.platform, env, fs: hostFs, which, mdfind });
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
	let quickExits = 0;

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
		let flags;
		try {
			const origins = parseOrigins(ORIGINS);
			const reach = parseReach(REACH);
			flags = chromiumFlags({ platform: process.platform, env, profile: PROFILE, pac: pac(origins, reach), rules: resolverRules(origins, reach), spki: CERT ? spkiOf(fs.readFileSync(CERT)) : '' });
		} catch (e) {
			log(`refused up: the origin list is unusable (${e.message})`);
			return false;
		}
		const extra = filterFlags(get('flags') || '');
		for (const w of extra.dropped) log(`flags: dropped ${w}`);
		const out = fs.openSync(path.join(LOGDIR, 'chromium.log'), 'a');
		// DevTools on the loopback only: the container gets the proxy.
		child = spawn(chromium, [...flags, ...extra.pass, '--remote-debugging-address=127.0.0.1', `--remote-debugging-port=${CDP_PORT}`, '--', url], { stdio: ['ignore', out, out], windowsHide: true });
		fs.closeSync(out);
		const c = child;
		c.on('error', e => {
			c.failed = true;
			log(`Chromium did not start: ${e.message}`);
		});
		started = epoch();
		proxy = serve({ listen: `${PROXY_BIND}:${PROXY_PORT}`, upstream: `127.0.0.1:${CDP_PORT}`, origins: ORIGINS, log: proxyLog });
		proxy.on('connection', s => {
			sockets.push(s);
			s.on('close', () => {
				sockets = sockets.filter(x => x !== s);
			});
		});
		proxy.on('error', e => log(`proxy: ${e.message}`));
		log(`up: Chromium ${pid()} on ${url} (${SIZE}), proxy on ${PROXY_BIND}:${PROXY_PORT}`);
		return true;
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
			try {
				killTree(c.pid);
			} catch {}
			// A Chromium that ignores TERM for 5 s is killed.
			const late = setTimeout(() => alive() && c.kill('SIGKILL'), 5000);
			await gone;
			clearTimeout(late);
		}
		if (c) log('down');
		child = null;
	}

	function state(word) {
		now = word;
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
		let activity = 0;
		try {
			const st = fs.lstatSync(path.join(CTL, '..', 'activity'));
			if (st.isFile()) activity = Math.floor(st.mtimeMs / 1000);
		} catch {}
		const h = (readPlain(path.join(CTL, '..', 'hold'), 12) || '').trim();
		return idleTooLong({ now: epoch(), started, activity, hold: /^[0-9]+$/.test(h) ? Number(h) : 0, idleS: IDLE_S });
	}

	// One loop does everything, signals included: a signal only asks it to quit
	// and cuts its sleep short.
	let quit = false;
	let wake = () => {};
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
						wanted = 'down';
						state('stopped');
						break;
					case 'stats':
						stats();
						state(now);
						break;
				}
			}
			if (wanted === 'up' && alive() && idle()) {
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
