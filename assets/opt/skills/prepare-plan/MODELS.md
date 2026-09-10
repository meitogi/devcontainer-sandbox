# Model tiers — machine reference

> Consumed by `prepare-plan.skill.md` §Model tiers. Terse on purpose.
> Snapshot 2026-09-10.

## Models

| Model | ID | Rank | $/MTok in/out | Cache read | Context | Min Claude Code |
|---|---|---|---|---|---|---|
| Fable 5.1 | `claude-fable-5-1` | 5 | 10 / 50 | 0.25 | 1M | 2.1.258 |
| Fable 5 | `claude-fable-5` | 5 | 10 / 50 | 1 | 1M | — |
| Opus 5 | `claude-opus-5` | 4 | 5 / 25 | 0.5 | 1M | — |
| Opus 4.8 | `claude-opus-4-8` | 4 | 5 / 25 | 0.5 | 1M | — |
| Opus 4.7 | `claude-opus-4-7` | 3 | 5 / 25 | 0.5 | 1M | — |
| Sonnet 5 | `claude-sonnet-5` | 2 | 2 / 10 | 0.2 | 1M | — |
| Haiku 4.5 | `claude-haiku-4-5` | 1 | 1 / 5 | 0.1 | **200K** | — |

Cache write = 1.25× input everywhere. `—` in *Min Claude Code* = every
version this repo supports.

Rank drives the gates. Two rank ties, same rule for both :

- **Fable 5.1 / Fable 5 tie at rank 5** (same class, same price). 5.1
  is newer, strictly more capable, quarter-price cache reads, and its
  cyber safeguards intervene ~60 % less often in Claude Code — it leads.
  The ladder token `fable` means *the newest Fable the running Claude
  Code can select* (see § Availability gate) ; rendered as `fable-5.1`
  or `fable-5`, never as the bare token.
- **Opus 5 / Opus 4.8 tie at rank 4.** Opus 5 is newer / more capable :
  it is the **tier B primary**, and tier A's first fallback behind
  Fable. 4.8 sits one rung below it in both, and takes the primary slot
  back in A and B when the classifier gate fires — empirically 5 and
  both Fables refuse more often on offensive-framed prompts.

Rank equality is what the gates read, not the model ID : a session
running on 4.8 where the primary is opus-5, or on Fable 5 where the
primary is fable-5.1, is a **match**, not a fallback — no degraded-mode
directives. The tie does not survive the `*` though : there Opus 5 and
the Fables are out on behaviour, not on rank, so none of them matches
an `A*` / `B*` primary.

## Availability gate — by Claude Code version

The `/model` picker is baked into the Claude Code build : a model the
build does not list cannot be selected, so recommending it is noise.
**First step of every run**, before any tier work :

1. Read the version : `$CLAUDE_CODE_VERSION` (set in this container ;
   fallback `claude --version`). Unreadable → assume the oldest
   supported build (no model with a *Min Claude Code* value).
2. Every model whose *Min Claude Code* is above the running version is
   **absent** : never name it — not in the context message, the Model
   line, a ladder, a legend, or a STATUS cell. It drops out of every
   ladder and its rank-tied sibling takes the slot (`fable` → `fable-5`
   below 2.1.258). Nothing else in this file changes.

Only Fable 5.1 carries a minimum today (2.1.220 verified without it,
2.1.258 verified with it). Add a value to the column when a new model
ships ; the ladders never need editing for it.

## Classifier-sensitive gate — by framing, not by topic

The gate fires on **offensive framing**, not on the topic. Same code
read to *understand* it (Fable OK) versus to *exploit* it (gate fires).

**Signal words in the session description** — case-insensitive :

```
exploit, shellcode, bypass, crack, jailbreak, adversarial, attack,
PoC CVE-, circumvent, keylog, rootkit, DKOM, EDR bypass,
anti-cheat bypass, DRM bypass, phishing, botting, hash cracking
```

**Non-signals** — these describe RE / security work that Fable handles
fine :

```
reverse to understand, port asm, extract state machine, document
format, audit, threat model, harden, sec review, protocol impl
```

Effect when the gate fires :
- **Classifier-free set** locks : Opus 4.8, Opus 4.7, Sonnet 5, Haiku 4.5.
- **Prone set drops out** : Opus 5 (cyber classifiers), Fable 5.1 and
  Fable 5 (cyber + bio + frontier-LLM + reasoning-extraction + general
  harms — 5.1 fires less than 5, but not zero).
- Tier A ladder becomes `opus-4.8 → opus-4.7 → sonnet-5` (Fable and
  Opus 5 dropped).
- Tier B ladder becomes `opus-4.8 → opus-4.7 → sonnet-5` (Opus 5
  dropped ; 4.8 takes the primary slot). A* and B* are then identical.
- Tier C/D primaries unchanged (already classifier-free).
- Session tier is printed with a `*` suffix (`Tier A*`, `Tier B*`, …).
- Prepare-plan announces in the pre-question context : "classifier-
  sensitive framing detected — classifier-free ladder locked".

Fallback rule if unsure : lean toward *not* firing. The user picks
another option if the classifier bites — cheaper than losing Fable on
analytical RE.

## Tiers

| Tier | Role | Ladder (normal) | Ladder (`*`, gate fired) |
|---|---|---|---|
| **A** | Max reasoning | `fable` → `opus-5` → `opus-4.8` → `opus-4.7` | `opus-4.8` → `opus-4.7` → `sonnet-5` |
| **B** | Default | `opus-5` → `opus-4.8` → `opus-4.7` → `sonnet-5` | `opus-4.8` → `opus-4.7` → `sonnet-5` |
| **C** | Specified execution | `sonnet-5` → `opus-4.7` | (same) |
| **D** | Mechanical / sub-agents | `haiku-4.5` → `sonnet-5` | (same) |

`fable` resolves per the availability gate (`fable-5.1` from 2.1.258,
`fable-5` before) ; the other Fable is a rank-5 match, not a ladder
entry. `opus-5` and `opus-4.8` are adjacent in A and B because they
tie at rank 4 — running on either is a match for the tier, and neither
triggers degraded mode. The `*` column drops `opus-5` and hands the
primary slot to `opus-4.8`.

## Base tier by session type

| Session type | Base tier |
|---|---|
| Architecture / approach decision | A |
| Exploratory / ambiguous code (unreproduced bug, unknown area) | A/B |
| Specified feature (clear DoD) | B |
| Migration | B risky / C mechanical |
| Tests-only | C |
| Doc | B prose / C reference |
| Ops / CI / deploy | B |
| Bulk mechanical (renames, codemod) | C (+ D fan-out) |
| Review / verification | B |
| Urgent hotfix (prod down) | B |
| Spike / throwaway POC | C |
| Dependency upgrade | C (B if major breaking) |
| Security (audit, vuln fix) | A/B |
| Perf (profiling + fix) | B |
| UI / CSS / visual integration | C (B if component architecture) |
| One-shot analysis script | C/D |
| Config / env / flags | C (B if prod) |
| Release / changelog / versioning | C |
| Bug fix (reproducible, scoped) | B/C |
| Refactor (behavior-preserving) | B (A if cross-cutting) |
| Third-party API integration | B |
| Data pipeline / ETL | B semantics / C plumbing |
| Observability | C (B if designing strategy) |
| Build tooling / dev-env | C (B if team-breaking) |
| CI failure diagnosis | B flaky / C named cause |
| Prompt / skill / agent engineering | B |
| CRUD endpoint on established patterns | C |
| Frontend architecture (store, routing, SSR) | B |
| SSR / hydration bug | B |
| Reverse proxy / TLS / Nginx | B prod / C local |
| Docker image / compose | C (B if prod pipeline) |
| Realtime (WebSocket / SSE) | B |
| Caching layer (Redis / HTTP) | B |
| Background jobs / queues / cron | B semantics / C wiring |
| DB query optimization / indexing | B |
| Rust ownership-heavy / unsafe / FFI | B (+1 → A for unsafe/FFI) |
| Package publishing | C |
| RE — analytical investigation | A |
| RE — port of a proven spec | B (+1 → A if contested) |
| RE — mechanical extraction | C (+ D fan-out) |

Rules :
- Unlisted → nearest row + modifiers ; nothing fits → B.
- Stack never sets the tier — work type does.

## Modifiers (±1, clamped A..D)

- **+1** if : ambiguity · hard to reverse (prod data, deploy, public
  schema/API) · prior failure at current tier · pivot session · no test
  harness.
- **−1** if all : mechanically verifiable DoD · bounded diff · repeats
  established pattern.

## Decision procedure (per session)

```
0. Availability gate         → drop absent models from every ladder
1. Session type              → base tier
2. Modifiers ±1              → final tier (clamped A..D)
3. Classifier framing gate   → `*` suffix + adjust ladder (tier A only)
4. Planning session ?        → Fable criteria (skip if gate fired)
5. Print : tier[*] + ladder + degraded directives if fallback likely
```

## Planning session — Fable if ≥1 criterion (gate NOT fired)

1. ≥3 sessions with dependencies.
2. Approach not settled.
3. Hidden-constraint domain (legacy, unknown codebase, RE analytical).
4. Re-plan after broken plan.
5. High error cost (schema, public API, irreversible migration).

None → Opus 5. Gate fired → Opus 4.8 (Fable and Opus 5 off).

## Degraded mode (tier A/B on a fallback model)

- Tighter literal spec (4.7 doesn't generalize intent).
- Split : explore/decide, then implement.
- Sonnet verification sub-agent before DoD.

## Sub-agents

| Delegated task | Model |
|---|---|
| Grep / localisation / inventory | Haiku |
| Multi-file read + synthesis | Haiku volume / Sonnet nuance |
| Independent verification / review | Sonnet |
| Parallel alternative attempt | Sonnet |
| Substantial isolated sub-impl | Sonnet |
| Final synthesis / decisions | never delegated |

Bash permissions don't propagate — pre-grant in `settings.local.json`.

## Edge cases

- Mixed session → split ; if unavoidable, tier of most demanding sub-work.
- Retry after failure → one tier up, never same tier + same prompt.
- Between two tiers → higher early in plan, lower late + harnessed.
- Tight usage limits → degrade C→D first, never the pivot session.
