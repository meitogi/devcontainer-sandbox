#!/usr/bin/env node
/**
 * tokens skill — recap CLI.
 *
 * Two entry modes :
 *   - **args mode** (cron / scripting) : flags parsed by `util.parseArgs`,
 *     result printed as an SI-compact Markdown table or JSON.
 *   - **interactive TTY menu** : opens when no args + stdin is a TTY,
 *     unless `--no-interactive` is set.
 *
 * Reads local `<project-root>/.claude/tokens/logs/YYYY-MM/*.jsonl` (session
 * 2 scope). Session 4 will add cross-container aggregation.
 *
 * Node ≥ 18 (relies on `util.parseArgs`). Zero npm deps, CommonJS.
 *
 * @typedef {import('./lib/logs.js').Event} Event
 * @typedef {import('./lib/logs.js').ProjectConfig} ProjectConfig
 * @typedef {import('./lib/window.js').TimeWindow} TimeWindow
 *
 * @typedef {'project'|'session'|'day'|'model'} GroupBy
 *
 * @typedef {Object} AggregateRow
 * @property {string} label
 * @property {number} sessions
 * @property {string} model                    unique model if all events share one, else `'—'`
 * @property {import('./lib/pricing.js').TokenCounts} tokens
 * @property {number} cost_usd
 */


const fs = require('node:fs');
const { parseArgs } = require('node:util');
const readline = require('node:readline');
const path = require('node:path');
const { spawnSync, execFileSync } = require('node:child_process');
const { compact, compactUSD } = require('./lib/format.js');
const { sinceReset, currentWeek, currentMonth, lastN, fromTo, all } = require('./lib/window.js');
const { findProjectRoot, readConfig, walkEvents, walkAllProjects } = require('./lib/logs.js');
const { isKnown, pricingFileInfo } = require('./lib/pricing.js');
const { listProjects, renameProject, forgetProject } = require('./lib/projects-ops.js');

const REFRESH_PRICING_SH = path.join(__dirname, 'refresh-pricing.sh');
const DOCKER_SCAN_SH = path.join(__dirname, 'lib', 'docker-scan.sh');

const HELP = `
Usage: node recap.js [flags] [slug]

Window (mutually exclusive; default: --since-reset):
  --since-reset          since last Saturday 20h UTC (Anthropic weekly reset)
  --week                 current week (Mon 00h UTC)
  --month                current month (day 1 00h UTC)
  --last=<N>[dh]         sliding window (e.g. 7d, 24h)
  --from=YYYY-MM-DD      explicit start (optionally with --to=YYYY-MM-DD)
  --all                  all-time

Filter / group:
  --project=<title>      filter by project title (repeatable)
  --current-project      current cwd project only (default: multi-project union)
  --no-docker            skip docker-scan (local registry only)
  --by-project           aggregate per project
  --by-session           one row per session
  --by-day               one row per day (UTC)
  --by-model             one row per model
  --json                 machine output
  --no-color             disable ANSI
  --no-interactive       skip menu even on a TTY

Project management:
  --list-projects        list all known projects (local + docker volumes)
  --rename <slug>        rename a project ; requires --title (and/or --subtitle)
  --forget <slug>        remove a project from every registry it appears in
  --title="…"            new title (with --rename)
  --subtitle="…"         new subtitle (with --rename)

Sans args + TTY : menu interactif.
`.trim();

/**
 * Parse argv with strict `util.parseArgs`. Rejects unknown flags.
 * @param {string[]} argv
 * @returns {{values: Object, positionals: string[]}}
 * @throws {Error} on unknown flags
 */
function parseFlags(argv) {
  return parseArgs({
    args: argv,
    strict: true,
    allowPositionals: true,
    options: {
      'since-reset': { type: 'boolean' },
      week: { type: 'boolean' },
      month: { type: 'boolean' },
      last: { type: 'string' },
      from: { type: 'string' },
      to: { type: 'string' },
      all: { type: 'boolean' },
      project: { type: 'string', multiple: true },
      'all-projects': { type: 'boolean' },
      'current-project': { type: 'boolean' },
      'no-docker': { type: 'boolean' },
      'by-project': { type: 'boolean' },
      'by-session': { type: 'boolean' },
      'by-day': { type: 'boolean' },
      'by-model': { type: 'boolean' },
      json: { type: 'boolean' },
      'no-color': { type: 'boolean' },
      'no-interactive': { type: 'boolean' },
      'list-projects': { type: 'boolean' },
      rename: { type: 'boolean' },
      forget: { type: 'boolean' },
      title: { type: 'string' },
      subtitle: { type: 'string' },
      help: { type: 'boolean', short: 'h' },
    },
  });
}

/**
 * Pick the time window based on flags. Window flags are mutually exclusive.
 * @param {Object} v  parsed flag map
 * @returns {TimeWindow}
 * @throws {Error} on multiple window flags
 */
function resolveWindow(v) {
  const flags = ['since-reset', 'week', 'month', 'last', 'from', 'all'];
  const active = flags.filter(f => v[f]);
  if (active.length > 1) throw new Error(`window flags are mutually exclusive: ${active.join(', ')}`);
  if (v.all) return all();
  if (v.week) return currentWeek();
  if (v.month) return currentMonth();
  if (v.last) return lastN(v.last);
  if (v.from) return fromTo(v.from, v.to);
  return sinceReset();
}

/**
 * Pick the aggregation dimension. Explicit `--by-*` flags are mutually exclusive.
 * Auto-default: one project → `'session'`, multiple → `'project'`. Prints the
 * chosen mode to stderr for transparency.
 * @param {Object}   v
 * @param {Event[]}  events
 * @returns {GroupBy}
 * @throws {Error} on multiple --by-* flags
 */
function resolveGrouping(v, events) {
  const explicit = ['by-project', 'by-session', 'by-day', 'by-model'].filter(f => v[f]);
  if (explicit.length > 1) throw new Error(`--by-* flags are mutually exclusive: ${explicit.join(', ')}`);
  if (explicit.length === 1) return explicit[0].replace(/^by-/, '');
  const projects = new Set(events.map(e => e.project_root));
  const auto = projects.size > 1 ? 'project' : 'session';
  process.stderr.write(`grouping: ${auto} (auto — ${projects.size} project${projects.size > 1 ? 's' : ''})\n`);
  return auto;
}

/**
 * Group events by the selected dimension and sum deltas.
 * @param {Event[]}              events
 * @param {GroupBy}              groupBy
 * @param {Map<string,string>}   titleByRoot  project_root → display label
 * @returns {AggregateRow[]}
 */
function aggregate(events, groupBy, titleByRoot) {
  const rows = new Map();
  const emptyTokens = () => ({ in: 0, cache_read: 0, cache_create: 0, out: 0 });
  for (const ev of events) {
    let key, label;
    if (groupBy === 'project') {
      key = ev.project_root;
      label = titleByRoot.get(ev.project_root) || path.basename(ev.project_root || '') || ev.project_root || '—';
    } else if (groupBy === 'session') {
      key = ev.session;
      label = ev.session;
    } else if (groupBy === 'day') {
      key = ev.ts_iso.slice(0, 10);
      label = key;
    } else if (groupBy === 'model') {
      key = ev.model;
      label = ev.model;
    }
    if (!rows.has(key)) {
      rows.set(key, {
        label,
        sessions: new Set(),
        models: new Set(),
        tokens: emptyTokens(),
        cost_usd: 0,
      });
    }
    const r = rows.get(key);
    r.sessions.add(ev.session);
    r.models.add(ev.model);
    r.tokens.in += ev.tokens.in;
    r.tokens.cache_read += ev.tokens.cache_read;
    r.tokens.cache_create += ev.tokens.cache_create;
    r.tokens.out += ev.tokens.out;
    r.cost_usd += ev.cost_usd;
  }
  return [...rows.values()].map(r => ({
    label: r.label,
    sessions: r.sessions.size,
    model: r.models.size === 1 ? [...r.models][0] : '—',
    tokens: r.tokens,
    cost_usd: r.cost_usd,
  }));
}

/**
 * Build a `Total (N …)` row summing every row. Returns `null` for
 * single-row inputs (nothing to sum). Session count logic differs by dimension:
 *   - `groupBy === 'session'` → row count (each row is one session)
 *   - otherwise → sum-of-uniques as a lower bound
 * @param {AggregateRow[]} rows
 * @param {GroupBy}        groupBy
 * @returns {?AggregateRow}
 */
function totalRow(rows, groupBy) {
  if (rows.length <= 1) return null;
  const t = { in: 0, cache_read: 0, cache_create: 0, out: 0 };
  const sessions = new Set();
  const models = new Set();
  let cost = 0;
  for (const r of rows) {
    t.in += r.tokens.in;
    t.cache_read += r.tokens.cache_read;
    t.cache_create += r.tokens.cache_create;
    t.out += r.tokens.out;
    cost += r.cost_usd;
    for (const m of (r.model === '—' ? [] : [r.model])) models.add(m);
  }
  // sessions total: sum for by-session (each row = 1 unique session);
  // otherwise sum-of-uniques is a lower bound — safe: max across rows.
  const sessionsTotal = groupBy === 'session'
    ? rows.length
    : rows.reduce((s, r) => s + r.sessions, 0);
  return {
    label: `Total (${rows.length} ${pluralize(groupBy)})`,
    sessions: sessionsTotal,
    model: models.size === 1 ? [...models][0] : '—',
    tokens: t,
    cost_usd: cost,
  };
}

/** @param {GroupBy} groupBy @returns {string} */
function pluralize(groupBy) {
  return { project: 'projects', session: 'sessions', day: 'days', model: 'models' }[groupBy] || groupBy;
}

/**
 * Build the display label from a project config. Falls back to `—`.
 * @param {?ProjectConfig} cfg
 * @returns {string}
 */
function formatProjectLabel(cfg) {
  if (!cfg) return '—';
  if (cfg.subtitle) return `${cfg.title} — ${cfg.subtitle}`;
  return cfg.title;
}

/**
 * Truncate a string to at most `w` chars, replacing the last char with `…`.
 * @param {string} s @param {number} w @returns {string}
 */
function truncate(s, w) {
  if (s.length <= w) return s;
  return s.slice(0, Math.max(0, w - 1)) + '…';
}

// C:R = cache_read, C:W = cache_create (cache write). Kept compact for tables.
const HEADERS = ['Project', 'Sessions', 'Model', 'in', 'C:R', 'C:W', 'out', 'USD'];
const HEADERS_BY = {
  project: 'Project',
  session: 'Session',
  day: 'Day',
  model: 'Model',
};
const NUMERIC_COLS = new Set([1, 3, 4, 5, 6, 7]);

/**
 * Render rows as a Markdown-dialect table with SI-compact numbers,
 * right-aligned numeric columns, ANSI bold on TTY. The `Total` row (if
 * present) is dimmed.
 * @param {AggregateRow[]} rows
 * @param {GroupBy}        groupBy
 * @param {boolean}        useColor
 * @returns {string}
 */
function renderTable(rows, groupBy, useColor) {
  if (rows.length === 0) return '';
  const headers = [...HEADERS];
  headers[0] = HEADERS_BY[groupBy] || 'Project';

  const dataRows = rows.map(r => [
    r.label,
    String(r.sessions),
    r.model,
    compact(r.tokens.in),
    compact(r.tokens.cache_read),
    compact(r.tokens.cache_create),
    compact(r.tokens.out),
    compactUSD(r.cost_usd),
  ]);

  // Truncate label col if longer than 32 chars.
  for (const row of dataRows) row[0] = truncate(row[0], 32);

  const widths = headers.map((h, i) => Math.max(h.length, ...dataRows.map(r => r[i].length)));

  const pad = (cell, i) => NUMERIC_COLS.has(i) ? cell.padStart(widths[i]) : cell.padEnd(widths[i]);
  // Separator matches the visible block width around each cell: ` ${padded} ` = w + 2 chars.
  const sep = widths.map((w, i) => {
    const total = w + 2;
    const dashes = '-'.repeat(Math.max(3, total - 1));
    return NUMERIC_COLS.has(i) ? dashes + ':' : ':' + dashes;
  });

  const bold = (s) => useColor ? `\x1b[1m${s}\x1b[0m` : s;
  const dim = (s) => useColor ? `\x1b[2m${s}\x1b[0m` : s;

  const headerRow = '| ' + headers.map((h, i) => bold(pad(h, i))).join(' | ') + ' |';
  const sepRow = '|' + sep.join('|') + '|';
  const dataLines = dataRows.map((r, idx) => {
    const isTotal = idx === dataRows.length - 1 && rows[idx].label.startsWith('Total (');
    const line = '| ' + r.map((c, i) => pad(c, i)).join(' | ') + ' |';
    return isTotal ? dim(line) : line;
  });

  return [headerRow, sepRow, ...dataLines].join('\n');
}

/**
 * Main stats pipeline: resolve window → walk logs (multi-project by
 * default, or `--current-project` for cwd only) → warn on unknown models
 * → filter → aggregate → render (Markdown table or JSON).
 * @param {Object} v  parsed flag map
 * @returns {void}
 */
function runStats(v) {
  const window = resolveWindow(v);
  const useDocker = !v['no-docker'];

  /** @type {Map<string,string>} */
  const titleByRoot = new Map();
  let events = [];

  if (v['current-project']) {
    const projectRoot = findProjectRoot();
    const cfg = readConfig(projectRoot);
    for (const ev of walkEvents(projectRoot, window)) events.push(ev);
    if (cfg) titleByRoot.set(projectRoot, formatProjectLabel(cfg));
  } else {
    for (const ev of walkAllProjects(window, { docker: useDocker })) events.push(ev);
    for (const p of listProjects({ docker: useDocker })) {
      const label = p.subtitle ? `${p.title} — ${p.subtitle}` : p.title;
      if (p.host_workspace_path) titleByRoot.set(p.host_workspace_path, label);
      if (p.project_root) titleByRoot.set(p.project_root, label);
    }
  }

  const unknownModels = new Set();
  for (const ev of events) {
    if (ev.model && ev.model !== 'unknown' && !isKnown(ev.model)) unknownModels.add(ev.model);
  }
  if (unknownModels.size > 0) {
    process.stderr.write(`⚠ unknown model(s): ${[...unknownModels].join(', ')} — run refresh-pricing.sh --reconcile\n`);
  }

  let filteredEvents = events;
  if (v.project && v.project.length) {
    filteredEvents = events.filter(ev => {
      const label = titleByRoot.get(ev.project_root);
      const short = label ? label.split(' — ')[0] : null;
      return v.project.some(p => p === label || p === short || p === ev.project_root);
    });
    if (filteredEvents.length === 0) {
      process.stdout.write(`No sessions matching --project=${v.project.join(',')} in this window.\n`);
      return;
    }
  }

  const groupBy = resolveGrouping(v, filteredEvents);
  const rows = aggregate(filteredEvents, groupBy, titleByRoot);
  rows.sort((a, b) => b.cost_usd - a.cost_usd);
  const total = totalRow(rows, groupBy);
  if (total) rows.push(total);

  if (v.json) {
    const out = rows.map(r => ({
      label: r.label,
      sessions: r.sessions,
      model: r.model,
      tokens: r.tokens,
      cost_usd: Number(r.cost_usd.toFixed(6)),
    }));
    process.stdout.write(JSON.stringify({ window: { label: window.label, start: new Date(window.startEpoch).toISOString(), end: new Date(window.endEpoch).toISOString() }, groupBy, rows: out }, null, 2) + '\n');
    return;
  }

  if (filteredEvents.length === 0) {
    process.stdout.write(`No sessions logged in this window (${window.label}).\n`);
    return;
  }

  const useColor = process.stdout.isTTY && !v['no-color'];
  process.stdout.write(`Window: ${window.label} (${new Date(window.startEpoch).toISOString()} → ${new Date(window.endEpoch).toISOString()})\n`);
  process.stdout.write(`Legend: C:R = cache read, C:W = cache write (cache creation).\n`);
  process.stdout.write(renderTable(rows, groupBy, useColor) + '\n');
}

/**
 * Promise-wrapped readline question.
 * @param {import('node:readline').Interface} rl
 * @param {string} q
 * @returns {Promise<string>}
 */
function ask(rl, q) {
  return new Promise(resolve => rl.question(q, resolve));
}

/**
 * Interactive menu loop. Runs until the user picks Quit or Ctrl-C.
 * Menu items 3 and 4 shell out to `refresh-pricing.sh` (with `--reconcile`
 * for item 3). Item 2 is a session-4 placeholder.
 * @returns {Promise<void>}
 */
async function menuLoop() {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  process.on('SIGINT', () => { rl.close(); process.exit(130); });
  try {
    while (true) {
      process.stdout.write('\n=== Tokens recap ===\n');
      process.stdout.write('1. View stats\n');
      process.stdout.write('2. Manage projects (coming in session 4)\n');
      process.stdout.write('3. Manage models (refresh-pricing.sh --reconcile)\n');
      process.stdout.write('4. Refresh pricing (refresh-pricing.sh)\n');
      process.stdout.write('5. Quit\n');
      const choice = (await ask(rl, '> ')).trim().toLowerCase();
      if (choice === '5' || choice === 'q' || choice === 'quit' || choice === '') break;
      if (choice === '2') { await manageProjectsInteractive(rl); continue; }
      if (choice === '1') {
        await viewStatsInteractive(rl);
        continue;
      }
      if (choice === '3') {
        spawnSync('bash', [REFRESH_PRICING_SH, '--reconcile'], { stdio: 'inherit' });
        continue;
      }
      if (choice === '4') {
        spawnSync('bash', [REFRESH_PRICING_SH], { stdio: 'inherit' });
        continue;
      }
      process.stdout.write(`  unknown choice: ${choice}\n`);
    }
  } finally {
    rl.close();
  }
}

/**
 * Guided flow: prompt for period, grouping, and format, then delegate to
 * {@link runStats}. Prints the equivalent CLI so users learn the flags.
 * @param {import('node:readline').Interface} rl
 * @returns {Promise<void>}
 */
async function viewStatsInteractive(rl) {
  const period = (await ask(rl, 'Period? [r]eset (Sat 20h UTC) / [w]eek / [m]onth / [d] last N days / [h] last N hours / [D] from date / [a]ll (default: r): ')).trim().toLowerCase();
  const v = {};
  if (period === 'w') v.week = true;
  else if (period === 'm') v.month = true;
  else if (period === 'd') {
    const n = (await ask(rl, 'Days: ')).trim();
    v.last = `${parseInt(n, 10) || 7}d`;
  } else if (period === 'h') {
    const n = (await ask(rl, 'Hours: ')).trim();
    v.last = `${parseInt(n, 10) || 24}h`;
  } else if (period === 'D') {
    const from = (await ask(rl, 'From (YYYY-MM-DD): ')).trim();
    if (from) v.from = from;
  } else if (period === 'a') v.all = true;
  else v['since-reset'] = true;

  const group = (await ask(rl, 'Group by? [p]roject / [s]ession / [d]ay / [m]odel / [n]o grouping (default: auto): ')).trim().toLowerCase();
  if (group === 'p') v['by-project'] = true;
  else if (group === 's') v['by-session'] = true;
  else if (group === 'd') v['by-day'] = true;
  else if (group === 'm') v['by-model'] = true;

  const fmt = (await ask(rl, 'Format? [t]able / [j]son (default: t): ')).trim().toLowerCase();
  if (fmt === 'j') v.json = true;

  try {
    runStats(v);
  } catch (e) {
    process.stderr.write(`error: ${e.message}\n`);
  }

  const parts = [];
  for (const [k, val] of Object.entries(v)) {
    if (val === true) parts.push(`--${k}`);
    else if (Array.isArray(val)) for (const x of val) parts.push(`--${k}=${x}`);
    else parts.push(`--${k}=${val}`);
  }
  process.stdout.write(`\n« Equivalent CLI: node recap.js ${parts.join(' ')} »\n`);
}

/**
 * When running inside a container and docker-scan can't reach any volumes,
 * emit one stderr line suggesting the user install tokens on the host for
 * full cross-container aggregation. Non-blocking — recap continues.
 * @returns {void}
 */
function warnIfInContainer() {
  if (!fs.existsSync('/.dockerenv')) return;
  let volumes = '';
  try {
    volumes = execFileSync('bash', [DOCKER_SCAN_SH, 'list-volumes'], {
      encoding: 'utf8',
      timeout: 5_000,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
  } catch { /* docker absent */ }
  if (volumes.trim() === '') {
    process.stderr.write('⚠ running inside container — for full cross-container aggregation, install tokens on host (see tokens/install.sh)\n');
  }
}

/**
 * Print all projects (from local registry + docker volumes) as an aligned
 * table, sorted by last_seen desc. Backs `--list-projects` and menu item 2.1.
 * @param {Object} [opts]
 * @param {boolean} [opts.docker=true]
 * @returns {void}
 */
function printProjectsTable(opts = {}) {
  const rows = listProjects(opts);
  if (rows.length === 0) {
    process.stdout.write('No projects registered yet.\n');
    return;
  }
  const headers = ['Slug', 'Title', 'Host path', 'Last seen', 'Where'];
  const data = rows.map(r => [
    r.slug,
    r.subtitle ? `${r.title} — ${r.subtitle}` : (r.title || '—'),
    r.host_workspace_path || r.project_root || '—',
    r.last_seen || '—',
    [r.local ? 'local' : null, ...r.volumes].filter(Boolean).join(', ') || '—',
  ]);
  const widths = headers.map((h, i) => Math.max(h.length, ...data.map(r => r[i].length)));
  const pad = (cell, i) => cell.padEnd(widths[i]);
  process.stdout.write('| ' + headers.map((h, i) => pad(h, i)).join(' | ') + ' |\n');
  process.stdout.write('|' + widths.map(w => '-'.repeat(w + 2)).join('|') + '|\n');
  for (const row of data) process.stdout.write('| ' + row.map((c, i) => pad(c, i)).join(' | ') + ' |\n');
}

/**
 * Interactive sub-menu for menu item 2 (Manage projects).
 * @param {import('node:readline').Interface} rl
 * @returns {Promise<void>}
 */
async function manageProjectsInteractive(rl) {
  while (true) {
    process.stdout.write('\n=== Manage projects ===\n');
    process.stdout.write('1. List all\n');
    process.stdout.write('2. Rename\n');
    process.stdout.write('3. Forget\n');
    process.stdout.write('4. Back\n');
    const c = (await ask(rl, '> ')).trim().toLowerCase();
    if (c === '4' || c === 'b' || c === 'back' || c === '') return;
    if (c === '1') { printProjectsTable(); continue; }
    if (c === '2' || c === '3') {
      const rows = listProjects();
      if (rows.length === 0) { process.stdout.write('No projects registered yet.\n'); continue; }
      rows.forEach((r, i) => {
        process.stdout.write(`  ${i + 1}. [${r.slug}] ${r.title || '—'}${r.subtitle ? ' — ' + r.subtitle : ''}\n`);
      });
      const pick = (await ask(rl, 'Pick number (or slug, blank to cancel): ')).trim();
      if (!pick) continue;
      const idx = parseInt(pick, 10);
      const target = (idx >= 1 && idx <= rows.length) ? rows[idx - 1] : rows.find(r => r.slug === pick.toLowerCase());
      if (!target) { process.stdout.write(`  no match for "${pick}"\n`); continue; }
      if (c === '2') {
        const title = (await ask(rl, `New title (blank keeps "${target.title}"): `)).trim();
        const subtitle = (await ask(rl, `New subtitle (blank keeps "${target.subtitle || ''}"): `)).trim();
        const fields = {};
        if (title) fields.title = title;
        if (subtitle) fields.subtitle = subtitle;
        if (!fields.title && !fields.subtitle) { process.stdout.write('  no change.\n'); continue; }
        const res = renameProject(target.slug, fields);
        process.stdout.write(res.ok ? `  ✓ renamed to "${res.project.title}"\n` : `  ✗ ${res.error}\n`);
      } else {
        const confirm = (await ask(rl, `Forget "${target.title}" (${target.slug})? [y/N]: `)).trim().toLowerCase();
        if (confirm !== 'y' && confirm !== 'yes') { process.stdout.write('  cancelled.\n'); continue; }
        const res = forgetProject(target.slug);
        process.stdout.write(res.ok ? `  ✓ forgotten\n` : `  ✗ ${res.error}\n`);
      }
    }
  }
}

/**
 * Emit one stderr warning if `pricing.json` is missing, unreadable, or
 * older than 90 days. Called once at `main()` startup.
 * @returns {void}
 */
function warnPricingFile() {
  const info = pricingFileInfo();
  if (!info.exists) {
    process.stderr.write(`⚠ pricing.json missing at ${info.path} — run refresh-pricing.sh\n`);
    return;
  }
  if (info.fetched_at === null) {
    process.stderr.write(`⚠ pricing.json unreadable (no fetched_at) — run refresh-pricing.sh\n`);
    return;
  }
  if (info.ageDays !== null && info.ageDays > 90) {
    process.stderr.write(`⚠ pricing.json is ${info.ageDays.toFixed(0)} days old — run refresh-pricing.sh\n`);
  }
}

/**
 * Entry point. Parses flags, warns on stale pricing, then either opens the
 * interactive menu (no args + TTY) or runs `runStats` directly.
 * @returns {Promise<void>}
 */
async function main() {
  const argv = process.argv.slice(2);
  let parsed;
  try {
    parsed = parseFlags(argv);
  } catch (e) {
    process.stderr.write(`error: ${e.message}\n\n${HELP}\n`);
    process.exit(2);
  }
  const v = parsed.values;
  const positionals = parsed.positionals || [];
  if (v.help) {
    process.stdout.write(HELP + '\n');
    return;
  }

  warnPricingFile();
  warnIfInContainer();

  if (v['list-projects']) {
    printProjectsTable({ docker: !v['no-docker'] });
    return;
  }
  if (v.rename) {
    const slug = positionals[0];
    if (!slug) {
      process.stderr.write('error: --rename requires <slug> positional arg\n');
      process.exit(2);
    }
    const res = renameProject(slug, { title: v.title, subtitle: v.subtitle });
    if (!res.ok) {
      process.stderr.write(`error: ${res.error}\n`);
      process.exit(1);
    }
    process.stdout.write(`✓ renamed "${res.project.slug}" → "${res.project.title}"${res.project.subtitle ? ' — ' + res.project.subtitle : ''}\n`);
    return;
  }
  if (v.forget) {
    const slug = positionals[0];
    if (!slug) {
      process.stderr.write('error: --forget requires <slug> positional arg\n');
      process.exit(2);
    }
    const res = forgetProject(slug);
    if (!res.ok) {
      process.stderr.write(`error: ${res.error}\n`);
      process.exit(1);
    }
    process.stdout.write(`✓ forgot "${res.project.slug}" (${res.project.title || res.project.project_id})\n`);
    return;
  }

  if (argv.length === 0 && process.stdin.isTTY && !v['no-interactive']) {
    await menuLoop();
    return;
  }

  try {
    runStats(v);
  } catch (e) {
    process.stderr.write(`error: ${e.message}\n`);
    process.exit(1);
  }
}

main();
