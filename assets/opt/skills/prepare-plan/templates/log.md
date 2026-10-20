# Template — `LOG.md` (multi-session)

> Part of `/prepare-plan` — read on demand by the branch that renders this
> file. Substitute every `{{placeholder}}` before writing ; the skill's
> placeholder check enforces zero leftovers.

````markdown
# Log — {{feature_title}}

> Two parts. **Carry-forward** (right below) is the only part a session
> reads by default : curated, ≤ ~30 lines, pruned at every DoD. The
> **journal** after the rule is append-only history — one section per
> delivered session, newest at the bottom, opened on demand.

## Carry-forward

_What a later session must know before touching anything : active
gotchas, constraints discovered on the way, workarounds still in place.
Delete a line the day it stops applying — the journal keeps the history._

- _(empty — first session seeds it)_

---

Each journal section follows the same shape :

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
