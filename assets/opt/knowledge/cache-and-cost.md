# Prompt caching and what a session costs

Full anatomy of a real session — **2026-09-28, farm campfire**, 6 h 17 of work,
measured from its own transcript rather than modelled.

> Figures extracted from
> `~/.claude/projects/-workspace/5a36df01-608e-476d-bd9b-6a8315b03c48.jsonl`,
> field `message.usage`, de-duplicated on `message.id`.
> Opus 5 rates: **$5 / M input**, **$25 / M output** (Anthropic first-party
> grid, table dated 2026-06-24 — re-check if it has moved).
>
> ⚠ The arithmetic below is Opus 5 throughout, because that is the model the
> session ran on. **Opus 5.5 is cheaper** — $4 / $20, and cache reads at $0.20
> instead of $0.50 — so on 5.5 every dollar figure here is roughly 0.6× to
> 0.8× what it shows, and the *read* share shrinks faster than the rest. The
> ratios, the shapes and the levers are unchanged; only the constants move.
> Per-model prices and the extension version each model needs:
> `/opt/devcontainer/base/skills/prepare-plan/MODELS.explained.md`.

---

## Contents

- [1. The principle in one sentence](#1-the-principle-in-one-sentence)
- [2. When the cache is written, when it is read](#2-when-the-cache-is-written-when-it-is-read)
- [3. The four lines on the bill](#3-the-four-lines-on-the-bill)
- [4. The TTL window](#4-the-ttl-window)
- [5. This session, for real](#5-this-session-for-real)
- [6. The context curve](#6-the-context-curve)
- [7. Compaction, seen from the bill](#7-compaction-seen-from-the-bill)
- [8. What breaks the cache](#8-what-breaks-the-cache)
- [9. The levers, by effectiveness](#9-the-levers-by-effectiveness)
- [10. How far down can you get?](#10-how-far-down-can-you-get)
- [11. Retrospective: this session, split up](#11-retrospective-this-session-split-up)
- [12. Check it yourself](#12-check-it-yourself)

---

## 1. The principle in one sentence

**The API has no memory. Every call resends the whole conversation from the
start.** Caching does not change what is sent — it changes what processing it
costs.

```
Call #1       →  [system][prompt 1]
Call #2       →  [system][prompt 1][reply 1][prompt 2]
Call #3       →  [system][prompt 1][reply 1][prompt 2][reply 2][prompt 3]
Call #588     →  [........ 832,000 tokens ........]
                  ↑
                  all of that goes back over the wire, on EVERY call
```

With no cache, call #588 is billed 832 k tokens at full price. With the cache,
the part already seen is billed **one tenth**.

---

## 2. When the cache is written, when it is read

It is a **prefix match**, byte by byte, from the very start of the prompt. The
server compares what you send against what it has already seen, and cuts at the
first divergence:

```
  what you send :  [══════════ identical to the last call ══════════][   new   ]
                    └──────────────── READ  (× 0.1) ────────────────┘└ WRITE ┘
                                                                       (× 2)
```

- **READ** — everything already cached **and unchanged**. Grows every turn.
- **WRITE** — the part not in it yet: the new tool_result, the new message. In
  steady state, **800 to 1,500 tokens per turn**.

A typical turn from this session, measured:

```
t+203min   read  = 639,000 tokens  →  $0.3195
           write =   1,275 tokens  →  $0.0128
           output=   1,360 tokens  →  $0.0340
                                      ───────
                                      $0.3663  for a single turn
```

The write is negligible. **All of the cost is in the re-read.**

### Prompt order matters

Rendering happens in this order, and the cut is made at the first divergence:

```
  [ tools ] → [ system ] → [ messages ............................. ]
     ↑            ↑           ↑
  position 0    stable      volatile
```

A change at position 0 invalidates **everything** after it. That is why a
timestamp in the system prompt is catastrophic, and why a new message at the end
of the conversation costs nothing: it comes after all the rest.

---

## 3. The four lines on the bill

| Line | Multiplier | On Opus 5 | When |
|---|---|---|---|
| `input_tokens` | **1×** | $5.00 / M | never cached (prefix too short, or no breakpoint) |
| `cache_creation_input_tokens` TTL 5 min | **1.25×** | $6.25 / M | writing a short cache |
| `cache_creation_input_tokens` TTL 1 h | **2×** | $10.00 / M | writing a long cache ← **this session** |
| `cache_read_input_tokens` | **0.1×** | $0.50 / M | re-reading a valid cache |
| `output_tokens` | **1×** | $25.00 / M | **never cached, never reduced** |

Two counter-intuitive things:

1. **Writing a 1 h cache costs double a normal read.** It only pays from the
   3rd request onwards (`2 + 0.1 + 0.1 = 2.2` against `3`). For the 5 min TTL:
   it pays from the 2nd (`1.25 + 0.1 = 1.35` against `2`).
2. **Output is never cached.** On a short session it dominates; on a long one it
   becomes marginal. Here: $12.95 of output against $136.59 of re-reading.

---

## 4. The TTL window

The TTL **slides**: every read resets it.

```
 call 1           call 2          call 3                          call 4
   │ WRITE          │ READ          │ READ                          │ READ
   ▼                ▼               ▼                               ▼
───┬────────────────┬───────────────┬───────────────────────────────┬──────▶
   ├──── TTL 1h ────╳ (cancelled)
                    ├──── TTL 1h ───╳ (cancelled)
                                    ├─────────── TTL 1h ────────────╳
                                                                    ├─ 1h ─▶
```

As long as the gap between two calls stays under the TTL, **the cache never
dies**, whatever the total duration. A 6 h session with a call every 20 min pays
one initial write and nothing more.

The case that hurts:

```
 call 3                                             call 4
   │ READ                                             │ ⚠ FULL RE-WRITE
   ▼ $0.32                                            ▼ $6.40
───┬──────────────────────────────╳──────────────────┬──────────▶
   ├─────────── TTL 1h ───────────╳ expired           │
                                   ←── 25 min dead ──→
```

On a 640 k context: $0.32 warm, **$6.40 after expiry**. A factor of **20×**.

### What happened here

| | |
|---|---|
| Gaps > 2 min between two calls | **33** |
| Longest gap | **34 min** |
| Configured TTL | **60 min** |
| Re-writes caused by an expiry | **0** |

The longest silence of the session — 34 min, while the campfire tests ran —
stayed comfortably inside the window. **The cache never expired once.** The
1.57 M tokens written are all ordinary incremental writing, not repair.

---

## 5. This session, for real

```
╔══════════════════════════════════════════════════════════════════╗
║  Session 5a36df01 · 2026-09-28 · 07:02 → 13:19  (6 h 17)         ║
╠══════════════════════════════════════════════════════════════════╣
║  User messages                     56                            ║
║  Tool results                     559                            ║
║  Actual API calls                 588   (≈ 10.5 per message)     ║
║  Final context            832,662 tokens (of 1 M)                ║
╚══════════════════════════════════════════════════════════════════╝

  LINE                    TOKENS          PRICE       SHARE
  ─────────────────────────────────────────────────────────────────
  cache_read         273,172,760       $136.59   ████████████ 83 %
  cache_write (1h)     1,570,732        $15.71   █             9 %
  output                 518,159        $12.95   █             8 %
  uncached input           1,101         $0.01                 0 %
  ─────────────────────────────────────────────────────────────────
  TOTAL                                $165.25

  With no cache at all               $1,386.68   ← × 8.4
  Saved                              $1,221.43
```

The one figure that sums it up:

```
   273,172,760 tokens read     ÷   1,570,732 tokens written   =   174 : 1
```

**Every token written to cache was re-read 174 times.** That is the
amortisation, and it is why the 1 h TTL at 2× is a good buy here while it would
be absurd on a three-turn conversation.

Average cost per user message: **$2.95**.

---

## 6. The context curve

Context only grows, so the cost per turn grows with it. Cumulatively that is
**quadratic**, not linear.

```
context
  1M ┤                                                      ← Opus 5 ceiling
     │                                                ▁▂▃
800k ┤                                          ▂▄▆███████  ╳ compaction
     │                                     ▂▄▆██████████████     ↓
600k ┤                            ▁▂▄▆████████████████████    ▆▆▆▆▆ 404k
     │                   ▂▄▆█████████████████████████████
400k ┤           ▂▄▆████████████████████████████████████
     │     ▄▆████████████████████████████████████████
200k ┤ ▂▆██████████████████████████████████████████
     │█████████████████████████████████████████████
   0 └──┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬───▶
       30   60   90  120  150  180  210  240  270  300  330  360  min
```

What a single turn costs, at four points in the session:

```
  t+  0 min   ctx  53 k   ▏             $0.027 of re-reading
  t+ 53 min   ctx 295 k   ████          $0.148
  t+135 min   ctx 479 k   ███████       $0.239
  t+203 min   ctx 640 k   █████████     $0.320
  t+360 min   ctx 832 k   ████████████  $0.416
```

**The same work costs 15× more at the end than at the start.** Not because the
task got harder — because there are 780 k tokens of history to re-read before
answering.

### Cost per 30-minute slice

```
 t+  0  ████                      $4.73    45 calls
 t+ 30  ██████████████████       $18.33   120 calls  ← burst of tool use
 t+ 60  █████████                 $9.48    45
 t+ 90  █████████████            $13.05    55
 t+120  █████████████            $13.88    52
 t+150  █████████████████████    $21.84    73
 t+180  █████████████████        $17.63    52
 t+210  ██                        $1.97     5         ← waiting on tests
 t+240  █████████                 $9.53    25
 t+270  ██████████████████████   $22.48    55
 t+300  ████████                  $8.15    19
 t+330  ████████                  $8.25    19
 t+360  ███████████████          $15.93    23         ← $7.78 of it compaction
```

At t+210, five calls in 30 minutes cost $1.97 — that is the "waiting for the
runs to finish" block. Cost follows activity, not the clock: **a session that is
open but silent costs nothing.**

---

## 7. Compaction, seen from the bill

At **t+372 min** the context was approaching 832 k and compaction fired: the
history was summarised, so **the prefix changed**, so all of it had to be
rewritten.

```
  BEFORE                                 AFTER
  ┌───────────────────────────┐          ┌──────────────┐
  │ 832 k of context          │   ───▶   │ 404 k        │
  │ read $0.416 / turn        │          │ read $0.202  │
  └───────────────────────────┘          └──────────────┘
              cost of the operation : $3.84
              (377,656 tokens × $10/M of write, plus the output)
```

A normal turn costs $0.37. **That turn cost $3.84** — more than an average user
message. But it halved the cost of every turn after it:

```
  saving per turn after compaction :  $0.416 − $0.202  =  $0.214
  pays for itself after            :  $3.84 / $0.214  ≈  18 turns
```

The session ran well past 18 turns, so the operation was a win. **But that is
exactly the reasoning that argues for a fresh chat**: 15 k of context instead of
404 k costs $0.0075 a turn instead of $0.202, i.e. **27× less**, and the initial
write costs $0.15 instead of $3.84.

---

## 8. What breaks the cache

Anything that changes a byte **before** the end of the prefix. In order of
severity:

| What changes | What it invalidates |
|---|---|
| A tool definition (added, removed, **reordered**) | everything — tools are at position 0 |
| The model | everything — caches are per-model |
| The system prompt (one word, a date, a flag) | everything after it |
| A `tool_choice`, an image, turning thinking on | messages only |
| A new message at the end of the conversation | **nothing** ✅ |

The classic silent killers, worth hunting in any code that builds a prompt:

- `Date.now()` / `datetime.now()` in the system prompt → a different prefix on
  every request, **zero hits, ever**
- a UUID or request id placed early
- `JSON.stringify` of an object whose key order is not guaranteed
- a tool set that varies per user
- conditional sections of the system prompt (`if flag: system += …`) → one cache
  variant per combination of flags

The symptom reads directly: `cache_read_input_tokens` stays at 0 on requests
whose prefix is in fact identical.

One subtlety that matters in practice: **the lookup window only goes back 20
content blocks.** An agentic turn that chains more than 20 tool_use /
tool_result pairs can miss the anchor point on the next turn, and cause a silent
miss despite a correct prefix.

---

## 9. The levers, by effectiveness

### ① Open a fresh chat with a handoff — × 27

The only lever that changes the order of magnitude. It resets the curve.

```
   832 k of context  →  $0.416 / turn
    15 k of handoff  →  $0.0075 / turn
```

The handoff (`CAMPFIRE-NEXT-SESSION.md`) is ~1,500 words and holds everything
that matters. The other 830 k were file reads, test output and dead ends —
re-read in full on every turn, for hours, serving nothing.

### ② Subagents — × 10 to × 50 on the task concerned

A fan-out that reads 20 files does it in **its own** context and returns 300
tokens of conclusion. The 20 files never enter the main context, so they are
**never re-read over the next 200 turns**.

```
  without a subagent :  80 k of files × 200 turns × $0.50/M  =  $8.00
  with a subagent    :  0.3 k × 200 turns                    =  $0.03
                        + the subagent's own cost            ≈  $0.30
```

This is §7 of CLAUDE.md, and its basis is as much economic as qualitative.

### ③ Stay inside the TTL window — × 20, but binary

Only plays on one case: being inside the 60 min (× 0.1) or outside it (× 2).
Here the lever never had to play — no gap exceeded 34 min.

### ④ Don't re-read what you've already read

A `Read` on a file already in context adds a copy, and **both** are re-read on
every turn after that. Same for redundant `cat`s and repeated `git diff`s.

---

## 10. How far down can you get?

This section is not intuition: the model below reproduces the real bill **to
0.0 %**, so its extrapolations are worth something.

### The model

```
      read_total  =  T · F   +   g · T² / 2
                     ╰────╯       ╰──────╯
                     linear      quadratic
                   the baseline  the history
```

| Symbol | Meaning | Measured here |
|---|---|---|
| `T` | number of API calls | **588** |
| `F` | baseline reloaded on every call — system + CLAUDE.md + memory + tool schemas | **53,442 tk** |
| `g` | context growth per call | **1,399 tk** |

```
  predicted : 588 × 53,442  +  1,399 × 588² / 2  =  273.2 M
  measured  :                                       273.2 M     ✅ 0.0 % off

     of which baseline re-read 588 times    31.4 M   (12 %)   ← INCOMPRESSIBLE
     of which quadratic history            241.8 M   (88 %)   ← divisible by N
```

**88 % of the re-read cost is the quadratic term.** It is that term, and only
that term, that splitting attacks.

### Splitting into N sessions

With `N` sessions of `T/N` calls each, the quadratic term is divided by `N` —
but **each session re-pays the baseline `F` as a write, at 2×**. Hence a
trade-off, and an optimum.

```
  N   turns/sess   final ctx      read   baseline w     TOTAL
  ──────────────────────────────────────────────────────────────
   1        588        876k     $136.62      $0.53      $137.15
   2        294        465k      $76.17      $1.07       $77.23
   4        147        259k      $45.94      $2.14       $48.08
   8         74        156k      $30.83      $4.28       $35.10
  12         49        122k      $25.79      $6.41       $32.20
  15         39        108k      $23.77      $8.02       $31.79   ◄ optimum
  20         29         95k      $21.76     $10.69       $32.45
  30         20         81k      $19.74     $16.03       $35.77
  60         10         67k      $17.73     $32.07       $49.79   ↑ it climbs back
```

The optimum is not an empirical setting, it derives:

```
        N* = T · √( g·r / 2·F·w )         r = 0.1×   w = 2×

           = 588 · √( 1399 × 0.5e-6 / (2 × 53,442 × 10e-6) )  =  15.0
```

> **≈ 15 sessions of ~39 API calls each → $31.79 instead of $137.15, i.e. × 4.3.**

And **past that it degrades**: at 60 sessions you re-pay a 53 k-token baseline
60 times at $10/M, which costs more than the history you avoid. Splitting
forever is counter-productive.

### In tokens — and why the curve is not the same

```
  N     read     base w   incr w   output     TOTAL    vs N=1     $
 ───────────────────────────────────────────────────────────────────────
  1   273.3 M     0.1 M    0.8 M    0.5 M    274.7 M    × 1.0   $137.15
  2   152.3 M     0.1 M    0.8 M    0.5 M    153.8 M    × 1.8    $77.23
  4    91.9 M     0.2 M    0.8 M    0.5 M     93.4 M    × 2.9    $48.08
  8    61.7 M     0.4 M    0.8 M    0.5 M     63.4 M    × 4.3    $35.10
 15    47.5 M     0.8 M    0.8 M    0.5 M     49.7 M    × 5.5    $31.79 ◄ $ min
 30    39.5 M     1.6 M    0.8 M    0.5 M     42.4 M    × 6.5    $35.77
 60    35.5 M     3.2 M    0.8 M    0.5 M     40.0 M    × 6.9    $49.79
```

**In tokens, splitting always wins** — the total column falls all the way. **In
dollars it does not**, because a written token costs 20× a read one: at N=60 you
have 6.9× fewer tokens but you pay more for them.

The measured session, in raw volume:

```
  275,262,752 tokens billed   for   832,662 tokens of final context
  ──────────────────────────────────────────────────────────────────────
  → every token of context was re-billed ~331 times on average
```

### A workable session size

The theoretical optimum `N*=15` gives sessions of **39 API calls**, which — at
the measured rate of 10.5 calls per user message — is barely **4 exchanges per
session**. That is unworkable: you would spend your time writing handoffs, and
every handoff is a chance to lose context that mattered.

The gain falls off steeply, which leaves room:

```
   1 → 4  sessions :  −$89   ████████████████████  (65 % of the total gain)
   4 → 8  sessions :  −$13   ███
   8 → 15 sessions :   −$3   █
```

> **Workable zone: N = 3 to 6.** That is ~100 to 200 API calls, ~10 to 20
> exchanges, 1 h 30 to 2 h of work, context capped around 200–260 k. You
> capture most of the saving with sessions still long enough to hold a line of
> reasoning.

And the criterion is not the token counter, it is **the task boundary**: one
session = one coherent objective. Cut when the objective changes, when a
decision has been taken and the exploration that led to it no longer serves, or
when a long wait begins. Never cut in the middle of a debugging session — the
cost of re-establishing context far exceeds the saving.

A secondary but real argument: **an 832 k context is not only expensive, it is
noisy.** It holds the dead ends, the stale reads and the test output already
acted on. Splitting is therefore not only a cost optimisation, it is also a
signal reset — provided the handoff is good.

### The wall

```
  $137 ─┐
        │╲
        │ ╲
   $48 ─┤  ╲___
        │      ╲──___
   $32 ─┤            ╲______•──────────╱   ← it climbs back
        │                   N*=15
   $16 ─┼ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  floor T·F = $15.71
        └────┬────┬────┬────┬────┬────┬──▶ N
             4    8   12   16   20   24
```

The floor is `T · F`: **all 588 calls have to carry the 53,442 tokens of
baseline**, whatever you do. To get under it you have to reduce `F` itself — a
shorter CLAUDE.md, fewer tools loaded up front (which is exactly what deferred
tool loading does: schemas are fetched on demand), a leaner memory. Halving `F`
moves the optimum to N ≈ 21 and the cost to **~$19**.

### And subagents?

They attack a **different** term. Decomposition of the measured growth:

```
  total context growth               822,499 tk
  ├─ my output (thinking + text)     518,159 tk   ████████████  63 %
  └─ tool results + reminders        304,340 tk   ███████       37 %
```

Counter-intuitive but clear: **it is not tool output that fills the context, it
is the reasoning itself.** In this session no tool result exceeded 2 k tokens —
no large `Read`, no massive dump.

That is precisely what makes subagents effective: a subagent does not only take
tool results out of the main thread, it takes **all the reasoning that goes with
them**, and returns only a conclusion.

```
  without delegation :  the main thread gains k·g tokens, re-read (T−i) times
  with delegation    :  it gains ~300 tokens, and the subagent pays its own baseline
```

Hence the rule, which has a precise shape:

```
     gain  ≈  (context avoided) × (calls remaining) × $0.50/M
```

The gain is **proportional to the number of turns remaining**. Delegating an
exploration at turn 50 of 588 pays enormously; delegating it at turn 550 pays
almost nothing. **A subagent's value decays with when you call it** — which is
the argument for delegating early, before you know whether it will be worth it.

### Combining them

The two levers multiply, because they touch different variables of the same
product `g · T²`: splitting divides by `N`, subagents reduce `g` **and** the
main thread's `T`.

```
  1 session, no subagents                                 $137
  15 sessions                                              $32
  15 sessions + aggressive delegation (g −40 %, T −30 %)   ~$25 – 30
  absolute floor (baseline × number of calls)              $16
```

Short answer to "how far?": **about × 4 to × 5, not × 50.** The 53 k-token
baseline reloaded on every call is a wall, and it is the wall you would have to
attack to go further.

---

## 11. Retrospective: this session, split up

The boundaries below are not arbitrary — they come out of analysing the 56 user
messages and the real topic pivots.

```
 ph  length  calls   context         read      $     subject
 ───────────────────────────────────────────────────────────────────────────
  A  62min    165    53k →  284k    27.9M  $13.93   fixed spawns → campfire-spots.js
                                                     → CAMPFIRE-SPOTS.md → commit
  B  73min    125    56k →  231k    18.0M   $8.99   E2E harness, multi-map scripts,
                                                     campfire-wall dashboard
  C  39min     79    56k →  167k     8.8M   $4.41   working the runs,
                                                     debug stage / kill / ban
  D  37min     73    56k →  159k     7.8M   $3.92   mechanics: causes of death,
                                                     Kapha, vit_penalty, weight
  E 109min     98    56k →  194k    12.2M   $6.12   gear campaign: cards,
                                                     rings, antenna, reflect
  F  50min     41    56k →  114k     3.5M   $1.74   launching the final test,
                                                     waiting
  G  26min     30    56k →   98k     2.3M   $1.16   meta: cache, TTL, cost
 ───────────────────────────────────────────────────────────────────────────
     7 sessions · context peak 284k instead of 832k
```

```
  TOTAL IF SPLIT   $65.36
  ACTUAL          $165.25      → × 2.5
```

**Only × 2.5**, against × 4.3 for the ideal theoretical split — because the real
phases are uneven: A alone is 165 calls. Cutting it in two (research/plan, then
implementation+doc) gives 8 sessions, a peak at **182 k**, and ~$61. Past that
you are into marginal gains.

### What the retrospective mostly shows

**Phase G should never have been there.** The whole cache / TTL / cost
discussion has **no dependency** on the campfire context — all it needed was the
transcript, read by script. It ran at ~425 k of context:

```
  as it actually ran   $6.38
  in a fresh chat      $1.16     → × 5.5 for nothing
```

That is the most expensive pattern and the easiest to avoid: **a complete change
of subject without a change of session.** There is no trade-off to make and no
context to risk losing — just a reflex to acquire.

**The context peak matters as much as the bill.** 832 k → 284 k is also 548 k
less noise: the campfire runs invalidated by the `CR_REFLECTSHIELD` chain bug,
the gear dead ends, the test output already acted on. All of it re-read on every
turn for hours while being stale.

**Where to cut, concretely:**

| Signal | Example here |
|---|---|
| A deliverable is finished and committed | end of A — the doc is generated and pushed |
| The tool is built, you move on to using it | end of B → C |
| A decision is taken, the exploration that led to it no longer serves | end of D — `vit_penalty` understood, the rathena greps are dead |
| A long wait begins | F — the test is running, nothing to carry |
| **The subject changes completely** | **G — nothing to do with the farm any more** |

And where **not** to cut: in the middle of a debugging session, between a
hypothesis and its check, or before a test result has been interpreted.

---

## 12. Check it yourself

The counters are in every API response and logged in the transcript:

```bash
node -e "
const fs=require('fs');
const P=process.argv[1];
const byId=new Map();
for(const l of fs.readFileSync(P,'utf8').split('\n').filter(Boolean)){
  let e; try{e=JSON.parse(l)}catch{continue}
  const m=e.message;
  if(!m||!m.usage||e.type!=='assistant') continue;
  if(!byId.has(m.id)) byId.set(m.id,m.usage);   // ← de-duplication IS MANDATORY
}
const r=[...byId.values()], S=k=>r.reduce((a,u)=>a+(u[k]||0),0);
const cost = S('cache_read_input_tokens')*0.5e-6
           + S('cache_creation_input_tokens')*10e-6
           + S('input_tokens')*5e-6
           + S('output_tokens')*25e-6;
console.log('API calls :', r.length);
console.log('read  :', S('cache_read_input_tokens').toLocaleString());
console.log('write :', S('cache_creation_input_tokens').toLocaleString());
console.log('output:', S('output_tokens').toLocaleString());
console.log('TOTAL : \$'+cost.toFixed(2));
" ~/.claude/projects/-workspace/<session-id>.jsonl
```

⚠️ **De-duplicating on `message.id` is not optional.** The transcript writes
several records per API response (one per content block), all carrying the
**same** `usage` object. Without de-duplication you count 1,279 records instead
of 588 responses, and the total is overstated by a factor of 2.1 — that is the
mistake I nearly published before checking.

The `cache_creation` field additionally gives the per-TTL breakdown:

```json
"cache_creation": { "ephemeral_1h_input_tokens": 5959,
                    "ephemeral_5m_input_tokens": 0 }
```

Here: **100 % in 1 h, 0 % in 5 min** — which confirms the session's
configuration without having to take it on trust.

---

## In one picture

```
     what you think you pay for        what you actually pay for
   ┌──────────────────────┐        ┌──────────────────────────────┐
   │ Claude's             │        │ re-reading the history 83 %  │
   │ answers              │        │ writing the cache       9 %  │
   │                      │        │ the answers             8 %  │
   └──────────────────────┘        └──────────────────────────────┘
                                    ↑
                                    83 % of the cost is past you are
                                    carrying, not work you are doing
```

So the useful question is never "is the cache warm". It is **"what am I dragging
through this context that no longer serves, and re-paying for on every
turn"**.
