---
description: |
  The agent's own browser — a dedicated Chromium on the host's GPU (macOS
  LaunchAgent, full frame rate) or, failing that, a headless Mesa Chromium in a
  sidecar container, both driven over CDP from the devcontainer through
  `agent-browser`. Read this before opening the project's page in a browser you
  drive yourself, before any frame-rate or video measurement, and whenever
  `agent-browser` or the visual-loop scripts exit 3.

  Auto-trigger : "open the game in the agent browser", "agent-browser up",
  "drive my own browser", "full frame rate", "the host browser does not
  answer", "install the agent browser", "the sidecar browser", "which browser
  am I driving", "CDP endpoint of the agent browser".
argument-hint: "[up <url> | down | status | env]"
---

# Agent browser

A browser that is **yours**, never the human's tab : a dedicated Chromium with
its own profile, reaching only the project's origins, driven over CDP. Two
places it can run ; `agent-browser` picks by heartbeat :

| Side | What | Reached at | When |
|---|---|---|---|
| **host** | Chromium on the real GPU, kept by a macOS LaunchAgent (`host-agent.sh install`) or a foreground supervisor (`host-agent.sh run`, Linux / WSL2) ; headless on Metal by default | `host.docker.internal:9223` — an origin-filtering proxy, never Chromium's own port | its heartbeat is under 5 s old |
| **sidecar** | headless Chromium on Mesa (software GL) in a cap-dropped container sharing `app`'s network namespace | `127.0.0.1:9323` | no host heartbeat, sidecar heartbeat under 5 s |
| neither | — | — | **exit 3** : a HUMAN action (below). Relay the message, wait, never retry in a loop |

Frame-rate numbers come from the host side only ; the sidecar gives correct
pixels, not speed.

## Commands

```
agent-browser up [url]      # the page (default AGENT_BROWSER_URL, else the first origin) → "host: running <pid> <url>" + the CDP endpoint
agent-browser down | restart | stats | logs | hold <min>
agent-browser status        # which side answers, last state, firewall entry, kit hash
agent-browser env           # export CDP_HOST=… CDP_PORT=…
```

**Drive it with the visual-loop scripts, unchanged** — the proxy answers
`/json/version` with its own browser-level door, so `cdp.mjs`, `front.mjs`,
`e2e.mjs` work as they do against the human's browser on 9222 :

```
eval "$(agent-browser env)" && node /opt/devcontainer/base/skills/visual-loop/scripts/cdp.mjs shot --url "$AGENT_BROWSER_URL" --out .tmp/shots/boot.png
```

The lock file is keyed by host:port, so the agent browser and the human's
browser have independent locks (**exit 10** = another session holds *this*
browser ; wait and re-run). **Exit 9** (tab not frontmost) does not happen
headless ; windowed, keep the window unminimised.

**Play it** — `e2e.mjs` with a suite declaring `meta.player` : keyboard,
virtual gamepads, shots, video with sound, fps, a proofs folder per run.
visual-loop's skill, « Playing a page ».

Exit codes of `agent-browser` : 0 ok · 1 the supervisor refused (URL outside
the origins, Chromium missing — `logs`) · 2 usage / configuration · **3 no
browser answers** · 5 no answer within 20 s.

## What the browser may reach

Everything comes from `.devcontainer/.env` — flag > env > hard stop, no silent
default for the origins :

| Variable | Default | Meaning |
|---|---|---|
| `AGENT_BROWSER_ORIGINS` | **required** | space-separated `scheme://host[:port]`, host may start with `*.` — the pages the browser may load and the proxy lets you drive / navigate to |
| `AGENT_BROWSER_REACH` | empty | extra `host[:port]` the page may connect to but never be navigated to (a relay, a STUN server) |
| `AGENT_BROWSER_URL` | first origin + `/` | what `up` opens without an argument |
| `AGENT_BROWSER_SIZE` | `1280,800` | window size, CSS px at scale 1 |
| `AGENT_BROWSER_AUDIO` | `off` | `on` drops `--mute-audio`, for a human listening to the host's browser. A video recorded by visual-loop's player harness has its sound either way — it taps the page's Web Audio graph, not the speakers |
| `AGENT_BROWSER_WINDOW` | `0` | `1` = a real window on the host instead of `--headless=new` |
| `AGENT_BROWSER_PROXY_PORT` | `9223` | the proxy's port — `host:9223` goes in `firewall/ports.txt`, then Rebuild Container |
| `AGENT_BROWSER_CDP_PORT` | `9323` | Chromium's own DevTools port (host loopback ; the sidecar's) |
| `AGENT_BROWSER_PROXY_BIND` | `127.0.0.1` | what the proxy binds — see Linux below |
| `AGENT_BROWSER_HOST` | `host.docker.internal` | the name the container reaches the host by (`agent-browser env` → `CDP_HOST`) — a Linux Docker Engine without that name takes the `docker0` address |
| `AGENT_BROWSER_CERT` | empty | a dev cert (path, repo-relative) whose key alone is trusted |
| `AGENT_BROWSER_CHROMIUM` | auto | the Chromium / Chrome binary on the host |
| `AGENT_BROWSER_IDLE_S` | `360` | the host turns Chromium off after that many idle seconds (`hold <min>` postpones) |

One grammar, one implementation : `cdp-proxy.mjs check-url | pac |
resolver-rules` generate the PAC, the `--host-resolver-rules` and the proxy's
own filter from that list. The proxy refuses `Browser.*`, file inputs,
downloads, navigation elsewhere, `Target.*` on other targets, and workers of
other origins ; refusals are logged on the host (`cdp-proxy.log`) and answered
as a CDP error `refused by cdp-proxy: <why>`.

## The human's part (exit 3)

**macOS — the LaunchAgent.** The kit comes out of the **image**, never out of
the tree : nothing the container writes runs on the Mac. In the Mac's Terminal,
from the project root :

```
KIT="$HOME/Library/Application Support/agent-browser/$(sed -n 's/^DC_PROJECT=//p' .devcontainer/.env)/kit"; mkdir -p "$KIT"
docker compose -f .devcontainer/docker-compose.yml run --rm --no-deps -T app agent-browser host-kit | tar -x -C "$KIT"
bash "$KIT/host-agent.sh" install
```

`install` prints the origins it will allow and loads
`io.meitogi.agent-browser.<project>` ; `status` shows the heartbeat and the kit
hash (compare with `agent-browser status` in the container) ; `logs` follows
the three logs ; `uninstall` removes everything. A new image → extract again,
re-run install. With SwiftBar installed, a menu-bar icon shows the state.

**Linux — TODO, with a working fallback.** No launchd : run the same supervisor
in a terminal, `bash "$KIT/host-agent.sh" run` (Ctrl-C stops it and the
browser). Docker Engine reaches the host as the `docker0` address, not
`127.0.0.1`, so set `AGENT_BROWSER_PROXY_BIND=0.0.0.0` (or that address) in
`.env` ; without a `host.docker.internal` entry (`--add-host
host.docker.internal:host-gateway`), set `AGENT_BROWSER_HOST` to the
`docker0` address as well. A systemd user unit would make it permanent — not shipped yet.

**Windows / WSL2 — TODO, same fallback.** Run `host-agent.sh run` from the WSL2
shell with `AGENT_BROWSER_CHROMIUM` pointing at `chrome.exe` ; Windows Firewall
prompts for the proxy's port the first time (private networks only). The
`host-os` marker `cdp.mjs` already reads tells the unreachable hint apart.

**Sidecar (no host browser at all).** `agent-browser sidecar-kit` is a tar of
a Dockerfile, its supervisor and a compose fragment. On the host, from the
project root :

```
mkdir -p .devcontainer/agent-browser-sidecar
docker compose -f .devcontainer/docker-compose.yml run --rm --no-deps -T app agent-browser sidecar-kit | tar -x -C .devcontainer/agent-browser-sidecar
```

Merge `agent-browser.yml`'s service into `.devcontainer/docker-compose.yml`
(commit both — a Dockerfile the project reviews), then `docker compose -f
.devcontainer/docker-compose.yml --profile agent-browser up -d agent-browser`.
No firewall entry : the sidecar is on `app`'s loopback.

## `wtf` integration

The command is on PATH in any container built from the image ; a project that
wants `wtf browser …` adds these entries to its `.wtfcmd.yaml` (the host side
runs on the Mac, where `wtf` exists too) :

```yaml
- group: browser
  name: [up, u]
  desc: Open the project's page in the agent browser (host GPU if its agent answers, else the sidecar).
  args: [{ name: url, desc: "Page to open ; default AGENT_BROWSER_URL" }]
  cmd: agent-browser up {{ if .url }}{{ esc .url }}{{ end }}
- group: browser
  name: [down, d]
  cmd: agent-browser down
- group: browser
  name: status
  cmd: agent-browser status
- group: browser
  name: env
  desc: 'eval "$(wtf browser env)" before the visual-loop scripts.'
  cmd: agent-browser env
- group: browser
  name: host
  desc: |
    HOST ONLY (the Mac's Terminal). install | uninstall | status | logs | run :
    extracts the kit from the image into ~/Library/Application Support/agent-browser/<project>/kit, then runs host-agent.sh <sub>.
  args: [{ name: sub, default: status }]
  cmd: |
    KIT="$HOME/Library/Application Support/agent-browser/$(sed -n 's/^DC_PROJECT=//p' .devcontainer/.env)/kit"
    mkdir -p "$KIT"
    docker compose -f .devcontainer/docker-compose.yml run --rm --no-deps -T app agent-browser host-kit | tar -x -C "$KIT"
    bash "$KIT/host-agent.sh" {{ esc .sub }}
```

## The channel, for whoever debugs it

Files under `.devcontainer/tmp/agent-browser/` (`host/` for the host side) :
`cmd` = `<nonce> up <url> | restart | down | stats`, written by the container ;
`state` = `<nonce> <running|stopped|idle> <pid> <url>` and `heartbeat` (an
epoch, every second), written by the supervisor ; `stats`, `flags` (bench
switches only : `--disable-frame-rate-limit`, `--disable-gpu-vsync`,
`--window-size=W,H`), `activity`, `hold`. Polled, not inotify (the bind mount
crosses the VM boundary). The supervisor never reads nor writes through a
symlink the container could leave there, takes the URL after `--`, and never
echoes a refused URL. Tests : `bash test/agent-browser.test.sh` in the
sandbox repository, and `node --test
/opt/devcontainer/base/skills/agent-browser/host/cdp-proxy.test.mjs` anywhere
(the live part runs when `AGENT_BROWSER_TEST_CDP=host:port` names a browser
showing a page on the test origins).
