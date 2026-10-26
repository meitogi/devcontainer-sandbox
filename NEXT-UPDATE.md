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

Everything up to the `v1.14.0` tag shipped in 1.14.0; its annotation lists
what that release carried.

## Known defects a release should carry, not yet committed

Listed here so a release does not go out without them being a deliberate
choice. These are **not** in the `git log` check above — nothing is committed
for them yet.

- **agent-browser, macOS** : `host-agent.sh install` bakes `AGENT_BROWSER_CHROMIUM`
  only from `.env`, and the supervisor searches again under launchd, where a
  Playwright Chromium the user's shell finds is missed (« Chromium not found »,
  `up` stops at once). The robrowser agent bakes the path it resolved at install ;
  do the same. Worked around in a project's `wtf agent-browser install` wrapper.
- **agent-browser, headless** : `capture()` (visual-loop's `shot`) returns a flat
  grey image of a headless host Chromium while the page renders (its in-page
  `MediaRecorder` video is correct) ; and a tab left by a previous run can read
  `visibilityState` hidden until `agent-browser down` + `up`. Seen with a WebGL2
  game (ctr-native-web T3, 2026-10-21).
