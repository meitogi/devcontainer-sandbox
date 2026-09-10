# Knowledge — index

Entry point for the AI-facing documentation of this devcontainer.
Human-facing docs (`README.md`, `RUNBOOK.md`, `SECURITY.md`) stay at the
root of `.devcontainer/`. **Topics that Claude needs when modifying the
code live here under `knowledge/`**, one file per topic, so the AI loads
only the relevant section instead of the whole monolith. Split rule:
topics **≥ 100 lines** get their own `knowledge/<topic>.md`; topics
**< 50 lines** stay inline in this INDEX. The 50–100 L range is
case-by-case.

## Topic files

- [`firewall.md`](firewall.md) — **Web search & research policy** (when to
  propose `domains.local.txt` vs a committed `domains.d/` entry for sources outside the
  17-host baseline) + firewall internals (compile-policy pipeline) + strict
  mode (force-proxy, mitmproxy, ipset, HTTPS_PROXY propagation, sysctls
  pitfalls, ruamel.yaml constraint).
- [`firewall-reload-local.md`](firewall-reload-local.md) — hot-reload the
  local layer (`domains.local.txt` + `policy.local.d/`) without rebuilding
  the devcontainer, via `sudo .devcontainer/reload-local.sh`. Basic mode
  only ; strict mode still requires rebuild.
- [`extension-points.md`](extension-points.md) — how to add a skill,
  host-helper, ecosystem extractor, lifecycle behaviour, firewall
  domain, mitmproxy addon, Dockerfile variant.
- [`docker-base-image.md`](docker-base-image.md) — base-image scheme,
  failsafe Claude binary chain, layer ordering, build flags, baked
  extensions.
- [`ollama-local.md`](ollama-local.md) — host-side Ollama backend and
  `claude-switch` toggle (full user-facing guide, formerly at the
  `.devcontainer/` root).
- [`wtf.md`](wtf.md) — `.wtfcmd.yaml` authoring guide (task runner
  baked in the base image).

## Inline topics — table of contents

- [Lifecycle ordering + extension points](#lifecycle-ordering--extension-points)
- [Idempotency contracts](#idempotency-contracts)
- [Per-ecosystem allowlists — `domains.d/`](#per-ecosystem-allowlists--domainsd)
- [Local Ollama backend (host-side `claude-switch`)](#local-ollama-backend-host-side-claude-switch)
- [Policy parity across Claude Code targets](#policy-parity-across-claude-code-targets)
- [Meta-skill `/prepare-plan` (scaffolding)](#meta-skill-prepare-plan-scaffolding)
- [Modifications interdites / fragiles](#modifications-interdites--fragiles)
- [Volumes & filesystem layout](#volumes--filesystem-layout)
- [Claude OAuth sync flow](#claude-oauth-sync-flow)
- [Hooks install pattern](#hooks-install-pattern)
- [Skills install pattern](#skills-install-pattern)
- [Debug recipes](#debug-recipes)
- [Cross-platform sed (BSD vs GNU)](#cross-platform-sed-bsd-vs-gnu)
- [Checklist — "I'm resuming this devcontainer setup"](#checklist--im-resuming-this-devcontainer-setup)
- [Template origin](#template-origin)

---

## Lifecycle ordering + extension points

The devcontainer lifecycle has five hook points, executed in this order. Choosing the right one for a new behaviour is non-trivial: each has different idempotency guarantees and runs in a different context.

| # | Hook | Where | When | Use for |
|---|---|---|---|---|
| 1 | `initialize.sh` | **host**, before build | every container open (cheap if already configured) | flag files, `.env` sync, interactive menus, syncs that must happen before Docker sees the change |
| 2 | `on-create.sh` | container, sudo-capable | **once** per container creation, before VS Code Server downloads extensions | firewall early bring-up (before any outbound is needed) |
| 3 | `post-create.sh` | container | **once** per container creation, after on-create | symlink `/workspace/CLAUDE.md` by claude-mode, smoke-test firewall |
| 4 | `post-start.sh` | container | **every** container start (including restarts) | banner, OAuth sync, sync-skills, install-extensions safety net, idempotent cleanups |
| 5 | `shell-init.sh` | container, sourced | **every** interactive terminal opens | CA env vars, gh device auth attempt, creds-conflict prompt, session banner |

Sentinels that gate the lifecycle:

| Sentinel | Set by | Purpose |
|---|---|---|
| `.devcontainer/.configured-auth` | `initialize.sh` menu | gh auth mode (`standard` / `advanced`); deletion triggers re-prompt |
| `.devcontainer/.configured-claude-mode` | `initialize.sh` menu | claude mode (`dev` / `reviewer`); `post-create.sh` symlinks accordingly |
| `.devcontainer/.configured-firewall-mode` | `initialize.sh` (silent `strict`) | `off` / `basic` / `strict`; canonical mode source |
| `.devcontainer/.configured-claude-rules` | Claude first-prompt analysis | one-shot setup of project conventions in CLAUDE.md |

### Where to add a new behaviour

**New behaviour at every restart** (e.g. refresh a cached file from upstream):
→ Append to `post-start.sh`. The script must be **idempotent**: it runs on every container start including restarts after editing.

**New behaviour once per terminal** (e.g. export an env var for tools that don't read `/etc/environment`):
→ Add to `shell-init.sh`. Be conservative — this runs on every shell, including non-interactive ones invoked by VS Code internally. Always gate interactive prompts with `[ -t 0 ]`.

**New behaviour on first container creation** (e.g. one-shot data import, schema migration, persistent dir creation):
→ Add to `post-create.sh`. Will NOT re-run after `Reopen in Container` on an existing container.

**New behaviour before VS Code Server is alive** (e.g. firewall setup, system-level mounts):
→ Add to `on-create.sh`. The only hook with sudo at this stage. Keep it minimal; failures are hard to debug.

**New behaviour on the host before build** (e.g. read a host-side flag, prompt the user, sync a config file):
→ Add to `initialize.sh`. This is the **only** hook that can interact with the user before the container starts.

---

## Idempotency contracts

Every script in this devcontainer is expected to be safely re-runnable. Violating these contracts breaks `Reopen in Container`, `Rebuild Container`, and the post-start replay during restarts.

| Script | Contract | Mechanism |
|---|---|---|
| `initialize.sh` | Re-runnable; flags short-circuit interactive prompts | `[ -f .configured-X ] && return` early-exits per setting |
| `init-firewall.sh` | Re-runnable; full reset then re-apply | `iptables -F`, `ipset destroy`, `dnsmasq pkill` at start |
| `compile-policy.py` | Atomic write of compiled output | `.tmp` + `os.rename()` (atomic on same FS) |
| `post-start.sh` | All sub-steps no-op if already applied | flag files, `grep -q` before append, `command -v` before invoke |
| `install-extensions.sh` | Skip if extension already installed | parses `code --list-extensions` first |
| `sync-creds.sh` | Compare `expiresAt`, copy only if newer | always `exit 0` (never blocks Claude) |
| `sync-skills.sh` | Merge skill hooks into settings.json, dedup by `command` | inline Python merge, no overwrite |
| `firewall-mode.sh` | Re-runnable; flips flag + `.env` consistently | `awk + temp file + mv` for `.env` portability |
| `test-firewall.sh` | Side-effect free; can run mid-session | `curl` + `nc` probes only |

**Anti-pattern**: appending to a file without `grep -q` first. Every container restart would duplicate the line.

**Anti-pattern**: editing `/etc/environment` with `sed -i` from a host-side script (BSD vs GNU sed mismatch). Use `awk + temp file + mv`.

---

## Per-ecosystem allowlists — `domains.d/`

`init-firewall.sh` merges **every `.txt` under `domains.d/`** additively with
the baseline `domains.txt`. That is the committed place for hosts a project's
own dependencies need — npm registries, package CDNs, a vendor's binary host.

```
firewall/domains.txt              the project baseline, committed
firewall/domains.d/<eco>.txt      per-ecosystem additions, committed
firewall/domains.local.txt        personal, gitignored, ad-hoc only
```

Same syntax in all three. All are **baked at build**, so any change needs
`Dev Containers: Rebuild Container` — they are not read at runtime.

Populating `domains.d/<eco>.txt` is manual: install the dependency, read what
`firewall-blocks` reports as denied, and commit those hosts. `firewall-blocks`
is the authoritative list — guessing a vendor's CDN from its `.com` almost
never works.

---

## Local Ollama backend (host-side `claude-switch`)

Switch Claude Code between Anthropic cloud (default) and a local Ollama backend on the Mac host, with full mitmproxy audit. Full user-facing guide: [ollama-local.md](ollama-local.md). The toggle lives in `host-helpers/claude-switch` — there's intentionally no in-container helper anymore.

Pieces wired up in the devcontainer:

| Surface | File | Role |
|---|---|---|
| DNS alias (Ollama) | `docker-compose.yml` (`extra_hosts`) | `ollama.internal:host-gateway` (audited) + `ollama.local:host-gateway` (bypass, `.local` ∈ NO_PROXY) |
| DNS alias (sidecar) | `init-firewall.sh` (dnsmasq) | `server=/claude-bridge/127.0.0.11` + `cname=claude-bridge.local,claude-bridge` (`.local` ∈ NO_PROXY for bypass) — value-overrides the 8.8.8.8 line `compile-policy.py` auto-emits |
| Firewall L1 | `firewall/domains.txt` | `[POST] ollama.internal /v1/messages` block + `[POST] claude-bridge /v1/messages` block |
| Firewall L7 (Ollama) | `firewall/policy.d/ollama.internal.yaml` | `endpoints: /v1/messages POST max_body_kb: 32768`, `allowed_header_patterns: ^X-(Api\|Anthropic\|Service\|Claude\|Stainless\|App\|Client\|Organization)-?` (mirror of api.anthropic.com — Claude Code sends those headers regardless of destination, mitmproxy enforces before Ollama sees them), `enforcement_mode: block`. See [§ Policy parity](#policy-parity-across-claude-code-targets) |
| Firewall L7 (sidecar) | `firewall/policy.d/claude-bridge.yaml` | STRICT 1:1 mirror of `api.anthropic.com.yaml` `/v1/messages` block. See [§ Policy parity](#policy-parity-across-claude-code-targets) for the invariant |
| Translation sidecar | `docker-compose.yml` (`claude-bridge:` service) + `claude-bridge/Dockerfile` | UCP image baking apt + UCP clone + pip as cached layers (boot <10 s) ; vendored `ucp-overlay/app/` patches Ollama 0.9+ `reasoning` SSE → Anthropic `thinking` content blocks. Image tag `uniclaudeproxy:local` |
| Sidecar config | `claude-bridge/config.example.json` (committed) + `claude-bridge/config.json` (gitignored, auto-bootstrapped by `initialize.sh`) + `claude-bridge/healthcheck.sh` (TCP probe `:9223` since UCP has no `/health`) | Maps Anthropic model names → Ollama aliases (`use_react: true, force_stream: true, enable_thinking: true`) + `system_replacements` to defuse "You are Claude Code" inside Ollama |
| Host port open | `.devcontainer/firewall/ports.txt` (`host:11434`, `claude-bridge:9223`, one per line) | iptables ACCEPT before RFC1918 REJECT (cf. `init-firewall.sh` § *ports.txt*) — baked into the image at build ; both entries coexist, only the active `ANTHROPIC_BASE_URL` decides which path is used |
| Routing toggle | `.env` (3 URL lines value-discriminated : `http://ollama.internal:11434`, `http://claude-bridge:9223`, `http://claude-bridge.local:9223`) + `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CONFIG_DIR`) | 3 modes (`local`, `local-proxy`, `cloud`) driven by `host-helpers/claude-switch` ; sed targets the exact URL value, not just the var name, so the inactive lines stay as data. `local-proxy` auto-starts the sidecar via the same logic as `host-helpers/claude-bridge up`. Per-profile prompt files `CLAUDE-local-<name>-dev.md` are a planned convention (current files : `CLAUDE-local-dev.md` only) — a `/tune-claude-local` skill that would land per-profile content is deferred for v1 |
| Sidecar lifecycle wrapper | `host-helpers/claude-bridge` (host-side) | `{up\|down\|restart\|status\|logs}` — built-in healthcheck polling (`docker inspect .State.Health.Status`). Refuses inside the container. Rarely needed manually because `claude-switch local-proxy` auto-starts |
| Manual tuning harness | `tests/diag-bridge-translation.sh` + `tests/tweak-claude-md-for-local.sh` | Cloud-as-oracle measurement + idempotent variant applier between `<!-- 1B-LIGHT-MODEL-DIRECTIVES-START/END -->` markers of `CLAUDE-local-dev.md`. Workflow documented in [ollama-local.md § Tuning](ollama-local.md#tuning-the-local-prompt-for-your-hardware-current-ad-hoc-workflow). **Future** : a `/tune-claude-local` skill could industrialize this loop ; deferred for v1 |
| Config dir isolation | `~/.claude-local/` (created by `post-start.sh` when local mode active in `.env` at boot) | Per-mode `.credentials.json` + `projects/` + `todos/` ; shared (symlinked from `~/.claude/`) : `commands skills memory plugins settings.json .claude.json`. Guarantees cloud OAuth creds are never touched by local / local-proxy mode |
| Project rules | `<project>/CLAUDE.md` symlink | `claude-switch local` / `local-proxy` repoints to `CLAUDE-local-dev.md` (which "Read also: CLAUDE-dev.md" for baseline) ; `claude-switch cloud` restores from `.configured-claude-mode` |
| Banner + init | `post-start.sh` | Yellow `🦙 Claude mode: LOCAL` (Ollama direct) or `LOCAL-PROXY` (sidecar) per the active `ANTHROPIC_BASE_URL` ; red banner if bypass `ollama.local` / `claude-bridge.local`. Same gate runs `_init_claude_local_dir` once per container start |

Mechanism rationale (don't break these):
- The `.internal` TLD is NOT in `NO_PROXY` (`localhost,127.0.0.0/8,host.docker.internal,.local`), so traffic to `ollama.internal:11434` is routed via `HTTPS_PROXY=http://127.0.0.1:8080` (mitmproxy). `.local` IS in NO_PROXY, hence the bypass alias.
- The `ports.txt` rule is intentionally NOT UID-filtered — mitmproxy itself needs to dial the host. That's also why anything in the container can reach `host-gateway:11434` directly (mitigated by the policy enforcement layer when the audited alias is used).
- Isolation via `CLAUDE_CONFIG_DIR=/home/node/.claude-local` subsumes the credentials-backup concern : Claude Code reads `.credentials.json` from that dir, not from `~/.claude/`, so cloud OAuth state is untouched. The symlink set for `commands/skills/memory/plugins/settings.json/.claude.json` ensures skills + hooks + memory propagate in both directions (cloud changes visible in local and vice-versa).
- Host-only switch by design : the previous in-container `claude-switch` + `claude` wrapper re-read `.env` on every CLI invocation (CLI instant) but never reached the VSCode extension (VS Code Server inherits env from container PID 1, frozen at boot — Rebuild Container was already the only way to refresh the extension). It also let any in-container process flip the LLM endpoint by `sed`-ing its own `.env`. Moving to `host-helpers/claude-switch` unifies the semantics — CLI and extension now both wait for a Rebuild Container to pick up the new env vars (Reload Window relaunches VS Code Server but inherits the same frozen PID 1 env) — and removes the in-container attack surface. The CLAUDE.md symlink + `~/.claude-local` init propagate immediately via the bind mount + shell-init.sh fallback, without a rebuild.
- Model name mapping is done via `ollama cp <local-model> claude-opus-4-7` on the host — Claude Code resolves the model from the POST body, not from `/v1/models`. The model alias list lives in [ollama-local.md](ollama-local.md); sync at every Anthropic generation bump.

**Known limitation (May 2026) — thinking models hang Claude Code** : Ollama
0.24+ surfaces native thinking content blocks verbatim through its Anthropic
compat endpoint (`content[].type="thinking"` in the SSE stream). Claude Code
2.1.x then hangs waiting for `text` content that never arrives, since the
model burned its `max_tokens=64000` budget on thinking. Confirmed by replay
test : `claude --print 'ping'` (95KB payload, 22K input tokens) on Ollama
+ gemma4 returned 200 in 98.5s with 52 thinking_delta + 2 text_delta tokens.
Cloud equivalent : 2.7s. Ollama issues [#13949](https://github.com/ollama/ollama/issues/13949)
(documents the hang) + [#14809](https://github.com/ollama/ollama/issues/14809)
(requests server-side `think:false` flag) are still open.

**Workaround paths** (Q2 2026) :
- Pull a non-thinking model and alias it as `claude-opus-4-7` (most thinking
  models on M-series are still slow on 17K+ token prompts though — typically
  60–90s of prompt eval before generating).
- Run [UniClaudeProxy](https://github.com/vibheksoni/UniClaudeProxy)
  host-side to translate Ollama's thinking blocks into Anthropic-spec
  thinking content (Claude Code knows how to render those since extended
  thinking shipped).
- Stay in cloud mode for daily use ; local only for offline experiments.

---

## Policy parity across Claude Code targets

**Invariant** : every host that receives direct Claude Code API calls —
`api.anthropic.com`, `ollama.internal`, `claude-bridge` — MUST enforce
at-least-as-strict L7 policy constraints on shared paths. The baseline
lives in [`policy.d/api.anthropic.com.yaml`](../firewall/policy.d/api.anthropic.com.yaml) ;
the two local files mirror or extend it.

For `/v1/messages` (the only path Claude Code's chat loop uses) :

| Constraint | Baseline (`api.anthropic.com.yaml`) |
|---|---|
| `methods` | `[POST]` |
| `max_body_kb` | `32768` (32 MB) |
| `allowed_header_patterns` | `^X-(Api\|Anthropic\|Service\|Claude\|Stainless\|App\|Client\|Organization)-?` |
| `enforcement_mode` | `warn` (discovery) — locals use `block` (stricter, allowed) |

**Why** : Claude Code emits identical request shapes against all 3
targets — same Anthropic SDK, same headers, same body schema. A
constraint that exists on the cloud but not on the local fallbacks
creates a silent security regression : a Stainless SDK update adds a
new header → Anthropic policy is updated to allow it → local policies
forgotten → local mode now rejects (or worse, accepts headers cloud
mode rejects). Tracking the invariant in code is cheaper than tracking
it in memory.

**Rules** :

1. [`policy.d/claude-bridge.yaml`](../firewall/policy.d/claude-bridge.yaml)
   MUST be a **strict 1:1 mirror** of the `/v1/messages` block in
   `api.anthropic.com.yaml`. The sidecar receives byte-identical
   Claude-SDK requests — no reason to diverge.
2. [`policy.d/ollama.internal.yaml`](../firewall/policy.d/ollama.internal.yaml)
   MUST include the same `/v1/messages` block (1:1 with the
   Anthropic baseline). MAY extend with Ollama-native paths
   (`/api/version`, `/api/tags`, …) — extending the surface is fine,
   weakening the shared block is not.
3. `enforcement_mode` MAY be **stricter** than Anthropic's baseline
   (`block` is stricter than `warn`). Currently both locals use
   `block` because their API surface is fully known — no discovery
   warranted.

**Workflow when modifying `api.anthropic.com.yaml`** :

1. Modify as needed (new header pattern, raise body cap, new path, …).
2. If your change touches `/v1/messages` or `allowed_header_patterns` :
   a. Apply the **same** change to `policy.d/claude-bridge.yaml`
      (1:1 mirror — copy the block verbatim).
   b. Apply the **same** change to `policy.d/ollama.internal.yaml`
      (at-least-as-strict — same block, plus any Ollama-only
      extensions that were already there).
3. The parity comment headers at the top of each of the 3 files
   remind you and reference this section — do not remove them.
4. Validate via `diff` between the 3 files' `/v1/messages` blocks
   (or `yq '.endpoints[] | select(.path == "^/v1/messages$")'`).

**Future** : a `lint-parity.sh` script could automate the diff check
at policy-compile time (`init-firewall.sh` → `compile-policy.py` →
parity lint → emit). Out of scope for v1 ; the comment headers + this
section are the contract today.

---

## Meta-skill `/prepare-plan` (scaffolding)

`/prepare-plan <feature-name> [<description>]` scaffolds a multi-session rollout directory under `/workspace/plans/<feature>/`:

```
plans/<feature>/
├── ROLLOUT.md       overall goals + phases + decision log
├── STATUS.md        per-session status table (✅/🚧/📋)
├── LOG.md           append-only per-session journal
├── EXISTING.md      inventory of files touched
└── sessions/
    └── session-1-<slug>.md   first session with prompt to paste into a fresh Claude chat
```

Auto-triggers on natural FR/EN phrases (`fais-moi un plan`, `prépare un rollout`, `scaffold a plan`) with `AskUserQuestion` confirmation. Direct slash skips the confirm.

Collision policy: if `plans/<feature>/` exists, refuse and propose `<feature>-v2/`.

Sanity check at end: grep for `{{placeholder}}` / `<feature_name>` survivors — refuse if any remain.

---

## Modifications interdites / fragiles

| File / pattern | Why fragile | Safe action |
|---|---|---|
| `firewall/policy.compiled.yaml` | Generated at every boot — your edit gets overwritten | Edit source (`domains.txt`, `policy.d/`, `domains.local.txt`) instead |
| `firewall/policy.yaml` | Does not exist since A1.1 (replaced by `policy.d/<host>.yaml`) | Don't recreate; use the modular `policy.d/` layout |
| `claude-creds` volume | `external: true`, shared across projects | Don't delete without `docker volume create` recreating it; user re-logs in |
| `mitmproxy-${DC_PROJECT}` volume | Per-project; deleting forces CA regen at next strict boot | Safe to delete; container reopen regenerates CA |
| Adding wildcard `[*]` host in `domains.txt` committed | Defeats Layer 3 of the threat model | Use `policy.local.d/<host>.yaml` with a justification comment |
| New POST host in `domains.txt` committed | Audit nightmare, expands main allowlist | Use an isolated devcontainer instead |
| Importing `import yaml` in a mitmproxy addon | PyInstaller bundle ships ruamel only, not PyYAML | Use `from ruamel.yaml import YAML; YAML(typ='safe')` |
| `sed -i` in host scripts (initialize.sh, firewall-mode.sh) | BSD macOS vs GNU Linux mismatch | Use `awk + temp + mv` |
| Editing `phases/` directory | Removed in A5 cleanup; superseded by the rollout sessions structure | Add new sessions to the rollout instead |
| Adding `mkdir -p` to a script that doesn't `chown` after | Volumes get root-owned; node user can't write | Always `chown -R node:node` after creating in container scripts (or use `sudo -u node mkdir`) |
| `chown -R` / `chmod -R` / `find -exec` on a large tree in a separate RUN from the content creation (v2.1-2) | Docker records metadata flips (uid/gid) as full file copies in the overlay diff → phantom layer at full tree size (was +243 MB on the baked VSIX tree before fix) | **Co-locate** metadata flips with the RUN that created the tree. If you must flip metadata in a later RUN, target only the specific files that changed |
| `ENV HOME=/home/node` placed before root `RUN npm install -g` in Dockerfile.base (v2.1-1) | npm in root writes its cache to `/home/node/.npm` instead of `/root/.npm` → ~290 MB root-owned squat persisting in every container | Either move `ENV HOME` after `USER node`, or **explicit cleanup** in the install RUN: `rm -rf /home/node/.npm /root/.npm /tmp/* && npm cache clean --force` (current choice — ceinture+bretelles) |
| Changing UUIDs in `extensions.json` baked by `Dockerfile.base` (v2.1-2) | `3c13ae49-…` identifier and `89769da0-…` publisherId are stable per-extension/per-publisher (Marketplace assigns once, never changes). Wrong UUIDs → VS Code redownloads at runtime → silently back to Scenario 3, baked VSIX wasted | Don't touch. If Anthropic ever republishes under a new publisherId, that's a major event — bump everywhere consistently |
| Adding `~/.vscode-server` bind-mount to `docker-compose.yml` | Would mask the baked extension at runtime → silently back to Scenario 3, defeating v2.1-2 | Don't add. The baked extension lives inside the image layer, not in a volume |
| Sourcing `.env` with `set -a` before `docker build` in `initialize.sh` (v2.1-1 amend) | When mode=strict, `.env` carries `HTTPS_PROXY=http://127.0.0.1:8080`. Docker daemon auto-forwards these to the build container → ECONNREFUSED (mitmproxy isn't running at build time) | `env -u HTTPS_PROXY -u HTTP_PROXY -u NO_PROXY -u {lowercase variants} docker build ...` strip — already wired in `build_base_if_missing()` |
| Editing `.devcontainer/Dockerfile` directly (post-v2.1) | Slim project layer expects `FROM claude-devcontainer-base:${CLAUDE_CODE_VERSION}` only. Adding RUNs here defeats the base layer cache for all projects sharing the base | Either : (a) the change belongs in `Dockerfile.base` (shared) → edit base + bump `CLAUDE_CODE_VERSION` to invalidate cache, or (b) the change is project-specific → use a variant `Dockerfile.<variant>` |

---

## Volumes & filesystem layout

Four named volumes are declared in [docker-compose.yml](../docker-compose.yml):

| Volume | Mount point | Scope | Purpose |
|---|---|---|---|
| `claude-config-<project>` | `/home/node/.claude` | per-project | Claude CLI settings, session history, skills, plans, `.claude.json` |
| `claude-creds-<shared>` (external) | `/home/node/.claude-creds` | **cross-project** | Shared `.credentials.json` + `.claude.json` template |
| `bash-history-<project>` | `/commandhistory` | per-project | Persistent shell history |
| `gh-secrets-<project>` (external) | `/mnt/gh-secrets` (read-only) | per-project | GitHub App private key + config for gh-secure |

**Why the split:** `claude-creds` is declared `external: true` with `CLAUDE_CREDS_VOLUME` (defaulting to `claude-creds-<project>` but typically overridden to `claude-creds-shared`) so several devcontainers of different projects can share the same OAuth login. Everything else stays per-project for clean isolation.

The workspace itself is a **bind mount** (`..:/workspace:delegated`), so anything outside `/home/node/` lives on the host.

---

## Claude OAuth sync flow

`/home/node/.claude/.credentials.json` holds `claudeAiOauth.{accessToken, refreshToken, expiresAt}`. Claude Code auto-refreshes the access token before expiry. Without sync, each devcontainer would keep its own copy and drift out of phase.

### Single source of truth: `claude/sync-creds.sh`

[claude/sync-creds.sh](../claude/sync-creds.sh) is an idempotent, bidirectional script:

- Compares `expiresAt` on both sides, copies from whichever side has the higher value (most recently refreshed wins)
- Same access token → no-op
- Both valid but different → writes `/tmp/.claude-creds-conflict` (interactive resolution at next terminal open, handled in [shell-init.sh](../shell-init.sh))
- `--verbose` / `VERBOSE=1` → prints `✓ Credentials synced...`
- `DEBUG=1` → decision log on stderr
- **Always exits 0** so a hook failure can never block Claude Code

### Three call sites

| Trigger | Where | Mode |
|---|---|---|
| Container start (`postStartCommand`) | [post-start.sh](../post-start.sh) | verbose |
| Interactive terminal open (sourced from `.zshrc`/`.bashrc`) | [shell-init.sh](../shell-init.sh) | verbose |
| End of Claude Code turn / session | `Stop` + `SessionEnd` hooks in `~/.claude/settings.json` | silent |

The runtime hooks are what keep the **shared volume fresh during a long session**: if Claude refreshes the token mid-session, the next `Stop` pushes it to `/home/node/.claude-creds/` so a sibling container started later picks it up without re-login.

### `.claude.json` sync (separate)

`.claude.json` (settings, theme, onboarding flag) is synced in [post-start.sh](../post-start.sh) by **file mtime**, not by OAuth expiry — different semantics. Kept inline.

---

## Hooks install pattern

Claude Code reads hooks from `~/.claude/settings.json`. Two mechanisms write to that file:

1. **Skills hooks** — [skills/sync-skills.sh](../skills/sync-skills.sh) scans `.devcontainer/skills/**/hooks.json` and merges each entry into `~/.claude/settings.json`, deduping by `command`.
2. **Infra hooks** — [post-start.sh](../post-start.sh) merges the `Stop` + `SessionEnd` creds-sync hooks inline (Python block at end of file), same dedup-by-`command` logic.

Both mechanisms are idempotent: re-running post-start.sh never duplicates entries.

To inspect what's currently registered:

```bash
python3 -m json.tool ~/.claude/settings.json | less
```

---

## Skills install pattern

Each skill lives under `.devcontainer/skills/<name>/`. Structure:

- `<name>.skill.md` → copied to `~/.claude/commands/<name>.md` → exposed as `/user:<name>` slash command
- `hooks.json` (optional) → merged into `~/.claude/settings.json`
- Any data files (`*.config.md`, calibration JSON, …) live alongside

Files suffixed `.local.skill.md` or inside a `*.local/` folder are **personal / gitignored** (see `.gitignore`) — meant for skills you don't want to commit.

[sync-skills.sh](../skills/sync-skills.sh) is called at the end of [post-start.sh](../post-start.sh) at every container start.

---

## Debug recipes

### Post-start log

Everything `post-start.sh` emits goes to `/tmp/post-start.log`. The path is echoed when you open the first terminal (via shell-init.sh).

```bash
cat /tmp/post-start.log
```

### Inspect OAuth tokens

```bash
# expiresAt as UTC date
jq -r '.claudeAiOauth.expiresAt / 1000 | todate' /home/node/.claude/.credentials.json
jq -r '.claudeAiOauth.expiresAt / 1000 | todate' /home/node/.claude-creds/.credentials.json

# check which side is newer without copying
DEBUG=1 .devcontainer/claude/sync-creds.sh
```

### Resolve a creds conflict manually

```bash
rm /tmp/.claude-creds-conflict                  # silence the prompt
cp /home/node/.claude-creds/.credentials.json \
   /home/node/.claude/.credentials.json         # force shared → local
chmod 600 /home/node/.claude/.credentials.json
```

### Volumes & containers

```bash
docker volume ls | grep -E 'claude|gh-secrets'
docker volume inspect claude-creds-shared
docker compose -f .devcontainer/docker-compose.yml ps
```

### Replay post-start without rebuilding

```bash
bash .devcontainer/post-start.sh
```

(Idempotent. Safe to run mid-session.)

---

## Cross-platform sed (BSD vs GNU)

`initialize.sh` runs on the host (which can be macOS). BSD sed differs from
GNU sed for `sed -i` (BSD requires an explicit backup extension argument).
Helpers `set_env_var`/`unset_env_var` use **awk + temp file + mv** instead
of `sed -i` for portability.

If you ever need to rewrite a file in-place from a script that runs on both
macOS and Linux, prefer:

```bash
awk '...' input.txt > tmp && mv tmp input.txt
# OR
grep -v 'pattern' input.txt > tmp && mv tmp input.txt
```

---

## Checklist — "I'm resuming this devcontainer setup"

1. `cat /tmp/post-start.log` — any warnings at last start?
2. `docker volume ls | grep claude` — shared volume still mounted?
3. `jq .claudeAiOauth.expiresAt /home/node/.claude-creds/.credentials.json` — token still valid?
4. `grep sync-creds ~/.claude/settings.json` — creds-sync hooks registered?
5. `gh auth status` — GitHub auth still alive?
6. Any `⚠️` in post-start log → follow instructions there
7. `cat /workspace/.devcontainer/.configured-firewall-mode` → `basic` or `strict` ? (legacy `okeish`/`paranoid` accepted as aliases)
8. If `strict` : `.devcontainer/tests/diagnose.sh` should return all green

---

## Template origin

This devcontainer was generated from the `devcontainer-tools` template (see [README.md](../README.md)). To pull the latest upstream changes into this project:

```bash
bash /path/to/devcontainer-tools/update.sh
```

The update script shows a diff before each overwrite, bumps `.configured-setup` version, and is safe to re-run. Templated files (Dockerfile, docker-compose.yml, devcontainer.json) are **not** touched by update — regenerate with `install.sh` if needed.
