# Template — `STATUS-lite` (§0.6 only, `plans/<feature_name>/STATUS.md`)

> Part of `/prepare-plan` — read on demand by the branch that renders this
> file. Substitute every `{{placeholder}}` before writing ; the skill's
> placeholder check enforces zero leftovers.

Distinct from the multi-session `STATUS.md` (session table with prompt
links). This 3-row version tracks a single-PR-worth of deferred work.

````markdown
# Status — {{feature_title}}

> **Scope** : {{description}}
>
> **Scaffolded on** : {{date}}
>
> **Prompt** : [prompt.md](prompt.md) — paste into a fresh Claude Code
> session to implement.
>
> **Model** : {{model_line_short}}

| Step | Status |
|---|---|
| `prompt.md` written | ✅ |
| implementation | 📋 |
| commit | 📋 |

## Legend

✅ done · 📋 pending · ⚠️ blocked · ❌ cancelled

{{tier_legend}}

## Notes

_(Add follow-ups, gotchas, or deferred concerns here as you go.)_
````
