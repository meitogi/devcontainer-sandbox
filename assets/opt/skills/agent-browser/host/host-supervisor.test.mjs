// host-supervisor.test.mjs — the supervisor's pure parts: the channel grammar,
// the Chromium search per OS, the flags, the stats parsers, the orphan match.
// The loop itself (files, signals, a fake Chromium, the real proxy) is driven
// by test/agent-browser.test.sh.
//
//   node --test /opt/devcontainer/base/skills/agent-browser/host/host-supervisor.test.mjs
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { chromiumFlags, filterFlags, findChromium, idleTooLong, nextCmd, orphansOf, parseCmd, parsePsTime, readEnvFile, spkiOf, statsFromCim, statsFromPs } from './host-supervisor.mjs';

test('cmd: a digits-only nonce, a verb, the URL as one word ; anything else is ignored', () => {
	assert.deepEqual(parseCmd('1730000000123 up http://localhost:5173/\n'), { nonce: '1730000000123', verb: 'up', url: 'http://localhost:5173/' });
	assert.deepEqual(parseCmd('42 down'), { nonce: '42', verb: 'down', url: '' });
	assert.equal(parseCmd('abc up http://localhost:5173/'), null);
	assert.equal(parseCmd('12a stats'), null);
	assert.equal(parseCmd(''), null);
	assert.equal(parseCmd('-1 down'), null);
});

test('flags: only the bench switches pass, the rest is dropped', () => {
	assert.deepEqual(filterFlags('--disable-gpu-vsync --evil --window-size=800,600 --user-data-dir=/tmp\n'), {
		pass: ['--disable-gpu-vsync', '--window-size=800,600'],
		dropped: ['--evil', '--user-data-dir=/tmp'],
	});
	assert.deepEqual(filterFlags('--disable-frame-rate-limit --window-size=1,2 --window-size=12345,80').pass, ['--disable-frame-rate-limit']);
	assert.deepEqual(filterFlags(''), { pass: [], dropped: [] });
});

// A fake filesystem: the executables that exist, the directories' entries.
const fakeFs = (files, dirs = {}) => ({ executable: p => files.includes(p), readdir: d => dirs[d] ?? [] });

test('Chromium search on a Mac: the same places and words as the shell version, in order', () => {
	const home = '/Users/u';
	const r = findChromium({ platform: 'darwin', env: { HOME: home }, fs: fakeFs([]), which: () => '', mdfind: () => [] });
	assert.equal(r.chromium, '');
	assert.deepEqual(r.tried, [
		'AGENT_BROWSER_CHROMIUM (.devcontainer/.env): unset',
		'/Users/u/Library/Application Support/agent-browser/chromium/Chromium.app/Contents/MacOS/Chromium',
		'/Applications/Chromium.app/Contents/MacOS/Chromium',
		'/Users/u/Applications/Chromium.app/Contents/MacOS/Chromium',
		'/Users/u/Library/Caches/ms-playwright/chromium-*/chrome-mac*/Chromium.app/Contents/MacOS/Chromium',
		'/Users/u/.cache/ms-playwright/chromium-*/chrome-linux*/chrome',
		'/Users/u/.cache/puppeteer/chromium/mac*/chrome-mac/Chromium.app/Contents/MacOS/Chromium',
		'/Users/u/.cache/puppeteer/chromium/linux*/chrome-linux/chrome',
		'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
		'/Users/u/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
		'/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing',
		'/Users/u/Library/Caches/ms-playwright/chromium-*/chrome-mac*/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing',
		'/Users/u/.cache/puppeteer/chrome/mac*/chrome-mac*/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing',
		'/Users/u/.cache/puppeteer/chrome/linux*/chrome-linux*/chrome',
		'/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
		'PATH: chromium chromium-browser google-chrome google-chrome-stable microsoft-edge microsoft-edge-stable',
		'Spotlight: org.chromium.Chromium',
	]);
	const pw = '/Users/u/Library/Caches/ms-playwright/chromium-1140/chrome-mac-arm64/Chromium.app/Contents/MacOS/Chromium';
	const found = findChromium({
		platform: 'darwin', env: { HOME: home },
		fs: fakeFs([pw, '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'], { '/Users/u/Library/Caches/ms-playwright': ['chromium-1140', 'ffmpeg-1010'], '/Users/u/Library/Caches/ms-playwright/chromium-1140': ['chrome-mac-arm64'] }),
		which: () => '', mdfind: () => [],
	});
	assert.equal(found.chromium, pw, 'the first that exists wins, a Playwright glob expanded');
	assert.ok(found.tried.includes(pw));
	const own = findChromium({ platform: 'darwin', env: { HOME: home, AGENT_BROWSER_CHROMIUM: '/opt/My' }, fs: fakeFs(['/opt/My', pw]), which: () => '', mdfind: () => [] });
	assert.equal(own.chromium, '/opt/My');
	assert.equal(own.tried[0], 'AGENT_BROWSER_CHROMIUM (.devcontainer/.env): /opt/My');
	const spot = findChromium({ platform: 'darwin', env: { HOME: home }, fs: fakeFs(['/Volumes/x/Chromium.app/Contents/MacOS/Chromium']), which: () => '', mdfind: () => ['/Volumes/x/Chromium.app'] });
	assert.equal(spot.chromium, '/Volumes/x/Chromium.app/Contents/MacOS/Chromium', 'Spotlight last');
	const path = findChromium({ platform: 'linux', env: { HOME: '/home/u' }, fs: fakeFs(['/usr/bin/chromium']), which: n => (n === 'chromium' ? '/usr/bin/chromium' : ''), mdfind: null });
	assert.equal(path.chromium, '/usr/bin/chromium');
	assert.ok(!path.tried.some(l => l.startsWith('Spotlight')), 'no Spotlight line without mdfind');
});

test('Chromium search: what npx @puppeteer/browsers install puts in ~/.cache/puppeteer, Chromium before Chrome for Testing', () => {
	const home = '/Users/u';
	const pp = `${home}/.cache/puppeteer`;
	const chromium = `${pp}/chromium/mac_arm-1400000/chrome-mac/Chromium.app/Contents/MacOS/Chromium`;
	const cft = `${pp}/chrome/mac_arm-140.0.7339.80/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
	const dirs = {
		[`${pp}/chromium`]: ['mac_arm-1400000'],
		[`${pp}/chromium/mac_arm-1400000`]: ['chrome-mac'],
		[`${pp}/chrome`]: ['mac_arm-140.0.7339.80'],
		[`${pp}/chrome/mac_arm-140.0.7339.80`]: ['chrome-mac-arm64'],
	};
	const both = findChromium({ platform: 'darwin', env: { HOME: home }, fs: fakeFs([cft, chromium], dirs), which: () => '', mdfind: () => [] });
	assert.equal(both.chromium, chromium);
	assert.ok(both.tried.includes(chromium) && both.tried.includes(cft), 'both expanded in « looked in »');
	assert.equal(findChromium({ platform: 'darwin', env: { HOME: home }, fs: fakeFs([cft], dirs), which: () => '', mdfind: () => [] }).chromium, cft);
	const kit = `${home}/Library/Application Support/agent-browser/chromium/Chromium.app/Contents/MacOS/Chromium`;
	assert.equal(findChromium({ platform: 'darwin', env: { HOME: home }, fs: fakeFs([chromium, kit], dirs), which: () => '', mdfind: () => [] }).chromium, kit, 'install-chromium first');
	const lx = '/home/u/.cache/puppeteer/chrome/linux-140.0.7339.80/chrome-linux64/chrome';
	const linux = findChromium({
		platform: 'linux', env: { HOME: '/home/u' },
		fs: fakeFs([lx], { '/home/u/.cache/puppeteer/chrome': ['linux-140.0.7339.80'], '/home/u/.cache/puppeteer/chrome/linux-140.0.7339.80': ['chrome-linux64'] }),
		which: () => '', mdfind: null,
	});
	assert.equal(linux.chromium, lx);
});

test('Chromium search on Windows: the kit download, Chrome, Chromium, then Edge', () => {
	const env = { LOCALAPPDATA: 'C:\\Users\\u\\AppData\\Local', USERPROFILE: 'C:\\Users\\u', ProgramFiles: 'C:\\Program Files', 'ProgramFiles(x86)': 'C:\\Program Files (x86)' };
	const r = findChromium({ platform: 'win32', env, fs: fakeFs([]), which: () => '', mdfind: null });
	assert.equal(r.chromium, '');
	assert.deepEqual(r.tried, [
		'AGENT_BROWSER_CHROMIUM (.devcontainer/.env): unset',
		'C:\\Users\\u\\AppData\\Local\\agent-browser\\chromium\\chrome-win\\chrome.exe',
		'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
		'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
		'C:\\Users\\u\\AppData\\Local\\Google\\Chrome\\Application\\chrome.exe',
		'C:\\Users\\u\\AppData\\Local\\Chromium\\Application\\chrome.exe',
		'C:\\Users\\u\\AppData\\Local\\ms-playwright\\chromium-*\\chrome-win*\\chrome.exe',
		'C:\\Users\\u\\.cache\\puppeteer\\chromium\\win*\\chrome-win\\chrome.exe',
		'C:\\Users\\u\\.cache\\puppeteer\\chrome\\win*\\chrome-win*\\chrome.exe',
		'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
		'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
		'PATH: chrome chromium msedge',
	]);
	const edge = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
	assert.equal(findChromium({ platform: 'win32', env, fs: fakeFs([edge]), which: () => '', mdfind: null }).chromium, edge, 'Edge, always installed, as the last resort');
	const kit = 'C:\\Users\\u\\AppData\\Local\\agent-browser\\chromium\\chrome-win\\chrome.exe';
	assert.equal(findChromium({ platform: 'win32', env, fs: fakeFs([edge, kit]), which: () => '', mdfind: null }).chromium, kit, 'install-chromium first');
	const pp = 'C:\\Users\\u\\.cache\\puppeteer\\chromium\\win64-1400000\\chrome-win\\chrome.exe';
	const ppDirs = { 'C:\\Users\\u\\.cache\\puppeteer\\chromium': ['win64-1400000'], 'C:\\Users\\u\\.cache\\puppeteer\\chromium\\win64-1400000': ['chrome-win'] };
	assert.equal(findChromium({ platform: 'win32', env, fs: fakeFs([edge, pp], ppDirs), which: () => '', mdfind: null }).chromium, pp, 'Puppeteer\'s Chromium before Edge');
});

test('flags: the set of the shell version ; Metal on a Mac only ; window and audio switches', () => {
	const base = { profile: '/p', pac: 'function FindProxyForURL(){}', rules: 'MAP * ~NOTFOUND', env: {} };
	const linux = chromiumFlags({ ...base, platform: 'linux' });
	for (const f of ['--user-data-dir=/p', '--no-first-run', '--window-size=1280,800', '--force-device-scale-factor=1', '--proxy-bypass-list=<-loopback>', '--host-resolver-rules=MAP * ~NOTFOUND', '--disable-features=WebRtcHideLocalIpsWithMdns', '--mute-audio', '--headless=new']) {
		assert.ok(linux.includes(f), f);
	}
	assert.ok(linux.includes(`--proxy-pac-url=data:application/x-ns-proxy-autoconfig;base64,${Buffer.from(base.pac).toString('base64')}`));
	assert.ok(!linux.includes('--use-angle=metal'));
	assert.ok(chromiumFlags({ ...base, platform: 'darwin' }).includes('--use-angle=metal'));
	assert.ok(!chromiumFlags({ ...base, platform: 'win32' }).includes('--use-angle=metal'));
	const open = chromiumFlags({ ...base, platform: 'darwin', env: { AGENT_BROWSER_WINDOW: '1', AGENT_BROWSER_AUDIO: 'on', AGENT_BROWSER_SIZE: '1920,1080' } });
	assert.ok(!open.includes('--headless=new') && !open.includes('--use-angle=metal') && !open.includes('--mute-audio') && open.includes('--window-size=1920,1080'));
	assert.ok(chromiumFlags({ ...base, platform: 'linux', spki: 'abc=' }).includes('--ignore-certificate-errors-spki-list=abc='));
});

test('spki: the same pin as the openssl pipe of the shell version', { skip: !hasOpenssl() && 'no openssl here' }, () => {
	const dir = mkdtempSync(join(tmpdir(), 'spki-'));
	try {
		execFileSync('openssl', ['req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256', '-nodes', '-keyout', join(dir, 'k.pem'), '-out', join(dir, 'c.pem'), '-subj', '/CN=localhost', '-days', '1'], { stdio: 'ignore' });
		const shell = execFileSync('sh', ['-c', `openssl x509 -in "${dir}/c.pem" -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64`]).toString().trim();
		assert.equal(spkiOf(readFileSync(join(dir, 'c.pem'), 'utf8')), shell);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

function hasOpenssl() {
	try {
		execFileSync('openssl', ['version'], { stdio: 'ignore' });
		return true;
	} catch {
		return false;
	}
}

test('stats: ps cputime as 1/100 s ticks, the profile matched ; CIM the same', () => {
	assert.equal(parsePsTime('0:01.50'), 150);
	assert.equal(parsePsTime('01:02:03'), (3600 + 120 + 3) * 100);
	assert.equal(parsePsTime('1-00:00:01'), (86400 + 1) * 100);
	const ps = ['  0:01.50  1000 /x/Chromium --user-data-dir=/p/profile --flag', ' 0:00.25   500 /x/Helper --user-data-dir=/p/profile', ' 9:00.00  9999 /x/Chromium --user-data-dir=/q/profile'].join('\n');
	assert.deepEqual(statsFromPs(ps, '/p/profile'), { ticks: 175, rss: 1500, n: 2 });
	const cim = JSON.stringify([
		{ ProcessId: 10, KernelModeTime: 1000000, UserModeTime: 500000, WorkingSetSize: 2048 * 1024, CommandLine: '"C:\\c\\chrome.exe" --user-data-dir=C:\\a\\profile --x' },
		{ ProcessId: 11, KernelModeTime: 0, UserModeTime: 100000, WorkingSetSize: 1024, CommandLine: '"C:\\c\\chrome.exe" --type=gpu-process --user-data-dir=C:\\a\\profile' },
		{ ProcessId: 12, KernelModeTime: 9, UserModeTime: 9, WorkingSetSize: 9, CommandLine: null },
	]);
	assert.deepEqual(statsFromCim(cim, 'C:\\a\\profile'), { ticks: 16, rss: 2049, n: 2 });
	assert.deepEqual(statsFromCim(JSON.stringify({ ProcessId: 1, KernelModeTime: 0, UserModeTime: 0, WorkingSetSize: 0, CommandLine: 'x' }), 'C:\\a\\profile'), { ticks: 0, rss: 0, n: 0 }, 'one process: CIM gives an object, not an array');
});

test('orphans: the processes on this very profile, not on a longer one', () => {
	const list = [
		{ pid: 1, cmd: '"C:\\c\\chrome.exe" --user-data-dir=C:\\L\\agent-browser\\demo\\profile --headless=new' },
		{ pid: 2, cmd: '"C:\\c\\chrome.exe" "--user-data-dir=C:\\L\\agent-browser\\demo\\profile"' },
		{ pid: 3, cmd: '"C:\\c\\chrome.exe" --user-data-dir=C:\\L\\agent-browser\\demo\\profile2' },
		{ pid: 4, cmd: 'notepad.exe' },
		{ pid: 5, cmd: '"C:\\c\\chrome.exe" --user-data-dir=c:\\l\\agent-browser\\demo\\profile' },
	];
	assert.deepEqual(orphansOf(list, 'C:\\L\\agent-browser\\demo\\profile', 'win32'), [1, 2, 5]);
	assert.deepEqual(orphansOf(list, 'C:\\L\\agent-browser\\demo\\profile', 'linux'), [1, 2], 'case matters off Windows');
});

test('env.json: string values of the agent browser\'s own keys only', () => {
	assert.deepEqual(readEnvFile('{"AGENT_BROWSER_ORIGINS":"http://localhost:5173","NODE":"C:\\\\n\\\\node.exe","PATH":"x","AGENT_BROWSER_IDLE_S":360,"NODE_OPTIONS":"--require x"}'), {
		AGENT_BROWSER_ORIGINS: 'http://localhost:5173',
		NODE: 'C:\\n\\node.exe',
	});
	assert.throws(() => readEnvFile('not json'));
});

test('idle: no activity for IDLE_S and no hold in the future → off', () => {
	const t = { now: 1000, started: 0, idleS: 360 };
	assert.equal(idleTooLong({ ...t, activity: 700 }), false);
	assert.equal(idleTooLong({ ...t, activity: 600 }), true);
	assert.equal(idleTooLong({ ...t, activity: 0, started: 900 }), false, 'started counts as activity');
	assert.equal(idleTooLong({ ...t, activity: 0, hold: 1001 }), false, 'a hold in the future keeps it up');
	assert.equal(idleTooLong({ ...t, activity: 0, hold: 999 }), true);
});

test('next cmd: a new nonce runs once ; an unreadable file is no news ; a restart never re-runs what state answered', () => {
	const up = '42 up http://localhost:5173/\n';
	assert.deepEqual(nextCmd({ text: up, seen: '', handled: '-' }), { run: { nonce: '42', verb: 'up', url: 'http://localhost:5173/' }, seen: up, ignored: false });
	assert.deepEqual(nextCmd({ text: up, seen: up, handled: '42' }), { run: null, seen: up, ignored: false }, 'unchanged: nothing');
	// A read that failed (undefined) must not reset what was seen: else the next
	// good read looks new and the same command runs twice.
	assert.deepEqual(nextCmd({ text: undefined, seen: up, handled: '42' }), { run: null, seen: up, ignored: false });
	assert.equal(nextCmd({ text: up, seen: '', handled: '42' }).run, null, 'its nonce already answered (state, read back at start): not again');
	assert.deepEqual(nextCmd({ text: null, seen: up, handled: '42' }), { run: null, seen: '', ignored: false }, 'the file gone: seen reset');
	assert.deepEqual(nextCmd({ text: 'abc up x', seen: '', handled: '-' }), { run: null, seen: 'abc up x', ignored: true });
});
