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

Everything up to the `v1.16.1` tag shipped in 1.16.1; its annotation lists
what that release carried. Since :

- **agent-browser handoff** : `agent-browser handoff [url] [--say "…"]` hands
  the host browser to the user — a real window, same profile, the request in a
  banner with Done, a desktop notification — and blocks until they give it back
  (Done, closing the window, `agent-browser handback`, a signal) ; headless
  again on the page the window showed. The instance's visual-loop lock is held
  meanwhile (scripts get exit 10) ; the idle watchdog never stops a window.
  Channel : a `window [<url>]` and a `handback` cmd, a `window` file ; the state
  word stays `running`. Sidecar : refused (no window).
- **agent-browser, headless looks like the window** : `--user-agent` built from
  the binary's version (never `HeadlessChrome`), and the window's
  `userAgentData` brands (Chromium's GREASE included) set on every target over
  Chromium's own loopback DevTools, both modes ; `AGENT_BROWSER_UA_OVERRIDE=off`
  to measure Chromium's own.
- **agent-browser, no keychain prompt** : `--use-mock-keychain` on every Mac
  start. Existing logins of a profile are lost once (cookies now under the mock
  key) — sign in again through `handoff`.
- **agent-browser, graceful stop** : every stop sends `Browser.close` first (a
  kill after 5 s), so a fresh sign-in's cookies reach the disk.
- **cdp-proxy, downloads into the project** : `Page.` / `Browser.setDownloadBehavior`
  pass with `allowAndName` into an existing directory under the project root
  (`AGENT_BROWSER_ROOT`, set by `host-agent.sh` / `host-agent.ps1` install), no
  symlink nor `..` ; `deny` / `default` pass ; `allow` and anything else refused.
  Re-checked when a download begins (cancelled if the directory moved).
  Accepted residual : a check-then-use race on that container-owned tree can put
  one GUID-named, extension-less new file elsewhere on the host. **Needs a kit
  reinstall on the host** (`install`) for the root to reach the supervisor.
- **host-agent install --visible** (`host-agent.sh`, `host-agent.ps1`, `run`
  too) : a real window on every start for that install, no `.env` edit ; a
  later `install` without it is headless again ; refused with `start`.

## Known defects a release should carry, not yet committed

Listed here so a release does not go out without them being a deliberate
choice. These are **not** in the `git log` check above — nothing is committed
for them yet.

- **agent-browser, headless** : `capture()` (visual-loop's `shot`) returns a flat
  grey image of a headless host Chromium while the page renders (its in-page
  `MediaRecorder` video is correct) ; and a tab left by a previous run can read
  `visibilityState` hidden until `agent-browser down` + `up`. Seen with a WebGL2
  game (ctr-native-web T3, 2026-10-21). Weighs more from 1.15.0, where
  visual-loop drives the agent browser by default.
- **agent-browser, Windows tray** : « Stop the agent browser » once brought up
  a Windows error dialog (Windows 11 ARM64 VM, 2026-11-02) ; its title and
  text were not kept, so which process it reports is unknown. The stop itself
  is `host-agent.ps1 stop` in a hidden PowerShell, which shows no dialog of its
  own : the supervisor or Chromium it kills is the likely source.
