# Template — `sessions/session-{{session_id}}-{{session_slug}}.md` (multi-session)

> Part of `/prepare-plan` — read on demand by the branch that renders this
> file. Substitute every `{{placeholder}}` before writing ; the skill's
> placeholder check enforces zero leftovers.

The session file IS the prompt — no wrapper, no fence. The user copies
its full content into a fresh chat. One template for every session :
session 1 of a new scaffold (§4), a session added by §7, and the
successor a session scaffolds at its DoD.

| Placeholder | Value |
|---|---|
| `{{session_id}}` | `1`, `4`, `3.1` … |
| `{{session_slug}}` | kebab slug of this session |
| `{{prev_session}}` | `<id> (<slug>)` of the row just above in STATUS, or `none — first session` |
| `{{session_goal}}` | this session's concrete deliverable and its explicit non-goals — not the rollout goal, ROLLOUT.md holds that |

**Do not restate ROLLOUT.md.** The rollout goal, the navigation and the
Decisions live there and the prompt points at them ; a copy here goes
stale the first time a decision is amended. The prompt carries only what
is specific to this session.

````markdown
# Session {{session_id}} — {{session_slug}}

I'm starting session {{session_id}} of the `{{feature_name}}` rollout.
Previous session : {{prev_session}}.

Entry point : `/workspace/plans/{{feature_name}}/ROLLOUT.md` (goal +
Decisions — settled, do not relitigate).
Read also :
- `STATUS.md` (where we are)
- `LOG.md` — **only** the `## Carry-forward` section and the latest
  session entry. The rest is history : open an older section only when
  a question needs it.
- `EXISTING.md` (file map — the code itself is the detail)

{{model_line}}

## Goal of this session

{{session_goal}}

Keep scope tight ; if you discover follow-up work, add a row to
STATUS.md (`/prepare-plan add {{feature_name}} …`) instead of folding it
in. If we exceed ~15 exchanges on the same unresolved problem : stop,
write the current state (hypotheses tested, dead ends, next lead) to
LOG.md or a notes file, and propose splitting into a fresh session.

{{subagents_block}}

DoD at the end of this session :
1. STATUS.md : flip session {{session_id}} row 📋 → ✅, prompt link → —,
   bump the Delivered counter, refresh "Next focus" (next open row, or
   `rollout complete`).
2. LOG.md : append `## {{session_id}} — {{session_slug}}` dated today
   with files touched + What / Why / Decisions / Gotchas / Tests /
   Commit. Then **curate `## Carry-forward`** : add what a later session
   must know, delete what no longer applies (≤ ~30 lines).
3. EXISTING.md : update the file map if files / structures were added
   or removed — `path — role`, one line each, no code excerpts, ~60
   lines max.
4. If a next session is planned and has no prompt yet : scaffold it from
   `/opt/devcontainer/base/skills/prepare-plan/templates/session.md` and
   link it from its STATUS row. Per the sub-agents rule above, the draft
   is written by an **Opus** agent whatever this session's tier — review
   it against the filesystem before linking, since a scaffolded prompt's
   claims read as authoritative to the session that runs it.
5. If any part of this session's verification is deferred to the host
   (smoke test, visual check, platform behavior) : follow
   `/opt/devcontainer/base/skills/prepare-plan/templates/test-plan.md` —
   **triage it through E2E first**, write the suite under
   `plans/{{feature_name}}/suites/` and run it, then write
   `TEST-PLAN-{{session_id}}.md` NOW, while the context is live. Deferring
   the write defeats its purpose.
6. Propose a commit (do NOT commit without explicit user confirmation).
````
