# Extension points — how to add typical things

**The common gestures are documented for humans, and the same files are baked
into this image.** Read them there first:

    /opt/devcontainer/base/docs/how-to/

- `add-a-skill.md` — a slash command for the agent
- `add-a-lifecycle-hook.md` — a fragment in `on-create` / `post-create` /
  `post-start`, and the table that decides which
- `allow-a-domain.md` — the allowlist, and **how to discover** the hostnames
  instead of guessing them
- `add-a-stack.md` — a toolchain the Node 24 base does not carry
- `patch-the-extension.md` — modifying the Claude Code extension, and when not
  to

Those are byte-identical to
<https://github.com/meitogi/devcontainer-sandbox/blob/master/docs/how-to/> —
one tree, copied in at build, so there is nothing here to drift from it. Each
page states how to **verify** the change took effect, which is the part worth
quoting back to a user. The vocabulary is at
`/opt/devcontainer/base/docs/concepts.md`, and layer resolution in full is in
the image's `EXTENDING.md`.

What stays below is maintainer work on **this image**, which has no
human-facing page because it is not something a project does.

## Add a new mitmproxy addon

The addons are part of the image, not of a project: `firewall-docker-setup.sh`
bakes a project's `domains*`/`ports.txt`/`policy.d`, and nothing else. A new
addon is a change to this repository, or to an image that `FROM`s it.

1. Create `assets/etc-firewall/addons/<name>.py` (lands at
   `/etc/devcontainer-firewall/addons/`)
2. Import `ruamel.yaml` — **not** PyYAML; the mitmproxy bundle ships ruamel only
3. Implement the `request(flow)` / `response(flow)` hooks
4. Add it to the `--scripts` chain in `bin/mitm-init.sh`
5. Add a stub in `assets/etc-firewall/tests/addons.sh` (it stubs
   `mitmproxy.http` via `sys.modules`)
6. If the addon writes a new log file, check `node` is in the group that can
   read it — `firewall-blocks` relies on `adm` for exactly this reason

## Debug capture addon (`capture_messages_debug.py`)

Always loaded, **off by default**. When enabled it dumps every POST
`/v1/messages*` body for `api.anthropic.com` + `ollama.internal` +
`ollama.local` to `/tmp/claude-capture/` as a `.json` (the raw request body)
plus a `.sh` (a ready-to-replay curl that re-sends the exact bytes).

Use case: compare what Claude Code actually sends in cloud vs local mode, or
replay a hanging request against another backend without re-triggering the
conversation. It captures both flow paths regardless of which mode `.env` is
in.

**Live toggle via a sentinel file** — every request `stat()`s it, so on and off
take effect instantly, with no mitmproxy restart:

```bash
touch /tmp/claude-capture/.enabled
rm    /tmp/claude-capture/.enabled
```

Enable, trigger the failing request, disable, then read the newest `.json` —
structure, system prompt length, tool count, `max_tokens`, and the
`thinking` / `context_management` / `output_config` / `diagnostics` extras.
`bash <stem>.sh` replays it with timing.

Headers are redacted in the generated `.sh` (`x-api-key`, `authorization`,
`anthropic-auth-token` → `XXX-REDACTED`). The `.json` body is untouched: auth
lives in headers only.

Storage is `tmpfs`, so captures vanish on restart — copy anything worth keeping
out of `/tmp/claude-capture/` first.

> Trees that ship a `host-helpers/mitm-capture` wrapper (the dogfood
> repository) can drive the same sentinel from the host. This image does not
> ship that helper; the two commands above are the whole mechanism.
