---
description: Route code work following a plan to one of 4 execution contexts by increasing persistence — (1) This session, 0 files (default) ; (2) Fresh chat prompt only, 0 files ; (3) Prompt written to .md with status, 2 files ; (4) Multi-session scaffold, 5 files. Prints a mandatory pre-question context message (complexity + sessions envisaged verbatim + escalation reason) then calls AskUserQuestion once. When the recommendation is a no-persistence mode (#1 or #2), option #3 sits in position #2 as the upgrade path. Every generated prompt carries a per-session model tier recommendation (A/B/C/D) with a fallback ladder. AUTO-TRIGGER at Phase 4 of Plan mode. Also auto-triggers on natural phrases like "fais-moi un plan", "scaffold a plan", "j'ai pas le temps". A 5th entry point, `add`, inserts a session into an existing multi-session plan (intermediate id `3.1`, or appended `N+1`) — triggers "/prepare-plan add", "ajoute une session (intermédiaire) à <plan>", "insère une session avant la 4".
argument-hint: "<feature-name> [<free-text scope description>] | add <feature-name> [after <id>] <description>"
---

# /prepare-plan — route implementation work

Routes code work following a plan to one of 4 execution contexts, from
0-file ephemeral (implement now in current chat) to 5-file multi-session
scaffold under `/workspace/plans/<feature>/`. Every invocation prints a
mandatory pre-question context message then calls `AskUserQuestion` once.

## When to use

**Auto-invoked at Phase 4 of Plan mode** (after exploration, just before
writing the final plan file) to route the implementation context.

Outside Plan mode, invoke on triggers : "scaffold a plan", "prep a rollout
for", "route this to a plan", "make a plan for me", "I'll do it later",
"no time to handle this now", "come back to this later".

## When NOT to use

- Research / exploration without a deliverable plan → not this skill ; say so and stop.
- Extend an existing multi-session plan → not §0 : go to §7 (Add a
  session). A §0.6 plan (`prompt.md` + 3-row STATUS) has no session table
  — §7 refuses it.

## Process

**Entry point** — an invocation whose first token is `add`, or that asks
to add / insert a session into a plan that already exists under
`/workspace/plans/`, skips §0-§6 and goes to §7. Everything else starts
at §0.

### 0. Context-routing decision — mandatory AskUserQuestion

**Four options**, ordered by growing persistence :

| # | Mode | Files | When |
|---|---|---|---|
| 1 | **This session** | 0 | **Default recommended**. Implement now, ephemeral. Fits in the active chat with headroom. |
| 2 | **Fresh chat, prompt only** | 0 | Isolation wanted, no persistence. Prompt rendered in chat 5-backtick fence, user copies to a fresh session. |
| 3 | **Prompt written to .md (with status)** | 2 | Persistence + audit for a single-PR scope. Writes `prompt.md` + `STATUS.md` (3-row tracker). Also the natural fallback for "I'll do it later". |
| 4 | **Multi-session scaffold** | 5 | ≥2 sessions, irreversible phases, cross-cutting refactor. Full `ROLLOUT/STATUS/LOG/EXISTING` + `sessions/session-1-*`. |

Recommendation defaults to **#1**. Escalate only on clear signal :

| Signal | Recommend |
|---|---|
| Persistent artifact wanted, single-PR scope | 3 |
| "I'll do it later" / deferred tracking needed | 3 |
| Isolation wanted, no persistence needed | 2 |
| ≥2 sessions / irreversible phases / audit needed | 4 |
| _(anything else)_ | **1** |

**Options-ordering rule** — when the recommended option is a
no-persistence mode (**#1 or #2**), option **#3** (`Prompt written to
.md`) MUST appear in position **#2** so the persistence upgrade path is
the first alternative visible. Example : if #1 is recommended, order =
[1 (Recommended), 3, 2, 4]. Exactly one option carries `(Recommended)` —
never zero, never two.

**Current-model gate** — before recommending, derive the work's tier
(§Model tiers ; tier of session 1, or of the whole work if
single-session) and compare it to the model this session runs on (named
in your system prompt). Three states :

| State | Definition | Effect on the recommendation |
|---|---|---|
| **match / overkill** | current model ≥ tier primary, by **rank** (`opus-5.5` / `opus-5` / `opus-4.8` tie, so do `fable-5.1` / `fable-5`) — but on a `*` tier, `fable` and the Opus 5.x pair never match, the gate excludes them by behaviour, not by rank | #1 « This session » stays recommendable (default). If overkill by ≥2 ranks (e.g. fable for tier C/D), note the wasted cost — still allowed. |
| **in-ladder** | current model in the tier's fallback ladder, not primary | #1 allowed **with** degraded-mode directives applied to the current session. Say so in the context message. |
| **below-ladder** | current model below the whole ladder (e.g. haiku for tier B) | #1 MUST NOT be recommended — recommend #2 or #3 (the generated prompt carries the Model line). #1 stays listed, its description names the mismatch. |

#### Pre-question context message — REQUIRED before `AskUserQuestion`

Skipping this = user picks blind. Print as raw markdown (not inside a
code fence, ~20-40 lines), with these 5 blocks in order :

1. **Complexity and scope** — bullet list :
   - Files to touch (existing + new), with paths
   - Rough total LoC and time estimate (hours, or minutes if trivial)
   - Nature : additive / refactor / migration / cross-cutting
   - Irreversible phases (schema migrations, data transforms, network
     mutations) : yes / no
2. **Sessions envisioned** — parseable list (**commitment** ; multi-session
   uses these verbatim, no 2nd validation). Each session carries its model
   tier, derived per §Model tiers (base + modifiers) :
   ```
   Sessions envisioned:
   - session 1 (<kebab-slug>) — <one-liner of the concrete deliverable> — tier <A|B|C|D> (<primary model>)
   - session 2 (<kebab-slug>) — <one-liner> — tier <A|B|C|D> (<primary model>)  (if >1 session)
   ```
   If it's a single session, still list `session 1` explicitly.
3. **Current model** — one line, from the current-model gate above :
   ```
   Current model : <model> — <match | overkill (tier <X> suffices) | in-ladder fallback (degraded directives apply) | below tier <X> → fresh chat required>
   ```
4. **Why the recommended choice** — one paragraph linking complexity to
   the recommendation. If escalated from #1, name the signal. If the
   current-model gate demoted #1, name the mismatch.
5. **What each option produces** — 4 one-liners : 0 / 0 / 2 / 5 files
   respectively.

#### Branch on the answer

| Answer | Branch | Files |
|---|---|---|
| This session | Print `Plan scaffold skipped — implementing in current session.`, hand back to Claude. | 0 |
| Fresh chat, prompt only | Go to §0.5 | 0 |
| Prompt written to .md (with status) | Go to §0.6 | 2 |
| Multi-session scaffold | Go to §1 with `mode = multi` | 5 |

`AskUserQuestion` is called **exactly once** — never twice in the same
invocation.

### 0.5. Prompt-only mode — chat display, 0 files

Reached when step 0 answer = "Fresh chat, prompt only". Renders the
prompt in chat wrapped in a 5-backtick fence — user copies from the chat
and pastes into a fresh Claude Code session.

1. Resolve `feature_name` / `feature_title` / `description` per §1.
2. Build the prompt from `$T/prompt-body.md` (see §File templates).
   In this mode, **omit** the "How to use this file" blockquote
   header (no file to open).
3. Print exactly :

   ```
   ✅ Self-contained prompt ready. Use the copy button on the code block below, paste into a fresh Claude Code session.

   `````
   <rendered prompt>
   `````
   ```

   5 backticks is required because the prompt contains inner 3-backtick
   blocks (bash, toml, python) ; escalate to 6 backticks if the prompt
   itself contains a 5-backtick block.

   Then stop — no next-steps block (no file to link to), no collision
   check, no plan-file edit.

Plan mode behavior : identical — chat only, never embedded in the plan
file (zero disk writes is trivially satisfied).

### 0.6. Prompt-with-status mode — light scaffold, 2 files

Reached when step 0 answer = "Prompt written to .md (with status)".
Writes exactly TWO files to `plans/<feature_name>/` : `prompt.md` (the
self-contained prompt) + `STATUS.md` (3-row tracker). No `ROLLOUT.md` /
`LOG.md` / `EXISTING.md` / `sessions/` — that's `Multi-session scaffold`.

1. Resolve identifiers per §1.
2. Collision check per §2 (propose `-v2` if directory exists).
3. `mkdir -p /workspace/plans/${feature_name}/` (skipped in Plan mode).
4. Build `prompt.md` from `$T/prompt-body.md` with the
   "How to use this file" blockquote header kept. Substitutions :
   - `{{feature_title}}` → human title
   - `{{feature_name}}`  → kebab slug
   - `{{description}}`   → scope text
   - `{{plan_approach}}` → Phase 4 design or upstream context. Fallback
     `_(no approach captured — first session will design it)_`.
   - `{{tests}}`         → verification steps, or fallback
     `existing tests pass; new behavior verified end-to-end`.
   - `{{model_line}}`    → tier block rendered per §Model tiers.
   - `{{model_line_short}}` + `{{tier_legend}}` → STATUS-lite Model line
     and tier legend, per §Model tiers.
   - `{{subagents_block}}` → shared sub-agents block, per §Model tiers.
5. Build `STATUS.md` from `$T/status-lite.md`.
6. Write both files (skipped in Plan mode).
7. Print the next-steps block as raw markdown :

   > ✅ Prompt + status saved at [plans/{{feature_name}}/](plans/{{feature_name}}/)
   >
   > **Files** :
   > - [prompt.md](plans/{{feature_name}}/prompt.md) — self-contained prompt ← **paste into a fresh Claude Code chat**
   > - [STATUS.md](plans/{{feature_name}}/STATUS.md) — 3-row tracker (`prompt.md written` ✅ / `implementation` 📋 / `commit` 📋)
   >
   > The fresh chat flips `implementation` 📋 → ✅ then `commit` 📋 → ✅
   > as part of its DoD.

### 1. Parse invocation and derive identifiers

`/prepare-plan <feature-name> [<description>]` or the natural-language
equivalent :

- `feature_name` — kebab-case, matches `[a-z][a-z0-9-]*`. If the first
  whitespace-token already matches, use it. Otherwise derive from the
  description (lowercase, strip stopwords, kebab-case, ≤ 40 chars).
  Reject `/`, `..`, uppercase, spaces. If too generic (≤ 3 chars, or
  common verb like `fix`, `add`, `do`), ask user for explicit name.
- `description` — everything after `feature_name`, trimmed. If empty,
  ask for a one-line scope.
- `feature_title` — capitalise each word (split on `-`).
- `date` — `date +%F` (ISO `YYYY-MM-DD`).
- `first_session_slug` — short kebab for the first concrete step.
  Default `scaffold`. Examples : `scaffold`, `inventory`, `baseline`,
  `spike`, `apply-shim`.

Print one confirmation line :

```
→ feature_name=<name>, first_session_slug=<slug>, target=/workspace/plans/<name>/
```

### 2. Collision check

`target = /workspace/plans/${feature_name}/`. If it exists, NEVER
overwrite — propose `-v2`, `-v3`, …, recompute `target`, and wait for
explicit user confirmation :

```
⚠ /workspace/plans/<name>/ already exists. Proposing /workspace/plans/<name>-v2/ instead.
  Confirm with "yes" or provide a different name.
```

### 3. Exploration — fill EXISTING.md (multi-session mode)

- **Skip** if scope is confined to named files — `Read` them directly.
- **Spawn 1–3 Explore agents in parallel** ("quick" thoroughness) if the
  area is broad or unfamiliar (e.g. "refactor the auth layer"). Brief
  each with a focused question.
- **Default to skip** if you can't articulate a precise question — vague
  exploration produces noise.

Aggregate findings into a draft EXISTING.md section, or fall back to a
fill-me stub for session 1 to populate.

### 4. Generate the 5 files (multi-session mode)

`ROOT="/workspace/plans/${feature_name}"`. `mkdir -p "$ROOT/sessions"`,
then write each file substituting every `{{placeholder}}` from
§File templates (read the five files first). Variables :

| Placeholder | Value |
|---|---|
| `{{feature_name}}` | kebab slug |
| `{{feature_title}}` | human title |
| `{{description}}` | scope text |
| `{{date}}` | today ISO |
| `{{first_session_slug}}` | first session slug |
| `{{existing_body}}` | exploration findings as a `path — role` map (one line each, no code excerpts, ~60 lines max), or the fill-me stub |
| `{{session_id}}` / `{{session_slug}}` | `1` / `{{first_session_slug}}` |
| `{{prev_session}}` | `none — first session` |
| `{{session_goal}}` | session 1's concrete deliverable — not the rollout goal, ROLLOUT.md holds that |
| `{{model_line}}` | session-1 tier block, rendered per §Model tiers |
| `{{model_tier_cell}}` | STATUS Model cell, e.g. `B (opus-5.5)` |
| `{{tier_legend}}` | legend lines for the tiers used, per §Model tiers |
| `{{subagents_block}}` | shared sub-agents block, per §Model tiers |

Write order :

1. `$ROOT/ROLLOUT.md`
2. `$ROOT/STATUS.md`
3. `$ROOT/LOG.md`
4. `$ROOT/EXISTING.md`
5. `$ROOT/sessions/session-1-{{first_session_slug}}.md` (from `$T/session.md`)

### 5. Sanity check — no leftover placeholders

```bash
if grep -RE '<feature[_-]name>|<feature[_-]title>|<first[_-]session[_-]slug>|\{\{[a-z_]+\}\}' "$ROOT" 2>/dev/null; then
  echo "❌ Unresolved placeholders in $ROOT — aborting and removing partial output."
  rm -rf "$ROOT"
  exit 1
fi
```

Empty result beats broken plan. If any placeholder remains, wipe `$ROOT`
and stop.

### 6. Print the next-steps block (multi-session mode)

Raw markdown, NOT inside a code fence (markdown links only click through
when outside fences). Paths workspace-relative (`plans/<name>/...`),
never absolute (`/workspace/plans/...`).

> ✅ Plan scaffolded at [plans/{{feature_name}}/](plans/{{feature_name}}/)
>
> **Files** :
> - [ROLLOUT.md](plans/{{feature_name}}/ROLLOUT.md) — entry point, read first
> - [STATUS.md](plans/{{feature_name}}/STATUS.md) — session scoreboard
> - [LOG.md](plans/{{feature_name}}/LOG.md) — append-only journal (empty)
> - [EXISTING.md](plans/{{feature_name}}/EXISTING.md) — code inventory
> - [sessions/session-1-{{first_session_slug}}.md](plans/{{feature_name}}/sessions/session-1-{{first_session_slug}}.md) — **first session prompt** ← open this and paste its content into a fresh Claude Code chat
>
> To add a session later — at the end or between two existing ones : `/prepare-plan add {{feature_name}} [after <id>] <description>`.

### 7. Add a session to an existing plan

Reached from the entry point above. Grammar :
`add <feature-name> [after <id>] <description>` — or the natural-language
equivalent (« ajoute une session intermédiaire entre la 2 et la 3 » =
`after 2`).

1. **Resolve the plan.** `ROOT=/workspace/plans/<feature-name>`. Missing →
   say so, list the closest names under `/workspace/plans/`, stop. A
   `prompt.md` without `ROLLOUT.md` → §0.6 plan, refuse (Failure modes).
2. **Read the state** : `STATUS.md` (rows, ids, model cells, counter,
   Next focus), `ROLLOUT.md` § Decisions, `LOG.md` § Carry-forward if
   present (older plans have none — then the latest LOG entry only).
   Never the whole LOG.
3. **Compute the id.** Never renumber : prompts, LOG headings and commits
   cite the ids.
   - No `after` → the largest integer id + 1.
   - `after X` → `X.1` ; if `X.1` … `X.k` exist, `X.(k+1)`. Inserting
     after an intermediate (`after 3.1`) gives `3.1.1` only if the user
     asked for that exact position ; otherwise prefer `3.2`.
   - `X` must be an existing row ; if not, list the ids and stop.
4. **Context message, then one question.** Print (raw markdown, ~10
   lines) : the session line in the §0 format
   (`session <id> (<slug>) — <deliverable> — tier <X> (<model>)`, tier
   per §Model tiers) ; the rows it sits between ; whether the next row's
   prompt already exists and names the previous session (it will be
   re-pointed). Then **one** `AskUserQuestion` : « Add as session <id>
   (Recommended) » / « Append at the end instead (<N+1>) » / « Cancel ».
   The 4-option routing question of §0 is NOT asked — routing is settled,
   the plan exists.
5. **Write** (Plan mode : spec only, see §Plan mode integration). Read
   `$T/session.md` and `$T/model-rendering.md` first.
   - `STATUS.md` : insert the row right after the last row whose id sorts
     before the new one (numeric per dot-segment : `3 < 3.1 < 3.2 < 4`),
     shaped like its neighbours —
     `| <id> | <slug> — <brief> | <tier cell> | 📋 | [→ prompt](sessions/session-<id>-<slug>.md) |`.
     Bump the counter's total (`x / N` → `x / N+1`). If the new row is now
     the first open one, rewrite « Next focus ». If its tier is not in the
     legend yet, add the legend line.
   - `sessions/session-<id>-<slug>.md` from `$T/session.md`, with
     `{{prev_session}}` = the row just above it.
   - **Successor** : if the row just below has a 📋 prompt whose text
     names the old predecessor as « previous session » / in its
     « Read also », re-point that reference to `<id>` and report the edit.
     Touch nothing else in it.
6. **Check what you wrote** — §5's grep on the new session file and
   `STATUS.md` only. On a hit : delete the new session file, restore the
   STATUS row you inserted, stop. Never `rm -rf` an existing plan.
7. **Next steps** (raw markdown, workspace-relative links) :

   > ✅ Session <id> added to [plans/<feature>/STATUS.md](plans/<feature>/STATUS.md)
   >
   > - [sessions/session-<id>-<slug>.md](plans/<feature>/sessions/session-<id>-<slug>.md) — prompt ← paste into a fresh Claude Code chat when its turn comes
   > - <successor re-pointed : `sessions/session-<next>-….md`, or « no successor prompt to update »>

## Plan mode integration

When invoked during Plan mode (system reminder says "Plan mode is
active"), the skill MUST NOT mutate disk — only `Read`,
`AskUserQuestion`, and text output are allowed. All writes are deferred
to post-`ExitPlanMode` execution ; the spec is embedded into the current
plan file (`/home/node/.claude/plans/<plan-name>.md`) via Claude editing
that file.

| Mode | What goes into the plan file | Post-`ExitPlanMode` action |
|---|---|---|
| This session | Nothing beyond the approved plan body. | Claude implements directly. |
| Fresh chat, prompt only | Nothing — rendered prompt goes to chat wrapped in 5-backtick fence. | User copies from chat, pastes into fresh session. |
| Prompt written to .md (with status) | Append `## Prompt-with-status spec` section with `### plans/<name>/prompt.md` + body, then `### plans/<name>/STATUS.md` + body. | Claude runs `mkdir -p` + 2 `Write` calls + §0.6 step 7 next-steps block. |
| Add a session (§7) | Append `## Add-session spec` section : the new STATUS row with its position, the full session prompt under `### plans/<name>/sessions/session-<id>-<slug>.md`, and any successor-prompt edit as a before / after pair. | Claude applies the STATUS edit + 1 `Write` (+ the successor edit), then §7 step 6-7. |
| Multi-session scaffold | Append `## Scaffold spec` section with `### plans/<name>/<FILE>` header + body for each of the 5 files. | Claude runs `mkdir -p` + 5 `Write` calls + §5 sanity grep + §6 next-steps block. |

## Model tiers

Per-session model recommendation. Full catalog + rules (session-type
table, classifier gate signal words) : [MODELS.md](MODELS.md) — same
directory, travels with the skill.

### Ladders

| Tier | Role | Ladder (normal) | Ladder (`*`, classifier gate) |
|---|---|---|---|
| **A** | Max reasoning | `fable` → `opus-5.5` → `opus-5` → `opus-4.8` → `opus-4.7` | `opus-4.8` → `opus-4.7` → `sonnet-5` |
| **B** | Default | `opus-5.5` → `opus-5` → `opus-4.8` → `opus-4.7` → `sonnet-5` | `opus-4.8` → `opus-4.7` → `sonnet-5` |
| **C** | Specified execution | `sonnet-5` → `opus-4.7` | (same) |
| **D** | Mechanical / sub-agents | `haiku-4.5` → `sonnet-5` | (same) |

Ranking (for gates) :
`fable-5.1 ≈ fable-5 > opus-5.5 ≈ opus-5 ≈ opus-4.8 > opus-4.7 > sonnet-5 > haiku-4.5`.

`fable` in a ladder is a token, not a model : it resolves to the newest
Fable the running Claude Code can select (§ Availability gate below) —
`fable-5.1` from 2.1.258, `fable-5` before — and is always rendered
resolved. The two Fables tie at rank 5 : running on Fable 5 where the
primary is `fable-5.1` is a match.

Opus 5.5, Opus 5 and 4.8 tie at rank 4 (same context / class), so they
sit adjacent in A and B : **running on any of them is a match for the
tier**, and none triggers degraded mode — that starts at 4.7. Opus 5.5
leads because it is newer *and* cheaper ($4/$20 against $5/$25, cache
reads at $0.20 against $0.50) ; it is also the one model here gated on
a Claude Code version — absent below extension 2.1.280, where Opus 5
leads instead. 4.8 takes the primary slot back under `*` because the
5.x pair empirically refuses more on offensive-framed prompts.

### Base tier by session type (compact — exhaustive table in MODELS.md)

- **A** : architecture / approach decision · ambiguous exploration
  (unreproduced bug, unknown area, RE analytical investigation).
- **B** : specified feature · risky migration · doc prose · ops/deploy ·
  review · hotfix · perf · refactor · exploit dev / bypass (with `*`).
- **C** : tests-only · mechanical migration · reference doc · bulk
  (renames, codemod) · spike · deps upgrade · config · CRUD on
  established patterns.
- **D** : sub-agent grep/inventory fan-out (never a main session).

Unlisted → nearest case + modifiers ; nothing fits → B.

### Availability gate (before anything else)

The `/model` picker is baked into the Claude Code build ; a model the
build cannot select must never appear in the output. Rule and per-model
minimum : [MODELS.md § *Availability gate*](MODELS.md#availability-gate--by-claude-code-version).

- **Version** : the `prepare-plan availability gate: Claude Code X` line
  injected at SessionStart by `model-availability.js` — it is the cache,
  do not re-run a command when it is present. Missing (hook not merged,
  context lost) → one `claude --version`, then `echo $CLAUDE_CODE_VERSION`
  as the last resort ; still nothing → assume the oldest supported build.
- **Effect** : each model whose minimum is above the version is absent —
  not in the context message, the Model line, a ladder, a legend or a
  STATUS cell. Its rank-tied sibling takes its slot ; nothing else in
  the ladders moves. Two models carry a minimum today : Fable 5.1 (2.1.258)
  and Opus 5.5 (2.1.280) — see the table above, which is the source of truth.

### Classifier gate (adds `*` to tier)

The gate fires on **offensive framing** in the session description, not
on the topic. Full signal-word list :
[MODELS.md § *Classifier-sensitive gate*](MODELS.md#classifier-sensitive-gate--by-framing-not-by-topic).
Quick check — the gate fires if the description reads as :

- Writing an exploit / shellcode / ROP chain / CVE PoC.
- Bypassing anti-cheat / DRM / EDR / auth check.
- Cracking passwords / hashes.
- Adversarial payload (ML jailbreak, prompt injection research).
- Stealth / evasion utility (anti-fingerprint, botting, anti-detection).

Analytical RE (reverse to understand, port asm, extract state machine,
document format) does NOT fire — Fable stays viable.

When it fires : tier suffix → `A*` / `B*` / etc. ; tier **A and B**
ladders swap to the classifier-free variant (Fable and the Opus 5.x pair dropped,
`opus-4.8` primary in both) ; announce "classifier-sensitive framing
detected — classifier-free ladder locked" in the pre-question context.

### Modifiers (±1, clamped A..D)

- **+1** if any : ambiguity · hard to reverse (prod data, deploy,
  public schema/API) · prior failure at the current tier · pivot
  session · no test harness.
- **−1** if all : mechanically verifiable DoD · bounded diff, trivial
  rollback · repeats an established pattern.

### Decision procedure (per session)

```
0. Availability gate         → drop absent models from every ladder
1. Session type              → base tier
2. Modifiers ±1              → final tier (clamped A..D)
3. Classifier framing gate   → `*` suffix + adjust tier-A ladder
4. Planning session ?        → Fable criteria (skip if gate fired)
5. Render : tier[*] + ladder (+ degraded directives if fallback likely)
```

### Rendering

`{{model_line}}`, `{{model_line_short}}`, `{{tier_legend}}` and
`{{subagents_block}}` are rendered from `$T/model-rendering.md` (see
§File templates). Read it before writing any prompt or STATUS file — never
from memory : it carries the self-check gate block verbatim.

## File templates

The templates live beside the skill, **read on demand** — only the files
the chosen branch writes. `$T` = `/opt/devcontainer/base/skills/prepare-plan/templates`
(absolute : the skill itself is copied to `~/.claude/commands/`, its
siblings are not). Each file is the source of truth for its output.

| File | Renders | Read by |
|---|---|---|
| `$T/model-rendering.md` | Model line, short line, tier legend, sub-agents block | §0.5, §0.6, §4, §7 |
| `$T/prompt-body.md` | the self-contained prompt | §0.5, §0.6 |
| `$T/status-lite.md` | 3-row `STATUS.md` | §0.6 |
| `$T/rollout.md`, `$T/status.md`, `$T/log.md`, `$T/existing.md` | multi-session scaffold | §4 |
| `$T/session.md` | any `sessions/session-<id>-<slug>.md` prompt | §4, §7, and every session scaffolding its successor |
| `$T/test-plan.md` | `TEST-PLAN[-<id>].md` + suites under `plans/<feature>/suites/` | only when verification is deferred to the host |

Branch #1 « This session » reads none of them.


## Constraints

Only invariants that don't already appear inline in §0-§6 :

- Output path is always `/workspace/plans/<feature_name>/`. Never elsewhere.
- Never overwrite an existing plan directory — propose `-v2`, `-v3`, …
- `feature_name` matches `[a-z][a-z0-9-]*`. Reject `/`, `..`, uppercase, spaces.
- Every generated file has resolved placeholders (§5 enforces).
- Generated files are in **English** per project CLAUDE.md rule, even when
  the conversation is in French.
- Inside Plan mode : NO direct disk mutation (no `Write`, no `Edit`, no
  `Bash mkdir`). Only `Read`, `AskUserQuestion`, text output, and plan-file
  edits by Claude. All writes deferred to post-`ExitPlanMode`.
- Every generated prompt (modes 2/3/4 and §7) carries a Model line : tier + full
  fallback ladder, never a bare model ID. Tiers derived per §Model tiers.
  Both STATUS variants name the model (column / dedicated line) and list
  the used tiers in their legend.

## Failure modes

| Symptom | Cause | Mitigation |
|---|---|---|
| `feature_name` directory exists | Repeat or pre-existing plan | Propose `-v2`, wait for confirmation. Never overwrite. |
| `feature_name` too generic (≤ 3 chars, or verb `fix` / `add` / `do`) | Vague description | Ask user for explicit name. |
| Explore agent times out / returns nothing | Scope mis-bounded | Fallback to `EXISTING.md` stub. Session 1 fills it. |
| Sanity check finds `{{placeholder}}` | Substitution miss | Wipe output, abort. Empty beats broken. |
| No plan approach captured (skill outside Plan mode) | Upstream design not passed | Use fallback line, warn user prompt is thin. |
| User wants to extend existing plan | New session needed | §7. Never renumber existing sessions. |
| §7 target is a §0.6 plan | No session table | Refuse ; promoting it to a multi-session scaffold is a separate request. |
| Template file missing under `$T` | Image older than the skill, or path drift | Stop and say so — never render a template from memory. |
| Recommendation feels wrong | Judgment off | Non-binding — user picks another option. |
| Recommended model unavailable | Availability varies | The fallback ladder is already printed in the prompt. For tier A/B on a fallback model, the degraded-mode sentence applies (tighter spec + Sonnet verification sub-agent). |
| Session pasted on a below-ladder model | User skipped /model | The prompt's self-check gate fires : blocking AskUserQuestion before any work, re-checked on the next turn after /model. |
