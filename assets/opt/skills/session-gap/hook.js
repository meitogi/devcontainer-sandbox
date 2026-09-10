#!/usr/bin/env node
// session-gap.js — Claude Code UserPromptSubmit hook.
//
// Compares the incoming prompt's arrival to the last real event in the
// session transcript. Past a threshold (default 1 h) it injects context
// noting the gap : a resumed session pays for a cold prompt cache and
// re-reads its own history, so continuing typically costs about twice what
// restating the task in a fresh session would.
//
// Closes the measured gap "7 intra-session gaps > 1 h and 5 cold resumes"
// across the 50-session corpus. The rule already existed in prose and was
// simply forgotten ; two timestamps make it deterministic.
//
// Contract (CLAUDE.md §11) : PROPOSE, never act. The hook never ends or
// clears a session.
//
// ── Burst exclusion ────────────────────────────────────────────────────
// MEASURED: on UserPromptSubmit the incoming prompt's `user` line is already
// in the transcript ~35 ms BEFORE this hook runs (transcript 09:49:38.613Z,
// hook 09:49:38.648Z), alongside its attachment / queue-operation lines. So
// `now - max(timestamp)` always reads ~0 and would never fire.
//
// The fix is cluster-descent rather than an epsilon around `now` : sort the
// timestamps descending and walk down until the first delta larger than
// BURST — that delta IS the gap, and it depends on neither clock agreement
// nor the 35 ms race holding. The first branch recovers the case where this
// hook wins the race and the prompt's own line is not written yet.
//
// The threshold (1 h) is three orders of magnitude above any plausible
// burst, so BURST anywhere in 1 s – 5 min gives identical firing behaviour.
//
// ── Why a tail read and no JSON.parse ──────────────────────────────────
// Transcripts reach 10+ MB. A full read + parse measured 117 ms — paid on
// EVERY prompt, on top of node startup and of notify-queue's own
// UserPromptSubmit hook. A 1 MB tail is ~10 ms. 1 MB rather than
// notify-queue's 256 KB because the bytes immediately before the burst are
// the previous turn's tool results, where single lines reach hundreds of KB.
//
// Scanning for the timestamp field with a regex instead of parsing deletes
// the whole malformed-JSONL failure class : the truncated leading line the
// byte-offset read produces, a half-flushed trailing line, and any non-JSON
// garbage are simply non-matches. The escaped `\"timestamp\":` form nested
// inside a tool result does not match — the backslash breaks contiguity.
//
// ── stdout discipline ──────────────────────────────────────────────────
// On UserPromptSubmit, non-JSON stdout is injected as raw context appended
// to the user's prompt. The ONLY write to stdout in this file is the final
// JSON ; anything diagnostic goes to stderr. Exit is always 0 — exit 2 on
// this event BLOCKS the prompt.
//
// Self-throttling : once fired, the gap collapses to seconds, so the signal
// appears exactly once per gap. No suppression state.
//
// ⚠️ sync-skills.sh is APPEND-ONLY : it merges hooks.json into
// ~/.claude/settings.json, dedups by exact command string, and never
// removes. Renaming this file leaves a dead command in settings.json —
// prune it by hand if you ever rename it.
//
// Stdin contract (Claude Code UserPromptSubmit hook):
//   {"session_id": "...", "transcript_path": "...", "cwd": "...",
//    "hook_event_name": "UserPromptSubmit", "prompt": "..."}
//
// Env overrides (fixtures / tests only):
//   SESSION_GAP_HOURS   gap threshold in hours         (default 1)
//   SESSION_GAP_MIN_KB  minimum transcript size in KB  (default 250)

import fs from 'node:fs'
import path from 'node:path'

process.on('uncaughtException', () => process.exit(0))

const TAIL_BYTES = 1048576 // 1 MB
const BURST_MS = 120000
const HOUR_MS = 3600000
const YEAR_MS = 31536000000

/** Numeric env override. `0` is a legitimate value, so never coalesce on falsy. */
function numEnv(value, fallback) {
	if (value === undefined || value === '') return fallback
	const parsed = Number(value)
	return Number.isFinite(parsed) ? parsed : fallback
}

const env = process.env
const thresholdMs = numEnv(env.SESSION_GAP_HOURS, 1) * HOUR_MS
const minBytes = numEnv(env.SESSION_GAP_MIN_KB, 250) * 1024

/** Read the hook payload from stdin. A closed / non-blocking fd is not an error. */
function readPayload() {
	try {
		return JSON.parse(fs.readFileSync(0, 'utf8'))
	} catch {
		return null
	}
}

/** Absolute transcript path, resolved against the payload cwd when relative. */
function resolveTranscript(payload) {
	const given = payload.transcript_path
	if (!given) return ''
	if (path.isAbsolute(given)) return given
	return path.resolve(payload.cwd || process.cwd(), given)
}

/** Trailing slice of a file, at most TAIL_BYTES. */
function readTail(file, size) {
	const length = Math.min(size, TAIL_BYTES)
	const buffer = Buffer.allocUnsafe(length)
	const fd = fs.openSync(file, 'r')
	try {
		const read = fs.readSync(fd, buffer, 0, length, size - length)
		return buffer.toString('utf8', 0, read)
	} finally {
		fs.closeSync(fd)
	}
}

/** Every plausible event timestamp in a transcript slice, milliseconds. */
function timestamps(text, now) {
	const found = []
	const floor = now - YEAR_MS
	const ceiling = now + 60000
	for (const match of text.matchAll(/"timestamp"\s*:\s*"([^"]+)"/g)) {
		const value = Date.parse(match[1])
		if (Number.isFinite(value) && value >= floor && value <= ceiling) found.push(value)
	}
	return found
}

/**
 * The gap in ms between the current submission burst and the event before it,
 * or 0 when there is no earlier event to compare against.
 */
function gapBefore(sorted, now) {
	const count = sorted.length
	if (!count) return 0
	// This hook won the race — the prompt's own line isn't written yet.
	if (now - sorted[0] > BURST_MS) return now - sorted[0]
	for (let i = 1; i < count; i++) {
		const delta = sorted[i - 1] - sorted[i]
		if (delta > BURST_MS) return delta
	}
	return 0
}

/** "4h12m", "2h", "97m" — the shape the message quotes back to the user. */
function humanize(ms) {
	const minutes = Math.round(ms / 60000)
	const hours = Math.floor(minutes / 60)
	const rest = minutes % 60
	if (!hours) return `${minutes}m`
	if (!rest) return `${hours}h`
	return `${hours}h${String(rest).padStart(2, '0')}m`
}

function buildMessage(gapMs) {
	return (
		`session-gap signal: the last activity in this session was ` +
		`${humanize(gapMs)} ago. A resumed session pays for a cold prompt ` +
		`cache and re-reads its own history, so continuing here typically ` +
		`costs about twice what restating the task in a fresh session would. ` +
		`Answer the user's prompt first. If the remaining work turns out to ` +
		`be self-contained, then — and only then — propose moving it to a ` +
		`fresh session and offer to write the handoff prompt. Do not end or ` +
		`clear the session yourself. If the user prefers to continue here, ` +
		`drop the topic and don't re-raise it.`
	)
}

const payload = readPayload()
if (!payload) process.exit(0)

const transcript = resolveTranscript(payload)
if (!transcript) process.exit(0)

let stat
try {
	stat = fs.statSync(transcript)
} catch {
	process.exit(0)
}

// Nothing worth abandoning in a short session — a few exchanges paused over
// lunch carry no context that a fresh prompt wouldn't restate for free.
if (stat.size < minBytes) process.exit(0)

const now = Date.now()
const sorted = timestamps(readTail(transcript, stat.size), now).sort((a, b) => b - a)
const gapMs = gapBefore(sorted, now)

if (gapMs > thresholdMs) {
	process.stdout.write(
		JSON.stringify({
			hookSpecificOutput: {
				hookEventName: 'UserPromptSubmit',
				additionalContext: buildMessage(gapMs),
			},
		}),
	)
}
process.exit(0)
