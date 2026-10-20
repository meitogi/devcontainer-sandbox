# Template — `STATUS.md` (multi-session)

> Part of `/prepare-plan` — read on demand by the branch that renders this
> file. Substitute every `{{placeholder}}` before writing ; the skill's
> placeholder check enforces zero leftovers.

````markdown
# Status — Actionable sessions

> Click `→ prompt` to open the `sessions/session-NN.md` file to paste into
> a fresh Claude Code session.
> For the detailed history (reasons, files touched, gotchas), see
> [LOG.md](LOG.md). For current code state, see [EXISTING.md](EXISTING.md).

| Session | Brief | Model | Status | Prompt |
|---|---|---|---|---|
| 1 | {{first_session_slug}} — first concrete step | {{model_tier_cell}} | 📋 | [→ prompt](sessions/session-1-{{first_session_slug}}.md) |

## Legend

✅ delivered · 🚧 in progress · 📋 planned · ⚠️ blocked · ❌ cancelled

{{tier_legend}}

## Progress

- **Delivered** : 0 / 1
- **Next focus** : session 1 ({{first_session_slug}})
````
