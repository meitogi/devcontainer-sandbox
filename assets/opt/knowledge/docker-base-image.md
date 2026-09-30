# DevContainer base image scheme

**One image, built once in its own repository and published multi-arch to
`ghcr.io/meitogi/devcontainer-sandbox`.** A project does not build it. Earlier
versions of this sheet described a `Dockerfile.base` a project built locally,
tagged `claude-devcontainer-base:${VERSION}`, plus a `Dockerfile.php` variant.
That lineage is gone — nothing in a v3 tree builds a base layer.

```
the image repo          the project
─────────────────       ──────────────────────────────────────────
Dockerfile              Dockerfile        FROM ghcr.io/…:<base>-cc<cc>
  single stage,           + project-specific RUNs
  node:24-bookworm-slim   + a firewall bake stage
  ~1.1 GB               docker-compose.yml  BASE_IMAGE arg
```

The tag is a pure function of two files in the image repo : `package.json`
supplies the `<base>` half, `cc-versions.json` the `<cc>` half and the matrix of
Claude Code versions built. A project picks a published pair; it does not mint
one. Stack additions go in the project's own `Dockerfile` on top — see the
extending guide rather than this sheet.

## `CLAUDE_CODE_VERSION` — a build argument, not a project setting

It is `ARG CLAUDE_CODE_VERSION` in the image's Dockerfile, supplied by CI from
`cc-versions.json`, and it drives **two** install paths at build time :

| Use | Where | Mechanism |
|---|---|---|
| 1. VSIX URL | `ARG CLAUDE_CODE_VERSION` | `curl marketplace.visualstudio.com/.../claude-code/${V}/vspackage?targetPlatform=${VP}` |
| 2. npm fallback pin | the conditional npm RUN | `npm install -g @anthropic-ai/claude-code@${V}`, invoked only when the VSIX branch did not produce a working binary |

**There is no third path, and that is deliberate.** A `devcontainer.json`
extension pin used to act as a safety net; it is now the one route by which an
**unpatched** copy of the extension can arrive, because the image bakes a patched
one and registers it in `extensions.json`, which is what VS Code actually reads.
The v3 template therefore does not list `anthropic.claude-code` at all, and the
`claude-ext-pin-warn` fragment banners at every start if a pin reappears or
diverges from the baked version.

A project changes its Claude Code version by pulling a different published tag,
not by editing a variable.

## Failsafe Claude binary chain (3 scenarios)

`docker build` NEVER fails on a Claude-side problem. Marketplace can be down, a version retired the same day Anthropic publishes the next — daily work isn't hostage to Anthropic's CDN. Three scenarios encoded by `/etc/claude-source` :

| Scenario | Trigger | `/etc/claude-source` | `/usr/local/bin/claude` | `extensions.json` baked | Sentinel |
|---|---|---|---|---|---|
| 1 (optimal) | VSIX DL OK + Phase B symlink OK | `extension:<path>` | symlink to ext binary | yes | absent |
| 2 (Phase B failed) | VSIX DL OK + binary path moved or `claude --version` mismatch | `npm-fallback (VSIX baked, Phase B path issue)` | npm `cli.js` | yes | **present** |
| 3 (Marketplace down) | VSIX DL KO at build | `npm-fallback (no VSIX, runtime ext install via Marketplace)` | npm `cli.js` | no — VS Code DL at runtime via `devcontainer.json` pin | **present** |

`/etc/claude-fallback-warn` sentinel (scenarios 2+3) drives:
- the loud banner from the `claude-fallback-warn` post-start fragment, citing
  `/etc/claude-source` plus diagnostic commands
- the `Binary:` row of `boot-summary`, the closing panel of a start

Diagnosis : `docker exec <ctr> cat /etc/claude-source`. Troubleshooting tree :
[`../docs/troubleshooting.md`](../docs/troubleshooting.md).

## Layer ordering

From least → most volatile :

| # | Layer | Invalidated by | Approx. size |
|---|---|---|---|
| 1 | `FROM node:24-bookworm-slim` | Debian/Node base bump | ~140 MB |
| 2 | apt minimal + `build-essential libssl-dev` + locale/man/doc purge + `curl wget` explicit | apt deps change | ~200 MB |
| 3 | mitmproxy binary baked (`/opt/mitmproxy/`) — A3 | `MITM_VERSION` bump | ~80 MB |
| 4 | gh CLI | gh repo update | ~40 MB |
| 5 | user setup + git-delta + `ENV HOME` | rarely | ~5 MB |
| 6 | firewall toolchain COPY (compile-policy.py, addons/, policy.d/, the baked allowlist) | firewall source edit | ~1 MB |
| 7 | **Claude layer** — RUN VSIX DL + extract → RUN Phase B symlink + npm fallback → write `/etc/claude-source` | `CLAUDE_CODE_VERSION` bump | ~240-470 MB |
| 8 | the baked tree — hooks, knowledge, docs, skills and their deps | any asset edit | ~5 MB |

Bumping `CLAUDE_CODE_VERSION` only invalidates layer 7 (~30s rebuild on arm64). Layers 1-6 stay cached. Bumping `MITM_VERSION` invalidates from layer 3 down (~2 min rebuild).

## Why Debian slim (not Alpine)

Glibc 2.36 (Debian bookworm) preserved → Claude binary (Bun-compiled, ~240 MB) + iptables/ipset/dnsmasq + npm postinstalls (sharp, bcrypt) work identically. We pin to `node:24-bookworm-slim` rather than the floating `node:24-slim` to keep the Debian base explicit — Docker Hub may rebase `node:24-slim` to a future trixie at some point, and we'd rather make that a deliberate bump than discover it via a silent CI break. `node:24-bookworm-slim` drops ~500 MB of inherited build-deps we don't use (libxml2-dev, libpq-dev, libmagickwand-dev). We add back only what's needed: `build-essential python3 libssl-dev` for node-gyp.

## Build-time observability

The `host-helpers/verify-slim-base` and `host-helpers/analyze-base-image`
scripts this sheet used to document belonged to the era when every project
built its own base image locally. That lineage is gone : the image is built
once and published, so a project has nothing to inspect at build time.

The equivalent checks now live in the image's own repository and run before a
release rather than after a project's build — the size and layout gates, the
per-architecture bench matrix, and the privilege and escalation suites that
replay against any published tag without needing a checkout.

## Build flags

| Env var | Set by | Effect |
|---|---|---|
| `DEBUG_REBUILD_CONTEXT=1` | User in env or `.devcontainer/.env` | `devc initialize` dumps the process tree + env to `.devcontainer/tmp/logs/`. Use case : the rebuild-signal detection misreads a start. |

`BUILD_BASE_NO_CACHE` is retired along with the local base build — there is no
base layer left for a project to rebuild without cache. `devc initialize` still
walks the parent process ancestry (`devcontainer / docker / compose / buildkit /
Code Helper`) to tell a plain start from a rebuild, which is what
`DEBUG_REBUILD_CONTEXT` dumps.

## `extensions.json` baked

VS Code reads `~/.vscode-server/extensions/extensions.json` to know what's installed. Without an entry, it **redownloads even if the directory exists**. We bake the file with hardcoded UUIDs :

| Field | Value | Why hardcoded |
|---|---|---|
| `identifier.uuid` | `3c13ae49-babe-45fe-8c48-5e45077a62bf` | Stable per-extension (Marketplace assigns once per publish, never changes) |
| `metadata.publisherId` | `89769da0-cc4b-40b0-8216-93ffb5a96b56` | Stable per-publisher (Marketplace assigns once per publisher account) |
| `metadata.publisherDisplayName` | `Anthropic` | Stable per-publisher |
| `version` | `${CLAUDE_CODE_VERSION}` | Substituted at build time |

If Anthropic ever republishes the extension under a new publisher ID → major event, bump everywhere.
