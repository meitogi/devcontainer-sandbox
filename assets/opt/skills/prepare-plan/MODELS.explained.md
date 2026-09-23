# Claude model choice — the human guide

> Companion to [MODELS.md](MODELS.md) (terse machine reference consumed
> by `prepare-plan.skill.md`). This file adds the *why*.
>
> Snapshot 2026-09-23. API prices in $/MTok. On a Claude Code
> subscription, read prices as **usage-limit burn rates** — Fable burns
> ~2× faster than an Opus on output (permanent thinking included), but
> Fable 5.1's cache reads cost half of Opus 5's, so on long agentic
> sessions (mostly cached re-reads) the gap narrows well below 2×.

## Summary

| Model | ID | Price in/out | Cache read | Context | Min Claude Code | Positioning |
|---|---|---|---|---|---|---|
| Fable 5.1 | `claude-fable-5-1` | $10 / $50 | $0.25 | 1M | 2.1.258 | Max capable ; thinking always on ; very long turns ; quieter safeguards than Fable 5 |
| Fable 5 | `claude-fable-5` | $10 / $50 | $1 | 1M | — | Superseded, still served ; rank-5 match when 5.1 is absent |
| Opus 5.5 | `claude-opus-5-5` | $4 / $20 | $0.20 | 1M | **2.1.280** | Tier B primary — newest and cheapest Opus ; forced tool use looks removed (the published tool-use table lists only `auto` / `none` for it) |
| Opus 5 | `claude-opus-5` | $5 / $25 | $0.50 | 1M | — | Rank-tied with 5.5, one rung below ; refuses more on offensive framing |
| Opus 4.8 | `claude-opus-4-8` | $5 / $25 | $0.50 | 1M | — | Rank-tied with the 5.x pair ; classifier-quiet, takes over under the gate |
| Opus 4.7 | `claude-opus-4-7` | $5 / $25 | $0.50 | 1M | — | Previous gen ; fallback / literal-instruction niche |
| Sonnet 5 | `claude-sonnet-5` | $2 / $10 | $0.20 | 1M | — | Near-Opus on code, faster ; intro price made permanent 2026-08-10 |
| Haiku 4.5 | `claude-haiku-4-5` | $1 / $5 | $0.10 | **200K** | — | Mechanical, high-volume, cheap sub-agents |

Cache writes are 1.25× the input price on every model (2× for the 1 h
variant). Prices read off `platform.claude.com/docs/en/about-claude/pricing`
on 2026-09-23.

## Availability — the Claude Code build decides

The `/model` picker ships inside the Claude Code build. A 2.1.220
container cannot select Fable 5.1 no matter what the API offers, so a
plan that names it is noise for that user and a trap for the self-check
gate. Hence the *Min Claude Code* column and the availability gate in
[MODELS.md](MODELS.md) : a model above the running version is *absent*
— never named, dropped from every ladder, its rank-tied sibling takes
the slot. The ladders themselves never change ; `fable` is a token that
resolves to the newest Fable the build can select.

One file, not two : the session-type catalog, modifiers and ladders are
version-independent, and two copies would drift (the `templates/v2`
skill already has). The version is read once per session by the
`model-availability.js` SessionStart hook and injected as context — the
skill never runs a command for it ; `echo $CLAUDE_CODE_VERSION` is only
the fallback when the injected line is missing.

## The Fable pair — same price, one leads

- **Fable 5.1** (2026-09-01) — same $10 / $50, cache reads at a quarter
  of Fable 5's, stronger on hours-long agentic coding, multistep
  research, document/spreadsheet work, vision and deep-context
  retrieval. In Claude Code its cyber safeguards intervene ~60 % less
  often than Fable 5's. At `low` effort it is often competitive with
  Opus on cost per task while doing better — try that before dropping a
  tier for budget reasons. Three API-level breaks (no forced
  `tool_choice`, thinking blocks bound to the model and to the
  conversation prefix) are invisible inside Claude Code.
- **Fable 5** — still served. A session already running on it where the
  primary is `fable-5.1` is a rank-5 match, not a fallback. Only build
  below 2.1.258 still *recommends* it.

## The Opus family — nearly the same price, different behavior

5, 4.8 and 4.7 all cost $5 / $25 with 1M context ; **5.5 undercuts them
at $4 / $20, with cache reads at $0.20 instead of $0.50**. The pick is
empirical :

- **Opus 5.5** — newest, cheapest, and the tier B primary since
  2026-09-23. It appears in the Claude Code bundle from extension
  2.1.280 and not before, so below that version it is simply absent
  and Opus 5 leads instead. Its refusal behaviour has **not** been
  observed here : the classifier gate drops it with Opus 5 by
  precaution, which costs nothing because 4.8 is the fallback either
  way. The published tool-use table lists only `auto` / `none` for it,
  where Opus 5 also has `any` / `tool` — read that as forced tool use
  being gone, and do not write a plan that depends on it.
- **Opus 5** — one rung below 5.5, and the primary on any build older
  than 2.1.280. On RE-heavy workloads it refuses more often than 4.8
  when the prompt looks offensive-framed (see § *Classifier framing*) —
  that, not capability, is what the classifier gate arbitrates.
- **Opus 4.8** — rank-tied with the 5.x pair, one rung below them in
  the A/B ladders. Empirically the sweet spot between capability and
  non-refusal, which is why it takes the primary slot back the moment
  the gate fires.
- **Opus 4.7** — previous generation. Fallback when 4.8/5 are
  unavailable, or for tightly framed structured extraction (its more
  literal instruction-following can help there).

Because 5 and 4.8 tie at rank 4, running on either is a match for tier
A/B — the ladder orders them, it does not grade them. Degraded mode
starts at 4.7. Under the `*` the tie is void : 5 is out on refusal
behaviour, which no rank equality compensates. An RE-heavy codebase
that wants the classifier-quiet
model by default can swap the two in the A/B ladders ; the shape holds
one-for-one.

## Classifier framing — the actual gate

The refusal classifier reacts to the **framing** of the prompt, not the
topic. Same asm-reading task :
- "Reverse this function to understand its logic" → Fable / Opus 5 fine.
- "Write an exploit for CVE-2025-xxxx using this asm" → gate fires.

That's why RE analytical work (understanding, porting, documenting)
stays on Fable / Opus 5 with no penalty. Only sessions framed
offensively — exploit dev, bypass writing, cracking, jailbreak research
— drop to the classifier-free set (4.8, 4.7, Sonnet 5, Haiku 4.5).

Coverage differs inside the prone set : Opus 5 runs cyber classifiers
only ; both Fables add bio, frontier-LLM, reasoning-extraction and
general-harms. Fable 5.1 fires less than Fable 5 did, not zero — it
stays in the prone set.

Prepare-plan detects this from the session description — signal words
in [MODELS.md § *Classifier-sensitive gate*](MODELS.md).

## When to use what — signals per model

**Fable 5.1 / 5** — signal : *"this reasoning error costs hours"*. The
bug that already beat Opus, overnight autonomous runs, architecture
where a wrong choice costs weeks, ambiguous ragexe RE with proof
required. Analytical framing keeps it viable for RE.

**Opus 5** — signal : *"newer capability, no offensive framing"*. The
tier B primary : feature dev, prose, docs, code review. Any serious
work where you're not sure and nothing reads as offensive.

**Opus 4.8** — signal : *"same class, quieter classifier"*. Tier B's
first fallback, and its primary as soon as the gate fires. RE-adjacent
work when framing might read as offensive. Landing here from a tier
A/B recommendation is not a downgrade — no degraded-mode directives.

**Opus 4.7** — signal : *"availability fallback, or literal
extraction"*. Notification when 4.8/5 down. Tightly framed structured
tasks where you want literalism (invoices → jsonl, one row per file).

**Sonnet 5** — signal : *"the thinking is done, apply the spec"*.
Well-scoped feature copy-patterned on existing code. Tests on existing
code. One-shot scripts. Substantial sub-agents (verification, review).

**Haiku 4.5** — signal : *"lookup, no synthesis"*. Point questions on
the codebase. Bulk mechanical renames. Sub-agent fan-out (5×
parallel inventory) — never a main session tier.

## Tier system

| Tier | Role | Ladder (normal) | Ladder (`*`, classifier gate) |
|---|---|---|---|
| **A** | Max reasoning | `fable` → `opus-5` → `opus-4.8` → `opus-4.7` | `opus-4.8` → `opus-4.7` → `sonnet-5` |
| **B** | Default | `opus-5` → `opus-4.8` → `opus-4.7` → `sonnet-5` | `opus-4.8` → `opus-4.7` → `sonnet-5` |
| **C** | Specified execution | `sonnet-5` → `opus-4.7` | (same) |
| **D** | Mechanical / sub-agents | `haiku-4.5` → `sonnet-5` | (same) |

Ladders are stable across model bumps — a new same-price Opus enters
ahead of the one it supersedes, and the classifier-free variant only
takes it if it doesn't refuse more than what it replaces. That is why
`opus-5` leads A/B while `opus-4.8` leads `A*`/`B*`. A new same-price
Fable does not even touch the ladder : `fable` resolves to it through
the availability gate.

Session-type → base tier catalog + modifier rules : [MODELS.md](MODELS.md).
Two ideas make it exhaustive without enumerating every domain :

- **The stack never sets the tier — the work type does.** Vue CRUD =
  C ; Vue SSR hydration bug = B.
- **Modifiers ±1** — upgrade if ambiguity, irreversibility, prior
  failure, pivot session, no test harness ; downgrade if mechanically
  verifiable DoD + bounded diff + established pattern.

### Worked examples

- **Codemod across 40 files, green suite** → bulk C ; mechanical DoD ;
  Haiku fan-out. → **C**.
- **ALTER + backfill on prod, no staging** → migration B ; irreversible
  → +1 → **A** (Fable primary, Opus 5.5 behind it).
- **Architecture README** → doc prose B ; no modifier → **B**.
- **Specified feature, repo without tests** → B ; no harness → +1 →
  **A**, *or* stay B with mandated Sonnet verification pass + write
  tests first (usually preferable).
- **Write exploit PoC for CVE-2025-xxxx** → security B ; classifier
  framing → **B*** (the Opus 5.x pair dropped, primary falls to Opus 4.8).
- **Reverse ragexe's dispatch table** → RE analytical A ; not offensive
  framing → **A** (Fable primary — `fable-5.1` on 2.1.258, `fable-5`
  on 2.1.220).

### Model for the planning session itself

The `/prepare-plan` mechanics are procedural ; what needs reasoning is
the plan's **content**. Rule : planning effort ∝ cost of a bad plan.
**Fable for planning if at least one** : ≥3 sessions with dependencies
· approach not settled · hidden-constraint domain · re-plan after
broken plan · high error cost. Classifier gate fires → Opus 4.8 (Fable
and the Opus 5.x pair off). None of the above → Opus 5.5, or Opus 5
below extension 2.1.280. Trivial work → current model, even Sonnet.

### Degraded mode (tier A/B on a fallback model)

- Tighter, more literal spec (4.7 doesn't generalize intent).
- Split the session : explore/decide, then implement.
- Sonnet verification sub-agent pass at the end.

### Sub-agents

Agent tool's `model` parameter is Claude-driven — no human `/model`.
Haiku for grep/inventory fan-outs, Sonnet for independent verification
or parallel attempts. Final decisions never delegated. Bash permissions
don't propagate to sub-agents — pre-grant in `settings.local.json`.

## Automation status

1. **/prepare-plan extension** — ✅ done — per-session tier + classifier
   gate detection in the context message, Model line + fallback ladder
   + self-check gate in every generated prompt, tier legend (with `*`
   explainer when applicable) in both STATUS variants.
2. **Statusline** — display current model. Mismatch detection vs plan's
   STATUS.md = advanced version, later.
3. **Sub-agents** — directives embedded in generated prompts.
4. **Availability gate** — ✅ done — `model-availability.js` SessionStart
   hook caches the Claude Code version in context ; MODELS.md carries
   the per-model minimum.

Hard limit : a session can't change its own model — `/model` is a user
action ; the fallback ladder + self-check gate are the mitigation.
