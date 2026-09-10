# tokens — per-project token & cost capture

Stop-hook skill that parses each Claude Code session transcript and appends
one JSONL event per Stop under
`<project-root>/.claude/tokens/logs/YYYY-MM/<session_id>.jsonl`. Delta is
computed against the last cumulative total in the same file; costs use a
hardcoded fallback pricing table (Opus/Sonnet/Haiku).

Also maintains `<project-root>/.claude/tokens/config.json` (title / subtitle
/ host path) and appends new projects to `~/.claude/tokens/projects.jsonl`.

Full roadmap: [/workspace/plans/tokens/ROLLOUT.md](/workspace/plans/tokens/ROLLOUT.md).
