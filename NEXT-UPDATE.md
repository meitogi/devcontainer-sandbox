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

Everything up to `97cc419` shipped in 1.9.1; the `v1.9.1` tag annotation lists
what that release carried.

- **The post-start log line shows again under zsh** (`assets/opt/shell-init.sh`,
  `assets/opt/knowledge/INDEX.md`). The reader globbed both the flat
  `tmp/logs/post-start-*.log` and the per-boot `tmp/logs/*/post-start-*.log`;
  since 1.9.0 the flat form never exists, and zsh's `NOMATCH` aborted the whole
  command — `no matches found` on every new terminal, and no
  `📄 Post-start log:` line. Both readers now use
  `find … -maxdepth 2 -name 'post-start-*.log'`, which needs no shell option.
  The two copy-paste commands in `INDEX.md` failed the same way under the
  Bash tool's zsh. Covered by `test/overlay.test.sh` (zsh, boot-folder log
  only).

## Known defects a release should carry, not yet committed

Listed here so a release does not go out without them being a deliberate
choice. These are **not** in the `git log` check above — nothing is committed
for them yet.

(none at the moment.)
