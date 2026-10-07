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

Everything up to `cde9218` shipped in 1.9.2; the `v1.9.2` tag annotation lists
what that release carried.

- **The v2 template tree is gone from the image's vocabulary**
  (`assets/opt/hooks/post-create.d/20-seed-settings-local.sh`,
  `assets/opt/skills/prepare-plan/MODELS.explained.md`,
  `assets/opt/knowledge/INDEX.md`). The seed hook fell back to
  `/workspace/templates/v2/.claude/settings.local.json.example` when the
  project had no `.claude/settings.local.json.example` of its own — a path that
  only ever existed in the devcontainer-tools monorepo, which retired
  `templates/v2/` on 2026-10-07 along with `install.sh`. The fallback is
  removed; a v3 project always has the `.example`, `devc init` writes it. The
  two prose mentions (`templates/v2` skill, `install.sh`) are reworded. Nothing
  to cover: no test could reach the fallback path from a v3 project.
- **The reload sheet says strict is supported**
  (`assets/opt/knowledge/firewall-reload-local.md`,
  `assets/opt/knowledge/INDEX.md`). `reload-firewall` has run in `strict` since
  the mitmproxy addons started re-reading `policy.compiled.yaml` on mtime, but
  the sheet still said basic-only, refused in strict, and described the
  pre-`--dry-run` script. Rewritten from the script: both modes, the guard
  cascade, `--dry-run` then `wtf firewall reload` (`docker exec -it -u 0`),
  ephemeral by design. Docs only, nothing to cover.

## Known defects a release should carry, not yet committed

Listed here so a release does not go out without them being a deliberate
choice. These are **not** in the `git log` check above — nothing is committed
for them yet.

(none at the moment.)
