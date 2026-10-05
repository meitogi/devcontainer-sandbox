# Tokens — consumption recap

Claude front-end for the standalone CLI
[`recap.js`](.devcontainer/skills/tokens/recap.js) — walks the JSONL
logs under `<project-root>/.claude/tokens/logs/YYYY-MM/*.jsonl`,
filters by time window, aggregates by project / session / day /
model, prints an SI-compact table.

## Arguments

$ARGUMENTS

## Execution

Run `node /workspace/.devcontainer/skills/tokens/recap.js
$ARGUMENTS` (via the Bash tool) and show the raw output — it is
already formatted as a Markdown table, do not reformat it.

If no argument is given **and stdin is a TTY**, the CLI opens an
interactive menu. From Claude, always prefer passing explicit flags
(e.g. `--since-reset`, `--by-day`, `--json`) — the interactive menu
is meant for direct human use in a terminal.

## Main flags

- Window (mutually exclusive, default `--since-reset`) :
  `--since-reset` (Saturday 20h UTC, the Anthropic weekly limit),
  `--week` (Monday 00h UTC), `--month`, `--last=7d|24h|3h`,
  `--from=YYYY-MM-DD [--to=…]`, `--all`.
- Grouping (default auto — `by-session` when there is a single
  project, `by-project` otherwise) : `--by-project`, `--by-session`,
  `--by-day`, `--by-model`.
- Filters : `--project=<title>` (repeatable), `--json` (machine
  output), `--no-color`, `--no-interactive`.
- `--help` : full help.

## Examples

- `/user:tokens --since-reset` → sessions since Saturday 20h UTC.
- `/user:tokens --last=24h --by-day` → last 24 hours, one line per
  day.
- `/user:tokens --all --json` → the whole history as JSON for
  post-processing.
