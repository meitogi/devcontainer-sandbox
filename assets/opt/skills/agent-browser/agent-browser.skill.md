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
argument-hint: "[-i <instance>] [up <url> | down | status | env]"
---

# Agent browser

A browser that is **yours**, never the human's tab : a dedicated Chromium with
its own profile, reaching only the project's origins, driven over CDP. Two
places it can run ; `agent-browser` picks by heartbeat :

| Side | What | Reached at | When |
|---|---|---|---|
| **host** | Chromium on the real GPU, kept by a macOS LaunchAgent (`host-agent.sh install`), a Windows scheduled task (`host-agent.ps1 install`) or a foreground supervisor (`run`, Linux) ; headless on Metal by default | `host.docker.internal:9223` — an origin-filtering proxy, never Chromium's own port | its heartbeat is under 5 s old |
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
agent-browser route         # one line for scripts : <host|sidecar> <state> <CDP host> <CDP port>
agent-browser -i b <verb>   # the same, on a second browser (instance b)
```

**The visual-loop scripts drive it by default** — with `CDP_HOST` / `CDP_PORT`
unset, `cdp.mjs`, `e2e.mjs` and the rest ask `agent-browser route` for the
endpoint and run `agent-browser up <url>` first when it is not running
(`CDP_INSTANCE=b` for instance b). The proxy answers `/json/version` with its
own browser-level door, so nothing else changes :

```
node /opt/devcontainer/base/skills/visual-loop/scripts/cdp.mjs shot --url "$AGENT_BROWSER_URL" --out .tmp/shots/boot.png
```

`CDP_HOST` / `CDP_PORT` set (`eval "$(agent-browser env)"` sets them too) win :
that is how a script drives the human's browser on 9222 instead. The lock file
is keyed by the endpoint resolved, so the agent browser and the human's
browser have independent locks (**exit 10** = another session holds *this*
browser ; wait and re-run). **Exit 9** (tab not frontmost) does not happen
headless ; windowed, keep the window unminimised.

**Play it** — `e2e.mjs` with a suite declaring `meta.player` : keyboard,
virtual gamepads, shots, video with sound, fps, a proofs folder per run.
visual-loop's skill, « Playing a page ».

**Two browsers at once — instances.** One letter each, `a` (the default,
everything above) to `z` : `agent-browser -i b up <url>` or
`AGENT_BROWSER_INSTANCE=b`. Each is a Chromium of its own — own profile,
own DevTools proxy, own channel (`<CTL>/b/`), own visual-loop lock (keyed by
host:port) — on the same origins. Two things open it, both human :
`host:9224` in `firewall/ports.txt` then **Rebuild Container** ; then
`host-agent.sh start b` on the host (`install --all` brings up every instance
whose port that file opens ; `host-agent.sh instances` shows them first).

**Ports.** Set once, in `.devcontainer/.env` : `AGENT_BROWSER_PROXY_PORT`
(default 9223, what the container connects to) and `AGENT_BROWSER_CDP_PORT`
(default 9323, Chromium's own, host loopback). Instance n letters after `a` is
on base + n for both, so **b = `host:9224`** / 9324 — the container and the
host derive the same numbers, nothing else to keep in sync. Change the base
there, then `host-agent.sh install` again (and the firewall line, then Rebuild
Container). One instance elsewhere, from the command : `host-agent.sh install
b --port 55440 [--cdp-port 55540]` — written into its plist ; the supervisor
announces its proxy port in the channel (`host/port`) and `agent-browser`
follows it, no `.env` edit. The firewall must still open `host:55440`
(`install` warns). A later `install b` without `--port` goes back to the
`.env`'s port and prints the one to keep. `host-agent.sh list` shows every
instance's port, and other projects' agent browsers on a clashing one.
Use : a game's host and guest in two separate browsers, each filmed by its own
recorder ; `eval "$(agent-browser -i b env)"` gives b's endpoint. A sidecar
instance needs its own compose service (the fragment's, with `/ctl` on
`./tmp/agent-browser/b` and `AGENT_BROWSER_CDP_PORT` + 1) — not shipped.

**WebRTC between pages** works : the Chromium flags turn off mDNS host
candidates (`WebRtcHideLocalIpsWithMdns`), which the resolver rules would
leave unresolved — two tabs, or two instances, pair directly.

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
| `AGENT_BROWSER_PROXY_PORT` | `9223` | the proxy's port — `host:9223` goes in `firewall/ports.txt`, then Rebuild Container ; instance b uses + 1, c + 2… (« Ports » above, and `install <i> --port`) |
| `AGENT_BROWSER_CDP_PORT` | `9323` | Chromium's own DevTools port (host loopback ; the sidecar's) ; + 1 per instance letter |
| `AGENT_BROWSER_INSTANCE` | `a` | which instance the container command drives when `-i` is not given |
| `AGENT_BROWSER_PROXY_BIND` | `127.0.0.1` | what the proxy binds — see Linux below |
| `AGENT_BROWSER_HOST` | `host.docker.internal` | the name the container reaches the host by (`agent-browser env` → `CDP_HOST`) — a Linux Docker Engine without that name takes the `docker0` address |
| `AGENT_BROWSER_CERT` | empty | a dev cert (path, repo-relative) whose key alone is trusted |
| `AGENT_BROWSER_CHROMIUM` | auto | the Chromium / Chrome binary on the host |
| `AGENT_BROWSER_ICON_LETTERS` | first two letters of `DC_PROJECT` | 1 to 3 letters or digits in the SwiftBar icon's tag (upper-cased by default, taken as written when set) |
| `AGENT_BROWSER_<X>_ICON_LETTERS` | `AGENT_BROWSER_ICON_LETTERS` | the same for instance x (`X` its letter upper-cased, `_B_` for b) ; b, c… also carry their letter in the icon's dot |
| `AGENT_BROWSER_<X>_NOTE` | empty | the menu's second line for instance x — what it is for, e.g. « two-doctor sync suite only — stop b after » |
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

`install` loads `io.meitogi.agent-browser.<project>` — instance a alone ;
`install b` for b (`….<project>.b`), `install --all` for every instance the
firewall opens. It prints five numbered steps — `[1/5 kit]` (node, origins,
the kit copied), `[2/5 chromium]`, `[3/5 firewall]` (a **warning** when
`host:<port>` is not in `firewall/ports.txt` : add it, Rebuild Container),
`[4/5 launchd]`, `[5/5 heartbeat]` (the container can route to it) — each `ok`,
`warn` or `FAILED` with the cause and the command to run next.

| on the host | does |
|---|---|
| `host-agent.sh list` | every instance : installed / loaded / stopped, supervisor and Chromium pids, Chromium's state, proxy port and whether it listens, heartbeat age, log folder ; other projects' agent browsers with their ports ; `list --json` the same as one object (`instances[]`, `others[]`), for tools |
| `host-agent.sh stop [b]` | off without uninstalling (every installed one by default) : Chromium and the proxy gone, plist and menu-bar plugin kept (« not loaded »), stays off across logins |
| `host-agent.sh start [b]` | back on (a by default), the same five steps ; installs it when it is not |
| `host-agent.sh status [b]` | launchd state, the Chromium the plist carries, proxy listening, heartbeat, kit hash (compare with `agent-browser status` in the container) |
| `host-agent.sh logs [b]` | follows the three logs |
| `host-agent.sh uninstall [b]` | removes everything |
| `host-agent.sh run c --temp` | a temporary instance in the Terminal : no LaunchAgent, no icon ; Ctrl-C stops it and removes its profile and logs. Prints a block to paste to the agent (instance, origins, the commands, « exit 3 after Ctrl-C ») ; `--port` puts it on a port the firewall already opens. Refused on an installed instance. `run` without `--temp` prints the same block |
| `host-agent.sh install-chromium` | no Chromium on the Mac : downloads the latest snapshot into `~/Library/Application Support/agent-browser/chromium/`, clears the quarantine, prints the `AGENT_BROWSER_CHROMIUM=…` line to add to `.env` (it edits nothing) |

Chromium is looked for in `AGENT_BROWSER_CHROMIUM`, `install-chromium`'s
download, then Chromium builds (`/Applications`, `~/Applications`, Playwright's
cache, Puppeteer's `~/.cache/puppeteer`), then Google Chrome, Chrome for
Testing, Edge, `PATH`, then Spotlight — so `npx @puppeteer/browsers install
chromium@latest --path ~/.cache/puppeteer` is found with no `.env` line ; not
found, both `install` and the supervisor's log list every place tried. The plist carries the one `install` found. A new image → extract
again, re-run install. With SwiftBar installed, a menu-bar icon shows the state : a
globe, the project's letters in a tag, a dot for running / idle / not loaded /
stray Chromium ; b, c… carry their letter in the dot, and the menu shows the
instance's note under its name. install draws it from the kit's `menubar-icon.svg` with the
host's Chromium (falls back to SF Symbols if that fails) ; a project's own icon
is a copy of that SVG as `.devcontainer/agent-browser/menubar-icon.svg`, the
four state ids kept. Or ready-made, no Chromium involved : the four
`running` / `idle` / `unloaded` / `stray` `.png` (44×36 RGBA, shown at 22×18 pt)
in `.devcontainer/agent-browser/menubar-icon/`, `<state>.b.png` for b's (an
instance without its own set is drawn) ; for the Windows tray the eight
`<state>-<light|dark>.ico` there, `<state>-<theme>.b.ico` for b. A partial set
is refused, naming the missing files. Re-run install after changing any of them.

**Linux — TODO, with a working fallback.** No launchd : run the same supervisor
in a terminal, `bash "$KIT/host-agent.sh" run` (Ctrl-C stops it and the
browser). Docker Engine reaches the host as the `docker0` address, not
`127.0.0.1`, so set `AGENT_BROWSER_PROXY_BIND=0.0.0.0` (or that address) in
`.env` ; without a `host.docker.internal` entry (`--add-host
host.docker.internal:host-gateway`), set `AGENT_BROWSER_HOST` to the
`docker0` address as well. A systemd user unit would make it permanent — not shipped yet.

**Windows — the Task Scheduler.** The same supervisor (`host-supervisor.mjs`),
installed by `host-agent.ps1` : Windows PowerShell 5.1, no admin rights, node
22+ on the PC. Chromium is looked for in `AGENT_BROWSER_CHROMIUM`, the kit's
own download (`install-chromium`), Chrome (stable, Beta, Dev, Canary),
Chromium (installers, Scoop), Playwright's and Puppeteer's caches, Brave, then
**Edge** — always there, so a PC without Chrome still works — then `PATH` and
the registry's App Paths. In PowerShell, from the project root
(on the Windows disk, or `\\wsl$\…` when the project lives in WSL2) :

```
$KIT = "$env:LOCALAPPDATA\agent-browser\<project>\kit" ; New-Item -ItemType Directory -Force $KIT
cmd /c "docker compose -f .devcontainer/docker-compose.yml run --rm --no-deps -T app agent-browser host-kit | tar -x -C `"$KIT`""
powershell -ExecutionPolicy Bypass -File "$KIT\host-agent.ps1" install
```

`cmd /c`, not a PowerShell pipe : Windows PowerShell 5.1 re-encodes what it
pipes or redirects, and the tar arrives broken (`tar` ships with Windows 10
and later). The verbs and the five steps are `host-agent.sh`'s, `[4/5
scheduler]` in place of launchd : `install [b|--all] [--port n]`, `start`,
`stop`, `uninstall`, `list [--json]`, `status`, `logs`, `run [c] [--temp]`,
`install-chromium`, `instances`. What differs :

- the task is `\meitogi\agent-browser\<project>[.x]`, for the current user, at
  logon, and every minute from install on (one instance at a time : a
  supervisor that died is back within a minute ; the Task Scheduler's own
  « restart on failure » never fires for it), no time limit ; it starts the supervisor through
  `conhost.exe --headless`, so no console window opens ; its settings are in
  `%LOCALAPPDATA%\agent-browser\<project>[.x]\env.json`, beside the installed
  copy, the profile and the logs ;
- a task's own stop kills its process and nothing under it ; node's job
  object takes Chromium down with the supervisor anyway (measured on Windows
  11), and `stop` / `uninstall` still kill whatever names the instance as a
  tree — the tray and conhost included — while the supervisor kills a
  Chromium it finds on its profile when it starts ;
- the notification-area icon is `tray.ps1` (a second task) : the same four
  states and menu as the Mac's, drawn by `install` as ICOs for a light and a
  dark taskbar ;
- `install-chromium` takes the ARM64 snapshot on an ARM64 PC when there is
  one, the x64 build otherwise (Windows runs it emulated) ;
- the proxy binds `127.0.0.1` : no Windows Firewall prompt. `0.0.0.0` would
  prompt.

Not verified on a real PC yet : that Docker Desktop's `host.docker.internal`
reaches a proxy bound to `127.0.0.1` (it does on the Mac), and how fast the
channel answers when the project lives in WSL2 (`\\wsl$`). Without host-agent.ps1,
`host-agent.sh run` from the WSL2 shell remains a fallback. The `host-os`
marker (`wsl`, `gitbash`) makes `cdp.mjs`'s and `agent-browser`'s exit-3
hints name the PowerShell commands.

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
    HOST ONLY (the Mac's Terminal). install | start | stop | list | status | logs | uninstall | install-chromium | run :
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
`state` = `<nonce> <running|stopped|idle> <pid> <url>`, `heartbeat` (an
epoch, every second) and `port` (its proxy port, read by `agent-browser` when
digits), written by the supervisor ; `stats`, `flags` (bench
switches only : `--disable-frame-rate-limit`, `--disable-gpu-vsync`,
`--window-size=W,H`), `activity`, `hold`. Polled, not inotify (the bind mount
crosses the VM boundary). The supervisor is `host-supervisor.mjs` — one node
script for every OS, its DevTools proxy in the same process, so a stopped
supervisor never leaves a proxy holding the port. It never reads nor writes through a
symlink the container could leave there, takes the URL after `--`, and never
echoes a refused URL. Tests : `bash test/agent-browser.test.sh` in the
sandbox repository, and `node --test
/opt/devcontainer/base/skills/agent-browser/host/cdp-proxy.test.mjs` anywhere
(the live part runs when `AGENT_BROWSER_TEST_CDP=host:port` names a browser
showing a page on the test origins).
