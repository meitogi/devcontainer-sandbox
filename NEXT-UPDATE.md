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

Everything up to the `v1.13.0` tag shipped in 1.13.0; its annotation lists
what that release carried.

- **agent-browser** : the SwiftBar plugin shows the project's name beside its
  icon in the menu bar (two projects' agents were two identical circles).
- **agent-browser, two browsers at once** : instances by letter — `agent-browser
  -i b up|down|status|env` (or `AGENT_BROWSER_INSTANCE=b`), each its own
  Chromium, profile, DevTools proxy, channel (`<CTL>/b/`) and lock, on the same
  origins. Ports derived : b = proxy 9224 / Chromium 9324 (+ 1 per letter).
  `host-agent.sh install` without a list installs every instance whose port is
  in the project's `firewall/ports.txt` (label `….<project>.b`, own SwiftBar
  item `<project>.b`) ; `status` / `uninstall` cover every installed one ;
  `host-agent.sh instances` shows them, also from a container. **Projects that
  want b** : `host:9224` in `firewall/ports.txt`, Rebuild Container, re-extract
  the kit, `install`. Instance a is unchanged (paths, label, ports).
- **agent-browser, WebRTC** : `--disable-features=WebRtcHideLocalIpsWithMdns`
  on the host and sidecar Chromium — WebRTC host candidates were mDNS names
  (`….local`) the resolver rules left unresolved, so two pages never paired
  directly (`AGENT_BROWSER_REACH=*.local` was the workaround ; no longer needed).
- **vscode-logs-mirror** : with `VSCODE_LOGS_MIRROR=1` in `.devcontainer/.env`,
  `post-start.d/58` starts `bin/vscode-logs-mirror`, which rsyncs
  `~/.vscode-server/data/logs/` every 30 s into
  `.devcontainer/tmp/vscode-logs/container/<session>/` (5 sessions kept), so a
  Rebuild no longer takes the crashed session's logs with it. The host half
  (the Mac's VS Code logs under `vscode-logs/host/`) ships in the CLI's notify
  daemon. Read from the `.env` file, so a Reopen flips it.

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
