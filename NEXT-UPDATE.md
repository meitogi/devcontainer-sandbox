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

Everything up to the `v1.12.1` tag shipped in 1.12.1; its annotation lists
what that release carried.

- **`agent-browser`** (1.13.0) — the agent's own browser, project-agnostic :
  `bin/agent-browser` (control channel, routing by heartbeat between the host
  and a sidecar, `env` for the visual-loop scripts, `host-kit` / `sidecar-kit`
  tar streams) ; `assets/opt/skills/agent-browser/` with the skill, the host
  kit (macOS LaunchAgent `host-agent.sh install|uninstall|status|logs|run`,
  supervisor, Chromium flags generated from `AGENT_BROWSER_ORIGINS`, the
  origin-filtering `cdp-proxy.mjs` with a browser-level door so `cdp.mjs`
  works unchanged, SwiftBar plugin) and the sidecar kit (Mesa Chromium
  Dockerfile, supervisor, compose fragment). `docs/how-to/drive-the-agent-browser.md`.
  Linux / Windows hosts : documented TODO, `host-agent.sh run` as the fallback.
- **visual-loop player harness** (1.13.0) — `e2e.mjs` plays a page when its
  suite declares `meta.player` : keys via `Input.dispatchKeyEvent` timed in rAF
  frames or ms, four virtual gamepads (a `getGamepads` shim injected before
  load, standard mapping), mid-scenario shots, video with sound (in-page
  `MediaRecorder` on the canvas + a Web Audio tap, chunks drained over
  `Runtime.evaluate` ; recorded even under `--mute-audio`), CDP screencast as
  the silent fallback, an rAF fps meter, and a proofs folder per run
  (`--proofs`, `run.json` + `index.md`). `lib/player.mjs`, `lib/player-page.js`
  ; `cdp.mjs` exports `capture()` and `openSession` takes `inject` / `login`.

## Known defects a release should carry, not yet committed

Listed here so a release does not go out without them being a deliberate
choice. These are **not** in the `git log` check above — nothing is committed
for them yet.

(none at the moment.)
