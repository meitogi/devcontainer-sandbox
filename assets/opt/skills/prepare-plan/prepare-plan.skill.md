---
description: Route code work following a plan to one of 4 execution contexts by increasing persistence — (1) This session, 0 files (default) ; (2) Fresh chat prompt only, 0 files ; (3) Prompt written to .md with status, 2 files ; (4) Multi-session scaffold, 5 files. Prints a mandatory pre-question context message (complexity + sessions envisaged verbatim + escalation reason) then calls AskUserQuestion once. When the recommendation is a no-persistence mode (#1 or #2), option #3 sits in position #2 as the upgrade path. Every generated prompt carries a per-session model tier recommendation (A/B/C/D) with a fallback ladder. AUTO-TRIGGER at Phase 4 of Plan mode. Also auto-triggers on natural phrases like "fais-moi un plan", "scaffold a plan", "j'ai pas le temps".
argument-hint: "<feature-name> [<free-text scope description>]"
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
- Extend an existing plan directory → edit its `STATUS.md` / `LOG.md` /
  `sessions/` by hand (no append mode).

## Process

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
| **match / overkill** | current model ≥ tier primary, by **rank** (`opus-5` / `opus-4.8` tie, so do `fable-5.1` / `fable-5`) — but on a `*` tier, `fable` and `opus-5` never match, the gate excludes them by behaviour, not by rank | #1 « This session » stays recommendable (default). If overkill by ≥2 ranks (e.g. fable for tier C/D), note the wasted cost — still allowed. |
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
2. Build the prompt from the `prompt-body` template (see §Templates).
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
4. Build `prompt.md` from the `prompt-body` template with the
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
5. Build `STATUS.md` from the `STATUS-lite` template.
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
§Templates. Variables :

| Placeholder | Value |
|---|---|
| `{{feature_name}}` | kebab slug |
| `{{feature_title}}` | human title |
| `{{description}}` | scope text |
| `{{date}}` | today ISO |
| `{{first_session_slug}}` | first session slug |
| `{{existing_body}}` | exploration findings, or fill-me stub |
| `{{model_line}}` | session-1 tier block, rendered per §Model tiers |
| `{{model_tier_cell}}` | STATUS Model cell, e.g. `B (opus-5)` |
| `{{tier_legend}}` | legend lines for the tiers used, per §Model tiers |
| `{{subagents_block}}` | shared sub-agents block, per §Model tiers |

Write order :

1. `$ROOT/ROLLOUT.md`
2. `$ROOT/STATUS.md`
3. `$ROOT/LOG.md`
4. `$ROOT/EXISTING.md`
5. `$ROOT/sessions/session-1-{{first_session_slug}}.md`

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
> To add a session-2 later : edit [STATUS.md](plans/{{feature_name}}/STATUS.md) (new row) and create `sessions/session-2-<slug>.md` following session 1's shape.

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
| Multi-session scaffold | Append `## Scaffold spec` section with `### plans/<name>/<FILE>` header + body for each of the 5 files. | Claude runs `mkdir -p` + 5 `Write` calls + §5 sanity grep + §6 next-steps block. |

## Model tiers

Per-session model recommendation. Full catalog + rules (session-type
table, classifier gate signal words) : [MODELS.md](MODELS.md) — same
directory, travels with the skill.

### Ladders

| Tier | Role | Ladder (normal) | Ladder (`*`, classifier gate) |
|---|---|---|---|
| **A** | Max reasoning | `fable` → `opus-5` → `opus-4.8` → `opus-4.7` | `opus-4.8` → `opus-4.7` → `sonnet-5` |
| **B** | Default | `opus-5` → `opus-4.8` → `opus-4.7` → `sonnet-5` | `opus-4.8` → `opus-4.7` → `sonnet-5` |
| **C** | Specified execution | `sonnet-5` → `opus-4.7` | (same) |
| **D** | Mechanical / sub-agents | `haiku-4.5` → `sonnet-5` | (same) |

Ranking (for gates) :
`fable-5.1 ≈ fable-5 > opus-5 ≈ opus-4.8 > opus-4.7 > sonnet-5 > haiku-4.5`.

`fable` in a ladder is a token, not a model : it resolves to the newest
Fable the running Claude Code can select (§ Availability gate below) —
`fable-5.1` from 2.1.258, `fable-5` before — and is always rendered
resolved. The two Fables tie at rank 5 : running on Fable 5 where the
primary is `fable-5.1` is a match.

Opus 5 and 4.8 tie at rank 4 (same price / context / class), so they
sit adjacent in A and B : **running on either is a match for the
tier**, and neither triggers degraded mode — that starts at 4.7. Opus 5
leads because it is newer ; 4.8 takes the primary slot back under `*`
because 5 empirically refuses more on offensive-framed prompts.

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
  context lost) → one `echo $CLAUDE_CODE_VERSION`, then `claude
  --version` ; still nothing → assume the oldest supported build.
- **Effect** : each model whose minimum is above the version is absent —
  not in the context message, the Model line, a ladder, a legend or a
  STATUS cell. Its rank-tied sibling takes its slot ; nothing else in
  the ladders moves. Today only Fable 5.1 carries a minimum (2.1.258).

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
ladders swap to the classifier-free variant (Fable and Opus 5 dropped,
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

### Rendering `{{model_line}}`

Always tier + full fallback ladder — never a bare model ID. `fable` is
written resolved (`fable-5.1` or `fable-5`, per the availability gate),
and an absent model is never written at all. Three parts, in order :

1. The Model line (tier gets `*` if classifier gate fired) :

   ```
   > **Model : Tier B — opus-5** (fallback : opus-4.8 → opus-4.7 → sonnet-5). Run /model before pasting this prompt.
   ```

   or, gate fired :

   ```
   > **Model : Tier B* — opus-4.8** (fallback : opus-4.7 → sonnet-5, classifier-free set locked). Run /model before pasting this prompt.
   ```

2. For tiers **A/B only**, the degraded-mode sentence :

   ```
   > If running on a fallback model : keep the spec literal and explicit, and add an independent Sonnet sub-agent verification pass before the DoD.
   ```

3. For ALL tiers, the self-check gate block :

   ```
   **Model self-check (first action, before any work)** : check the model
   you are running on (named in your system prompt) against this
   session's tier.
   - Primary, rank-tied with it, or above : proceed silently.
     `opus-5` and `opus-4.8` are rank-tied — either satisfies a tier
     A/B primary, whichever of the two the Model line names.
     **Exception — a tier marked `*`** : the rank tie is void there.
     `fable` and `opus-5` are excluded by the classifier gate, not by
     rank ; on either of them, treat yourself as below the ladder.
   - In the fallback ladder, below the primary's rank : proceed,
     applying the degraded-mode directives.
   - Below the ladder : do NO work yet — ask via AskUserQuestion :
     (1) "I'll switch — /model <primary> now, then I reply 'go'"
         (Recommended) ;
     (2) "Continue anyway on <current model>" (degraded-mode directives
         apply).
     If (1) : end your turn telling the user to run /model <primary> and
     reply "go". On their next message, RE-RUN this self-check — /model
     applies to the next turns of the same session. Still below the
     ladder → ask again (the switch didn't happen). Never start work on
     the user's word alone ; the re-check is the proof.
     If work was already started below the ladder (missed gate), do NOT
     switch in place — fresh chat + /model + re-paste this prompt (it is
     self-contained).
   ```

### `{{model_line_short}}` and `{{tier_legend}}`

- `{{model_line_short}}` — one line, no /model sentence, no gate (for
  STATUS files) : `Tier B — opus-5 (fallback : opus-4.8 → opus-4.7 → sonnet-5)`.
  Add `*` after the tier letter if the classifier gate fired.
- `{{tier_legend}}` — one line per **distinct tier used** in the file
  (never all four unconditionally). If any listed tier carries `*`, add
  a final line explaining the marker :

  ```
  Model tiers used here :
  - **A*** = opus-4.8 (fallback : opus-4.7 → sonnet-5)
  - **B** = opus-5 (fallback : opus-4.8 → opus-4.7 → sonnet-5)
  - **C** = sonnet-5 (fallback : opus-4.7)
  - `*` suffix = classifier-sensitive session ; classifier-free set locked (Fable and Opus 5 dropped, opus-4.8 primary).
  ```

  The `*` explainer line appears **only if** at least one tier in the
  file uses it.

### `{{subagents_block}}` (shared by prompt-body and session templates)

```
Sub-agents :
- Exploration / localisation / inventory → fan-out of **Haiku** agents
  (never the main tier for grep work).
- Independent end-of-session verification → one **Sonnet** agent.
- Next-session prompt scaffolding → one **Opus** agent, regardless of
  this session's tier — a session prompt is a planning artifact. The
  main session reviews the draft against the filesystem, then links it.
- Synthesis and decisions stay in the main session — never delegated.
- Note : Bash permissions do not propagate to sub-agents — pre-grant in
  `settings.local.json` if the fan-out needs Bash.
```

## File templates

Templates below are the source of truth. Substitute every `{{placeholder}}`
before writing ; §5 sanity check enforces zero leftovers.

**Templates by mode** :
- Multi-session scaffold (§1-6) : `ROLLOUT.md`, `STATUS.md`, `LOG.md`,
  `EXISTING.md`, `sessions/session-1-*.md`. Optional per-session
  `TEST-PLAN-<id>.md` for platform-visible smoke tests, and — whenever
  that plan has a Part 1 — `suites/<name>.mjs`, the browser scenarios it
  automates. Suites are plan-scoped and gitignored like `fixtures/` ;
  only the driver is committed.
- Modes §0.5 and §0.6 : share `prompt-body` ; if verification is
  deferred to the host, both also write `TEST-PLAN.md` (no
  session-id — single prompt, single session).
- Mode §0.6 only : `STATUS-lite`.

### Template — `ROLLOUT.md` (multi-session)

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
| **[LOG.md](LOG.md)** | "What was done, why, what gotchas ?" — append-only journal |
| **[EXISTING.md](EXISTING.md)** | "What does the code look like today ?" — factual inventory |
| sessions/session-NN-*.md | Prompt to paste into a new Claude chat to start session NN |

## How to use

1. **To resume work** : open [STATUS.md](STATUS.md), find the next 📋
   session, check its **Model** column and run `/model` accordingly,
   then click `→ prompt` and paste into a fresh Claude Code session.
2. **To check what was done before** : read [LOG.md](LOG.md).
3. **To understand current code state** : read [EXISTING.md](EXISTING.md).

## Model tiers

Each session's Model column in [STATUS.md](STATUS.md) uses these tiers.
When adding a session-N row by hand, derive its tier here :

| Tier | Role | Fallback ladder (left = primary) |
|---|---|---|
| **A** | Max reasoning | fable → opus-5 → opus-4.8 → opus-4.7 |
| **B** | Default | opus-5 → opus-4.8 → opus-4.7 → sonnet-5 |
| **C** | Specified execution | sonnet-5 → opus-4.7 |
| **D** | Mechanical / sub-agents | haiku-4.5 → sonnet-5 |

- `fable` = the newest Fable the Claude Code in use can select
  (`fable-5.1` from 2.1.258, `fable-5` before) ; write it resolved.
- `opus-5` and `opus-4.8` tie in rank — either one is a match for tier
  A/B, degraded mode starts at `opus-4.7`. A classifier-sensitive
  session is written `A*` / `B*` and drops both fable and opus-5,
  leaving `opus-4.8 → opus-4.7 → sonnet-5`.
- **Base** : architecture/ambiguous → A · specified code, doc prose,
  ops, review, hotfix → B · tests-only, mechanical migration, bulk,
  spike, deps → C · sub-agent grep fan-out → D.
- **+1 tier** if : ambiguous · hard to reverse · prior failure at tier ·
  pivot session · no test harness. **−1** if : mechanical DoD + bounded
  diff + established pattern.
- Full rationale : `.devcontainer/skills/prepare-plan/MODELS.md`.

## Update convention (end of every delivered session)

Every session prompt prescribes these three updates in its DoD :

1. **STATUS.md** : flip the session row 📋 → ✅, replace the prompt link
   with `—`, bump the "Delivered" counter, refresh "Next focus".
2. **LOG.md** : append `## <Session ID> — <Title>` section dated today,
   listing files touched + What / Why / Decisions / Gotchas / Tests /
   Commit (~50–150 lines).
3. **EXISTING.md** : update if new files / structures were created.

## Decisions (immutable unless user explicitly amends)

_(Add decisions here as they are made. Each decision should explain the
trade-off and why this side was picked, so future sessions don't relitigate
settled questions.)_

- _(none yet — first session may seed this list)_
````

### Template — `STATUS.md` (multi-session)

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

### Template — `LOG.md` (multi-session)

````markdown
# Log — {{feature_title}}

> Append-only journal. One section per delivered session. Newest at the
> bottom. Each section follows the same shape :

```
## <Session ID> — <Title>

**Date** : YYYY-MM-DD
**Files touched** :
- path/to/file1
- path/to/file2

**What** : one-paragraph summary of the change.

**Why** : the reason / constraint that drove this scope.

**Decisions** :
- _bullet — short rationale_

**Gotchas** :
- _bullet — surprise or pitfall encountered_

**Tests** :
- _command run + expected outcome_

**Smoke results** :
- **Est. duration** : ~<n> min (<n> scenarios).
- **<YYYY-MM-DD>** — <env, e.g. `macOS 15.7.7 aarch64`>. <what
  passed / failed on the target platform> ; <fix commits if any> ;
  <what's still pending>.
- (Skip this section entirely if the session ships nothing
  user-visible. Otherwise back-fill as tests run — the entry stays a
  `pending` line until the smoke happens, so `git bisect` always
  knows which commit's binary was actually validated on the host.)

**Commit** : `<short hash> — <commit subject>` (or "not committed yet")
```

---

_(no sessions delivered yet — first append will be after session 1)_
````

### Template — `EXISTING.md` (multi-session)

````markdown
# Existing — technical inventory

> Snapshot of the code state at the start of this plan. Updated when a
> session adds / removes / restructures major files.
> For chronological history, see [LOG.md](LOG.md).
> For decisions and philosophy, see [ROLLOUT.md](ROLLOUT.md).

{{existing_body}}
````

When exploration was skipped, `{{existing_body}}` is :

```markdown
## To be filled

This inventory was not pre-populated when the plan was scaffolded —
session 1's first action is to fill it. Use `Read` and/or `Explore`
sub-agents to map :

- Directory structure of the relevant area
- Existing functions / modules that may be reused
- Tests covering the area
- Known gaps / pain points the rollout will address
```

When exploration ran, `{{existing_body}}` is the aggregated findings.

### Template — `sessions/session-1-{{first_session_slug}}.md` (multi-session)

The session file IS the prompt — no wrapper, no fence. The user copies
its full content into a fresh chat.

````markdown
# Session 1 — {{first_session_slug}}

I'm starting session 1 of the `{{feature_name}}` rollout.

Entry point : `/workspace/plans/{{feature_name}}/ROLLOUT.md`
Read also :
- `STATUS.md` (where we are)
- `LOG.md` (what's been done so far — empty on session 1)
- `EXISTING.md` (current code inventory)

{{model_line}}

Goal : {{description}}

First session focus : {{first_session_slug}}. Concretely — propose the
shape, validate with me, then implement the first concrete step. Keep
scope tight ; if you discover follow-up work, add a session-2 row to
STATUS.md instead of folding it in. If we exceed ~15 exchanges on the
same unresolved problem : stop, write the current state (hypotheses
tested, dead ends, next lead) to LOG.md or a notes file, and propose
splitting into a fresh session.

{{subagents_block}}

DoD at the end of this session :
1. STATUS.md : flip session 1 row 📋 → ✅, prompt link → —, bump
   Delivered counter (0→1), refresh "Next focus" (to `rollout complete`
   for a single-session rollout, or `session 2 — to be defined` for a
   multi-session one).
2. LOG.md : append `## 1 — {{first_session_slug}}` section dated today
   with files touched + What / Why / Decisions / Gotchas / Tests /
   Commit.
3. EXISTING.md : update if new files / structures were created.
4. If a next session is planned : scaffold `sessions/session-2-<slug>.md`
   and link it from its STATUS row. Per the sub-agents rule above, the
   draft is written by an **Opus** agent whatever this session's tier —
   review it against the filesystem before linking, since a scaffolded
   prompt's claims read as authoritative to the session that runs it.
5. If any part of this session's verification is deferred to the host
   (smoke test, visual check, platform behavior) : **triage it through
   E2E first** — sort every scenario into machine-assertable vs
   judgement, and when the surface is browser-driven write the suite
   under `plans/<feature>/suites/` and run it. Then write
   `TEST-PLAN-<session-id>.md` NOW, while the context is live, split
   Part 1 (automated) / Part 2 (human), every Part 2 item carrying its
   `Why the harness cannot`. Its last section is the resume prompt for
   the verification session. Deferring the write defeats its purpose.
6. Propose a commit (do NOT commit without explicit user confirmation).
````

### Template — `TEST-PLAN-<session-id>.md` (optional per session)

Scaffold only for sessions that ship **user-visible or platform-specific
behavior that the container can't validate** (macOS UN center, Windows
toast, Linux D-Bus, browser UI, host-installed CLI, etc.). Pure
container-testable code (refactors, backend logic, unit-testable
modules) doesn't need one.

Path : `plans/<feature>/TEST-PLAN-<session-id>.md`. Session ID matches
the LOG entry (`7b`, `3.5`, etc.).

#### Triage through E2E FIRST — before writing a single manual step

*host vs container* is only the first axis. The second one decides how
much of the human's evening this costs, and it is the one that gets
skipped : **is this scenario machine-assertable, or is it a judgement?**

Sort every scenario before writing it up :

| Bucket | Test is | Goes in |
|---|---|---|
| **Machine-assertable** | a DOM query, a natural dimension, an HTTP status, a row count, a SQL result — no judgement call | **Part 1**, as a scenario in `plans/<feature>/suites/<name>.mjs`, run by `wtf claude-live e2e` |
| **Already covered lower** | an L1/L2/L5 test asserts it | nowhere — cite the test name and move on |
| **Human judgement** | is it the *right* image, is the message *understandable*, does the motion jar, does the OS drag actually paint | **Part 2**, manual |

**Write Part 1 first, and actually run it.** A browser E2E harness
already exists — [.devcontainer/claude/scripts/e2e.mjs](../../claude/scripts/e2e.mjs)
drives the host Chromium over CDP holding one socket across steps, and
asserts against the DOM *and* the browser's own PGlite mirror
(`window.sqliteQuery`). Suites live per plan under
`plans/<feature>/suites/` because they are scoped to one session ; only
the driver is committed.

**A TEST-PLAN that is all-manual means the E2E pass was never
attempted.** That is the smell this section exists to catch : the
precedent behind this section shipped 14 manual scenarios, and most of
them turned out to be machine-checkable once someone tried.

**Every Part 2 item carries a `**Why the harness cannot**` line.** This
is the forcing function — it makes an unattempted automation visible,
because a vague reason is a reason you have not looked. Real ones read
like : *"it asserts `naturalWidth > 0`, which proves the bytes decoded ;
a thumbnail of the wrong document passes that check perfectly"*, or
*"it asserts the three strings are distinct — three distinct but equally
useless messages pass"*.

**A third verdict, SKIP, is not bureaucracy.** Some properties are only
opportunistically observable (a state the worker leaves in
milliseconds). PASS would claim an observation nobody made ; FAIL would
blame the product for the harness's vantage point. Say which layer
covers it instead.

````markdown
# Test Plan — session <session-id> end-to-end smoke

> **Scope** : validate what session <session-id> shipped —
> <one-line summary>.
>
> **Total estimated duration** : ~<n> min (of which ~<n> min bootstrap +
> <specific-waits, e.g. "35s for § X idle-timeout">).
>
> **Independent scenarios** — you can stop after § <n> and resume later
> without losing context.
>
> **Shipped commits** on `main` :
>
> | Commit | Subject |
> |---|---|
> | `<hash>` | <subject> |
>
> **Prerequisites** :
> - <container / host prep>
> - <optional external services (webhooks, test fixtures, …)>

## 0. Bootstrap (once per test session)  (~<n> min)

### 0.1 <build step>

<commands + expected output>

### 0.2 <host prep step>

<commands + expected output>

# Part 1 — E2E automatable  (~<n> min, you only read the output)

Driven by the harness over CDP. Everything here is a **machine-checkable
assertion** : a DOM query, a natural dimension, an HTTP status, a count.
No judgement calls. Nothing to do by hand — run this and copy the
verdicts across.

​```sh
wtf claude-live e2e -- --suite plans/<feature>/suites/<name>.mjs
# one scenario only, while chasing a failure :
wtf claude-live e2e -- --suite plans/<feature>/suites/<name>.mjs --only <ID>
​```

One `PASS` / `FAIL` / `SKIP` line per scenario with its evidence.
**SKIP is not a failure** — the property was not observable on that run,
and the line says which layer covers it instead.

### <ID> — <what it proves>

<one line of setup, if any>

- **Pass** — <the observable outcome>.
- **Fail** — <what the failure looks like, so it is recognised>.
- **Why it matters** — <the bug this catches ; skip when obvious>.

## <n>. <...>

# Part 2 — Not automatable  (~<n> min, needs your eyes)

## 2a. Human judgement or a real device

### M1 — <what a machine cannot judge>

<one drag, one look>

- **Pass** — <what "right" looks like, concretely>.
- **Why the harness cannot** — <the specific assertion it CAN make, and
  the wrong outcome that would still pass it>. Mandatory. A vague
  reason here means the automation was not attempted.

## 2b. Design / visual validation

### D1 — <the fidelity question>

- **Pass** — <matches the mockup on the axis that matters>.
- **Why the harness cannot** — <e.g. it asserts the token resolved, not
  that the result reads as intended at a glance>.

## Result checklist

Part 1 — copy from the harness output :

- [ ] **<ID>** — <one-liner>

Part 2 — filled by hand, **OK / FAIL / N/A** :

- [ ] **M1** — <one-liner>
- [ ] **D1** — <one-liner>

If all pass, the session's `**Smoke results**` entry in LOG.md is
back-filled with a `<date> — <env>. All N scenarios green.` line.
Any failure = open a `fix(<scope>)` follow-up commit and back-fill
which scenario found it.

---

## Resume in a fresh chat

When you smoke-test later, paste this into a new conversation. The `@`
triggers file inclusion (VS Code extension feature):

​```
Resuming rollout <feature-name> after smoke test <session-id>.

Context:
- @plans/<feature-name>/LOG.md § <session-id> — decisions + gotchas
- @plans/<feature-name>/TEST-PLAN-<session-id>.md — the plan I just followed

My test results (to fill in):
- [ ] 1 <scenario>:
- [ ] 2 <scenario>:
- [ ] <...>

Bugs observed:
- <paste here, or "none" if all passed>

Environment: macOS <version>, <binary-name> <version>
​```
````

### Template — `prompt-body` (shared by §0.5 chat display and §0.6 file write)

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

### Template — `STATUS-lite` (§0.6 only, `plans/<feature_name>/STATUS.md`)

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
- Every generated prompt (modes 2/3/4) carries a Model line : tier + full
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
| User wants to extend existing plan | No append mode | Tell user to edit `STATUS.md` / `LOG.md` / `sessions/` by hand. |
| Recommendation feels wrong | Judgment off | Non-binding — user picks another option. |
| Recommended model unavailable | Availability varies | The fallback ladder is already printed in the prompt. For tier A/B on a fallback model, the degraded-mode sentence applies (tighter spec + Sonnet verification sub-agent). |
| Session pasted on a below-ladder model | User skipped /model | The prompt's self-check gate fires : blocking AskUserQuestion before any work, re-checked on the next turn after /model. |
