# Baked shell init — /opt/devcontainer/base/shell-init.sh, sourced by
# ~/.zshrc and ~/.bashrc when the workspace carries no shell-init.sh of its
# own (v2 layout keeps its copy and wins; see the Dockerfile injection).
#
# Everything below reads image content or GUARDED workspace paths, so it
# works on a project whose .devcontainer holds nothing but the compose
# files — that is the point: a project needs no shell plumbing of its own.

# zsh-only — load Oh My Zsh + team-wide zsh base BEFORE the banner below
# so the prompt / completion / history are initialised when the rest of
# this file runs. Bash users skip this block cleanly. The project overlay
# is sourced LAST (bottom of this file) so it can override the baked base.
if [ -n "$ZSH_VERSION" ] && [[ $- == *i* ]]; then
  [ -f /opt/devcontainer/base/zshrc ] && \
    source /opt/devcontainer/base/zshrc
  [ -f /workspace/.devcontainer/zshrc-base ] && \
    source /workspace/.devcontainer/zshrc-base
fi

# Show post-start log path on first shell
# Sourced from .zshrc/.bashrc at container startup
# Only run in interactive terminals.
# devc-hook writes one timestamped log per phase under .devcontainer/tmp/logs/
# (devc-hook:65-68), so there is no fixed filename to test: take the newest
# post-start-*.log. The v2 path this guarded on, /tmp/post-start.log, is never
# written by v3 — the test was always false and the line never showed.
if [[ $- == *i* ]]; then
  # Sorted by NAME, not mtime: devc-hook stamps %Y%m%d-%H%M%S (fixed width,
  # zero-padded), so lexicographic order is chronological order. `ls -t` ties
  # when two runs land in the same second and then returns the older one.
  _ps_log=$(ls -1 /workspace/.devcontainer/tmp/logs/post-start-*.log 2>/dev/null | sort -r | head -1)
  [ -n "$_ps_log" ] && echo "📄 Post-start log: $_ps_log"
  unset _ps_log
fi

# Credentials conflict resolution
if [[ $- == *i* ]] && [ -f /tmp/.claude-creds-conflict ]; then
  echo ""
  echo "⚠️  Claude credentials conflict detected!"
  echo "  Both local and shared volumes have valid but different tokens."
  echo ""
  echo "  [1] Keep local  (this container's token)"
  echo "  [2] Keep shared (from another project/session)"
  echo ""
  read -p "Choose [1/2]: " CRED_CHOICE
  LOCAL_CRED="/home/node/.claude/.credentials.json"
  SHARED_CRED="/home/node/.claude-creds/.credentials.json"
  if [ "$CRED_CHOICE" = "2" ]; then
    cp "$SHARED_CRED" "$LOCAL_CRED"
    chmod 600 "$LOCAL_CRED"
    echo "✓ Using shared token."
  else
    cp "$LOCAL_CRED" "$SHARED_CRED"
    echo "✓ Using local token."
  fi
  rm -f /tmp/.claude-creds-conflict
fi

# Auto-sync credentials on terminal open (catches Claude Code token refreshes).
# Workspace copy wins (v2 layout), else the baked binary.
if [[ $- == *i* ]]; then
  if [ -x /workspace/.devcontainer/claude/sync-creds.sh ]; then
    VERBOSE=1 /workspace/.devcontainer/claude/sync-creds.sh
  elif [ -x /usr/local/bin/sync-creds ]; then
    VERBOSE=1 /usr/local/bin/sync-creds
  fi
fi

# ⚠️ Warn if test-root still has sudo access (sudoers entry is the real risk)
if [[ $- == *i* ]] && sudo -l 2>/dev/null | grep -q "test-root"; then
  echo ""
  echo "⚠️  WARNING: test-root.sh has sudo access!"
  echo "⚠️  Remove the test RUN line in .devcontainer/Dockerfile before committing."
fi

# mitmproxy CA env vars for tools that don't read the system trust store
# (Python requests, Node fetches not via system, …). HTTPS_PROXY is already
# set by docker-compose env_file (PID 1 inherits .env automatically), so we
# only handle CA-bundle paths here. Guard on cert presence — no-op in basic.
if [ -f /var/lib/mitmproxy/mitmproxy-ca-cert.pem ]; then
  export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
  export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
  export GIT_SSL_CAINFO=/etc/ssl/certs/ca-certificates.crt
fi

# Fallback init of ~/.claude-local for the "Reload Window after claude-switch"
# flow. post-start.sh is the canonical place that creates this dir (with the
# shared symlinks to ~/.claude/{commands,skills,memory,plugins,settings.json,
# .claude.json}), but post-start only fires at container start — so the very
# first time the user toggles cloud→local without rebuilding, the dir is
# missing and CLAUDE_CONFIG_DIR points at nothing. We re-create it here on
# shell open as a safety net : idempotent (no-op if already exists), zero
# cost in cloud mode (the grep returns 0 lines and the block skips).
if grep -qE '^ANTHROPIC_BASE_URL=http://ollama\.(internal|local)' /workspace/.devcontainer/.env 2>/dev/null \
   && [ ! -d "$HOME/.claude-local" ]; then
  mkdir -p "$HOME/.claude-local" && chmod 700 "$HOME/.claude-local"
  if [ -d "$HOME/.claude" ]; then
    for _claude_local_path in commands skills memory plugins settings.json .claude.json; do
      [ -e "$HOME/.claude/$_claude_local_path" ] && \
        ln -sfn "$HOME/.claude/$_claude_local_path" "$HOME/.claude-local/$_claude_local_path"
    done
    unset _claude_local_path
  fi
  printf '\033[1;36mℹ️  ~/.claude-local initialized via shell-init fallback (Reload Window without Rebuild)\033[0m\n'
fi

# Session summary — the boot panel first, then what it cannot know.
if [[ $- == *i* ]]; then
  echo ""
  # The panel is CACHED, not recomputed. post-start.d/95 ran boot-summary once
  # at the end of the start sequence and wrote the text here. Re-deriving it at
  # every shell open would cost a dozen probes per terminal and — the reason
  # that actually decides it — would stop being a summary of the BOOT: it would
  # answer about now, while calling itself a start-up report. The `measured`
  # stamp inside the panel says which instant it holds.
  # The fallback covers a container started without the lifecycle (a bare
  # `docker run` on the image): there is no boot on record, so measure.
  if [ -r /workspace/.devcontainer/tmp/boot-summary.txt ]; then
    cat /workspace/.devcontainer/tmp/boot-summary.txt
  elif command -v boot-summary >/dev/null 2>&1; then
    boot-summary
  fi

  # What follows is deliberately NOT in the panel: it changes during a session,
  # not at boot, so a cached copy would go stale while looking authoritative.

  # A2 blocks-log summary: only meaningful in strict mode (the addons that
  # write to /var/log/mitmproxy-blocks.log only run there). Differentiate
  # blocked (B) from warn-only (W) so the user sees if they're running in
  # audit mode (lots of W, no B). Fast grep — runs on every shell.
  FW_MODE=$(cat /etc/devcontainer-firewall/default-mode 2>/dev/null | tr -d '[:space:]')
  FW_MODE="${FW_MODE:-strict}"
  case "$FW_MODE" in
    strict|paranoid)
      if [ -r /var/log/mitmproxy-blocks.log ]; then
        # grep -c prints "0" then exits 1 on no match — `|| true` swallows
        # the exit so we don't get "0\n0" multi-line.
        TOTAL=$(wc -l < /var/log/mitmproxy-blocks.log 2>/dev/null || true)
        TOTAL="${TOTAL:-0}"
        if [ "$TOTAL" -gt 0 ] 2>/dev/null; then
          WARNS=$(grep -c '"mode":"warn"' /var/log/mitmproxy-blocks.log 2>/dev/null || true)
          WARNS="${WARNS:-0}"
          BLOCKED=$((TOTAL - WARNS))
          echo "  Events:    $BLOCKED blocked / $WARNS warn-only — run 'firewall-blocks' to inspect"
        fi
      fi
      ;;
  esac

  # Scan-deps reminder (F2) — 1-line cyan passive prompt if any package.json
  # is newer than its corresponding `domains.d/npm.txt`. Mirrors the loud
  # yellow ASCII box shown once per container start in post-start.sh — but
  # quieter, refreshed every shell open.
  if [ -z "${SCAN_DEPS_HOOK_DISABLED:-}" ] && command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY' 2>/dev/null || true
import os, subprocess
DOMAINS_D = '/workspace/.devcontainer/firewall/domains.d'
MANIFEST_NAME = 'package.json'
ECO_FILE = 'npm.txt'
def find_manifests(depths=(3, 5, 8, 10)):
    for d in depths:
        res = subprocess.run(
            ['find', '/workspace', '-maxdepth', str(d), '-type', 'f',
             '-name', MANIFEST_NAME,
             '-not', '-path', '*/node_modules/*',
             '-not', '-path', '*/vendor/*',
             '-not', '-path', '*/.git/*',
             '-not', '-path', '*/__pycache__/*',
             '-not', '-path', '*/research-bundles/*'],
            capture_output=True, text=True)
        ms = [p for p in res.stdout.splitlines() if p]
        if ms:
            return ms
    return []
manifests = find_manifests()
if not manifests:
    raise SystemExit
target = os.path.join(DOMAINS_D, ECO_FILE)
if not os.path.exists(target):
    n_changed = len(manifests)
    msg = f"{n_changed} manifest(s) detected, never extracted"
else:
    target_mt = os.path.getmtime(target)
    n_changed = sum(1 for m in manifests if os.path.getmtime(m) > target_mt)
    if not n_changed:
        raise SystemExit
    msg = f"{n_changed} manifest(s) modified since last extract"
print(f"\033[1;36m  Scan-deps: {msg} — run extract-auto-dependencies\033[0m")
PY
  fi

  # Eight lines of "how to reset everything" used to sit here, against three
  # lines of state — the ratio the boot panel exists to invert. Two gestures
  # survive, because they are two different facts: CHANGING the firewall mode
  # is not the same as resetting a flag to its default, and the old screen was
  # the only place that said how to do the first.
  # The files are named rather than firewall-mode.sh, which is v2 workspace
  # tooling a project on the published image does not carry.
  echo "  Firewall mode: echo {strict|basic|off} > .devcontainer/firewall/default-mode, then rebuild"
  echo "  Reset a flag:  rm .devcontainer/{firewall/default-mode,tmp/configured/claude-mode}, then rebuild"
fi

# Claude Code local/cloud mode is switched from the HOST, not the container —
# see .devcontainer/host-helpers/claude-switch and knowledge/ollama-local.md. Keeping
# the toggle outside the container means a compromised in-container process
# can't silently flip the LLM endpoint. The ~/.claude-local/ isolation
# directory is initialized by post-start.sh when local mode is detected in
# .env at container boot.

# Per-dev zsh override (gitignored, persists with the workspace) — sourced
# LAST so it can override anything from zshrc-base or env vars set above.
if [ -n "$ZSH_VERSION" ] && [[ $- == *i* ]] && \
   [ -f /workspace/.devcontainer/zshrc.local ]; then
  source /workspace/.devcontainer/zshrc.local
fi
