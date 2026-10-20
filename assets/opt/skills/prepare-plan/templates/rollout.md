# Template — `ROLLOUT.md` (multi-session)

> Part of `/prepare-plan` — read on demand by the branch that renders this
> file. Substitute every `{{placeholder}}` before writing ; the skill's
> placeholder check enforces zero leftovers.

````markdown
# Rollout — {{feature_title}}

> Entry point of this plan directory. For the actionable session table,
> see [STATUS.md](STATUS.md). For the reasoned journal of delivered
> sessions, see [LOG.md](LOG.md). For the technical inventory, see
> [EXISTING.md](EXISTING.md).

## Goal

{{description}}

## Navigation

| File | When to open |
|---|---|
| **[STATUS.md](STATUS.md)** | "Where are we, what's next ?" — actionable session table |
| **[LOG.md](LOG.md)** | "What must I know ?" — `Carry-forward` on top ; "what was done, why ?" — append-only journal below |
| **[EXISTING.md](EXISTING.md)** | "What does the code look like today ?" — factual inventory |
| sessions/session-<id>-*.md | Prompt to paste into a new Claude chat to start session `<id>` (`3`, `3.1` …) |

## How to use

1. **To resume work** : open [STATUS.md](STATUS.md), find the next 📋
   session, check its **Model** column and run `/model` accordingly,
   then click `→ prompt` and paste into a fresh Claude Code session.
2. **To check what was done before** : read [LOG.md](LOG.md).
3. **To understand current code state** : read [EXISTING.md](EXISTING.md).

## Model tiers

Each session's Model column in [STATUS.md](STATUS.md) uses these tiers.
To add a session (at the end, or between two existing ones), run
`/prepare-plan add {{feature_name}} [after <id>] <description>` — it
derives the tier from these rules :

| Tier | Role | Fallback ladder (left = primary) |
|---|---|---|
| **A** | Max reasoning | fable → opus-5.5 → opus-5 → opus-4.8 → opus-4.7 |
| **B** | Default | opus-5.5 → opus-5 → opus-4.8 → opus-4.7 → sonnet-5 |
| **C** | Specified execution | sonnet-5 → opus-4.7 |
| **D** | Mechanical / sub-agents | haiku-4.5 → sonnet-5 |

- `fable` = the newest Fable the Claude Code in use can select
  (`fable-5.1` from 2.1.258, `fable-5` before) ; write it resolved.
- Two models are gated on a Claude Code version : `fable-5.1` needs
  2.1.258 and `opus-5.5` needs 2.1.280. Below the gate the model is
  ABSENT from the ladder and its rank-tied sibling takes the slot —
  `opus-5` leads tier B instead. Resolve this against the running
  version before writing a ladder down.
- `opus-5.5`, `opus-5` and `opus-4.8` tie in rank — any of the three is
  a match for tier A/B, degraded mode starts at `opus-4.7`. A
  classifier-sensitive session is written `A*` / `B*` and drops fable
  and the opus-5.x pair, leaving `opus-4.8 → opus-4.7 → sonnet-5`.
- **Base** : architecture/ambiguous → A · specified code, doc prose,
  ops, review, hotfix → B · tests-only, mechanical migration, bulk,
  spike, deps → C · sub-agent grep fan-out → D.
- **+1 tier** if : ambiguous · hard to reverse · prior failure at tier ·
  pivot session · no test harness. **−1** if : mechanical DoD + bounded
  diff + established pattern.
- Full rationale : `/opt/devcontainer/base/skills/prepare-plan/MODELS.md`
  (the image ships it ; a v3 tree carries no `.devcontainer/skills/` copy).

## Update convention (end of every delivered session)

Every session prompt prescribes these three updates in its DoD :

1. **STATUS.md** : flip the session row 📋 → ✅, replace the prompt link
   with `—`, bump the "Delivered" counter, refresh "Next focus".
2. **LOG.md** : append `## <Session ID> — <Title>` section dated today,
   listing files touched + What / Why / Decisions / Gotchas / Tests /
   Commit (~50–150 lines). Then curate `## Carry-forward` at the top of
   LOG.md — the only part the next session reads by default.
3. **EXISTING.md** : update the `path — role` map if files / structures
   were added or removed (no code excerpts, ~60 lines max).

## Decisions (immutable unless user explicitly amends)

_(Add decisions here as they are made. Each decision should explain the
trade-off and why this side was picked, so future sessions don't relitigate
settled questions.)_

- _(none yet — first session may seed this list)_
````
