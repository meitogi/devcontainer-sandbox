# Extension points — how to add typical things

## Add a new skill (slash command)

1. Create `.devcontainer/skills/<name>/<name>.skill.md` — the body becomes the slash command prompt
2. Optional: `.devcontainer/skills/<name>/hooks.json` for `~/.claude/settings.json` merges
3. `sync-skills` (invoked by the `75-skills-sync` post-start fragment) automatically copies `*.skill.md` → `~/.claude/commands/<name>.md` on next restart
4. Skills suffixed `.local.skill.md` or living under `<name>.local/` are gitignored (personal skills)
5. Test: open a fresh terminal, run `/<name>` from Claude

## Add a new host-helper

1. Create executable `.devcontainer/host-helpers/<name>` (shebang `#!/usr/bin/env bash` typical, no `.sh` extension by convention)
2. Document in [RUNBOOK.md](../RUNBOOK.md) — host-helpers are operator-facing
3. If a `/prepare-X` skill generates work for the host, the helper consumes the output (e.g. `pr-from-draft` reads `pr-drafts/<id>.yaml`)
4. Add a `pass_if "<name> executable"` test in `diagnose.sh`

## Add a per-ecosystem allowlist

1. Create `firewall/domains.d/<eco>.txt` — same syntax as `domains.txt`
2. Install the dependency, then read what `firewall-blocks` reports as denied ;
   that output is the authoritative list of hosts to add, and it beats guessing
   a vendor's CDN from its `.com`
3. Commit the file — `domains.d/` is the project layer, so colleagues get it too
4. `Dev Containers: Rebuild Container` — the allowlist is baked, not read at runtime
5. Re-install : zero blocks confirms the list is complete

## Add a new lifecycle behaviour

Pick the hook based on idempotency required (see table above). Always:
- Source `set -euo pipefail` at the top
- Echo to the phase log under `.devcontainer/tmp/logs/` (post-start) or echo to stderr (other scripts) — never to stdout
- Guard against side-effects: `grep -q "marker" file || echo "marker" >> file`
- Test with multiple restarts: `docker compose restart app` → verify no growth in flags/files

## Remove a baked lifecycle fragment or skill

Both are `.txt` lists, same four rules as the firewall files (one entry per
line, `#` comments inline or full-line, blank lines ignored):

| Remove | File | Entry |
|---|---|---|
| a lifecycle fragment | `.devcontainer/hooks/disabled.txt` | `post-start.d/45-claude-update-probe.sh` |
| a skill | `.devcontainer/skills/disabled.txt` | the skill's **directory** name, e.g. `notify-queue` |

- `devc-hook <phase> --dry-run` lists what would run and from which layer.
- A fragment declaring `@required true` is refused and run anyway; the
  deliberate opt-in is a `!` prefix (`!post-start.d/20-firewall-reinit.sh`).
- Skills have no `@required`, so no `!` form. The key is the directory because
  hooks-only skills (`notify-queue`, `session-gap`) have no command name.
- Each of the three layers (image / extending Dockerfile / project) has its own
  file; the lists are unioned, never overridden.
- `customizations.stitchu-devc.disabledHooks` in `devcontainer.json` still
  works and is unioned in, but it is deprecated — JSONC needs a parser, and
  the one the shell had cut `//` inside strings.

## Add a new firewall domain (audit-tracked)

Three paths, in increasing scope:

1. **`domains.local.txt`** — for read-only docs you alone need. Gitignored. No PR review.
2. **`domains.d/<eco>.txt`** — for project deps. Committed → audit in PR.
3. **`domains.txt`** — baseline, touches every dev. Rarely correct. Prefer `policy.local.d/<host>.yaml` overrides if you need advanced rules.

POST allowlist changes are **always** suspect — prefer an isolated devcontainer over adding a POST host to the main allowlist.

## Add a new mitmproxy addon

1. Create `firewall/addons/<name>.py`
2. Import `ruamel.yaml` (NOT PyYAML — the mitmproxy bundle ships ruamel only)
3. Implement `request(flow)` / `response(flow)` hooks
4. Update `mitm-init.sh` `--scripts` chain to include the new addon
5. Add unit test stub in `firewall/tests/addons.sh` (uses `sys.modules` stub for `mitmproxy.http`)
6. Bump `usermod -aG adm node` group if the addon writes a new log file

## Debug capture addon (`capture_messages_debug.py`)

Always-loaded mitmproxy addon, **off by default**, that dumps every POST
`/v1/messages*` body for `api.anthropic.com` + `ollama.internal` + `ollama.local`
to `/tmp/claude-capture/` as a `.json` (the raw request body) + a `.sh`
(ready-to-replay curl that re-sends the exact bytes against Ollama).

Use case : compare what Claude Code actually sends in cloud vs local mode,
or replay a hanging request against alternate backends without re-triggering
the conversation. Captures both flow paths (cloud + local) regardless of
which mode `.env` is in.

**Live toggle** via sentinel file (no mitmproxy restart needed) — every
request stat()s the sentinel, so on/off takes effect instantly :

```bash
# [host] enable / disable
bash .devcontainer/host-helpers/mitm-capture on
bash .devcontainer/host-helpers/mitm-capture off

# [host] inspect
bash .devcontainer/host-helpers/mitm-capture status      # state + count
bash .devcontainer/host-helpers/mitm-capture ls          # list captures
bash .devcontainer/host-helpers/mitm-capture clear       # rm captures

# [container, equivalent without docker]
touch /tmp/claude-capture/.enabled                       # on
rm    /tmp/claude-capture/.enabled                       # off
```

Headers are redacted in the generated `.sh` (`x-api-key`,
`authorization`, `anthropic-auth-token` → `XXX-REDACTED`). The `.json`
body is untouched — auth lives in headers only, not in the body.

When investigating a hang : turn on, trigger the failing request, turn
off, inspect the latest `.json` (structure, system prompt length, tool
count, `max_tokens`, `thinking`/`context_management`/`output_config`/
`diagnostics` extras), and `bash <stem>.sh` to replay against Ollama
with timing. Storage is `tmpfs` inside the container so files vanish on
restart ; copy to `.devcontainer/pending/` to keep across reboots.

## Add a new Dockerfile variant

For projects that need extra runtime (PHP, Python for ML, etc.) — pattern from v2.1-3 :

1. Create `.devcontainer/Dockerfile.<variant>` :
   ```dockerfile
   ARG CLAUDE_CODE_VERSION=2.1.145
   FROM claude-devcontainer-base:${CLAUDE_CODE_VERSION}
   USER root
   RUN apt-get update && apt-get install -y --no-install-recommends \
       <variant-specific packages> \
       && apt-get clean && rm -rf /var/lib/apt/lists/* \
       && rm -rf /usr/share/doc/* /usr/share/man/*
   COPY --from=<reference-image>:<tag> <bin> /usr/local/bin/<bin>
   USER node
   ```
2. Reference from the consuming project's `docker-compose.yml`:
   ```yaml
   services:
     app:
       build:
         context: .
         dockerfile: Dockerfile.<variant>
   ```
3. **No** modif to `initialize.sh` (Option B) — `claude-devcontainer-base` is already built by the main project's initialize, the variant just `FROM`s it. Docker layer cache deduplicates the variant layer across projects that share the same `FROM` + same `RUN apt install`.
4. Pin the same `CLAUDE_CODE_VERSION` default as `Dockerfile.base` so bumps stay in sync (or override via compose `${VAR:-...}` from project `.env`).
5. Smoke-test : `docker build -f .devcontainer/Dockerfile.<variant> ...` then `docker run --rm <tag> <variant-tool> --version`.

Example: [Dockerfile.php](../Dockerfile.php) — PHP 8.2 + Composer 2 + 13 extensions, ~150 MB layer delta per PHP project, deduped across PHP-variant projects via Docker content-addressable cache.
