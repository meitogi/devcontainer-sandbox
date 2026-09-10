#!/usr/bin/env node
// model-availability.js — Claude Code SessionStart hook.
//
// Caches the running Claude Code version into the session context so the
// prepare-plan availability gate (MODELS.md § Availability gate) never has
// to run a command mid-skill. The `/model` picker is baked into the build :
// a model the build cannot select must not be recommended, and the version
// is the only signal that tells the two builds apart.
//
// Fires on every SessionStart source (startup / resume / clear / compact) —
// one short line, and a cleared or compacted context has lost the earlier
// copy. Emits nothing when no version can be read : the gate then assumes
// the oldest supported build (no model carrying a Min Claude Code value).
//
// Same conventions as rollout-debt.js : self-contained, exit 0 always (a
// non-zero SessionStart hook blocks session start), stdin not consumed.
// sync-skills.sh is append-only and dedups by exact command string — keep
// the file name stable, or prune the stale settings.json entry by hand.

import { spawnSync } from 'node:child_process'

process.on('uncaughtException', () => process.exit(0))

const SEMVER = /\d+\.\d+\.\d+/

function readVersion() {
	const fromEnv = SEMVER.exec(process.env.CLAUDE_CODE_VERSION || '')
	if (fromEnv) return fromEnv[0]
	const run = spawnSync('claude', ['--version'], { encoding: 'utf8', timeout: 3000 })
	const fromCli = SEMVER.exec(run.stdout || '')
	return fromCli ? fromCli[0] : null
}

const version = readVersion()
if (version) {
	process.stdout.write(
		JSON.stringify({
			hookSpecificOutput: {
				hookEventName: 'SessionStart',
				additionalContext:
					`prepare-plan availability gate: Claude Code ${version}. ` +
					`Use this value for MODELS.md § Availability gate — do not run a ` +
					`version command to re-read it.`,
			},
		}),
	)
}
process.exit(0)
