#!/usr/bin/env node
// worktree-guard — Claude Code PreToolUse hook on Bash.
//
// Refuses a `git worktree add` whose target is not under
// `<main repo>/.claude/worktrees/` — the path Claude Code itself uses for
// `claude --worktree`, EnterWorktree and `isolation: "worktree"` agents. One
// location means one `.gitignore` entry, one watcher exclusion, and no
// worktree lost in a sibling folder nobody looks in.
//
// The deny reason carries the rule, so the session reads it at the moment it
// matters instead of relying on a prose rule being remembered.
//
// Parsing is deliberately shallow: the command is split on shell separators
// (`&&`, `||`, `;`, `|`, newline), each segment tokenised with quote
// awareness, and a leading `cd <dir>` segment moves the base directory. A
// target that cannot be resolved statically (`$VAR`, backticks, `$(…)`) is
// refused too: the rule is "always", and the remedy — spell the path — is
// one edit away.
//
// Fail open on everything else: no payload, not a Bash call, not a git
// repository. Exit is always 0; the decision travels in the JSON.
//
// Stdin contract (Claude Code PreToolUse hook):
//   {"session_id": "...", "cwd": "...", "hook_event_name": "PreToolUse",
//    "tool_name": "Bash", "tool_input": {"command": "..."}}

import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'

process.on('uncaughtException', () => process.exit(0))

const ROOT_SUFFIX = '/.claude/worktrees'
// `git worktree add` options that consume the next token.
const VALUED = { '-b': 1, '-B': 1, '--orphan': 1, '--reason': 1 }
// git global options before the subcommand that consume the next token.
const GLOBAL_VALUED = { '-C': 1, '-c': 1, '--git-dir': 1, '--work-tree': 1, '--namespace': 1 }

function readPayload() {
	try {
		return JSON.parse(fs.readFileSync(0, 'utf8'))
	} catch {
		return null
	}
}

/** Quote-aware split of one shell segment into words. */
function words(segment) {
	const out = []
	let current = ''
	let quote = ''
	let started = false
	for (const ch of segment) {
		if (quote) {
			if (ch === quote) quote = ''
			else current += ch
		} else if (ch === '"' || ch === "'") {
			quote = ch
			started = true
		} else if (ch === ' ' || ch === '\t') {
			if (started) out.push(current)
			current = ''
			started = false
		} else {
			current += ch
			started = true
		}
	}
	if (started) out.push(current)
	return out
}

/**
 * The target of a `git … worktree add …` word list and the `-C` directory it
 * runs in, or null when the words are not a worktree add.
 */
function worktreeAdd(argv) {
	const count = argv.length
	let i = 0
	while (i < count && /^[A-Za-z_][A-Za-z0-9_]*=/.test(argv[i])) i++
	if (argv[i] !== 'git') return null
	i++
	let chdir = ''
	while (i < count && argv[i].startsWith('-')) {
		const option = argv[i]
		if (GLOBAL_VALUED[option]) {
			if (option === '-C') chdir = path.join(chdir, argv[i + 1] || '')
			i += 2
		} else i++
	}
	if (argv[i] !== 'worktree' || argv[i + 1] !== 'add') return null
	for (let j = i + 2; j < count; j++) {
		const word = argv[j]
		if (word === '--') return { chdir, target: argv[j + 1] || '' }
		if (VALUED[word]) j++
		else if (!word.startsWith('-')) return { chdir, target: word }
	}
	return { chdir, target: '' }
}

/** Absolute root of the main worktree that `dir` belongs to, or '' if none. */
function mainRoot(dir) {
	try {
		const common = execFileSync('git', ['-C', dir, 'rev-parse', '--path-format=absolute', '--git-common-dir'], {
			encoding: 'utf8',
			stdio: ['ignore', 'pipe', 'ignore'],
		}).trim()
		return path.dirname(common)
	} catch {
		return ''
	}
}

function deny(reason) {
	process.stdout.write(
		JSON.stringify({
			hookSpecificOutput: {
				hookEventName: 'PreToolUse',
				permissionDecision: 'deny',
				permissionDecisionReason: reason,
			},
		}),
	)
	process.exit(0)
}

const payload = readPayload()
if (!payload || payload.tool_name !== 'Bash') process.exit(0)
const command = payload.tool_input?.command
if (typeof command !== 'string' || !command.includes('worktree')) process.exit(0)

let base = payload.cwd || process.cwd()
for (const segment of command.split(/&&|\|\||[;|\n]/)) {
	const argv = words(segment.trim())
	if (argv[0] === 'cd' && argv[1]) {
		base = path.resolve(base, argv[1])
		continue
	}
	const add = worktreeAdd(argv)
	if (!add) continue
	const { chdir, target } = add
	const where = chdir ? path.resolve(base, chdir) : base
	const root = mainRoot(where)
	if (!root) continue
	const allowed = root + ROOT_SUFFIX
	const rule =
		`Worktrees live under ${allowed}/<name> — Claude Code's own default ` +
		`(claude --worktree, EnterWorktree, isolation: "worktree"). Prefer the ` +
		`EnterWorktree tool; with plain git, run ` +
		`\`git worktree add ${allowed}/<name> …\`.`
	if (!target || /[$`]/.test(target)) {
		deny(`worktree-guard: cannot resolve the target of \`git worktree add\` statically. Spell the path literally. ${rule}`)
	}
	const resolved = path.resolve(where, target)
	if (!resolved.startsWith(allowed + '/')) {
		deny(`worktree-guard: refused \`git worktree add ${target}\` (resolves to ${resolved}). ${rule}`)
	}
}
process.exit(0)
