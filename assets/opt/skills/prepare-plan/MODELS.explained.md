# Claude model choice — the human guide

> Companion to [MODELS.md](MODELS.md) (terse machine reference consumed
> by `prepare-plan.skill.md`). This file adds the *why*.
>
> Snapshot 2026-07-28. API prices in $/MTok. On a Claude Code
> subscription, read prices as **usage-limit burn rates** — Fable burns
> ~2× faster than an Opus for equal work (permanent thinking included).

## Summary

| Model | ID | Price in/out | Context | Positioning |
|---|---|---|---|---|
| Fable 5 | `claude-fable-5` | $10 / $50 | 1M | Max capable ; thinking always on ; very long turns |
| Opus 5 | `claude-opus-5` | $5 / $25 | 1M | Tier B primary — refuses more on offensive framing |
| Opus 4.8 | `claude-opus-4-8` | $5 / $25 | 1M | Rank-tied with 5 ; classifier-quiet, takes over under the gate |
| Opus 4.7 | `claude-opus-4-7` | $5 / $25 | 1M | Previous gen ; fallback / literal-instruction niche |
| Sonnet 5 | `claude-sonnet-5` | $3 / $15 (intro $2/$10) | 1M | Near-Opus on code, faster |
| Haiku 4.5 | `claude-haiku-4-5` | $1 / $5 | **200K** | Mechanical, high-volume, cheap sub-agents |

## The Opus family — same price, different behavior

5, 4.8, 4.7 all cost $5 / $25 with 1M context. The pick is empirical :

- **Opus 5** — newest and most capable of the three, and the tier B
  primary. On RE-heavy workloads it refuses more often than 4.8 when
  the prompt looks offensive-framed (see § *Classifier framing*) —
  that, not capability, is what the classifier gate arbitrates.
- **Opus 4.8** — rank-tied with 5, one rung below it in the A/B
  ladders. Empirically the sweet spot between capability and
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

Prepare-plan detects this from the session description — signal words
in [MODELS.md § *Classifier-sensitive gate*](MODELS.md).

## When to use what — signals per model

**Fable 5** — signal : *"this reasoning error costs hours"*. The bug
that already beat Opus, overnight autonomous runs, architecture where
a wrong choice costs weeks, ambiguous ragexe RE with proof required.
Analytical framing keeps it viable for RE.

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
`opus-5` leads A/B while `opus-4.8` leads `A*`/`B*`.

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
  → +1 → **A** (Fable primary, Opus 5 behind it).
- **Architecture README** → doc prose B ; no modifier → **B**.
- **Specified feature, repo without tests** → B ; no harness → +1 →
  **A**, *or* stay B with mandated Sonnet verification pass + write
  tests first (usually preferable).
- **Write exploit PoC for CVE-2025-xxxx** → security B ; classifier
  framing → **B*** (Opus 5 dropped, primary falls to Opus 4.8).
- **Reverse ragexe's dispatch table** → RE analytical A ; not offensive
  framing → **A** (Fable primary).

### Model for the planning session itself

The `/prepare-plan` mechanics are procedural ; what needs reasoning is
the plan's **content**. Rule : planning effort ∝ cost of a bad plan.
**Fable for planning if at least one** : ≥3 sessions with dependencies
· approach not settled · hidden-constraint domain · re-plan after
broken plan · high error cost. Classifier gate fires → Opus 4.8 (Fable
and Opus 5 off). None of the above → Opus 5. Trivial work → current
model, even Sonnet.

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

Hard limit : a session can't change its own model — `/model` is a user
action ; the fallback ladder + self-check gate are the mitigation.
