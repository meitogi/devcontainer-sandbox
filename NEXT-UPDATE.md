# Pending the next release

Content changes that are **committed on `master` but not published**. Anything
listed here reaches no container until a release carries it.

This file exists because the repo has no CHANGELOG and nothing else tracks the
gap between "committed" and "shipped". `RELEASING.md` step 2 points here.

## How to check this file is complete

Do not trust the list — derive it. Everything under the paths below is baked
into the image, so a commit touching them since the last tag is unreleased:

```
git fetch --tags
LAST=$(git describe --tags --abbrev=0)
echo "last tag: $LAST  (package.json: $(python3 -c 'import json;print(json.load(open("package.json"))["version"])'))"
git log --oneline "$LAST"..HEAD -- assets/ bin/ stacks/ Dockerfile cc-versions.json
```

An empty log means nothing is pending and this file should hold only the
heading. A non-empty log with nothing listed below means the list rotted —
believe the log.

Paths that do NOT require a bump, per `RELEASING.md` step 2: docs (`*.md`),
`.github/`, `test/`.

## Pending

- **`36b777e` — `ghcr.io` in the firewall baseline.**
  `assets/etc-firewall/domains.d/00-base.txt` gains a read-only `[GET] ghcr.io`
  bounded to `/token` and `/v2/*`, so `docker manifest inspect` and curls
  against the registry v2 API work from the **client** side. The dind daemon
  always reached ghcr.io, so `docker pull` never needed it; what was blocked
  was asking which tags a release published without shelling into a container
  on dind. This image is itself served from ghcr.io, so every consumer met the
  same wall.

  Verified at commit time: `compile-policy.py --parse-only` yields
  `host=ghcr.io methods=['GET'] paths=['/token', '/v2/*']`, identical to the
  local override it was promoted from (proven in one project since
  2026-09-15), and `test/run-firewall-suites.sh` stays at 80 passed, 0 failed.

  Deliberately committed without a bump (decision, 2026-10-05): a release cycle
  for one domain entry is not worth it, and a 1.9.0 is expected to accompany
  the dogfood migration. **That release must carry this.** Until it does, the
  entry is live only in projects that keep it in their own
  `domains.local.txt`.

- **Two promoted lessons in `assets/opt/knowledge/`** (2026-10-05, from the v3
  rollout's generic-lesson arbitration).

  `assets/opt/knowledge/workspace-mount.md` is new, and indexed from
  `INDEX.md`. It documents the two POSIX gaps in the `/workspace` bind mount
  that fail **silently**: `flock` grants the exclusive lock to every caller,
  and `git worktree add` records an absolute container `gitdir:` that no
  host-side git client can follow. Both were measured in a project using this
  image, and both present as a logic bug in the project's own code — which is
  why they belong to the image and not to a project's LESSONS.

  `assets/opt/knowledge/wtf.md` gains the shell fact it was missing — a `wtf`
  command body runs under `/bin/sh`, which is `dash` here, so bash-only
  constructs (`/dev/tcp`, `[[ ]]`, arrays, process substitution) fail in a body
  that worked in an interactive shell.

- **`wtf.md` documented a flag that does not exist.** ⚠ This is a doc defect,
  not an addition. `:81` listed `--debug` as a dry-run and `:86` called it
  *"the only inspection mechanism"*. Measured 2026-10-05 against the shipped
  `/usr/local/bin/wtf` (3 997 880 bytes): `wtf docker usage --debug` answers
  `wtf: error: flag debug not found.`, `wtf --debug` answers
  `command not found`, and the binary carries no such flag string. The flag
  table entry is now struck through with the measurement, the claim is
  corrected, and the three "Debug recipes" that opened with
  `wtf <cmd> --debug` are renumbered without it. Anyone who followed that page
  was told to use a flag that errors out.

- **The baked skills are in English** (2026-10-05). `assets/opt/skills/` carried
  **99** French detections — `diagram/scripts/{export,check,merge,exca}.mjs` (83,
  dense technical comments), `tokens/tokens.skill.md` (12, a wholly French skill
  doc), plus single hits. All translated, identifiers / paths / commands / flags
  untouched, `node --check` clean on the four `.mjs`. Also `test/run-image-suites.sh`
  and `test/release-check.sh` comments, and a dangling French pointer in
  `test/build-progress.py` (it cites a `LOG.md § 2` this repo does not have — the
  pointer is now flagged in place rather than silently wrong).

  ⚠ **What is deliberately still French, and must stay**: the auto-trigger phrases
  in `watch-log` and `prepare-stack` (the user types them in French — translating
  them deletes the trigger), and the French STATUS fixture in
  `test/session-signals.test.sh`, whose assertion is literally *"a French legend
  line is not an open row"*. Translating that fixture deletes the test.

  How this was found: a project tree's copy of these skills was classified as dead
  — correctly, `slim_tree` removes it because the image ships the skill — and the
  image's own copy was never checked. "The project copy is dead" says nothing about
  the language of what replaces it.

## Known defects a release should carry, not yet committed

Listed here so a release does not go out without them being a deliberate
choice. These are **not** in the `git log` check above — nothing is committed
for them yet.

- **The `creds-sync` hook is never pruned.**
  `assets/opt/hooks/post-start.d/85-merge-creds-hooks.sh` resolves `SYNC_CREDS`
  to the workspace copy when it exists and the baked binary otherwise, then
  dedups **by command**: it only ever appends. So a project that migrates off
  the v2 layout — where the workspace copy is deleted because it is
  byte-identical to the baked one — ends up with **both** commands registered
  on `Stop` and `SessionEnd`, one of them naming a file that no longer exists.
  Measured on ragnarok after its migration, 2026-10-05: 4 entries, 2 distinct,
  one dead.

  Bounded: credentials still sync, because the baked command is registered and
  works. But a dead hook fires twice per session end, in a path whose whole
  rule is never to block Claude.

  Fix belongs in that fragment — prune any registered `sync-creds` command
  whose target does not resolve, then merge. It is not project-specific: it is
  the "v2 project script to baked binary" transition, so the dogfood migration
  will reproduce it exactly. Recorded as D100 in
  `plans/devcontainer-v3/LOG.md`.
