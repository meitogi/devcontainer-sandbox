# navigator-pending-migration-fix

Standalone reference for `navigator-pending-migration-fix.py`. The `.py`
is the source of truth (idempotent, runs in `run-all.sh`). This doc
explains the *why* — for the next contributor who bumps
`CLAUDE_CODE_VERSION` and asks « do we still need this hack? ».

## Symptom

Extension activation crashes with :

```
PendingMigrationError: navigator is now a global in nodejs
    at get (extensionHostProcess.js:805:7210)
    at new ZodObject (anthropic.claude-code-<ver>/extension.js:166:73934)
```

Where it surfaces :

- « Claude VSCode » output channel, on activation.
- `~/.vscode-server/data/logs/*/exthost*/remoteexthost.log`.

User-visible : Claude panel fails to open. The activity-bar icon
flashes and dies. No webview, no command works.

## Root cause

Recent VS Code installs `globalThis.navigator` as a *PendingMigration
getter* — a `configurable: true` accessor that throws on **any access**,
including `typeof navigator`. The intent is to push extensions to
migrate their environment-detection code now that Node has `navigator`
as a real global (Node 21+).

Claude Code 2.1.x bundles a Zod version whose schema construction
reads `navigator` at module load (Zod's environment-detection branch
for browser vs Node). The read hits the PendingMigration getter →
throws → activation aborts.

The crash is upstream of any Claude Code logic — it triggers before
the activation function is called, during top-level `require`.

## Strategy

Prepend a tiny IIFE to `extension.js` that overwrites the getter with a
plain `value: undefined` data property :

```js
try {
  Object.defineProperty(globalThis, 'navigator', {
    value: undefined,
    writable: true,
    configurable: true,
  });
} catch (e) {}
```

After redefinition :

- `typeof navigator` is a primitive lookup — no getter invocation, no
  throw. Returns `"undefined"`.
- `navigator.someProp` would TypeError, but the bundle never reaches
  those reads because every one is gated by a `typeof navigator !==
  "undefined"` check (see safety audit).

The PendingMigration getter is `configurable: true`, which is what
makes the `defineProperty` overwrite legal. If a future VS Code build
flips it to `configurable: false`, this strategy stops working and the
patch raises silently (the `try/catch` swallows the error — investigate
via the activation log).

## Safety audit

`grep` of the installed bundle (2.1.145, linux-arm64) :

- `navigator.userAgent` × 9 — Cloudflare detection, IE/msie/trident
  branches, UA parsing. All preceded by `typeof navigator !==
  "undefined"` or `navigator &&`.
- `navigator.product` × 4 — React-Native environment check (`product
  === "ReactNative"`). All guarded.

Setting `navigator` to `undefined` IS the Node-environment branch the
bundle was written for. Every browser path short-circuits at the guard
and falls through to the Node path. Net behavior identical to running
the bundle in Node without VS Code's PendingMigration wrapper at all.

**Re-verify the grep on every CC version bump** :

```
grep -ob 'navigator\.userAgent' extension.js | wc -l
grep -ob 'navigator\.product'   extension.js | wc -l
grep -ob 'typeof navigator'     extension.js | wc -l
```

If counts of `userAgent`/`product` grow without a matching `typeof
navigator` guard count, audit the new accesses manually.

## Idempotency

Sentinel marker at the head of `extension.js` :

```
/*__VSCODE_NAVIGATOR_PENDING_MIGRATION_FIX_v1__*/
```

The `.py` checks `if MARKER in content` and short-circuits with a YELLOW
`[1/1] already patched` line. Re-running `run-all.sh` after a partial
rebuild is safe.

The `_v1` suffix lets us cycle the marker if the strategy ever changes
(e.g. switching to `value: {}` instead of `value: undefined`) — bump to
`_v2`, the old marker won't match, the new IIFE prepends.

## Persistence

The patch only writes to one file : the Claude Code extension's
`extension.js`. It does NOT survive :

- VS Code extension reinstall (manual « Reinstall » in the UI)
- CC version bump (new extension dir, fresh bundle)
- `~/.vscode-server` wipe

It DOES survive a container rebuild because the Dockerfile re-runs
`run-all.sh` at build time :

- `Dockerfile.base:234` (the `COPY claude/vscode-ext-patchs/ …`)
  invalidates RUN 2's layer cache whenever any file under
  `vscode-ext-patchs/` changes.
- `Dockerfile.base:244` (RUN 2) invokes `run-all.sh`, which iterates
  every `.py` and runs it against the freshly-extracted extension.

So as long as the rebuild happens after the install, the patch is
re-applied automatically. No manual step.

## Retirement

This patch is a workaround for an upstream bug. Retire it when CC ships
a build whose bundled Zod no longer touches `navigator` at module load.

Three checks before deleting :

1. `grep -c 'navigator' extension.js` — the count should not have
   *increased* (a decrease is fine; new accesses behind guards are
   fine ; an unguarded access is a red flag).
2. Inspect the contexts : `grep -ob 'navigator' extension.js` and slice
   ±60 chars around each hit. Every hit should be inside `typeof
   navigator !== "undefined"` or a `navigator && navigator.x` guard.
3. Fresh install without the patch : remove the IIFE, reload VS Code
   window, watch the « Claude VSCode » output channel and
   `remoteexthost.log` for `PendingMigrationError`. Absent → safe to
   retire.

When retiring, delete both files together :

```
.devcontainer/claude/vscode-ext-patchs/navigator-pending-migration-fix.py
.devcontainer/claude/vscode-ext-patchs/navigator-pending-migration-fix.md
```

`run-all.sh` picks up the deletion automatically (alphabetical glob,
no entry for missing files).

## References

- `navigator-pending-migration-fix.py` — the patch itself (source of
  truth).
- `_common.py` — `banner`, `resolve_ext_dir`, `check_files` reused.
- `run-all.sh` — orchestrator.
- `Dockerfile.base` (RUN 2, around line 244) — invocation site.
- `.devcontainer/LESSONS.md` — entry `2026-06-12 navigator/Zod` for the
  incident context this patch came out of.
