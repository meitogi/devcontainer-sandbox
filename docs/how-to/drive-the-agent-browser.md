# Drive the agent browser

**Goal.** Give the agent a browser of its own — a Chromium on your Mac's GPU
that loads only your project's pages — so it can screenshot, measure and play
the running app at full frame rate, without ever touching your tabs. When no
Mac browser answers, a headless one in a sidecar container stands in.

*Commands in this page say where they run : **host** (your Mac's Terminal, at
the project root) or **container** (a terminal inside the devcontainer).*

---

## Steps

### 1. Name the origins (container or host — it is a file)

In `.devcontainer/.env` :

```
AGENT_BROWSER_ORIGINS=http://localhost:5173
```

Space-separated `scheme://host[:port]` ; a host may start with `*.`. Nothing
else will load in that browser. Optional lines : `AGENT_BROWSER_AUDIO=on` (hear
the page on the host ; a recorded video has its sound either way), `AGENT_BROWSER_WINDOW=1` (a real window instead of
headless), `AGENT_BROWSER_SIZE=1280,800`.

### 2. Open the firewall for the proxy (container), then rebuild

In `.devcontainer/firewall/ports.txt` :

```
host:9223
```

Then **Rebuild Container**. The container reaches the Mac browser through a
proxy on that port, never through Chromium's own DevTools port.

### 3. Install the LaunchAgent (host)

```
KIT="$HOME/Library/Application Support/agent-browser/$(sed -n 's/^DC_PROJECT=//p' .devcontainer/.env)/kit"; mkdir -p "$KIT"
docker compose -f .devcontainer/docker-compose.yml run --rm --no-deps -T app agent-browser host-kit | tar -x -C "$KIT"
bash "$KIT/host-agent.sh" install
```

The kit is extracted from the image, so what launchd runs never came out of
the container's writable tree. `install` prints the origins it allows. Needs
`node` 22+ and a Chromium (`brew install --cask chromium`).

### 4. Open the page (container)

```
agent-browser up
```

prints `host: running <pid> <url>` and the CDP endpoint. Then the usual
visual-loop scripts, pointed at it :

```
eval "$(agent-browser env)" && node /opt/devcontainer/base/skills/visual-loop/scripts/cdp.mjs shot --url http://localhost:5173/ --out .tmp/shots/home.png
```

---

## How to check it worked

Host :

```
bash "$KIT/host-agent.sh" status
```

shows `launchd state = running`, a heartbeat of a few seconds and the kit hash.
Container :

```
agent-browser status
```

shows `route     : host`, `firewall  : host:9223 allowed (baked)` and the same
kit hash. `agent-browser down` closes the browser ; it also closes itself after
six idle minutes.

---

## Variants

**No Mac, or no launchd (Linux, WSL2).** Run the supervisor in a terminal :
`bash "$KIT/host-agent.sh" run`, with `AGENT_BROWSER_PROXY_BIND=0.0.0.0` in
`.env` on a Linux Docker Engine (and `AGENT_BROWSER_HOST=<docker0 address>`
when the container has no `host.docker.internal`). Ctrl-C stops it.

**No host browser at all.** Extract the sidecar kit into the project and start
it with its compose profile :

```
mkdir -p .devcontainer/agent-browser-sidecar
docker compose -f .devcontainer/docker-compose.yml run --rm --no-deps -T app agent-browser sidecar-kit | tar -x -C .devcontainer/agent-browser-sidecar
```

then merge `agent-browser.yml` into `.devcontainer/docker-compose.yml` and
`docker compose -f .devcontainer/docker-compose.yml --profile agent-browser up -d agent-browser`.
`agent-browser status` then routes to `sidecar`. Correct pixels, software GL —
never a frame-rate number.

**Both at once.** The host wins while its heartbeat is fresh ; `agent-browser
up` turns the other side off first.

---

## Reference

The agent-facing procedure, the full variable table, the `.wtfcmd.yaml`
snippet and the channel's file format : the `agent-browser` skill, baked at
`/opt/devcontainer/base/skills/agent-browser/agent-browser.skill.md`. Tests :
`test/agent-browser.test.sh` in
[the repository](https://github.com/meitogi/devcontainer-sandbox).
