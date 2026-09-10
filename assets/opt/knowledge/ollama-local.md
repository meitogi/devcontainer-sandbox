# OLLAMA-LOCAL — Switch Claude Code to a local Ollama backend

> Toggle Claude Code between Anthropic cloud (default) and a local Ollama
> server on your Mac, with full mitmproxy audit. The switch is driven from
> the host (the container has no business modifying its own routing). A
> **Rebuild Container** picks up the new env vars on both the CLI and the
> VSCode extension ; the CLAUDE.md symlink + `~/.claude-local` init
> propagate immediately via the bind mount without needing a rebuild.

## Table of contents

- [Why & limits](#why--limits)
- [Prerequisites](#prerequisites)
- [Host install Ollama (≥ v0.14.0)](#host-install-ollama--v0140)
- [Choose your hardware profile](#choose-your-hardware-profile)
- [Host-side serve helpers](#host-side-serve-helpers)
- [Default model name mapping — two approaches](#default-model-name-mapping--two-approaches)
- [Devcontainer activation](#devcontainer-activation)
- [What the host-side switch does](#what-the-host-side-switch-does)
- [Daily usage](#daily-usage)
- [Why host-only, no in-container helper](#why-host-only-no-in-container-helper)
- [Mode `local-proxy` (sidecar UniClaudeProxy)](#mode-local-proxy-sidecar-uniclaudeproxy)
- [Bypass audit — `ollama.local` (debug only)](#bypass-audit--ollamalocal-debug-only)
- [Bypass audit — `claude-bridge.local` (debug only)](#bypass-audit--claude-bridgelocal-debug-only)
- [Managing the sidecar (host-helper `claude-bridge`)](#managing-the-sidecar-host-helper-claude-bridge)
- [Tuning the local prompt for your hardware (current ad-hoc workflow)](#tuning-the-local-prompt-for-your-hardware-current-ad-hoc-workflow)
- [Opening additional host ports](#opening-additional-host-ports-mysql-redis-)
- [Troubleshooting](#troubleshooting)
- [Capture & replay (mitmproxy debug addon)](#capture--replay-mitmproxy-debug-addon)
- [Audit & observability — confirm Claude is hitting Ollama, not the cloud](#audit--observability--confirm-claude-is-hitting-ollama-not-the-cloud)
- [Canonical links](#canonical-links)

---

## Why & limits

**Why** : run Claude Code against a local LLM for offline work, prompt
experimentation, latency-tolerant tasks, or privacy-sensitive sketches —
without paying per-token cost. The audit boundary stays exactly the same
as cloud mode : every request goes through the same mitmproxy
enforcement chain.

**Not for** : production work that depends on Claude-quality output,
long-context tasks (Ollama models cap below Anthropic's 1M token
context), high-throughput streaming. Local models are useful, not
equivalent.

## Prerequisites

- Mac M1 / M2 / M3 with **≥ 16 GB RAM** (32 GB recommended for the
  larger models below).
- Docker Desktop running (this is already a prerequisite of the
  devcontainer).
- **Ollama ≥ v0.14.0** — hard requirement. v0.14.0 (released Jan 2026)
  is the first version that exposes the native Anthropic Messages API on
  `:11434`. Earlier versions only speak the Ollama-native API and won't
  work with Claude Code's request shape — there's no fallback proxy in
  this setup.

## Host install Ollama (≥ v0.14.0)

### Option A — Desktop app (recommended for first install)

1. Download from <https://ollama.com/download>.
2. Install the `.dmg`, launch Ollama — a llama icon appears in the menu
   bar and a native chat window opens.
3. The app starts `ollama serve` in the background automatically. The
   API is reachable on `http://localhost:11434` immediately.
4. Pull a model via the chat search bar (type the name, click Download)
   or via Settings → Models.
5. Verify the version : Settings → About, or `ollama --version` from the
   shell.

### Option B — CLI only (automation / headless)

```bash
brew install ollama
ollama --version              # confirm ≥ 0.14.0
ollama serve &                # skip if the desktop app already runs (port conflict)
ollama pull qwen3.6-35b-a3b   # or your model of choice (see table below)
```

**No manual endpoint activation** : as soon as `ollama serve` runs, the
Anthropic-compat Messages API is live on `:11434`.

## Choose your hardware profile

Find your machine below — each profile gives the model to pull, the
context length, and the serve invocation. The two shipped helpers
(`ollama-serve-16k` / `-32k`) handle Compact and Balanced ; the bigger
profiles override env vars on the same `-32k` helper to bump context
and slot counts (helpers accept `OLLAMA_*=… bash …` overrides since
they use `${VAR:-default}` parameter expansion).

### 16 GB unified RAM (Mac M-series base)

```bash
ollama pull qwen3:14b-q4_K_M                # ~9 GB
ollama cp qwen3:14b-q4_K_M claude-opus-4-7
bash .devcontainer/host-helpers/ollama-serve-16k     # 16k ctx q8
```

Budget : 9 GB model + 1.3 GB KV @ 16k q8 + 1 GB overhead ≈ 11 GB.
Pair with [Approach A](#approach-a--single-force-compact-tier-recommended--32-gb)
(`.env` forces both Anthropic model names to claude-opus-4-7 —
`claude-switch local` does this automatically).

### 32 GB unified RAM (Mac M-series Pro)

```bash
ollama pull qwen3.6-35b-a3b                 # MoE Q4, ~20 GB
# or : ollama pull qwen2.5-coder:32b        # dense Q4, ~19 GB
ollama cp qwen3.6-35b-a3b claude-opus-4-7
bash .devcontainer/host-helpers/ollama-serve-32k     # 32k ctx q8
```

Budget : 20 GB model + 4 GB KV @ 32k q8 + 2 GB overhead ≈ 26 GB. Pair
with [Approach A](#approach-a--single-force-compact-tier-recommended--32-gb)
(recommended) — Approach B feasible if you accept tight RAM margins.

### 32–64 GB dedicated VRAM (Linux/Windows GPU)

A discrete GPU has VRAM dedicated to the model, independent of system
RAM. Inference is 5–10× faster than a Mac at the same model size, so
larger context + concurrent slots are practical.

```bash
# 32 GB VRAM (RTX 5090, A100 40GB)
ollama pull qwen3:32b-q4_K_M                # ~19 GB

# 64 GB VRAM (A100 80GB, dual RTX 4090, H100 PCIe)
ollama pull qwen3:72b-q4_K_M                # ~40 GB

# Multi-alias (Approach B — plenty of headroom + GPU swap is cheap)
LOCAL_MODEL=qwen3:72b-q4_K_M                # adapt to your pull
for tag in claude-opus-4-7 claude-sonnet-4-6 claude-haiku-4-5 claude-haiku-4-5-20251001; do
  ollama cp "$LOCAL_MODEL" "$tag"
done

# Serve : 64k ctx + 2 concurrent slots
OLLAMA_CONTEXT_LENGTH=65536 \
OLLAMA_MAX_LOADED_MODELS=2 \
OLLAMA_NUM_PARALLEL=2 \
bash .devcontainer/host-helpers/ollama-serve-32k
```

Budget (32 GB VRAM) : 19 GB model + ~8 GB KV @ 64k q8 + 2 GB overhead ≈ 29 GB.
Budget (64 GB VRAM) : 40 GB model + ~16 GB KV + 4 GB second slot ≈ 60 GB.

### 64 GB unified RAM (Mac M3/M4 Pro/Max)

```bash
ollama pull qwen3:72b-q4_K_M                # ~40 GB
ollama cp qwen3:72b-q4_K_M claude-opus-4-7

# Default 32k ctx is fine — single slot for safety on unified RAM
bash .devcontainer/host-helpers/ollama-serve-32k
```

Budget : 40 GB model + 5 GB KV @ 32k q8 + 2 GB overhead ≈ 47 GB → leaves
~17 GB for the OS + apps. Pair with
[Approach A](#approach-a--single-force-compact-tier-recommended--32-gb) —
unified memory is shared with the OS, so a second slot risks pressure.

### 128 GB unified RAM (Mac M3 Ultra / Mac Studio)

```bash
ollama pull qwen3:72b-q4_K_M                # ~40 GB Q4 — recommended
# or : ollama pull qwen3:72b-q8_0           # ~70 GB Q8 — higher quality, slower

LOCAL_MODEL=qwen3:72b-q4_K_M
for tag in claude-opus-4-7 claude-sonnet-4-6 claude-haiku-4-5 claude-haiku-4-5-20251001; do
  ollama cp "$LOCAL_MODEL" "$tag"
done

OLLAMA_CONTEXT_LENGTH=131072 \
OLLAMA_MAX_LOADED_MODELS=2 \
OLLAMA_NUM_PARALLEL=2 \
bash .devcontainer/host-helpers/ollama-serve-32k
```

Budget : 40 GB model + ~21 GB KV @ 128k q8 + ~16 GB second slot + 4 GB
overhead ≈ 81 GB. Pair with
[Approach B](#approach-b--multi-alias-balancedperformance-tiers) —
plenty of headroom for transparent main/small-fast separation in the UI.

**RAM budget rule of thumb** : `model size + 1.5 × KV cache + 2 GB
overhead < total RAM × 0.8` (keep 20% for the OS + Claude Code + your
browser). KV cache at q8 costs ~80 KB/token for Qwen3-class models —
16k = ~1.3 GB, 32k = ~2.6 GB, 64k = ~5 GB, 128k = ~10 GB per slot.

## Host-side serve helpers

Two scripts ship with the project — both export the `ollama serve` env
vars matching their tier, then `exec ollama serve`. They run on the host
(they'll refuse inside the container). Quit the Ollama desktop app first
if it's running — it claims port 11434 without these env vars.

```bash
# [host] Compact tier — 16 GB Mac, qwen3:14b-q4_K_M, 16k ctx q8
bash .devcontainer/host-helpers/ollama-serve-16k

# [host] Balanced tier — 32 GB Mac, ~20 GB model, 32k ctx q8
bash .devcontainer/host-helpers/ollama-serve-32k
```

### Env vars tuned by each helper

| Var | `-16k` | `-32k` | What it does |
|---|---|---|---|
| `OLLAMA_FLASH_ATTENTION` | 1 | 1 | Required for KV cache quantization to take effect |
| `OLLAMA_KV_CACHE_TYPE` | q8_0 | q8_0 | ~50% RAM saved on KV vs fp16, negligible quality loss |
| `OLLAMA_CONTEXT_LENGTH` | 16384 | 32768 | Default ctx for all served models (no per-model Modelfile needed) |
| `OLLAMA_KEEP_ALIVE` | 30m | 1h | Time to keep model in RAM after last request — longer = fewer cold reloads |
| `OLLAMA_MAX_LOADED_MODELS` | 1 | 1 | One model in RAM at a time — bigger names unload the previous (RAM safety net) |
| `OLLAMA_NUM_PARALLEL` | 1 | 1 | Single inference slot — each extra slot allocates another full KV cache |

`--cache-type-k` / `--cache-type-v` are llama.cpp flags, not Ollama
flags — passing them to `ollama serve` is silently ignored. Ollama wraps
llama.cpp and exposes the same toggle as `OLLAMA_KV_CACHE_TYPE`, which
applies q8_0 to both K and V uniformly.

## Default model name mapping — two approaches

Claude Code sends Anthropic-style model names in its API payload (e.g.
`claude-opus-4-7`, `claude-sonnet-4-6`, `claude-haiku-4-5-20251001`). By
default Claude Code uses TWO distinct model names per session — `main`
(opus) for primary work and `small-fast` (haiku) for short sub-agent
tasks. Ollama treats every distinct name as a separate cache slot, even
if multiple names point to the same underlying blob.

Two ways to satisfy Claude Code's model requests against Ollama :

### Approach A — Single force (Compact tier, recommended ≤ 32 GB)

Force Claude Code to ask for ONE name only, then create ONE alias on
Ollama. Result : exactly one model loaded into RAM, ever. Matches the
Compact tier's `OLLAMA_MAX_LOADED_MODELS=1` constraint without risk of
swap thrashing.

**Step 1** — set the two model vars in `.env` (`claude-switch local`
uncomments them automatically) :
```env
ANTHROPIC_MODEL=claude-opus-4-7
ANTHROPIC_SMALL_FAST_MODEL=claude-opus-4-7
```

**Step 2** — alias your real model under the forced name :
```bash
LOCAL_MODEL=qwen3:14b-q4_K_M       # or whatever you pulled
ollama cp "$LOCAL_MODEL" claude-opus-4-7
```

That's it. Claude Code's UI will display "opus" for both main and
small-fast calls — transparent ; Ollama loads exactly one slot.

**Trade-off** : you lose Claude Code's automatic main/small-fast
separation (small tasks now use the same model as big ones). On a local
model this is fine — they're all roughly the same speed anyway, and the
RAM savings vastly outweigh the marginal latency cost.

### Approach B — Multi-alias (Balanced/Performance tiers)

Alias your pulled model under every Anthropic name Claude Code might
emit. No `.env` override needed. The model is content-addressed in
Ollama (blobs identified by SHA256) — `ollama cp` creates a new manifest
(~KB) that references the same blob files, so 13 aliases of a 20 GB
model still cost ~20 GB on disk (not 260 GB). Behaviorally equivalent
to a hardlink.

**Required** : `OLLAMA_MAX_LOADED_MODELS=2` (or more) in `ollama serve`
— otherwise main + small-fast will fight for the single slot and cause
constant swap. The Compact tier's `ollama-serve-16k` is hard-capped at
1 ; use `ollama-serve-32k` or your own variant.

Run once after `ollama pull` :

```bash
LOCAL_MODEL=qwen3.6-35b-a3b

# Latest (current generation, as of 2026-05)
ollama cp "$LOCAL_MODEL" claude-opus-4-7
ollama cp "$LOCAL_MODEL" claude-sonnet-4-6
ollama cp "$LOCAL_MODEL" claude-haiku-4-5
ollama cp "$LOCAL_MODEL" claude-haiku-4-5-20251001

# Legacy still supported (alias + dated snapshot)
ollama cp "$LOCAL_MODEL" claude-opus-4-6
ollama cp "$LOCAL_MODEL" claude-sonnet-4-5
ollama cp "$LOCAL_MODEL" claude-sonnet-4-5-20250929
ollama cp "$LOCAL_MODEL" claude-opus-4-5
ollama cp "$LOCAL_MODEL" claude-opus-4-5-20251101
ollama cp "$LOCAL_MODEL" claude-opus-4-1
ollama cp "$LOCAL_MODEL" claude-opus-4-1-20250805

# Deprecated — retire on 2026-06-15, drop these lines after that date
ollama cp "$LOCAL_MODEL" claude-sonnet-4-0
ollama cp "$LOCAL_MODEL" claude-sonnet-4-20250514
ollama cp "$LOCAL_MODEL" claude-opus-4-0
ollama cp "$LOCAL_MODEL" claude-opus-4-20250514
```

Verify : `ollama list` shows all the aliases.

**Refresh this list** when Anthropic publishes a new major generation —
track via the [models overview
page](https://platform.claude.com/docs/en/about-claude/models/overview).
When you bump Claude Code's model in the devcontainer, add the new ID
here and re-run the `ollama cp` block.

**Why static and not auto-refresh** : the auto-refresh approach would
hit `GET /v1/models` on the Anthropic API, which requires a standalone
`ANTHROPIC_API_KEY`. Claude Max uses OAuth (no API key), so the static
list is the only universal approach.

## Devcontainer activation

The wiring is already in place — `docker-compose.yml` defines the
`ollama.internal` and `ollama.local` aliases, `firewall/domains.txt`
allowlists the host, `firewall/policy.d/ollama.internal.yaml` defines
the L7 policy. You just need to open the host port once, then toggle
the routing vars whenever you want to switch.

1. Edit `.devcontainer/firewall/ports.txt` (it was called
   `direct-tcp-allow.txt` before 2026-08-10 ; both names are still read)
   and uncomment :
   ```
   host:11434
   ```
   For the [`local-proxy` mode](#mode-local-proxy-sidecar-uniclaudeproxy)
   (sidecar UniClaudeProxy translates Ollama thinking blocks), add
   `claude-bridge:9223` on its own line :
   ```
   host:11434
   claude-bridge:9223
   ```
   This file is **baked into the image at build**, not read at runtime —
   which is why the rebuild below is not optional.
   The two entries coexist — you can hold both open and only the active
   `ANTHROPIC_BASE_URL` decides which path Claude Code uses.
2. Rebuild the container (Cmd+Shift+P → "Dev Containers: Rebuild
   Container") — once. The iptables ACCEPT for `host:11434` (and
   `claude-bridge:9223` if listed) is applied at boot ; you don't need
   to rebuild again when toggling later.
3. From a host terminal (your Mac, NOT inside the container), in the
   project root :
   ```bash
   bash .devcontainer/host-helpers/claude-switch local
   ```
   This uncomments `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, and
   `CLAUDE_CONFIG_DIR` in `.env`, and repoints `<project>/CLAUDE.md` to
   [.devcontainer/claude/CLAUDE-local-dev.md](claude/CLAUDE-local-dev.md).
4. In VSCode : Cmd+Shift+P → **"Dev Containers: Rebuild Container"**.
   Reload Window is NOT enough — docker-compose reads `env_file` at
   container creation only, so PID 1's env (which both VS Code Server and
   fresh shells inherit from) stays frozen until a full rebuild. On the
   rebuild, `post-start.sh` initializes `~/.claude-local/` (skills /
   commands / memory symlinked from `~/.claude/`) and prints the banner
   `🦙 Claude mode: LOCAL (ollama.internal:11434 — via mitmproxy audit)`.
5. Verify from a container terminal :
   ```bash
   bash .devcontainer/host-helpers/claude-switch status   # from host
   ```
   Prints something like :
   ```
   base URL      : ANTHROPIC_BASE_URL=http://ollama.internal:11434
   config dir    : CLAUDE_CONFIG_DIR=/home/node/.claude-local
   CLAUDE.md     : .devcontainer/claude/CLAUDE-local-dev.md
   ```

From that point on, the host-side switch toggles the mode — a **Rebuild
Container** is needed for the env-var change to reach Claude Code (Reload
Window only relaunches VS Code Server which inherits the same frozen PID
1 env). The CLAUDE.md symlink + `~/.claude-local` init take effect
immediately without rebuild.

## What the host-side switch does

`claude-switch` drives **three modes** : `local` (Claude Code → Ollama
direct), `local-proxy` (Claude Code → `claude-bridge` sidecar → Ollama,
translating `<think>` blocks for reasoning models), `cloud` (Anthropic
SDK default). Each mode flips two pieces of state on the host bind
mount :

1. **Value-discriminated `.env` toggle** : uncomments exactly one
   `ANTHROPIC_BASE_URL=…` line (the one matching the target URL) and
   comments out the other two. Same logic for `ANTHROPIC_AUTH_TOKEN` /
   `CLAUDE_CONFIG_DIR`. The other two URL lines stay commented — they're
   data, not dead code, so flipping back is a one-line edit instead of a
   re-uncomment ritual. The three URLs that may appear in `.env` :
   - `local` → `http://ollama.internal:11434`
   - `local-proxy` → `http://claude-bridge:9223`
   - `cloud` → (the three vars stay commented entirely)
2. **Repoints `<project>/CLAUDE.md`** symlink :
   `local` / `local-proxy` → [.devcontainer/claude/CLAUDE-local-dev.md](claude/CLAUDE-local-dev.md) ;
   `cloud` → `CLAUDE-dev.md` (or `CLAUDE-reviewer.md`, per
   `.configured-claude-mode`).

`local-proxy` additionally **auto-starts the `claude-bridge` sidecar**
if it's not already running (via the same logic as `host-helpers/claude-bridge up`).
First boot takes <10 s (Dockerfile pre-bakes deps as cached layers) ; on
subsequent switches the sidecar typically stays running so the check is
a no-op. `claude-switch cloud` does NOT stop the sidecar — it's cheap to
keep alive and saves the boot time on the next `local-proxy` switch.

On the next container start, `post-start.sh` detects
the active local-mode line in `.env` and **initializes `~/.claude-local/`**
if it doesn't exist yet — `mkdir` + symlink the parts that should stay
shared across modes (`commands`, `skills`, `memory`, `plugins`,
`settings.json`, `.claude.json`). Per-mode state (`.credentials.json`,
`projects/`, `todos/`) stays isolated : Claude Code populates them fresh
inside `~/.claude-local/`.

Cloud OAuth credentials in `~/.claude/.credentials.json` are **never**
touched by local mode. The isolation via `CLAUDE_CONFIG_DIR` guarantees
zero risk of contaminating the shared `CLAUDE_CREDS_VOLUME` with
local-mode session state.

## Daily usage

From a host terminal in the project root :

```bash
bash .devcontainer/host-helpers/claude-switch local        # Claude Code → Ollama direct (raw)
bash .devcontainer/host-helpers/claude-switch local-proxy  # Claude Code → claude-bridge sidecar → Ollama (translates thinking)
bash .devcontainer/host-helpers/claude-switch cloud        # Claude Code → Anthropic cloud
bash .devcontainer/host-helpers/claude-switch status       # show current mode

# Sidecar management (rarely needed — local-proxy auto-starts it) :
bash .devcontainer/host-helpers/claude-bridge status       # is the sidecar up + healthy?
bash .devcontainer/host-helpers/claude-bridge logs         # tail uvicorn logs (debug)

# Tip : alias it in your host shell rc for shorter typing.
#   alias cs='bash $(pwd)/.devcontainer/host-helpers/claude-switch'
```

**Which mode to pick** :
- **Reasoning models** (qwen3, deepseek-r1, GLM-4.5, …) → `local-proxy`
  (the sidecar translates raw `<think>` blocks so Claude Code doesn't
  hang waiting for `text` content).
- **Non-reasoning models** (gemma2, qwen2.5, mistral, …) → either `local`
  (one less hop, ~ms less latency) or `local-proxy` (same UX, harmless
  pass-through).
- **Production work, long context, Claude-quality output** → `cloud`.

After each switch : VSCode → Cmd+Shift+P → **"Dev Containers: Rebuild
Container"**. Reload Window is NOT enough — it relaunches VS Code Server
inside the existing container, which still inherits PID 1's frozen env
(docker-compose reads `env_file` only at container creation). Only a
full Rebuild re-populates PID 1 with the new `.env` values, which both
the CLI in fresh terminals and the VSCode extension then inherit.

## Why host-only, no in-container helper

The earlier in-container `claude-switch` shell function paired with a
`claude` shell wrapper that re-read `.env` on every invocation. That
worked for the CLI in a fresh shell but **never for the VSCode extension**
(VS Code Server inherits env vars from container PID 1, frozen at boot —
no re-read on `.env` edits). So the in-container path was already
asymmetric : CLI was instant via the wrapper, extension needed a Rebuild
Container anyway.

Moving the switch to the host gives both surfaces the same semantics —
host edits `.env`, Rebuild Container picks it up everywhere — and removes
a small attack surface : a compromised in-container process can no longer
silently flip the LLM endpoint by `sed`-ing its own routing config. The
wrapper is gone, so `which claude` shows the real binary again ; nothing
masks it. Trade-off : CLI is no longer instant on switch — it now needs
the same Rebuild as the extension. We accept the symmetry as worth it.

### VSCode native setting (alternative)

Some versions of the Claude extension expose `claude-code.anthropicBaseUrl`
in VS Code Settings (UI override of the env var). Check `settings.json`
or the Settings UI for "Claude" — if available, that gives you a
per-workspace override without touching `.env`. The extension API
evolves, so verify availability at the time you read this.

## Mode `local-proxy` (sidecar UniClaudeProxy)

Claude Code's main local-mode failure case is **reasoning models on
Ollama 0.24+** : the server surfaces raw `<think>…</think>` blocks
verbatim as `content[].type="thinking"` in the Anthropic-compat stream,
Claude Code waits for `text` content that never arrives (the model
burned its `max_tokens` budget on thinking), and the CLI hangs ~60-90 s
before timing out. Tracked in
[ollama/ollama#13949](https://github.com/ollama/ollama/issues/13949) ;
no server-side knob exists.

The `local-proxy` mode interposes a small translation sidecar between
Claude Code and Ollama. It speaks Anthropic-compat on the client side
and OpenAI-compat on the Ollama side, **converts `<think>` blocks into
Anthropic-spec `thinking` content blocks** (which Claude Code knows how
to render since extended thinking shipped), and otherwise passes
streams through transparently.

### How it works

```
                   ┌────────────────────────────────────────┐
                   │           devcontainer compose         │
                   │                                        │
Claude Code  ──▶  mitmproxy (audit)  ──▶  claude-bridge:9223
   (POST                                  (UCP + local overlay,
   /v1/messages)                          translates <think>)
                                                 │
                                                 ▼  (OpenAI-compat,
                                                     direct, NO mitm)
                                         host.docker.internal:11434
                                              (Ollama on host)
```

- **Container** : `claude-bridge` service in
  [docker-compose.yml](docker-compose.yml). Image built from
  [`.devcontainer/claude-bridge/Dockerfile`](claude-bridge/Dockerfile) —
  apt + clone [UniClaudeProxy](https://github.com/vibheksoni/UniClaudeProxy)
  + pip baked as cached layers, boot <10 s.
- **Local UCP overlay** :
  [`.devcontainer/claude-bridge/ucp-overlay/app/`](claude-bridge/ucp-overlay/)
  (5 Python files) — vendored fix that re-injects Ollama 0.9+
  `reasoning` SSE deltas as `<think>` markers (upstream UCP master drops
  them silently as of 2026-05). The overlay is shipped here pending the
  upstream PR.
- **Audit boundary** : inbound leg (Claude Code → `claude-bridge:9223`)
  is mitm-audited like every other host. Outbound leg (`claude-bridge`
  → `host.docker.internal:11434`) skips mitm — same trade-off accepted
  as `ollama.local` bypass (the sidecar is a known-good translator
  inside the trust boundary).
- **Streaming only** : translation lives in the SSE stream path. The
  non-streaming JSON path (`stream:false`) doesn't re-emit `<think>`
  blocks today (Claude Code always sends `stream:true`, so this is
  invisible to it ; diag scripts use `stream:false` and need a separate
  read for thinking blocks). Tracked for future overlay work.

### Setup

The sidecar service ships in compose — no install step. To activate :

1. From the host, add `claude-bridge:9223` to
   `.devcontainer/firewall/ports.txt` (see
   [§ Devcontainer activation](#devcontainer-activation)) — once.
   Rebuild the container so the iptables ACCEPT rule lands.
2. From the host :
   ```bash
   bash .devcontainer/host-helpers/claude-switch local-proxy
   ```
   This auto-starts the sidecar if it's not already running (cold start
   <10 s, warm restart instant), flips the `.env` URL line to
   `http://claude-bridge:9223`, and repoints `CLAUDE.md` →
   `CLAUDE-local-dev.md`.
3. VSCode → Cmd+Shift+P → **"Dev Containers: Rebuild Container"**.
   Reload Window won't pick up the new env (PID 1 inherits `.env` only
   at container creation — see [§ Devcontainer activation](#devcontainer-activation)).
4. On the next prompt, Claude Code POSTs to `claude-bridge:9223`, the
   sidecar translates `<think>` into `thinking` blocks, the CLI renders
   them inline. No hang.

The sidecar config (`claude-bridge/config.json`) is auto-bootstrapped
from `config.example.json` by `initialize.sh` on first container open
— no manual `cp` needed. To switch which Ollama model the sidecar
routes to, edit `config.json` (the `models` map at the top maps
Anthropic model names to Ollama aliases) and `bash
.devcontainer/host-helpers/claude-bridge restart`.

## Bypass audit — `ollama.local` (debug only)

By default, local mode points at `ollama.internal:11434` which routes
through mitmproxy (audit log + L7 policy enforcement). If you need to
**bypass mitmproxy** temporarily — for example to isolate a streaming
bug, measure raw latency, or unblock yourself when mitmproxy misbehaves
— switch to the `ollama.local` alias instead.

### How to switch

From the host, edit `.devcontainer/.env` and change ONE line :

```env
# Audit mode (default, recommended) :
ANTHROPIC_BASE_URL=http://ollama.internal:11434

# Bypass mode (debug only) :
ANTHROPIC_BASE_URL=http://ollama.local:11434
```

Then Rebuild Container in VSCode (Reload Window won't refresh PID 1's
env — see § Devcontainer activation for the why). The next `claude`
call hits Ollama directly via the host gateway, skipping mitmproxy
entirely. The login banner turns red (`🦙 Claude mode: LOCAL BYPASS …
NO audit`) so you know you're off the audit path.

### Trade-offs

| Aspect | `ollama.internal` (default) | `ollama.local` (bypass) |
|---|---|---|
| Routing | via mitmproxy (HTTP_PROXY) | direct TCP to host (NO_PROXY=.local) |
| Audit log | yes (`/var/log/mitmproxy.log` + `mitmproxy-writes.log`) | **no** |
| Policy enforcement (path / method / body) | yes (`policy.d/ollama.internal.yaml`) | **none** |
| Latency overhead | small (~ms) | none |
| Streaming SSE | passes through mitmproxy | direct |

### When NOT to use bypass

Anything not strictly necessary. The bypass mode loses all audit and
policy guarantees — any process inside the container could POST
arbitrary payloads to `host-gateway:11434` with no trace. Use only for
isolated debug sessions, then switch back to `ollama.internal`.

## Bypass audit — `claude-bridge.local` (debug only)

Mirrors the [`ollama.local` bypass](#bypass-audit--ollamalocal-debug-only)
for the sidecar path : by default, `local-proxy` mode points at
`claude-bridge:9223` which routes through mitmproxy. The `claude-bridge.local`
alias goes direct TCP via the Docker peer IP (NO_PROXY `.local` match)
— useful when mitmproxy itself misbehaves on SSE streaming, or when you
want to measure raw sidecar latency without the proxy hop.

### How to switch

From the host, edit `.devcontainer/.env` and change ONE line :

```env
# Audit mode (default, recommended) :
ANTHROPIC_BASE_URL=http://claude-bridge:9223

# Bypass mode (debug only) :
ANTHROPIC_BASE_URL=http://claude-bridge.local:9223
```

Then Rebuild Container in VSCode (Reload Window won't refresh PID 1's
env — see § Devcontainer activation for the why). The next `claude`
call hits the sidecar directly via the Docker peer IP, skipping
mitmproxy entirely. The login banner turns red (`🦙 Claude mode:
LOCAL-PROXY BYPASS — NO audit`) so you know you're off the audit path.

### Trade-offs

| Aspect | `claude-bridge:9223` (default) | `claude-bridge.local:9223` (bypass) |
|---|---|---|
| Routing | via mitmproxy (HTTPS_PROXY) | direct TCP to sidecar (NO_PROXY=.local) |
| Audit log | yes (`/var/log/mitmproxy.log` + `mitmproxy-writes.log`) | **no** |
| Policy enforcement (path / method / body) | yes (`policy.d/claude-bridge.yaml`) | **none** |
| Latency overhead | small (~ms) | none |
| Streaming SSE | passes through mitmproxy | direct |
| `<think>` translation | yes (same overlay) | yes (same overlay — sidecar logic identical) |

The bypass keeps the sidecar's translation behavior intact — the only
thing dropped is the mitmproxy audit + policy layer.

### When NOT to use bypass

Same caveats as [`ollama.local`](#bypass-audit--ollamalocal-debug-only)
: anything not strictly necessary. The bypass mode loses all audit and
policy guarantees — any process inside the container could POST
arbitrary payloads to the sidecar with no trace. Use only for isolated
debug sessions, then switch back to `claude-bridge:9223`.

## Managing the sidecar (host-helper `claude-bridge`)

The `claude-bridge` host helper wraps `docker compose` calls for the
sidecar service, with built-in healthcheck polling :

```bash
bash .devcontainer/host-helpers/claude-bridge up        # build (if needed) + start + wait healthy (90s timeout)
bash .devcontainer/host-helpers/claude-bridge down      # stop (keeps the container around for fast restart)
bash .devcontainer/host-helpers/claude-bridge restart   # stop + start + wait healthy (60s timeout)
bash .devcontainer/host-helpers/claude-bridge status    # state + health + image tag + uptime
bash .devcontainer/host-helpers/claude-bridge logs      # `docker compose logs -f --tail=50` (Ctrl+C to exit)
```

Refuses to run inside the container (needs the host's docker daemon).

**Normal flow** : `claude-switch local-proxy` auto-starts the sidecar,
so manual `up` is rarely needed. The cases where you'd reach for the
wrapper :

- **After editing `claude-bridge/config.json`** : `restart` so the
  sidecar picks up the new config (e.g. you re-mapped which Ollama
  alias receives `claude-opus-4-7` requests).
- **Debugging a translation issue** : `logs` to see what UCP is doing.
  Look for `<think>` markers in the SSE deltas, `enable_thinking: true`
  on the relevant model, and `200 OK` per request.
- **Clean shutdown before pulling a new image** : `down`, then `up`.
- **Quick sanity** : `status` to confirm the sidecar is healthy without
  spinning up `docker compose ps` yourself.

The sidecar boots <10 s thanks to the dedicated
[`Dockerfile`](claude-bridge/Dockerfile) baking apt + UCP clone + pip
install as cached layers (pivoted from a boot-time bash chain).
First image build is ~60-90 s ; subsequent rebuilds hit the layer cache
and complete in <5 s.

## Tuning the local prompt for your hardware (current ad-hoc workflow)

`CLAUDE-local-dev.md` carries instructions Claude Code prepends to every
prompt in local-mode (concise output, no markdown headers, pause before
tool use, …). The shipped version is tuned for Apple M-series + qwen3.5:9b
through the sidecar. On a different hardware + model combination, you may
want to re-tune the directives.

The workflow below uses two scripts shipped in `.devcontainer/tests/`,
plus the mitm capture helper. It's a **manual** loop today — a
discoverable skill is planned (see [Tuning roadmap](#tuning-roadmap)
below) but not yet shipped, so users tuning today follow the 4 steps
below verbatim.

### 1. Enable mitm capture (host)

```bash
bash .devcontainer/host-helpers/mitm-capture on
```

This touches the sentinel `/tmp/claude-capture/.enabled` inside the
container. The always-loaded capture addon (see
[extension-points.md § Debug capture addon](extension-points.md#debug-capture-addon-capture_messages_debugpy))
starts writing every POST `/v1/messages*` body to
`/tmp/claude-capture/<ts>-<id>-<host>.{json,sh}`. The harness in step 2
reads these.

### 2. Run a baseline measurement (in-container)

```bash
bash .devcontainer/tests/diag-bridge-translation.sh
```

This is the **cloud-as-oracle** harness :

1. Spawns `claude --print 'ping'` and `claude --print '<reasoning prompt>'`
   in cloud mode (`env -u ANTHROPIC_*`) so mitm captures the exact body
   Claude Code sends to `api.anthropic.com`. Matches the new capture by
   content (the prompt is the last text block of the last user message)
   so concurrent claude sessions don't contaminate the measurement.
2. Replays each captured SEND against `http://claude-bridge:9223` with
   `model:"claude-opus-4-7"` + `stream:false` (clean JSON parsing).
3. Emits a side-by-side `summary.txt` at `/tmp/diag-bridge/<ts>/` :
   SEND size, CLOUD RECV preview, BRIDGE RCV content structure +
   `thinking_blocks` count + `text_chars` + latency + stop reason.

The variant label is extracted from the
`<!-- variant: V<N>-<slug> -->` marker inside the
`<!-- 1B-LIGHT-MODEL-DIRECTIVES-START / END -->` block of
`CLAUDE-local-dev.md` — defaults to `V0-baseline` when absent.

### 3. Apply a variant between iterations (in-container)

```bash
bash .devcontainer/tests/tweak-claude-md-for-local.sh --variant 1
```

Idempotent applier — rewrites the body between the
`<!-- 1B-LIGHT-MODEL-DIRECTIVES-START -->` and `<!-- … END -->` markers
of `CLAUDE-local-dev.md` without touching the rest of the file. Also
ensures `/workspace/CLAUDE.md` symlinks to `CLAUDE-local-dev.md`.

Shipped variants :
- `--variant 0` — baseline (empties the marked block ; falls back to
  the raw "small reasoning model" wrapper of `CLAUDE-local-dev.md`)
- `--variant 1` — `explicit-tiny-model` (5 directives : concise, no
  gratuitous headers, pause before tool use, ask for clarification,
  don't list options) — the current shipped default.

No-arg → prints the current state (active variant, marker presence,
symlink target) and the list of available variants. Doesn't mutate.

**To add a new variant** : open the script, find the
`make_variant_body()` function near the top, and append a `--variant N`
branch with a HEREDOC body. The HEREDOC should include a
`<!-- variant: V<N>-<slug> -->` line so the diag harness can label
measurements.

### 4. Iterate until "potable"

Re-run step 2 after each variant. Success criteria :

- **ping** : ≤ 100 chars on-topic + ≤ 30 s
- **reasoning** : contains `391` (= 17 × 23) + `thinking` block in
  streaming + ≤ 90 s

If 2 consecutive iterations fail the same criterion, stop and ask
yourself if the hardware tier you've targeted is realistic for this
model. A 9-billion-parameter reasoning model on 16 GB unified RAM has
fundamental latency floors that no prompt directive can move below.

Record the variant history (V0 → V1 → … and the deltas) in your own
notes. One worked example: V0 baseline (1k tokens, "potable" at
17.4 s / 41.9 s) → V1-explicit-tiny-model (13 lines, 3.9 s / 14.8 s,
**-78% ping, -65% reasoning**, no quality regression).

### Tuning roadmap

The 4-step loop above is the **current ad-hoc workflow**. A discoverable
`/tune-claude-local` skill that would automate the iteration (propose
variants from a profile + hardware survey, run the diag, suggest the
next directive change, apply it, repeat until potable) is **deferred to
a future rollout**. Users who want to tune for a new hardware + model
combo today follow the manual 4-step loop above ; when the skill ships,
this section will point at it instead.

## Opening additional host ports (MySQL, Redis, …)

`ports.txt` takes one `host:<port>` per line. Extend it for
other host services :

```
host:11434
host:3306
host:6379
```

Rebuild the container after editing — the file is baked into the image,
so a Reload Window does not pick it up. Each entry adds an iptables
ACCEPT rule posed BEFORE the RFC1918 REJECT.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `claude` returns 401 / auth error | `ANTHROPIC_AUTH_TOKEN` missing | `bash .devcontainer/host-helpers/claude-switch local` from host (re-uncomments all five vars) then Rebuild Container |
| Banner doesn't appear after Rebuild | `.env` formatted differently (custom edit) | Restore the strict `# VAR=` format that the host helper's sed expects, or manually edit `.env` |
| Skills missing in local mode | `~/.claude-local/` symlinks broken or pointed at stale `~/.claude/` paths | From a container terminal : `rm -rf ~/.claude-local` then open a new shell (shell-init.sh fallback re-creates from current `~/.claude/`). Persistent re-init across reboots happens in post-start.sh on Rebuild |
| Session history mixed between modes | You overrode `CLAUDE_CONFIG_DIR` manually | Use the host helper instead of hand-editing `.env` — it keeps the five vars + the symlink in sync |
| `CLAUDE.md` doesn't match the mode | `<project>/CLAUDE.md` symlink desynced (manual edit, conflicting rebuild) | `bash .devcontainer/host-helpers/claude-switch local` (or `cloud`) re-creates the right symlink — immediate, no rebuild needed for the symlink alone |
| Switch doesn't take effect after host helper | Forgot to Rebuild Container — VS Code Server still inherits PID 1's frozen env (docker-compose reads `env_file` at creation only) | Cmd+Shift+P → "Dev Containers: Rebuild Container". Reload Window is NOT enough — it relaunches VS Code Server but PID 1 stays |
| `Connection refused` to ollama.internal:11434 | Ollama not running on host | `ollama serve` (CLI) or launch the desktop app |
| `Connection refused` even with Ollama running | Port not in `.devcontainer/firewall/ports.txt` | Add `host:11434` to the file (baked into the image at build, cf. `init-firewall.sh` § *ports.txt — direct ACCEPT for non-HTTP TCP services*) + Rebuild Container (iptables ACCEPT applied at boot, not on Reload) |
| `Connection refused` even with both above | `host.docker.internal` not resolving via Docker (Linux Docker without `host-gateway`) | `dig +short @127.0.0.11 host.docker.internal` inside the container — empty means Docker's resolver doesn't know it. On Linux Docker Engine (≠ Desktop), add `--add-host=host.docker.internal:host-gateway` to `runArgs` in `devcontainer.json` so `init-firewall.sh` can capture the IP at boot. |
| `❌ ollama.internal (DNS resolution failed)` in `test-firewall.sh` | `init-firewall.sh` ran *before* Docker's resolver was reachable, or CNAME injection block failed | `sudo /usr/local/bin/init-firewall.sh` to re-run ; check `dbg "  injected host.docker.internal=…"` in the output. See [README.md § Local hosts — DNS-driven aliases](README.md#local-hosts--dns-driven-aliases-no-extra_hosts). |
| `403 blocked_header:X-Stainless-…` from mitmproxy | `policy.d/ollama.internal.yaml` missing the `allowed_header_patterns` block (mirror of api.anthropic.com) | Restore the `^X-(Api\|Anthropic\|Service\|Claude\|Stainless\|App\|Client\|Organization)-?` allowlist in the file ; rebuild container so the compiled policy reloads |
| `403 host_not_in_policy` from mitmproxy | `policy.d/ollama.internal.yaml` missing or path not allowed | Verify the file exists ; check `policy.compiled.yaml` includes the ollama.internal entry |
| 404 model not found | Anthropic model name not aliased via `ollama cp` | Re-run the `ollama cp` block above for the model the client requested |
| Out-of-memory on Ollama | Model too large for available RAM | Try a smaller variant (`qwen3.6-35b-a3b` → `qwen3-coder-next`, or `:14b` → `:8b`) |
| Streaming SSE breaks mid-response | Edge case in Ollama's Anthropic-compat layer | Report upstream to Ollama ; no devcontainer workaround |
| `claude --print 'ping'` hangs ~60-90s then 500 | Ollama 0.24 surfaces raw `content[].type="thinking"` blocks ; Claude Code waits for `text` content that the model burned through its 64K token budget on thinking ([ollama#13949](https://github.com/ollama/ollama/issues/13949)) | **Primary fix** : `bash .devcontainer/host-helpers/claude-switch local-proxy` → the [sidecar](#mode-local-proxy-sidecar-uniclaudeproxy) translates `<think>` blocks into Anthropic-spec `thinking` content (Claude Code renders them inline, no hang). Confirmed via [§ Capture & replay](#capture--replay-mitmproxy-debug-addon) replay test (98.5s on raw Ollama vs <5s through the sidecar). Server-side knob ([#14809](https://github.com/ollama/ollama/issues/14809)) remains open ; sidecar is the working path today. |
| `Connection refused claude-bridge:9223` | Sidecar not running (first switch to `local-proxy`, or stopped manually) | `bash .devcontainer/host-helpers/claude-bridge status` to confirm ; if `not running`, `bash .devcontainer/host-helpers/claude-bridge up` brings it back. Cold start <10 s (cached layers). |
| `claude-bridge` reports `unhealthy` | uvicorn died — config error or upstream Ollama unreachable (rare since Dockerfile pivot baked the boot deps) | `bash .devcontainer/host-helpers/claude-bridge logs` → look for the last Python stack trace. Common : `config.json` references an Ollama alias that doesn't exist on the host (`ollama list` then `ollama cp <real> claude-opus-4-7`). |
| `claude-bridge/config.json: No such file` at sidecar boot | First container open after a fresh clone — `initialize.sh` auto-bootstraps `config.json` from `config.example.json`, but a manual `git clean -fdx` would wipe both copies if the example is gitignored locally | Restore : `cp .devcontainer/claude-bridge/config.example.json .devcontainer/claude-bridge/config.json`. Normally handled automatically — verify `initialize.sh` ran (look for `claude-bridge/config.json bootstrapped` in `/tmp/initialize.log` on host). |
| mitm misbehaves on SSE streaming through the sidecar | mitmproxy 12.x SSE handling regression, or a custom addon mutating the stream | Switch to the bypass alias : edit `.env` → `ANTHROPIC_BASE_URL=http://claude-bridge.local:9223` (see [§ Bypass audit — claude-bridge.local](#bypass-audit--claude-bridgelocal-debug-only)) + Rebuild Container. Translation stays intact (the sidecar logic is the same) ; only audit + policy enforcement are dropped. Investigate the addon while the bypass keeps you unblocked. |
| `local-proxy` responses are low quality on my model | `CLAUDE-local-dev.md` tuned for a different hardware + model combo | Re-run the manual tuning workflow — see [§ Tuning the local prompt](#tuning-the-local-prompt-for-your-hardware-current-ad-hoc-workflow). One worked example: qwen3.5:9b on M-series, V0 → V1, -78% ping latency, -65% reasoning latency. |

## Capture & replay (mitmproxy debug addon)

When `claude --print 'ping'` (or any Claude Code call) misbehaves, capture
the exact request body Claude sends and replay it elsewhere — useful for
diffing cloud vs local behavior, isolating which field tilts Ollama, or
sharing repro payloads.

The capture addon is always loaded into mitmproxy but **off by default**.
Toggle it on/off live (no restart) from the host :

```bash
[host]  bash .devcontainer/host-helpers/mitm-capture on       # enable
[host]  claude --print 'ping'                                  # (in a container terminal)
[host]  bash .devcontainer/host-helpers/mitm-capture ls        # list captures
[host]  bash .devcontainer/host-helpers/mitm-capture off       # disable
[host]  bash .devcontainer/host-helpers/mitm-capture clear     # rm captures
```

What gets written to `/tmp/claude-capture/` per matched request :
- `<ts>-<id>-<host>.json` — the raw POST body as Claude sent it
- `<ts>-<id>-<host>.sh` — a ready-to-replay curl that re-sends the bytes
  against `http://ollama.internal:11434<path>` (with `x-api-key`,
  `authorization`, `anthropic-auth-token` redacted to `XXX-REDACTED`)

Scope : only POSTs on `/v1/messages*` for `api.anthropic.com` +
`ollama.internal` + `ollama.local`. Cloud and local mode both captured —
useful for side-by-side comparison.

Storage : container tmpfs (`/tmp/`), vanishes on container restart. Copy
captures into `.devcontainer/pending/` to inspect from host or persist
across reboots.

See [extension-points.md § Debug capture addon](extension-points.md#debug-capture-addon-capture_messages_debugpy)
for the addon implementation details + the sentinel mechanism.

## Audit & observability — confirm Claude is hitting Ollama, not the cloud

Once you've toggled to local mode and reloaded the VSCode window, run
the checks below to verify the routing actually changed. Failure
modes : extension cached the old base URL, `.env` edit didn't take,
proxy bypassed by the CLI tool, etc. Each layer has a different
signal.

### Layer 0 — `.env` state (host-side toggle landed)

```bash
# [container or host] : the three vars must be UNCOMMENTED (no leading `# `)
grep -E '^(ANTHROPIC_BASE_URL|ANTHROPIC_AUTH_TOKEN|CLAUDE_CONFIG_DIR)=' \
  .devcontainer/.env
```
Expected output (cloud mode shows the same lines with `# ` prefix — `grep -E '^#'` will match) :
```
ANTHROPIC_BASE_URL=http://ollama.internal:11434
ANTHROPIC_AUTH_TOKEN=ollama
CLAUDE_CONFIG_DIR=/home/node/.claude-local
```

### Layer 1 — post-start banner (container picked up the new env)

After Reload Window (or Rebuild Container), the boot banner at the
top of the terminal session should show :
```
🦙 Claude mode: LOCAL (ollama.internal:11434 — via mitmproxy audit)
ℹ️  Initialized /home/node/.claude-local (shared skills/commands/memory, isolated creds)
```
No 🦙 line = container is still in cloud mode (banner is added by
`post-start.sh` based on the `.env` regex). In that case, the
`.env` edit didn't survive the boot — re-run `claude-switch local`
from the host.

### Layer 2 — Claude CLI process env (PID 1 env actually changed)

```bash
# [container]
env | grep -E '^(ANTHROPIC_BASE_URL|CLAUDE_CONFIG_DIR)='
```

In local mode (after Rebuild Container) you should see the two vars
printed with the values from `.env`. **If the output is empty** after a
plain Reload Window, that's not a bug — `docker-compose.yml` reads
`.env` via `env_file:` **at container creation only**. PID 1's
environment is frozen from that moment ; Reload Window relaunches VS
Code Server inside the existing container, inheriting the same frozen
env. Only a full **Rebuild Container** repopulates PID 1 (and thus
every shell + the extension) with the new `.env` values.

The in-container `claude` wrapper that used to re-read `.env` on every
invocation was removed in session w-I (host-only switch by design — a
compromised in-container process must not be able to silently flip the
LLM endpoint). So CLI and extension now have identical semantics : both
read PID 1's env at process start, both wait for Rebuild Container to
see a switch.

To validate Claude actually hit Ollama and not the cloud :

```bash
# [container] Ask Claude its model identifier in one word
claude --print "what's your model identifier? one word."
# → Cloud : "claude-opus-4-7" (or similar)
# → Local : the underlying Ollama alias (e.g. "qwen3.6-35b-a3b")
```

### Layer 3 — mitmproxy log (Claude → Ollama actually transits)

Once you've made an actual Claude API call (open Claude Code, run
any prompt), grep the live mitm log :

```bash
# [container] All requests to ollama.internal, latest first (default mitmdump log)
grep ollama.internal /var/log/mitmproxy.log | tail -5

# [container] Non-GET requests (POST /v1/messages bodies, audited by passive_log addon)
grep ollama.internal /var/log/mitmproxy-writes.log | tail -3

# [container] Anything the policy rejected (should be empty in steady state)
grep ollama.internal /var/log/mitmproxy-blocks.log | tail -3
# or the helper :
firewall-blocks | grep ollama.internal
```

You should see CONNECT + POST /v1/messages lines with recent
timestamps. **If `mitmproxy.log` has no recent `ollama.internal`
entries after a prompt, Claude is bypassing the proxy** — either
still hitting the cloud (revert step) or somehow short-circuiting
to direct `ollama.local`.

In `ollama.local` (bypass) mode, **none of these logs will show
traffic** — that's the point of the bypass. Use Layer 4 instead.

### Layer 4 — Ollama host log (the model actually answered)

On your Mac (host), Ollama logs every inference. Tail it while you
trigger a prompt :

```bash
# [host] macOS Desktop app
tail -f ~/.ollama/logs/server.log

# [host] CLI install
tail -f $(ollama --help | grep -oE '/.*\.log' || echo /tmp/ollama.log)
```

You should see `POST /v1/messages` lines with timestamps matching
your prompt. This is the **strongest signal** Claude actually
inferred against Ollama — works for both `ollama.internal` and
`ollama.local` (the bypass mode otherwise has no audit trail).

### Layer 5 — Ask Claude its model name (semantic check)

In a fresh Claude prompt :
> "What's your model identifier? Just the string."

| Cloud (default) | Local (Ollama with `ollama cp` aliasing) |
|---|---|
| `claude-opus-4-7` / `claude-sonnet-4-6` / `claude-haiku-4-5` | the underlying alias you set, e.g. `qwen3.6-35b-a3b` or whatever was aliased to `claude-opus-4-7` |

Note : if you didn't do the `ollama cp` aliasing block (see
[Default model name mapping](#default-model-name-mapping--ollama-cp-recommended)),
local mode will refuse with a 404 model not found, which is itself
a clear signal you're hitting Ollama.

## Canonical links

- [Ollama Anthropic compatibility docs](https://docs.ollama.com/api/anthropic-compatibility)
- [Ollama Claude Code blog post](https://ollama.com/blog/claude)
- [Ollama desktop app blog](https://ollama.com/blog/new-app)
- [Claude Code environment variables](https://docs.claude.com/en/docs/claude-code/settings)
- [Anthropic Messages API reference](https://docs.anthropic.com/en/api/messages)
- [Anthropic models overview](https://platform.claude.com/docs/en/about-claude/models/overview)
