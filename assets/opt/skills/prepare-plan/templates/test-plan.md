# Template — `TEST-PLAN-<session-id>.md` (optional per session)

> Part of `/prepare-plan` — read on demand by the branch that renders this
> file. Substitute every `{{placeholder}}` before writing ; the skill's
> placeholder check enforces zero leftovers.

Scaffold only for sessions that ship **user-visible or platform-specific
behavior that the container can't validate** (macOS UN center, Windows
toast, Linux D-Bus, browser UI, host-installed CLI, etc.). Pure
container-testable code (refactors, backend logic, unit-testable
modules) doesn't need one.

Path : `plans/<feature>/TEST-PLAN-<session-id>.md`. Session ID matches
the LOG entry (`7b`, `3.5`, etc.). Modes §0.5 / §0.6 write
`TEST-PLAN.md` with no session-id — single prompt, single session.
Whenever the plan has a Part 1, its browser scenarios go in
`plans/<feature>/suites/<name>.mjs` — plan-scoped and gitignored like
`fixtures/` ; only the driver is committed.

## Triage through E2E FIRST — before writing a single manual step

*host vs container* is only the first axis. The second one decides how
much of the human's evening this costs, and it is the one that gets
skipped : **is this scenario machine-assertable, or is it a judgement?**

Sort every scenario before writing it up :

| Bucket | Test is | Goes in |
|---|---|---|
| **Machine-assertable** | a DOM query, a natural dimension, an HTTP status, a row count, a SQL result — no judgement call | **Part 1**, as a scenario in `plans/<feature>/suites/<name>.mjs`, run by `node /opt/devcontainer/base/skills/visual-loop/scripts/e2e.mjs` |
| **Already covered lower** | an L1/L2/L5 test asserts it | nowhere — cite the test name and move on |
| **Human judgement** | is it the *right* image, is the message *understandable*, does the motion jar, does the OS drag actually paint | **Part 2**, manual |

**Write Part 1 first, and actually run it.** A browser E2E harness ships with
the image — `/opt/devcontainer/base/skills/visual-loop/scripts/e2e.mjs`
drives the host Chromium over CDP holding one socket across steps, and asserts
against the DOM *and* against whatever in-page query bridge the suite names in
`meta.bridge`. Suites live per plan under
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
