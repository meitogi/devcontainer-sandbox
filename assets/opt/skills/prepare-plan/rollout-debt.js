#!/usr/bin/env node
// rollout-debt.js — Claude Code SessionStart hook.
//
// Detects rollout plans that still have open rows (🚧 / 📋 / ⚠️) in their
// STATUS.md table while nothing in the plan directory has been touched for
// more than N days, and injects a SessionStart additionalContext telling
// Claude to propose closing them out, deferring, or cancelling.
//
// Closes the measured gap "claude-notif-readonly frozen at Delivered 1/3
// since June" — no advisory rule fires on a file nobody opens.
//
// Contract (CLAUDE.md §11) : PROPOSE, never act. The hook injects context ;
// it never edits a STATUS.md and never starts the work.
//
// Staleness is the max mtime over the plan dir's immediate *.md files, not
// STATUS.md alone : editing LOG.md without STATUS.md would otherwise make an
// actively-worked plan look abandoned, and one wrong fire spends the
// signal's whole trust budget. `plans/*` is gitignored, so mtimes are
// genuine (never reset by a checkout) and `git log` is unavailable.
//
// Rows are read as markdown table cells, never by grepping the emoji : every
// STATUS.md carries a legend line ("✅ delivered · 🚧 in progress · 📋
// planned · …") that a naive grep matches in every plan, including the ones
// that are fully closed.
//
// No throttling state : the mtime IS the throttle. Acting on the signal
// touches STATUS.md and buys N days of silence ; ignoring it keeps the
// signal firing, which is the definition of debt.
//
// Self-contained per the v1.3.0 hook pattern (each hook lives in its skill
// dir, no shared library) — every hook script here is self-contained.
//
// ⚠️ sync-skills.sh is APPEND-ONLY : it merges hooks.json into
// ~/.claude/settings.json, dedups by exact command string, and never
// removes. Renaming this file leaves a dead `node …/rollout-debt.js` in
// settings.json that exits 1 on every session start — prune the stale entry
// by hand if you ever rename it.
//
// Exit code is always 0 — a non-zero exit on a SessionStart hook would block
// session start, unacceptable for a soft nudge.
//
// Stdin contract (Claude Code SessionStart hook):
//   {"session_id": "...", "transcript_path": "...", "cwd": "...",
//    "hook_event_name": "SessionStart", "source": "startup|resume|clear"}
// Stdin is not consumed — the check is purely filesystem-based.
//
// Env overrides (fixtures / tests only):
//   ROLLOUT_DEBT_ROOT  plans directory        (default /workspace/plans)
//   ROLLOUT_DEBT_DAYS  staleness threshold    (default 7)

// ESM : the repo root package.json is `"type": "module"`, so a bare .js here
// is a module. No per-dir package.json marker needed (notify-queue predates
// that and ships `{"type":"commonjs"}` instead).

import fs from 'node:fs'
import path from 'node:path'

process.on('uncaughtException', () => process.exit(0))

const DAY_MS = 86400000
const BRIEF_MAX = 80
// ⚠️ is U+26A0 U+FE0F — the bare U+26A0 is the needle, since "⚠️ x" starts
// with "⚠" but "⚠ x" does not start with "⚠️".
const OPEN_MARKS = ['\u{1F6A7}', '\u{1F4CB}', '⚠']

/** Numeric env override. `0` is a legitimate value, so never coalesce on falsy. */
function numEnv(value, fallback) {
	if (value === undefined || value === '') return fallback
	const parsed = Number(value)
	return Number.isFinite(parsed) ? parsed : fallback
}

const env = process.env
const root = env.ROLLOUT_DEBT_ROOT || '/workspace/plans'
const thresholdDays = numEnv(env.ROLLOUT_DEBT_DAYS, 7)

/** True if a table cell is a status cell holding an open marker. */
function isOpenCell(cell) {
	const text = cell.trim().replace(/^\*+/, '')
	const marks = OPEN_MARKS
	for (let i = 0; i < marks.length; i++) {
		if (text.startsWith(marks[i])) return true
	}
	return false
}

/** Split a markdown table row into its cells, tolerating a missing edge pipe. */
function rowCells(line) {
	const cells = line.split('|')
	if (cells[0].trim() === '') cells.shift()
	if (cells.length && cells[cells.length - 1].trim() === '') cells.pop()
	return cells
}

/**
 * Open rows of a STATUS.md table. A line qualifies only if it is a table row
 * (leading `|`) with a cell starting on an open marker — which excludes the
 * legend line, and the header / separator rows carry no such cell.
 */
function openRows(markdown) {
	const rows = []
	const lines = markdown.split('\n')
	const len = lines.length
	for (let i = 0; i < len; i++) {
		const line = lines[i].trim()
		if (!line.startsWith('|')) continue
		const cells = rowCells(line)
		const cellCount = cells.length
		let open = false
		for (let c = 0; c < cellCount; c++) {
			if (isOpenCell(cells[c])) {
				open = true
				break
			}
		}
		if (open) rows.push(cells)
	}
	return rows
}

/** The longest non-status cell of a row — the brief, whatever the column count. */
function briefOf(cells) {
	const count = cells.length
	let best = ''
	for (let i = 0; i < count; i++) {
		const cell = cells[i].trim()
		if (isOpenCell(cell)) continue
		if (cell.length > best.length) best = cell
	}
	if (best.length > BRIEF_MAX) return `${best.slice(0, BRIEF_MAX - 1).trimEnd()}…`
	return best
}

/** Newest mtime among the plan dir's immediate *.md files, 0 if none readable. */
function newestMarkdownMtime(dir) {
	let newest = 0
	let names
	try {
		names = fs.readdirSync(dir)
	} catch {
		return 0
	}
	const count = names.length
	for (let i = 0; i < count; i++) {
		const name = names[i]
		if (!name.endsWith('.md')) continue
		try {
			const mtime = fs.statSync(path.join(dir, name)).mtimeMs
			if (mtime > newest) newest = mtime
		} catch {
			// unreadable / broken symlink — ignore
		}
	}
	return newest
}

function collectStalePlans() {
	let entries
	try {
		entries = fs.readdirSync(root, { withFileTypes: true })
	} catch {
		return []
	}

	const now = Date.now()
	const stale = []
	const count = entries.length

	for (let i = 0; i < count; i++) {
		const entry = entries[i]
		if (!entry.isDirectory() && !entry.isSymbolicLink()) continue

		const dir = path.join(root, entry.name)
		let markdown
		try {
			if (!fs.statSync(dir).isDirectory()) continue
			markdown = fs.readFileSync(path.join(dir, 'STATUS.md'), 'utf8')
		} catch {
			continue
		}

		const rows = openRows(markdown)
		if (!rows.length) continue

		const newest = newestMarkdownMtime(dir)
		if (!newest) continue
		const ageDays = Math.floor((now - newest) / DAY_MS)
		if (ageDays <= thresholdDays) continue

		stale.push({ name: entry.name, ageDays, openCount: rows.length, brief: briefOf(rows[0]) })
	}

	stale.sort((a, b) => b.ageDays - a.ageDays)
	return stale
}

function buildMessage(stale) {
	const count = stale.length
	const parts = []
	for (let i = 0; i < count; i++) {
		const plan = stale[i]
		const rowLabel = plan.openCount === 1 ? '1 open row' : `${plan.openCount} open rows`
		const brief = plan.brief ? `, next up "${plan.brief}"` : ''
		parts.push(`plans/${plan.name} (${plan.ageDays} days, ${rowLabel}${brief})`)
	}

	const subject =
		count === 1
			? '1 plan has open rollout rows and has not been touched'
			: `${count} plans have open rollout rows and have not been touched`
	const target = count === 1 ? 'it be closed out' : 'each one be closed out'

	return (
		`rollout-debt signal: ${subject} in over ${thresholdDays} days — ` +
		`${parts.join(', ')}. At a natural pause in this session, propose to ` +
		`the user that ${target}, deferred, or cancelled, and that its ` +
		`STATUS.md be updated to record the decision. Do not edit any ` +
		`STATUS.md autonomously and do not start the work. If the user ` +
		`declines or postpones, drop the topic and don't re-raise it the same ` +
		`session.`
	)
}

const stalePlans = collectStalePlans()
if (stalePlans.length) {
	process.stdout.write(
		JSON.stringify({
			hookSpecificOutput: {
				hookEventName: 'SessionStart',
				additionalContext: buildMessage(stalePlans),
			},
		}),
	)
}
process.exit(0)
