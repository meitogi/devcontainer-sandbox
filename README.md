# devcontainer-claude-code

**A devcontainer base image that gives Claude Code room to work, and a network
it cannot leave.**

```
ghcr.io/meitogi/devcontainer-claude-code:<base-version>-cc<cc-version>
```

## The problem it solves

A devcontainer isolates the filesystem. It does **not** isolate the network —
and that is the half that matters once an AI agent is running with real
autonomy in your repo.

Everything inside the container reaches the whole internet by default: the
agent, but also an `npm install` postinstall script, a compromised transitive
dependency, a `curl` in a Makefile. "Deny by default" is not something you can
add convincingly after the fact, from inside, in a container the workload can
also write to.

So this image bakes it in, and makes it checkable :

- **Outbound is deny-by-default at DNS.** `dnsmasq` runs with no catch-all
  upstream, so a host that is not on the allowlist gets `REFUSED` and is never
  forwarded anywhere. A request to an unknown host fails at resolution, not at
  connect — which also closes DNS itself as an exfiltration channel.
- **The allowlist is yours, and it is baked.** The image ships the machinery and
  **no allowlist at all**. Your project's `firewall/` is compiled into the image
  at build time, so the image can never silently widen your rules — and nothing
  at runtime can either.
- **The container user cannot widen it.** `sudo` grants exactly two firewall
  binaries, the config is root-owned, the ruleset is not editable from the
  workload. That is not a claim: `privilege.sh` and `escalation.sh` ship inside
  the image and assert it, and you can replay them against any published tag.
- **Optional L7 audit.** In strict mode, allowed HTTPS goes through mitmproxy
  with per-host policies, so "allowed host" can mean "allowed host, these paths,
  these methods".

Everything in this repo is in the image, and nothing in the image comes from
anywhere else. That is deliberate: auditing the image means reading this tree.

## What you get, beyond the firewall

- **Claude Code, baked** — the VS Code extension and its CLI, pinned per tag, so
  a container starts usable instead of downloading itself into existence.
- **A lifecycle dispatcher** — `devc-hook` merges hook fragments from three
  layers (this image, an image extending it, your project) with a documented
  masking rule, so you add behaviour without forking anything.
- **Skills and knowledge** for the agent, under `/opt/devcontainer/base/` —
  including `/prepare-stack`, which walks a project through building its own
  layer on top of this one.
- **Node 24 on bookworm-slim**, zsh + Oh My Zsh, git + git-delta, `gh`, and a
  task runner. Non-Node stacks extend the image; see [Non-Node stacks](#non-node-stacks).

## It patches the Claude Code extension — read this before pulling

The image ships Anthropic's Claude Code VS Code extension **and modifies it**.
That is an unusual thing for a base image to do, so it is on the front page
rather than in a footnote.

**Sixteen** Python patchers rewrite three files of the extension bundle at image
build time — `package.json`, `extension.js`, `webview/index.js` — in three
categories:

| Category | What it is for |
|---|---|
| `ux` | Interface fixes and restyling: the footer pills, the model picker, the plan preview's find widget, webview login retries |
| `fix` | Behavioural defects: URI-to-workspace handling, session rename fallthrough, opening in the current panel |
| `notify` | Hooks the desktop notifier needs: the user-action observer, the authority writer, the outbound action injector |

**Every patch is inspectable and every one is optional.**
[PATCHES.md](assets/vscode-ext-patchs/PATCHES.md) documents what each one
changes, why it exists and what it costs. Choose at build:

```
docker build --build-arg CLAUDE_CODE_EXT_PATCHS=ux,fix .
```

or at runtime, in a container from an already-built image:

```
restore-ext-patches ux,fix     # replay a selection
restore-ext-patches none       # a completely unpatched extension
restore-ext-patches --list     # what is baked, and what is live right now
```

Both accept `all`, `none`, a category, a patch name, or any comma-separated
mix. **A token that names nothing fails loudly** rather than being silently
dropped. The default is `all`.

The runtime selection is real, not decorative: the build keeps a pristine copy
of the three files under `/usr/local/share/claude-ext-orig/` before touching
them, and that copy is what `restore-ext-patches` replays from. A VS Code window
reload is needed for a runtime change to show.

### Which extension versions

A patcher rewrites a bundled JavaScript file, so it is **tied to the version of
the extension it was written against**. The versions this image is built for are
exactly the ones listed in [cc-versions.json](cc-versions.json), and each one
gets its own tag:

```
ghcr.io/meitogi/devcontainer-claude-code:<base-version>-cc<claude-code-version>
```

Pin both. A project that validated its patches against one Claude Code version
stays on that tag while newer ones ship alongside — that is why the matrix
exists rather than a single moving `latest`. Several patchers branch internally
on the extension version (the model pill, for instance, is restyled after
2.1.258 and hidden before it), and each patcher absorbs its own failure: a patch
that no longer matches prints a red banner and the build continues, so an
extension change degrades the interface rather than breaking your image.

If you want none of this, `CLAUDE_CODE_EXT_PATCHS=none` gives you the
extension exactly as Anthropic publishes it, and everything else in the image
still works.

## Quickstart

Your project's `.devcontainer/Dockerfile` — the first stage is **not** optional,
it is what bakes your allowlist:

```dockerfile
ARG BASE_VERSION=0.1.0
ARG CLAUDE_CODE_VERSION=2.1.258

FROM ghcr.io/meitogi/devcontainer-claude-code:${BASE_VERSION}-cc${CLAUDE_CODE_VERSION} AS fw-bake
USER root
COPY firewall/ /tmp/fw-src/
RUN /usr/local/bin/firewall-docker-setup.sh --src /tmp/fw-src --dest /out

FROM ghcr.io/meitogi/devcontainer-claude-code:${BASE_VERSION}-cc${CLAUDE_CODE_VERSION}
USER root
COPY --from=fw-bake /out/ /etc/devcontainer-firewall/
USER node
```

Then in `devcontainer.json`:

```json
"onCreateCommand":   "devc-hook on-create",
"postCreateCommand": "devc-hook post-create",
"postStartCommand":  "devc-hook post-start"
```

Put the hosts your project needs in `firewall/domains.txt`, rebuild, and run
your install. **`firewall-blocks` tells you what was denied** — that output is
the list to add, and it beats guessing a vendor's CDN from its `.com`.

Ask Claude to run `/prepare-stack` and it will do all of the above for your
stack, discovering the allowlist by measurement rather than by guesswork.

## Skills the image ships

Skills live at `/opt/devcontainer/base/skills/` and `sync-skills.sh` installs
them as slash commands on every container start. **Start with `/prepare-stack`** —
it is the one that turns a bare project into a working devcontainer.

| Command | What it does |
|---|---|
| **`/prepare-stack`** | **Wires a project onto this image**: the extending Dockerfile with its mandatory firewall bake, an allowlist *discovered* from `firewall-blocks` rather than guessed, lifecycle fragments that reuse `devc-hook`, and lint/test declared so the commit gate returns a measured verdict. It refuses to infer your stack from a manifest — it asks. |
| `/prepare-plan` | Routes work that follows a plan to one of four execution contexts, by increasing persistence — from "this session, no files" to a multi-session scaffold. Each generated prompt carries a model-tier recommendation. |
| `/prepare-pr` | Generates a PR draft — body `.md` plus metadata `.yaml` — for host-side execution, since the container cannot push. |
| `/watch-log` | Prepares a script *you* run on the host, then detects its completion. For everything Claude cannot execute itself: host-only commands, `docker` on the host, `git push`, `gh` mutations. |
| `/diagram` | Produces an `.excalidraw` file from a description, an ASCII sketch or a Mermaid graph. |
| `/tokens` | Token-consumption recap, aggregated by project, session, day and model. |
| `/visual-loop` | The pixel-fidelity procedure — read real values from Figma and from the running app instead of eyeballing a screenshot. **Needs host-side browser tooling that this image does not ship**; the skill is the method, not the driver. |

Two more are **hooks only**, with no slash command: `notify-queue` feeds a
desktop notifier, and `session-gap` flags a conversation resumed after a long
pause. Both are wired through `hooks.json` and merged into Claude's settings by
`sync-skills.sh`.

To switch one off, rename its `<name>.skill.md` to `<name>.skill.disabled.md`
and re-run `sync-skills.sh` — it drops the command and skips the skill's hooks,
so disabling is one `mv` and one sync.

## What ships where

| Repo path | Image path | Content |
|---|---|---|
| `bin/` | `/usr/local/bin/` | `devc-hook` (lifecycle dispatcher), `reload-firewall` (guarded runtime reload), `firewall-digest.sh` (sourced library, 0644), `init-firewall.sh`, `test-firewall.sh`, `firewall-docker-setup.sh` (build-time bake), `compile-policy.py`, `mitm-init.sh`, `firewall-blocks` |
| `assets/opt/` | `/opt/devcontainer/base/` | `hooks/` (lifecycle fragments — the dispatcher's base layer), `skills/`, `knowledge/`, `zshrc` |
| `assets/etc-firewall/` | `/etc/devcontainer-firewall/` | `dnsmasq.conf`, `tests/`, `addons/` — the firewall *infrastructure*. The image ships **no domains allowlist** : the project allowlist is baked by the project Dockerfile (see below), so the image can never silently widen a project's firewall |
| `assets/vscode-ext-patchs/` | `/usr/local/bin/vscode-ext-patchs/` | regex patchers applied to the baked VS Code extension at image build |

Plus the toolchain baked by the `Dockerfile` itself : Node 24 (bookworm-slim),
Claude Code (VSIX + CLI, version pinned per tag), mitmproxy, dnsmasq,
iptables/ipset, git + git-delta, gh, wtf, zsh + Oh My Zsh, build-essential.

Not in the image, on purpose : the notify daemon (installed by
`devc notify install`), project firewall allowlists, CLAUDE.md templates,
LESSONS baseline (projects start blank), and the `devc` CLI itself
(`@stitchu/devcontainer-cli` is not on npm yet — it will be pre-installed
once published).

## Tag scheme

`<base-version>-cc<cc-version>` — e.g. `0.1.0-cc2.1.258`. Base follows its
own semver (the `version` field of [package.json](package.json)) ; each
release is published once per Claude Code version listed in
[cc-versions.json](cc-versions.json). Multiple CC versions coexist so a
project that validated its VS Code patches on one CC version can stay pinned
while newer ones ship.

Support policy : the list in [cc-versions.json](cc-versions.json) is a
**deliberate choice, not a moving window** — each entry costs a full multi-arch
CI build, so it holds the version the dogfood actually runs (its `default`) plus
whatever older pin still has users. The `devc` CLI refuses a pin on an unlisted
version.

## Using the image

A project consumes the image through its `.devcontainer/Dockerfile`, which
must run the firewall bake (the image ships the machinery, the project ships
the allowlist) :

```dockerfile
# Pin BOTH. The image version and the Claude Code version are independent axes,
# and the tag carries both — see § Tag scheme. Passing them as build args (from
# docker-compose, from .env) keeps a bump to one line instead of four.
ARG BASE_VERSION=0.1.0
ARG CLAUDE_CODE_VERSION=2.1.258

# ─── Stage 1 — bake the allowlist. NOT optional. ─────────────────────────────
# The image ships firewall machinery and NO allowlist. This stage compiles
# yours into /out. Skip it and init-firewall.sh fails at onCreate: every
# container start explodes while the image itself looks perfectly healthy.
FROM ghcr.io/meitogi/devcontainer-claude-code:${BASE_VERSION}-cc${CLAUDE_CODE_VERSION} AS fw-bake

# Whether domains.local.txt — the personal, gitignored layer — is compiled in.
# 0 is the hardened default: what one developer allows for an afternoon does
# not silently become the team's baseline. Opt in per-developer with =1, or
# team-wide with an `allow-local-at-rebuild` marker file next to domains.txt.
ARG FIREWALL_ALLOW_LOCAL_AT_REBUILD=0

USER root

# Your whole firewall/ directory: domains.txt, domains.d/*.txt, policy.d/,
# ports.txt. This is the ONE place your allowlist comes from.
COPY firewall/ /tmp/fw-src/

# Compiles the layers into a frozen set. Idempotent — every input's digest is
# recorded in effective/sources.sha256, so re-running with unchanged inputs is
# a logged no-op rather than a fresh result.
RUN FIREWALL_ALLOW_LOCAL_AT_REBUILD="${FIREWALL_ALLOW_LOCAL_AT_REBUILD}" \
    /usr/local/bin/firewall-docker-setup.sh --src /tmp/fw-src --dest /out

# ─── Stage 2 — the image your project actually runs ──────────────────────────
# A SECOND stage on purpose. firewall/ carries domains.local.txt and
# policy.local.d/, both gitignored and writable by anything in the container —
# an npm postinstall included. A `RUN rm` after the COPY would not help: the
# file still sits in the COPY layer, so `docker save` and any registry push
# still ship it. A throwaway stage leaves nothing behind.
FROM ghcr.io/meitogi/devcontainer-claude-code:${BASE_VERSION}-cc${CLAUDE_CODE_VERSION}
USER root

# Only the compiled result crosses over — never the sources.
COPY --from=fw-bake /out/ /etc/devcontainer-firewall/

# Fail the BUILD if the bake produced nothing. Without this, a silently empty
# bake yields an image that starts fine and filters nothing — the worst
# possible outcome, because it looks like it works.
RUN test -s /etc/devcontainer-firewall/baked-at \
 && test -s /etc/devcontainer-firewall/effective/sources.sha256

# Everything past this line runs unprivileged. Put your stack's own tooling
# above it, and end here.
USER node
```

## What to change in `devcontainer.json`

Three lifecycle lines are all that is strictly required — they hand each phase
to the baked dispatcher, which merges the image's fragments with yours:

```json
{
  "onCreateCommand":   "devc-hook on-create",
  "postCreateCommand": "devc-hook post-create",
  "postStartCommand":  "devc-hook post-start"
}
```

⚠️ **Do NOT list `anthropic.claude-code` in `customizations.vscode.extensions`.**

This is the one that bites. The image bakes the **patched** extension and
registers it in `extensions.json`; a pin in `devcontainer.json` is the single
path by which an **unpatched** copy from the Marketplace can arrive and replace
it. The `42-claude-ext-pin-warn` post-start hook banners if a pin reappears or
if the baked extension has gone missing — believe the banner.

List your project's own extensions normally; only that one is special.

The settings worth setting, and why:

```json
"customizations": {
  "vscode": {
    "settings": {
      // The baked extension is pinned by design. Auto-update would fetch an
      // unpatched build over it, which is the same failure as pinning it.
      "extensions.autoUpdate": false,
      "extensions.autoCheckUpdates": false,

      // zsh is the configured shell — Oh My Zsh, history, the prompt helpers
      // are all set up for it.
      "terminal.integrated.defaultProfile.linux": "zsh",

      // Provided by the `disable-webview-auth-redirect` patch. Without the
      // patch this setting does not exist and is simply ignored.
      "claudeCode.disableWebviewAuthRedirect": true,
      "claudeCode.disableLoginPrompt": true
    }
  }
}
```

Several `claudeCode.*` settings above are **created by the patches**, not by
Anthropic's extension — `fixStylePills` is another. They are inert on an
unpatched build, so leaving them in a project that later sets
`CLAUDE_CODE_EXT_PATCHS=none` costs nothing.

## Use compose — the firewall needs capabilities

**This is not optional either.** `init-firewall.sh` programs netfilter, and a
container without the right capabilities cannot do that: the firewall fails to
come up, and you get a container with no filtering at all. `devcontainer.json`
alone cannot grant capabilities — compose can.

```yaml
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile
      args:
        BASE_VERSION: ${BASE_VERSION:-0.1.0}
        CLAUDE_CODE_VERSION: ${CLAUDE_CODE_VERSION:-2.1.258}
        # Whether the build bakes firewall/domains.local.txt and
        # policy.local.d/ into the image. Hardened default 0 : those files are
        # gitignored and container-writable, so a rebuild would otherwise be a
        # silent path from "a postinstall edited a file" to "the firewall
        # allows more". Personal opt-in, through .env only.
        FIREWALL_ALLOW_LOCAL_AT_REBUILD: ${FIREWALL_ALLOW_LOCAL_AT_REBUILD:-0}

    # ─── The two capabilities the firewall needs, and ONLY those two ─────────
    # NET_ADMIN — create/flush iptables chains, create ipsets. This is what
    #             builds the ruleset at boot. Without it init-firewall.sh
    #             cannot start and nothing is filtered.
    # NET_RAW   — open raw sockets, which the ruleset and the probes need.
    #
    # Do not add a third. The image's own suite (run-image-suites.sh) asserts
    # this list is EXACTLY these two and fails otherwise — a capability is a
    # piece of root, and the point of this image is that the workload has none.
    #
    # Granting them to the CONTAINER does not grant them to the container USER:
    # escalation.sh asserts `node` holds CapEff=0000000000000000 even here, and
    # that `ip link add` and `iptables -L` are both refused without sudo.
    cap_add:
      - NET_ADMIN
      - NET_RAW

    # IPv6 off, defence in depth : the ruleset filters v4 : an interface that
    # auto-configures a v6 address would route around it. init-firewall.sh also
    # installs ip6tables DROP rules, belt and braces.
    sysctls:
      - net.ipv6.conf.all.disable_ipv6=1
      - net.ipv6.conf.default.disable_ipv6=1
      - net.ipv6.conf.lo.disable_ipv6=1

    env_file:
      - path: .env
        required: false

    volumes:
      - ..:/workspace:delegated
```

Then point `devcontainer.json` at it:

```json
{
  "dockerComposeFile": "docker-compose.yml",
  "service": "app",
  "workspaceFolder": "/workspace",
  "overrideCommand": false
}
```

`overrideCommand: false` matters — the image has its own `CMD` and letting
VS Code replace it with `sleep infinity` skips it.

**What must NOT be in that file**, because each one dissolves the boundary the
image exists to provide — and the image's suite asserts their absence on the
shipped templates:

| Never | Why |
|---|---|
| `privileged: true` | Every capability at once. The allowlist becomes decoration. |
| `network_mode: host` | The container shares the host's stack; there is no netns left to filter. |
| a `docker.sock` mount | That is root **on the host**, not in the container. Everything else becomes moot. |
| `ports:` | Publishes a container port to the host. The firewall governs *outbound*; this is the inbound direction, and it is your host you are opening. |

`devc-hook` merges three layers — `/opt/devcontainer/base/hooks/<phase>.d/*.sh`
(this image), `/opt/devcontainer/ext/hooks/<phase>.d/*.sh` (an image that
`FROM`s it) and `.devcontainer/hooks/<phase>.d/*.sh` (the project). Same
filename masks the layer below, unique filename adds, and a
`hooks/disabled.txt` (or the deprecated
`customizations.stitchu-devc.disabledHooks`) switches one off — except a
fragment marked `@required true`, which needs the explicit `!` opt-in.

Building an image **on top** of this one — your own hooks, skills, firewall
layer or extension patches : [EXTENDING.md](EXTENDING.md).

What the test suites cover, why, and how to run both halves :
[TESTING.md](TESTING.md).

## Non-Node stacks

There is no PHP or Android image. Stacks are project Dockerfiles that derive
from this base — copy the documented blocks :

- [stacks/php.md](stacks/php.md) — PHP 8.2 + Composer
- [stacks/android.md](stacks/android.md) — OpenJDK 17 + Kotlin + android.jar matrix
- [stacks/android-capacitor.md](stacks/android-capacitor.md) — the above + Coursier + Capacitor + AndroidX

## Check the image you pulled

Two suites ship **inside** the image and read nothing but the installed files,
so you can replay them against any published tag — no clone, no build:

```
docker run --rm -u node <image> bash /etc/devcontainer-firewall/tests/escalation.sh
docker run --rm -u node <image> bash /etc/devcontainer-firewall/tests/privilege.sh
```

`escalation.sh` freezes the OS boundary — the SUID/SGID inventory, file
capabilities, root-owned paths the container user can write, root's `PATH`, the
absence of a Docker socket, and the fact that `NET_ADMIN`/`NET_RAW` granted to
the container do not reach `node`. `privilege.sh` does the same for the firewall
control plane. Both refuse to run as root, on purpose.

The full assertion catalogue is in [TESTING.md](TESTING.md). Cutting a release
of this image — the gate, the version rules, the tag matrix — is
[RELEASING.md](RELEASING.md).

## License and third-party content

This repository is [MIT](LICENSE) licensed. That covers **this tree** — the
Dockerfile, `bin/`, `assets/`, the suites and the docs.

It does not, and cannot, relicense what the built image contains. The image is
assembled from Debian bookworm and Node 24, plus `dnsmasq`, `iptables`/`ipset`
(GPL-2.0), mitmproxy, `git-delta`, `gh`, zsh and Oh My Zsh, each under its own
terms; and it bakes the **Claude Code VS Code extension**, downloaded from the
Visual Studio Marketplace at build time and governed by Anthropic's terms, not
by this licence.

**Not affiliated with, endorsed by, or sponsored by Anthropic.** "Claude" and
"Claude Code" are Anthropic's; the name of this project describes what the
image is for.
