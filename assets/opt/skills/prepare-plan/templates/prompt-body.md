# Template — `prompt-body` (shared by §0.5 chat display and §0.6 file write)

> Part of `/prepare-plan` — read on demand by the branch that renders this
> file. Substitute every `{{placeholder}}` before writing ; the skill's
> placeholder check enforces zero leftovers.

Same body used in both modes ; only delivery differs (chat 5-backtick
fence in §0.5, `prompt.md` file in §0.6). In §0.5, omit the blockquote
header ; in §0.6, keep it.

````markdown
# {{feature_title}}

> **How to use this file**: open it, copy its full content, paste into
> a fresh Claude Code session. This prompt is self-contained — the fresh
> session needs no prior context. (Include this blockquote ONLY in §0.6
> file-write mode; omit it in §0.5 chat display.)

{{model_line}}

## Goal

{{description}}

## Approach

{{plan_approach}}

{{subagents_block}}

## DoD

1. Implement the change described above.
2. Verify : {{tests}}
3. If any part of this session's verification is deferred to the host
   (smoke test, visual check, platform behavior) : **triage it through
   E2E first** — machine-assertable scenarios become a suite under
   `plans/{{feature_name}}/suites/`, run by `wtf claude-live e2e` ; only
   what needs human judgement stays manual, each item saying why the
   harness cannot. Then write `plans/{{feature_name}}/TEST-PLAN.md` NOW,
   while the context is live — its last section is the resume prompt for
   the verification session. Deferring the write defeats its purpose.
4. Propose a commit (do NOT commit without explicit user confirmation).
5. **§0.6 only** — update `plans/{{feature_name}}/STATUS.md` : flip the
   `implementation` row 📋 → ✅, then after commit flip `commit` row
   📋 → ✅.
````
