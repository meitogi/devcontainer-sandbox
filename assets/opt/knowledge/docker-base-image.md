# DevContainer base image scheme (v2.1)

The image is split into **two layers** built separately, plus an optional **variant** for PHP-heavy projects. This was introduced in v2.1.

```
.devcontainer/
├── Dockerfile.base    NEW (v2.1) — heavy layer, built once per CLAUDE_CODE_VERSION
│                      by initialize.sh → tag claude-devcontainer-base:${VERSION}
│                      (~1.1 GB live-measured)
├── Dockerfile         slim project layer — FROM claude-devcontainer-base:${VERSION}
│                      + project-specific RUNs (empty for Node-only, ~5 MB delta)
│                      Built by docker compose.
└── Dockerfile.php     NEW (v2.1-3) — variant for PHP stack
                       FROM claude-devcontainer-base:${VERSION} + PHP 8.2 + Composer 2
                       (Option B : per-project Dockerfile, no intermediate tag)
```

## Single source of truth: `CLAUDE_CODE_VERSION`

The env var lives in `.devcontainer/.env` and drives **three** install paths:

| Use | Where | Mechanism |
|---|---|---|
| 1. VSIX URL (build-time) | `Dockerfile.base` `ARG CLAUDE_CODE_VERSION` | `curl marketplace.visualstudio.com/.../claude-code/${V}/vspackage?targetPlatform=${VP}` |
| 2. npm fallback pin | `Dockerfile.base` Phase A RUN | `npm install -g @anthropic-ai/claude-code@${V}` (only invoked if Phase B symlink failed) |
| 3. `devcontainer.json` extension pin | `customizations.vscode.extensions` array | **Manual sync** — JSONC comment above the array reminds. Safety net for Scenario 3 (Marketplace down at build) |

The two-locations drift (`.env` + `devcontainer.json`) was the v2.1-1 bug. v2.1-2 makes it loud (sentinel + comment) but doesn't auto-sync — `devcontainer.json` doesn't support `${localEnv}` substitution from `.devcontainer/.env` without host shell setup.

## Failsafe Claude binary chain (3 scenarios)

`docker build` NEVER fails on a Claude-side problem. Marketplace can be down, a version retired the same day Anthropic publishes the next — daily work isn't hostage to Anthropic's CDN. Three scenarios encoded by `/etc/claude-source` :

| Scenario | Trigger | `/etc/claude-source` | `/usr/local/bin/claude` | `extensions.json` baked | Sentinel |
|---|---|---|---|---|---|
| 1 (optimal) | VSIX DL OK + Phase B symlink OK | `extension:<path>` | symlink to ext binary | yes | absent |
| 2 (Phase B failed) | VSIX DL OK + binary path moved or `claude --version` mismatch | `npm-fallback (VSIX baked, Phase B path issue)` | npm `cli.js` | yes | **present** |
| 3 (Marketplace down) | VSIX DL KO at build | `npm-fallback (no VSIX, runtime ext install via Marketplace)` | npm `cli.js` | no — VS Code DL at runtime via `devcontainer.json` pin | **present** |

`/etc/claude-fallback-warn` sentinel (scenarios 2+3) drives:
- Yellow loud banner in `post-start.sh` citing `/etc/claude-source` truncated to 51 chars + 3 diagnostic commands
- 1-line `Binary:` indicator in `shell-init.sh` (yellow `npm fallback (...)` or gray `extension (Phase B)`)

Diagnosis : `docker exec <ctr> cat /etc/claude-source`. Troubleshooting tree : [RUNBOOK § Troubleshoot Claude failsafe](../RUNBOOK.md#15-troubleshoot-claude-failsafe-scenarios).

## Layer ordering in `Dockerfile.base`

From least → most volatile :

| # | Layer | Invalidated by | Approx. size |
|---|---|---|---|
| 1 | `FROM node:24-bookworm-slim` | Debian/Node base bump | ~140 MB |
| 2 | apt minimal + `build-essential libssl-dev` + locale/man/doc purge + `curl wget` explicit | apt deps change | ~200 MB |
| 3 | mitmproxy binary baked (`/opt/mitmproxy/`) — A3 | `MITM_VERSION` bump | ~80 MB |
| 4 | gh CLI | gh repo update | ~40 MB |
| 5 | user setup + git-delta + `ENV HOME` | rarely | ~5 MB |
| 6 | firewall scripts COPY (compile-policy.py, addons/, policy.d/) | firewall source edit | ~1 MB |
| 7 | **Claude layer** — RUN VSIX DL + extract → RUN Phase B symlink + npm fallback → write `/etc/claude-source` | `CLAUDE_CODE_VERSION` bump | ~240-470 MB |
| 8 | shell init | rarely | <1 MB |

Bumping `CLAUDE_CODE_VERSION` only invalidates layer 7 (~30s rebuild on arm64). Layers 1-6 stay cached. Bumping `MITM_VERSION` invalidates from layer 3 down (~2 min rebuild).

## Why Debian slim (not Alpine)

Glibc 2.36 (Debian bookworm) preserved → Claude binary (Bun-compiled, ~240 MB) + iptables/ipset/dnsmasq + npm postinstalls (sharp, bcrypt) work identically. We pin to `node:24-bookworm-slim` rather than the floating `node:24-slim` to keep the Debian base explicit — Docker Hub may rebase `node:24-slim` to a future trixie at some point, and we'd rather make that a deliberate bump than discover it via a silent CI break. `node:24-bookworm-slim` drops ~500 MB of inherited build-deps we don't use (libxml2-dev, libpq-dev, libmagickwand-dev). We add back only what's needed: `build-essential python3 libssl-dev` for node-gyp.

## Host helpers (build-time observability)

| Helper | Use case | What it reports |
|---|---|---|
| `host-helpers/verify-slim-base` | Post-build sanity check | 9 PASS/FAIL gates : size cap 1.2 GiB, `/home/node` ≤ 5 MiB, Claude pin match, opencode absent, mitmproxy bundled, slim package count consistent, layer dedup vs other images, docker system df snapshot |
| `host-helpers/analyze-base-image` | "Where do the GB go?" debug | Per-layer (`docker history`) + per-directory (`du -sh` inside image) + per-package (`dpkg-query` top 30) breakdown |

Both refuse to run inside the container (`docker exec` not available recursively + needs to inspect docker daemon). Portable awk fallback for macOS hosts without `numfmt`.

## Build flags

| Env var | Set by | Effect |
|---|---|---|
| `BUILD_BASE_NO_CACHE=1` | User in env or `.env` | `docker build --no-cache` on the next base build. Auto-consumed from `.env` after one rebuild. Use case : Anthropic re-published the same version with a fix. |
| `DEBUG_REBUILD_CONTEXT=1` | User in env | `initialize.sh` dumps process tree + env to `.devcontainer/logs/rebuild-context-<ts>.log` (gitignored). Use case : `--no-cache` propagation detection regression. |

`initialize.sh` also auto-detects `--build-no-cache` request by walking the parent process ancestry for `devcontainer / docker / compose / buildkit / Code Helper` (case-insensitive) — when VS Code "Rebuild Container Without Cache" is clicked, the flag propagates to the base build automatically.

## `extensions.json` baked

VS Code reads `~/.vscode-server/extensions/extensions.json` to know what's installed. Without an entry, it **redownloads even if the directory exists**. We bake the file with hardcoded UUIDs :

| Field | Value | Why hardcoded |
|---|---|---|
| `identifier.uuid` | `3c13ae49-babe-45fe-8c48-5e45077a62bf` | Stable per-extension (Marketplace assigns once per publish, never changes) |
| `metadata.publisherId` | `89769da0-cc4b-40b0-8216-93ffb5a96b56` | Stable per-publisher (Marketplace assigns once per publisher account) |
| `metadata.publisherDisplayName` | `Anthropic` | Stable per-publisher |
| `version` | `${CLAUDE_CODE_VERSION}` | Substituted at build time |

If Anthropic ever republishes the extension under a new publisher ID → major event, bump everywhere.
