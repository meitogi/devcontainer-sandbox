/**
 * tokens skill — local log discovery and event walking.
 *
 * Reads from `<project-root>/.claude/tokens/logs/YYYY-MM/*.jsonl`.
 * Session 2 scope: current project only. Session 4 extends this to
 * cross-container aggregation via `docker volume ls`.
 *
 * @typedef {import('./window.js').TimeWindow} TimeWindow
 *
 * @typedef {Object} ProjectConfig
 * @property {string}  project_id
 * @property {string}  title
 * @property {string}  [subtitle]
 * @property {string}  [host_workspace_path]
 * @property {string}  [container_workspace_path]
 *
 * @typedef {Object} Event  emitted by {@link walkEvents}
 * @property {number} ts             ms since epoch
 * @property {string} ts_iso         original ISO timestamp from the JSONL
 * @property {string} session        session UUID
 * @property {string} model          model ID (or `'unknown'`)
 * @property {string} project_root   absolute path from the event (fallback: current root)
 * @property {import('./pricing.js').TokenCounts} tokens  DELTA vs. previous event (never totals)
 * @property {number} cost_usd
 */

const fs = require('node:fs');
const path = require('node:path');

/**
 * Walk parents of `startDir` until we hit either a `.claude/tokens/` dir or
 * a `.git/` marker. Falls back to `startDir` if neither is found. Used by
 * recap.js to pick the log directory.
 * @param {string} [startDir=process.cwd()]
 * @returns {string}
 */
function findProjectRoot(startDir = process.cwd()) {
  let dir = path.resolve(startDir);
  while (true) {
    if (fs.existsSync(path.join(dir, '.claude', 'tokens'))) return dir;
    if (fs.existsSync(path.join(dir, '.git'))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) return startDir;
    dir = parent;
  }
}

/**
 * Read a project's `config.json`. Missing / unparseable → `null`.
 * @param {string} projectRoot
 * @returns {?ProjectConfig}
 */
function readConfig(projectRoot) {
  const p = path.join(projectRoot, '.claude', 'tokens', 'config.json');
  if (!fs.existsSync(p)) return null;
  try {
    return JSON.parse(fs.readFileSync(p, 'utf8'));
  } catch (e) {
    process.stderr.write(`warn: config.json parse failed: ${e.message}\n`);
    return null;
  }
}

/**
 * True iff the `YYYY-MM` month directory could contain events within the
 * given window. Used to prune log-directory scans before opening files.
 * @param {string}      monthName  e.g. `"2026-07"`
 * @param {TimeWindow}  window
 * @returns {boolean}
 */
function monthDirInWindow(monthName, window) {
  const m = /^(\d{4})-(\d{2})$/.exec(monthName);
  if (!m) return false;
  const year = parseInt(m[1], 10);
  const month = parseInt(m[2], 10);
  const monthStart = Date.UTC(year, month - 1, 1);
  const monthEnd = Date.UTC(year, month, 1) - 1;
  return monthEnd >= window.startEpoch && monthStart <= window.endEpoch;
}

/**
 * Yield {@link Event} objects from `<projectRoot>/.claude/tokens/logs/`
 * whose timestamp lies inside `window`. Bad lines / bad files are skipped
 * with a stderr warning — never crash the recap.
 * @param {string}     projectRoot
 * @param {TimeWindow} window
 * @yields {Event}
 */
function* walkEvents(projectRoot, window) {
  const logsDir = path.join(projectRoot, '.claude', 'tokens', 'logs');
  if (!fs.existsSync(logsDir)) return;
  const months = fs.readdirSync(logsDir).sort();
  for (const month of months) {
    if (!monthDirInWindow(month, window)) continue;
    const monthPath = path.join(logsDir, month);
    let entries;
    try {
      entries = fs.readdirSync(monthPath);
    } catch {
      continue;
    }
    for (const file of entries) {
      if (!file.endsWith('.jsonl')) continue;
      const full = path.join(monthPath, file);
      let content;
      try {
        content = fs.readFileSync(full, 'utf8');
      } catch (e) {
        process.stderr.write(`warn: cannot read ${full}: ${e.message}\n`);
        continue;
      }
      const lines = content.split('\n');
      for (const line of lines) {
        if (!line.trim()) continue;
        let ev;
        try {
          ev = JSON.parse(line);
        } catch (e) {
          process.stderr.write(`warn: bad JSONL in ${full}: ${e.message}\n`);
          continue;
        }
        if (!ev.tokens || typeof ev.cost_usd !== 'number' || !ev.ts) continue;
        const ts = Date.parse(ev.ts);
        if (Number.isNaN(ts)) continue;
        if (ts < window.startEpoch || ts > window.endEpoch) continue;
        yield {
          ts,
          ts_iso: ev.ts,
          session: ev.session,
          model: ev.model || 'unknown',
          project_root: ev.project_root || projectRoot,
          tokens: {
            in: ev.tokens.in || 0,
            cache_read: ev.tokens.cache_read || 0,
            cache_create: ev.tokens.cache_create || 0,
            out: ev.tokens.out || 0,
          },
          cost_usd: ev.cost_usd || 0,
        };
      }
    }
  }
}

/**
 * @typedef {Object} ProjectSource
 * @property {string}   project_id
 * @property {string}   [host_workspace_path]
 * @property {string}   [project_root]
 * @property {string}   [title]
 * @property {string}   [ts]                first-seen timestamp
 * @property {string[]} volumes             docker volume names where this project was seen
 * @property {boolean}  local               true iff seen in $CLAUDE_HOME/tokens/projects.jsonl
 */

function claudeHome() {
  return process.env.CLAUDE_HOME || path.join(process.env.HOME || '', '.claude');
}

function readJsonlSafe(filePath) {
  if (!fs.existsSync(filePath)) return [];
  const out = [];
  try {
    const content = fs.readFileSync(filePath, 'utf8');
    for (const line of content.split('\n')) {
      if (!line.trim()) continue;
      try { out.push(JSON.parse(line)); } catch {}
    }
  } catch (e) {
    process.stderr.write(`warn: cannot read ${filePath}: ${e.message}\n`);
  }
  return out;
}

function dockerScanScript() {
  return path.join(__dirname, 'docker-scan.sh');
}

/**
 * Enumerate all projects across local registry + docker-scan volumes.
 * Dedup by `project_id` (first-seen metadata wins; volumes are unioned).
 * @param {Object}  [opts]
 * @param {boolean} [opts.docker=true]
 * @returns {ProjectSource[]}
 */
function enumerateProjects(opts = {}) {
  const useDocker = opts.docker !== false;
  const home = claudeHome();
  const localRegistry = path.join(home, 'tokens', 'projects.jsonl');

  /** @type {Map<string, ProjectSource>} */
  const byId = new Map();

  const add = (row, source) => {
    if (!row || !row.project_id) return;
    let cur = byId.get(row.project_id);
    if (!cur) {
      cur = {
        project_id: row.project_id,
        host_workspace_path: row.host_workspace_path || '',
        project_root: row.project_root || '',
        title: row.title || '',
        ts: row.ts || '',
        volumes: [],
        local: false,
      };
      byId.set(row.project_id, cur);
    } else {
      if (!cur.host_workspace_path && row.host_workspace_path) cur.host_workspace_path = row.host_workspace_path;
      if (!cur.project_root && row.project_root) cur.project_root = row.project_root;
      if (!cur.title && row.title) cur.title = row.title;
      if (!cur.ts && row.ts) cur.ts = row.ts;
    }
    if (source.local) cur.local = true;
    if (source.volume && !cur.volumes.includes(source.volume)) cur.volumes.push(source.volume);
  };

  for (const row of readJsonlSafe(localRegistry)) add(row, { local: true });

  if (useDocker) {
    let volumes = '';
    try {
      const { execFileSync } = require('node:child_process');
      volumes = execFileSync('bash', [dockerScanScript(), 'list-volumes'], {
        encoding: 'utf8',
        timeout: 10_000,
        stdio: ['ignore', 'pipe', 'ignore'],
      });
    } catch { volumes = ''; }
    for (const vol of volumes.split('\n').filter(Boolean)) {
      let content = '';
      try {
        const { execFileSync } = require('node:child_process');
        content = execFileSync('bash', [dockerScanScript(), 'read-projects', vol], {
          encoding: 'utf8',
          timeout: 15_000,
          stdio: ['ignore', 'pipe', 'ignore'],
        });
      } catch { content = ''; }
      for (const line of content.split('\n')) {
        if (!line.trim()) continue;
        try { add(JSON.parse(line), { volume: vol }); } catch {}
      }
    }
  }

  return Array.from(byId.values());
}

/**
 * Resolve a walkable filesystem root for a project. Prefers `host_workspace_path`
 * (recap runs on host); falls back to `project_root` (recap runs in the same
 * container that wrote the events). Returns null if neither exists.
 * @param {ProjectSource} proj
 * @returns {?string}
 */
function walkableRootFor(proj) {
  const candidates = [proj.host_workspace_path, proj.project_root].filter(Boolean);
  for (const c of candidates) {
    if (fs.existsSync(path.join(c, '.claude', 'tokens'))) return c;
  }
  return null;
}

/**
 * Union of {@link walkEvents} across every known project (local registry +
 * docker-scan volumes). Yields the same {@link Event} shape as walkEvents;
 * projects with no walkable filesystem root are skipped with one stderr warn.
 * @param {TimeWindow} window
 * @param {Object}     [opts]
 * @param {boolean}    [opts.docker=true]
 * @yields {Event}
 */
function* walkAllProjects(window, opts = {}) {
  const projects = enumerateProjects(opts);
  for (const proj of projects) {
    const root = walkableRootFor(proj);
    if (!root) {
      process.stderr.write(`warn: project ${proj.title || proj.project_id} has no walkable path (host=${proj.host_workspace_path} root=${proj.project_root})\n`);
      continue;
    }
    yield* walkEvents(root, window);
  }
}

module.exports = {
  findProjectRoot,
  readConfig,
  walkEvents,
  monthDirInWindow,
  enumerateProjects,
  walkableRootFor,
  walkAllProjects,
  claudeHome,
};

if (require.main === module) {
  const assert = require('node:assert/strict');
  const w = { startEpoch: Date.UTC(2026, 6, 1), endEpoch: Date.UTC(2026, 6, 31) };
  assert.equal(monthDirInWindow('2026-07', w), true);
  assert.equal(monthDirInWindow('2026-06', w), false);
  assert.equal(monthDirInWindow('2026-08', w), false);
  assert.equal(monthDirInWindow('bad', w), false);
  const root = findProjectRoot('/workspace');
  assert.equal(root, '/workspace', `findProjectRoot(/workspace) = ${root}`);
  const projects = enumerateProjects({ docker: false });
  assert.ok(Array.isArray(projects), 'enumerateProjects returns array');
  console.log(`lib/logs.js: 6/6 ok (${projects.length} local projects)`);
}
