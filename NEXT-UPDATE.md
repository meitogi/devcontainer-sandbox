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

Everything up to `d018b13` shipped in 1.9.4; the `v1.9.4` tag annotation lists
what that release carried.

- **`claude-account`** (new `bin/`, baked to `/usr/local/bin`) — switch a
  container between Claude subscriptions without a rebuild: `list`, `status
  [--short]`, `path`, `use <name>`, `remove <name>`. Per-account slots live
  under `~/.claude-creds/accounts/<name>/`; the volume root stays account
  `default`, so 1.9.x containers on the same volume are unaffected.
  `sync-creds` resolves its shared path through it, `post-start.d/60` keeps
  `oauthAccount`/`userID` out of the `.claude.json` sync on a non-default
  account, and `shell-init.sh` prints a live account line under the boot
  panel and resolves the conflict prompt's path.

## Known defects a release should carry, not yet committed

Listed here so a release does not go out without them being a deliberate
choice. These are **not** in the `git log` check above — nothing is committed
for them yet.

(none at the moment.)
