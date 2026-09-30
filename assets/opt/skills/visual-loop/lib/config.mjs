// Configuration for the baked visual-loop scripts.
//
// Environment variables, not a config file discovered by walking up from the
// cwd. Three reasons, all of them already settled elsewhere in this tree:
//
//   1. A walk-up config reintroduces the bug cdp.mjs documents having escaped —
//      its lock file was moved off a repo-relative path precisely because every
//      git worktree derived its own and excluded nothing. A config found by
//      walking up is that bug, one level higher.
//   2. The image already owns exactly one config format (devc-conf.sh's `.txt`
//      reader, shared by the firewall allowlists and the disabled.txt files),
//      written because every reader used to hand-roll its own rules. A JSON
//      format with a single reader would be a third convention.
//   3. Transport is already solved: compose's `env_file` puts .devcontainer/.env
//      into PID 1, so every docker exec, VS Code terminal and Bash tool call
//      inherits the same values under every worktree, with no discovery at all.
//
// The contract is figma.mjs's, generalised: flag > env > hard stop, and *no
// silent fallback*. A guessed origin surfaces as a wrong measurement several
// steps later, which is strictly worse than refusing to start.

/** Trimmed value, or undefined — an empty variable is an unset one. */
export const env = (name) => (process.env[name] ?? '').trim() || undefined

/**
 * A value, or a one-line refusal naming the key. Never a stack.
 *
 * @param {string | undefined} value   already-resolved value (a flag wins)
 * @param {string} envName             the key to name in the refusal
 * @param {string} how                 one line saying what the value is
 * @param {string} [flagName]          the flag that would also supply it
 * @returns {string}
 */
export function need(value, envName, how, flagName) {
	if (value) return value
	const viaFlag = flagName ? `pass --${flagName} <value>, or ` : ''
	process.stderr.write(
		`${envName} is unset.\n` +
			`  -> ${viaFlag}set ${envName} in .devcontainer/.env (gitignored, loaded via env_file),\n` +
			`     then restart the container so the variable reaches this shell.\n` +
			`  -> ${how}\n`,
	)
	process.exit(2)
}
