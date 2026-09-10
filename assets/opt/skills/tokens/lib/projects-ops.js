/**
 * tokens skill — project registry ops (list / rename / forget).
 *
 * Backs `recap.js --list-projects / --rename / --forget` and the menu-item-2
 * flow. Reads registry from local `$CLAUDE_HOME/tokens/projects.jsonl` plus
 * every `claude-code-config-*` docker volume via `lib/docker-scan.sh`, and
 * writes back to the correct source (local FS direct; volumes via alpine).
 *
 * Never crashes on docker absent — degrades to local-only.
 *
 * @typedef {import('./logs.js').ProjectSource} ProjectSource
 *
 * @typedef {Object} ProjectEntry   returned by {@link listProjects}
 * @property {string}   slug        6-char sha1 prefix of project_id
 * @property {string}   project_id
 * @property {string}   title
 * @property {string}   subtitle
 * @property {string}   host_workspace_path
 * @property {string}   project_root
 * @property {string}   last_seen   ISO from config.json (or registry ts as fallback)
 * @property {string[]} volumes
 * @property {boolean}  local
 */

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { enumerateProjects, claudeHome } = require('./logs.js');

function slugOf(projectId) {
  return crypto.createHash('sha1').update(String(projectId)).digest('hex').slice(0, 6);
}

function dockerScanScript() {
  return path.join(__dirname, 'docker-scan.sh');
}

function readConfigAt(projectPath) {
  const p = path.join(projectPath, '.claude', 'tokens', 'config.json');
  if (!fs.existsSync(p)) return null;
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; }
}

function writeConfigAt(projectPath, cfg) {
  const dir = path.join(projectPath, '.claude', 'tokens');
  fs.mkdirSync(dir, { recursive: true });
  const p = path.join(dir, 'config.json');
  const tmp = p + '.new';
  fs.writeFileSync(tmp, JSON.stringify(cfg, null, 2));
  fs.renameSync(tmp, p);
}

function nowIso() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

/**
 * @param {Object}  [opts]
 * @param {boolean} [opts.docker=true]
 * @returns {ProjectEntry[]}  sorted by last_seen desc
 */
function listProjects(opts = {}) {
  const projects = enumerateProjects(opts);
  /** @type {ProjectEntry[]} */
  const rows = projects.map((p) => {
    let title = p.title;
    let subtitle = '';
    let last_seen = p.ts || '';
    for (const walkable of [p.host_workspace_path, p.project_root].filter(Boolean)) {
      const cfg = readConfigAt(walkable);
      if (cfg) {
        if (cfg.title) title = cfg.title;
        if (cfg.subtitle) subtitle = cfg.subtitle;
        if (cfg.last_seen && cfg.last_seen > last_seen) last_seen = cfg.last_seen;
        break;
      }
    }
    return {
      slug: slugOf(p.project_id),
      project_id: p.project_id,
      title,
      subtitle,
      host_workspace_path: p.host_workspace_path,
      project_root: p.project_root,
      last_seen,
      volumes: p.volumes.slice(),
      local: p.local,
    };
  });
  rows.sort((a, b) => (b.last_seen || '').localeCompare(a.last_seen || ''));
  return rows;
}

/**
 * Resolve a user-provided slug against listProjects().
 * Accepts: 6-char hash prefix (case-insensitive), exact title, exact project_id.
 * @param {string}         slug
 * @param {ProjectEntry[]} [rows]
 * @returns {?ProjectEntry}
 */
function resolveSlug(slug, rows) {
  if (!slug) return null;
  const all = rows || listProjects();
  const s = String(slug).toLowerCase();
  return (
    all.find((r) => r.slug === s)
    || all.find((r) => r.project_id === slug)
    || all.find((r) => r.title === slug)
    || null
  );
}

function appendLocalRegistry(entry) {
  const p = path.join(claudeHome(), 'tokens', 'projects.jsonl');
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.appendFileSync(p, JSON.stringify(entry) + '\n');
}

function rewriteLocalRegistry(rows) {
  const p = path.join(claudeHome(), 'tokens', 'projects.jsonl');
  fs.mkdirSync(path.dirname(p), { recursive: true });
  const tmp = p + '.new';
  fs.writeFileSync(tmp, rows.map((r) => JSON.stringify(r)).join('\n') + (rows.length ? '\n' : ''));
  fs.renameSync(tmp, p);
}

function readLocalRegistry() {
  const p = path.join(claudeHome(), 'tokens', 'projects.jsonl');
  if (!fs.existsSync(p)) return [];
  const out = [];
  for (const line of fs.readFileSync(p, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    try { out.push(JSON.parse(line)); } catch {}
  }
  return out;
}

function volumeAppendEvent(volume, entry) {
  try {
    execFileSync('bash', [dockerScanScript(), 'append-project-event', volume, JSON.stringify(entry)], {
      timeout: 15_000,
      stdio: 'ignore',
    });
  } catch {}
}

function volumeRewriteRegistry(volume, rows) {
  const tmp = path.join(require('node:os').tmpdir(), `tokens-registry-${process.pid}-${Date.now()}.jsonl`);
  fs.writeFileSync(tmp, rows.map((r) => JSON.stringify(r)).join('\n') + (rows.length ? '\n' : ''));
  try {
    execFileSync('bash', [dockerScanScript(), 'rewrite-projects', volume, tmp], {
      timeout: 15_000,
      stdio: 'ignore',
    });
  } catch {}
  try { fs.unlinkSync(tmp); } catch {}
}

function volumeReadRegistry(volume) {
  let content = '';
  try {
    content = execFileSync('bash', [dockerScanScript(), 'read-projects', volume], {
      encoding: 'utf8',
      timeout: 15_000,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
  } catch { return []; }
  const out = [];
  for (const line of content.split('\n')) {
    if (!line.trim()) continue;
    try { out.push(JSON.parse(line)); } catch {}
  }
  return out;
}

/**
 * Rename a project: update config.json (source of truth) + append a rename
 * event to every registry the project appears in (local + all volumes).
 * @param {string} slug
 * @param {{title?:string, subtitle?:string}} fields
 * @returns {{ok:boolean, project?:ProjectEntry, error?:string}}
 */
function renameProject(slug, fields) {
  const rows = listProjects();
  const proj = resolveSlug(slug, rows);
  if (!proj) return { ok: false, error: `no project matches "${slug}"` };
  if (!fields || (!fields.title && fields.subtitle === undefined)) {
    return { ok: false, error: 'no title or subtitle provided' };
  }

  const walkable = [proj.host_workspace_path, proj.project_root].find((c) => c && fs.existsSync(c));
  if (walkable) {
    const cfg = readConfigAt(walkable) || {
      project_id: proj.project_id,
      title: proj.title,
      subtitle: proj.subtitle,
      host_workspace_path: proj.host_workspace_path,
      container_workspace_path: proj.project_root,
      first_seen: nowIso(),
    };
    if (fields.title) cfg.title = fields.title;
    if (fields.subtitle !== undefined) cfg.subtitle = fields.subtitle;
    cfg.last_seen = nowIso();
    writeConfigAt(walkable, cfg);
  }

  const event = {
    ts: nowIso(),
    project_id: proj.project_id,
    event: 'rename',
    title: fields.title || proj.title,
    subtitle: fields.subtitle !== undefined ? fields.subtitle : proj.subtitle,
    host_workspace_path: proj.host_workspace_path,
    project_root: proj.project_root,
  };
  if (proj.local) appendLocalRegistry(event);
  for (const vol of proj.volumes) volumeAppendEvent(vol, event);

  return { ok: true, project: { ...proj, title: fields.title || proj.title, subtitle: fields.subtitle !== undefined ? fields.subtitle : proj.subtitle } };
}

/**
 * Filter a project out of every registry it appears in. Config.json in the
 * project's workspace is left intact — the user's data isn't touched.
 * @param {string} slug
 * @returns {{ok:boolean, project?:ProjectEntry, error?:string}}
 */
function forgetProject(slug) {
  const rows = listProjects();
  const proj = resolveSlug(slug, rows);
  if (!proj) return { ok: false, error: `no project matches "${slug}"` };

  if (proj.local) {
    const kept = readLocalRegistry().filter((r) => r.project_id !== proj.project_id);
    rewriteLocalRegistry(kept);
  }
  for (const vol of proj.volumes) {
    const kept = volumeReadRegistry(vol).filter((r) => r.project_id !== proj.project_id);
    volumeRewriteRegistry(vol, kept);
  }
  return { ok: true, project: proj };
}

module.exports = {
  listProjects,
  renameProject,
  forgetProject,
  resolveSlug,
  slugOf,
};

if (require.main === module) {
  const assert = require('node:assert/strict');
  assert.equal(slugOf('foo').length, 6);
  assert.equal(slugOf('foo'), slugOf('foo'));
  assert.notEqual(slugOf('foo'), slugOf('bar'));
  const rows = listProjects({ docker: false });
  assert.ok(Array.isArray(rows), 'listProjects returns array');
  assert.equal(resolveSlug('', rows), null);
  assert.equal(resolveSlug('nonexistent-slug-xyz', rows), null);
  console.log(`lib/projects-ops.js: 5/5 ok (${rows.length} projects)`);
}
