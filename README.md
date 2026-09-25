# devcontainer-sandbox

**A devcontainer base image that gives Claude Code room to work, and a network
it cannot leave.**

```
ghcr.io/meitogi/devcontainer-sandbox:<base-version>-cc<cc-version>
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
- **A boot panel** — `boot-summary` states, in one frame at the top of your
  first terminal, what the container actually started with: both versions, the
  Claude mode and which binary backs it, the firewall mode and allowlist size,
  the resolved patcher ref and whether its sentinels are live. Measured once at
  the end of `post-start` and cached, so every shell shows the boot rather than
  re-measuring the present.
  When something is off it says which line and why, and points at
  [docs/boot-warnings.md](docs/boot-warnings.md) — the jargon a warning cannot avoid
  ("no L7 filter", "sentinels", "Phase B") explained for someone meeting it for
  the first time, with the fix for each.
- **Skills and knowledge** for the agent, under `/opt/devcontainer/base/` —
  including `/prepare-stack`, which walks a project through building its own
  layer on top of this one.
- **Node 24 on bookworm-slim**, zsh + Oh My Zsh, git + git-delta, `gh`, and a
  task runner. Non-Node stacks extend the image; see [Non-Node stacks](#non-node-stacks).

## It ships the extension unmodified — and a toolkit to patch your own copy

The image preinstalls Anthropic's Claude Code VS Code extension **exactly as
published**, and modifies nothing. That is a deliberate constraint, so it is on
the front page rather than in a footnote.

Anthropic's *Legal and compliance* page sets three conditions on preinstalling
Claude Code: it must not be modified, no authentication method may be removed
or restricted, and "Claude Code" may not be used in the product's name. This
image respects all three — the VSIX is extracted and left alone, the native CLI
is symlinked rather than rewritten, authentication is untouched, and the image
is called `devcontainer-sandbox`.

You can check that rather than take it on faith. The extension tree in the
image is byte-identical to the Marketplace VSIX for the version in its tag:

```
docker run --rm <image> sh -c '. /etc/claude-build-env && sha256sum "$EXT_DIR/extension.js"'
```

### One upstream interaction to know about

On recent VS Code builds, `globalThis.navigator` is installed as a "pending
migration" accessor that **throws on any access**, `typeof` included. Claude
Code 2.1.x bundles a Zod version that reads `navigator` at module load, which
trips that throw during top-level `require` — before the activation function
runs. The symptom: the Claude panel does not open, the activity-bar icon
flashes and dies, and the output channel shows
`PendingMigrationError: navigator is now a global in nodejs`.

That is a defect in how two upstream projects meet, and **this image cannot fix
it**: fixing it means rewriting `extension.js`, which is precisely what
shipping the extension as published forbids. If you hit it, the workaround is
yours to apply on your own copy — a patcher that sets `navigator` to
`undefined` before the bundle loads, applied through the mechanism below. It is
one of the reasons the patch hook exists at all.

Whether you hit it depends on your VS Code version, not on this image.

### If you keep your own patchers

Some people run a patched copy of the extension for themselves. That is their
business, on their machine, on their own installation — so the image ships the
**toolkit** that can run a patcher, and no patcher:

| Ships | Does not ship |
|---|---|
| `run-all.sh` (selection + orchestration), `_common.py`, `AUTHORING.md` (the header contract) | any patcher, any registry of patchers, any description of how to write one against a particular bundle |
| `restore-ext-patches` — restore the pristine files, replay a selection | |
| `ext-patches-sync` + the `45-ext-patches.sh` hook — resolve patchers and apply them at container create | |
| `ext-patches-update` — move to another patch set, on demand | |

Two ways to bring your own. In **your own** Dockerfile, on **your own** image:

```
COPY my-patch.py /usr/local/bin/vscode-ext-patchs/
RUN . /etc/claude-build-env && restore-ext-patches all
```

…or at container create, without rebuilding, by setting these in
`.devcontainer/.env` (all commented out in `.env.example`, no defaults baked):

```
EXT_PATCHES_DIR=/opt/ext-patchs          # a directory you mount — no network, no token
# …or a repository, pinned and cached:
EXT_PATCHES_REPO=you/your-patchers
#EXT_PATCHES_REF=cc2.1.280-r1            # unset = auto: the newest tag cut for this container's Claude Code version
EXT_PATCHES_TOKEN=github_pat_...         # only if that repository is private
#EXT_PATCHES_ALLOW_UNTESTED=1            # resolve to HEAD when no tag matches this CC version
```

With none of them set the hook exits silently and the extension stays as
published — that is the default, and the nominal state of this image.

The selection vocabulary is `all`, `none`, a category (`ux`, `fix`, `notify`), a
patcher name, or any comma-separated mix; a token that names nothing fails
loudly rather than being silently dropped. The build keeps a pristine copy of
`package.json`, `extension.js` and `webview/index.js` under
`/usr/local/share/claude-ext-orig/`, so `restore-ext-patches` can always put the
extension back the way Anthropic shipped it. A VS Code window reload is needed
for any runtime change to show.

See [AUTHORING.md](assets/vscode-ext-patchs/AUTHORING.md) for the header
contract a patcher must honour.

**Moving to a newer patch set.** Unset, `EXT_PATCHES_REF` resolves at boot to
this container's own line — the newest `cc<version>-r<n>` already cached, or
the repository's tags once when nothing of that line is cached (a fresh
container, or the first boot after a Claude Code bump) — and never to HEAD. A
boot never moves on its own within a line: "whatever was newest that morning"
is not reproducible. Moving is a deliberate act with its own command,
`ext-patches-update`, which resolves a ref once, applies it, and leaves an auto
ref auto (the newly cached tag is what the next boot resolves to) or writes the
resolved value back into your
`.env`. What moves is a decision; what boots is still a pin.

It resolves **per Claude Code version**. A patcher set is tested against
particular versions and its tag says which — `cc<version>-r<n>` — so the
command reads the installed extension's version, keeps the tags of that line,
and takes the largest `-r`. Nothing tagged for your version is an answer, not a
guess: it refuses and names the lines that do exist. `EXT_PATCHES_ALLOW_UNTESTED=1`
takes the repository's HEAD instead, and even then what lands in the `.env` is
the commit it resolved to, never the word `HEAD`. A repository that tags
`v1.2.3` — anything not following the convention — keeps the newest-overall
behaviour unchanged.

```
ext-patches-update --check          # what is installed, what is available — changes nothing
ext-patches-update                  # the latest release (or tag), applied and re-pinned
ext-patches-update --ref v1.3.0     # a named target
ext-patches-update --dir /opt/mine  # a local checkout: no network, no token
ext-patches-update --reapply        # replay the current ref, e.g. after a CC bump
ext-patches-sync --status           # what is configured and cached, read-only
```

The pin is only rewritten once the patchers are actually on disk: an update
that failed to download leaves `.env` naming the ref you still have, rather
than sending the next boot after a cache that was never written. Add
`--no-write-env` for a trial run. A window reload is needed either way.

**What the fetch path costs you, stated plainly.** Resolving patchers from a
repository needs two GitHub hosts through the firewall, and the allowlist
entries for them are **owner-agnostic** — `^/repos/<owner>/<repo>/tarball/…`
and `^/repos/<owner>/<repo>/(releases/latest|tags)$` on `api.github.com`, plus
the archive path the first redirects to on `codeload.github.com`. They cannot
be narrowed to your repository, because the image ships no default and must not
name one. So on a container that carries a token, any GitHub source tarball
that token can read is reachable, and so is the tag list of any repository it
can see. It is GET-only, and limited to those three paths — no contents API,
no `/releases` listing, no git protocol, no write verb — and
the whole thing is inert without a token. If that trade is not one you want,
use `EXT_PATCHES_DIR` and mount the patchers instead: no network, no token,
nothing to expire. The entries and the reasoning are in
`assets/etc-firewall/domains.d/00-base.txt` and the matching `policy.d/` files.

### Which extension versions

The versions this image is built for are the ones listed in
[cc-versions.json](cc-versions.json), and each gets its own tag:

```
ghcr.io/meitogi/devcontainer-sandbox:<base-version>-cc<claude-code-version>
```

Pin both. The image version and the Claude Code version are independent axes,
which is why the matrix exists rather than a single moving `latest`. If you do
run patchers, note that one rewrites a bundled JavaScript file and so is tied
to the extension version it was written against — that is your pin to manage,
and the reason an unset `EXT_PATCHES_REF` resolves to your version's own line
and never to HEAD.

## Quickstart

Your project's `.devcontainer/Dockerfile` — the first stage is **not** optional,
it is what bakes your allowlist:

```dockerfile
# the three published lines
#   1.5.0-cc2.1.280   (default)
#   1.5.0-cc2.1.272
#   1.5.0-cc2.1.220
ARG BASE_VERSION=1.5.0
ARG CLAUDE_CODE_VERSION=2.1.280

FROM ghcr.io/meitogi/devcontainer-sandbox:${BASE_VERSION}-cc${CLAUDE_CODE_VERSION} AS fw-bake
USER root
COPY firewall/ /tmp/fw-src/
RUN /usr/local/bin/firewall-docker-setup.sh --src /tmp/fw-src --dest /out

FROM ghcr.io/meitogi/devcontainer-sandbox:${BASE_VERSION}-cc${CLAUDE_CODE_VERSION}
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

Skills live at `/opt/devcontainer/base/skills/` and `sync-skills` installs
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
`sync-skills`.

To switch one off, rename its `<name>.skill.md` to `<name>.skill.disabled.md`
and re-run `sync-skills` — it drops the command and skips the skill's hooks,
so disabling is one `mv` and one sync.

## What ships where

| Repo path | Image path | Content |
|---|---|---|
| `bin/` | `/usr/local/bin/` | `devc-hook` (lifecycle dispatcher), `boot-summary` (the boot panel), `reload-firewall` (guarded runtime reload), `firewall-digest.sh` (sourced library, 0644), `init-firewall.sh`, `test-firewall.sh`, `firewall-docker-setup.sh` (build-time bake), `compile-policy.py`, `mitm-init.sh`, `firewall-blocks` |
| `assets/opt/` | `/opt/devcontainer/base/` | `hooks/` (lifecycle fragments — the dispatcher's base layer), `skills/`, `knowledge/`, `zshrc` |
| `assets/etc-firewall/` | `/etc/devcontainer-firewall/` | `dnsmasq.conf`, `tests/`, `addons/` — the firewall *infrastructure*. The image ships **no domains allowlist** : the project allowlist is baked by the project Dockerfile (see below), so the image can never silently widen a project's firewall |
| `assets/vscode-ext-patchs/` | `/usr/local/bin/vscode-ext-patchs/` | the patch toolkit — orchestrator, shared helpers, header contract. No patcher: the extension ships unmodified |

Plus the toolchain baked by the `Dockerfile` itself : Node 24 (bookworm-slim),
Claude Code (VSIX + CLI, version pinned per tag), mitmproxy, dnsmasq,
iptables/ipset, git + git-delta, gh, wtf, zsh + Oh My Zsh, build-essential.

Not in the image, on purpose : the notify daemon (installed by
`devc notify install`), project firewall allowlists, CLAUDE.md templates,
LESSONS baseline (projects start blank), and the `devc` CLI itself
(`@stitchu/devcontainer-cli` is not on npm yet — it will be pre-installed
once published).

## Tag scheme

`<base-version>-cc<cc-version>` — e.g. `1.5.0-cc2.1.280`. Base follows its
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
#
# The three published lines:
#   1.5.0-cc2.1.280   (default)
#   1.5.0-cc2.1.272
#   1.5.0-cc2.1.220
ARG BASE_VERSION=1.5.0
ARG CLAUDE_CODE_VERSION=2.1.280

# ─── Stage 1 — bake the allowlist. NOT optional. ─────────────────────────────
# The image ships firewall machinery and NO allowlist. This stage compiles
# yours into /out. Skip it and init-firewall.sh fails at onCreate: every
# container start explodes while the image itself looks perfectly healthy.
FROM ghcr.io/meitogi/devcontainer-sandbox:${BASE_VERSION}-cc${CLAUDE_CODE_VERSION} AS fw-bake

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
FROM ghcr.io/meitogi/devcontainer-sandbox:${BASE_VERSION}-cc${CLAUDE_CODE_VERSION}
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

**You probably do not need to list `anthropic.claude-code` in
`customizations.vscode.extensions`** — the image already installs it, and a pin
only gives VS Code a reason to go and fetch it again.

It is no longer the trap it used to be. The image now bakes the extension
unmodified, so a Marketplace copy at the same version is the same bytes; a pin
costs a download, not a broken install. Two things still make it worth leaving
out: it can resolve to a **different version** than the tag you pinned, and if
you run your own patchers it will silently replace the copy they patched. Keep
`extensions.autoUpdate` off for the same reason.

The `42-claude-ext-pin-warn` post-start hook banners if a pin reappears or if
the baked extension has gone missing, and the `45-ext-patches` hook re-checks
its sentinels at every start — so if an update does replace the bundle, your
patchers are re-applied rather than quietly lost.

List your project's own extensions normally.

The settings worth setting, and why:

```json
"customizations": {
  "vscode": {
    "settings": {
      // The baked extension is pinned by design: auto-update would pull a
      // different version over the one your tag names.
      "extensions.autoUpdate": false,
      "extensions.autoCheckUpdates": false,

      // zsh is the configured shell — Oh My Zsh, history, the prompt helpers
      // are all set up for it.
      "terminal.integrated.defaultProfile.linux": "zsh",

      // Contributed by a patcher, not by the stock extension. Inert without
      // one, so it is harmless to leave in.
      "claudeCode.disableWebviewAuthRedirect": true,
      "claudeCode.disableLoginPrompt": true
    }
  }
}
```

Some `claudeCode.*` settings above are **contributed by patchers**, not by
Anthropic's extension. On this image, which ships none, they do not exist and
are simply ignored — so they cost nothing to leave in, and start working if you
later bring your own patchers.

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
        # The three published lines: 1.5.0-cc2.1.280 (default), 1.5.0-cc2.1.272,
        # 1.5.0-cc2.1.220.
        BASE_VERSION: ${BASE_VERSION:-1.5.0}
        CLAUDE_CODE_VERSION: ${CLAUDE_CODE_VERSION:-2.1.280}
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

**Claude Code is preinstalled unmodified.** Anthropic's *Legal and compliance*
page sets three conditions on preinstalling it: it must be installed and run as
published, no authentication method may be removed or restricted, and "Claude
Code" may not appear in the product's name or identity. This image is built to
meet all three — the VSIX is extracted and left byte-identical, authentication
is untouched, no patcher ships, and the image is named for what it is. Patching
your own installation is your call to make on your own machine; the toolkit
here can run a patcher, and brings none.

**Not affiliated with, endorsed by, or sponsored by Anthropic.** "Claude" and
"Claude Code" are Anthropic's; the name of this project describes what the
image is for.
