# Boot warnings — what they mean, and how to fix them

When a container built on this image starts, the last thing it prints is a panel
summarising what it actually started with. If anything is off, the panel says so
and points here.

```
╔════════════════════════════════════════════════════════════════════════╗
║  devcontainer-sandbox 1.5.0 · Claude Code 2.1.280                      ║
║  ⚠ 2 warnings: Firewall, Notify · measured 2026-09-25 10:11:12         ║
╠════════════════════════════════════════════════════════════════════════╣
║  Claude      dev · binary: extension (Phase B)                         ║
║  Firewall    basic · 412 allowlist entries                             ║
║  Patchers    cc2.1.280-r2 · sentinels all live                         ║
║  Skills      9 installed                                               ║
║  Notify      daemon STALE (pid 4711, last heartbeat 5800s ago)         ║
║  Log         .devcontainer/tmp/logs/post-start-20260925-101112.log     ║
╚════════════════════════════════════════════════════════════════════════╝
  ⚠ Firewall   no L7 filter — DNS allowlist only
  ⚠ Notify     heartbeat stopped — notifications will not arrive
```

**None of these stop the container.** They are all states where something you
probably expected to be true is not. Each one below says what you saw, what it
means in plain words, why it matters, and what to do.

You can re-print the panel at any time by typing `boot-summary` in a terminal
inside the container.

---

## Words you will see

One line each, so you can keep reading. The full definition of every term is on
[Concepts](concepts.md) — one definition, one place.

| Word | In one sentence |
|---|---|
| [allowlist](concepts.md#allowlist) | the list of hostnames this container may reach; anything else is refused |
| [DNS allowlist](concepts.md#dns-allowlist) | enforcing that list at name resolution, so an unlisted host never gets an address |
| [L7](concepts.md#l7) | a filter that reads the HTTP request itself, so it can allow `GET` on one path and refuse `POST` on another |
| [strict / basic / off](concepts.md#the-three-modes) | DNS **and** L7 · DNS only · no filtering |
| [path scopes](concepts.md#path-scopes-apply-in-strict-only) | the per-path rules in `domains.txt` and `policy.d/`; they exist **only** in `strict` |
| [baked / staged](concepts.md#bake--baked--staged) | compiled into the image at build time and active · written on disk and waiting for a rebuild |
| [patcher](concepts.md#patcher) | an optional script that modifies the Claude Code extension; most projects run none |
| [sentinel](concepts.md#sentinel) | the marker a patcher leaves, so a later boot can tell "already applied" from "gone" |
| [Phase B](concepts.md#phase-b) | using the binary already inside the VS Code extension instead of downloading a second copy |
| [heartbeat](concepts.md#heartbeat) | the file the notification daemon touches every ten seconds to say it is alive |

---

## `⚠ Firewall — no L7 filter, DNS allowlist only`

**What it means.** The container is in `basic` mode. Hostnames are still filtered;
what you *do* with an allowed host is not.

**Why it matters.** With L7 on, a host can be allowed for reading and refused for
writing. In `basic`, that distinction is gone — anything the allowlist permits, it
permits completely.

**Why you might be here on purpose.** `basic` is much lighter and it does not
require any program to trust the proxy's certificate. Some toolchains fight with
an intercepting proxy, and `basic` is the honest way out.

**How to fix it.** From a terminal, in the project directory:

```
echo strict > .devcontainer/firewall/default-mode
```

Then **Dev Containers: Rebuild Container** in VS Code. The mode is read at build
time, which is why editing the file alone changes nothing until you rebuild.

---

## `⚠ Firewall — no filtering at all, kill-switch mode`

**What it means.** Mode is `off`. Nothing is filtered — the container reaches the
whole internet.

**Why it matters.** This is the deliberate escape hatch for debugging a network
problem you suspect the firewall is causing. It is not meant to be left on. An
agent running in this container can reach anything, including services that would
accept its credentials.

**How to fix it.** Same as above, with `strict`, then rebuild.

---

## `⚠ Firewall — local overrides staged, NOT applied`

**What it means.** Your project has extra allowlist entries in
`.devcontainer/firewall/domains.local.txt` (or `policy.local.d/`), and they are
**not** in force. The file exists; the firewall does not know about it.

**Why it matters.** This is the failure that looks like a bug in something else:
you add a host, restart, and the connection is still refused. The rules are real,
they are just not loaded.

**Why it happens.** Local overrides are excluded from the frozen ruleset by
default, on purpose — so that what the image enforces is reproducible and does not
depend on a file on one machine.

**How to fix it — pick one.**

- Try them without a rebuild, from a host terminal:
  `reload-firewall --dry-run` to preview, then apply.
- Bake them in permanently: add `FIREWALL_ALLOW_LOCAL_AT_REBUILD=1` to
  `.devcontainer/.env` and rebuild.
- Or promote them: if they belong to the project rather than to you, move them
  from `domains.local.txt` into `domains.txt`, which is always baked.

Choosing between the three scopes, and finding the hostnames in the first
place: [Allow a domain](how-to/allow-a-domain.md).

---

## `⚠ Claude — binary: npm fallback, the extension's embedded binary was not used`

**What it means.** The image could not point `claude` at the binary already inside
the VS Code extension, so it installed a separate copy from npm.

**Why it matters.** Mostly size: the image is about 224 MB heavier than it should
be. The tool itself works. It can also mean the two copies drift — the extension
on one version, the command line on another.

**How to fix it.** This is an image build problem, not something to fix in your
project. It is worth reporting. The useful detail is in one file:

```
cat /etc/claude-source
```

---

## `⚠ Patchers — an apply would change it, it is running unpatched`

**What it means.** Patchers are configured, but the extension no longer carries
their markers — typically because VS Code updated the extension and replaced the
modified bundle with a fresh one.

**Why it matters.** Whatever the patchers add is not there. If you rely on it, it
is silently missing.

**How to fix it.** Re-apply them:

```
ext-patches-sync --force
```

Then **Developer: Reload Window** in VS Code. `ext-patches-sync --status` shows
what is configured and what is cached.

What patchers are, and when not to use them:
[Patch the extension](how-to/patch-the-extension.md).

---

## `⚠ Patchers — nothing cached for this line, no patcher applied`

**What it means.** The patcher reference is set to `auto`, and no patcher release
exists for the Claude Code version installed here — or the machine could not reach
the repository that holds them.

**Why it matters.** No patcher ran. The extension is the published one.

**How to fix it.** Either pin a reference you know works, in `.devcontainer/.env`:

```
EXT_PATCHES_REF=cc2.1.280-r2
```

…or accept the untested head deliberately:

```
EXT_PATCHES_ALLOW_UNTESTED=1 ext-patches-update
```

Pinning is the safe answer. `auto` only ever picks a release that was tested
against your exact Claude Code version, which is why it refuses rather than
guessing.

How the reference resolves, and how to move it deliberately:
[Patch the extension](how-to/patch-the-extension.md).

---

## `⚠ Notify — heartbeat stopped, notifications will not arrive`

**What it means.** The notification daemon ran, then stopped. It normally touches
its lock file every 10 seconds; that file has gone stale.

**Why it matters.** Desktop notifications — "your task finished", "permission
needed" — will not reach you. Nothing else breaks, so this one is easy to miss for
a long time.

**How to fix it.** The daemon runs on your machine, not in the container, and it
is started when the container is opened. The simplest fix is to close and reopen
the folder in a container. Its log says why it stopped:

```
cat .devcontainer/tmp/notify/daemon.log
```

The most common cause is a Node version on the host that is too old — it needs 18
or newer.

---

## Nothing here matches what I saw

Open an issue: <https://github.com/meitogi/devcontainer-sandbox/issues>. Attach the
file named on the panel's `Log` line — it holds the whole start sequence.

If the panel was clean and something is still wrong,
[Troubleshooting](troubleshooting.md) is sorted by symptom instead of by
warning. Back to [the documentation map](index.md).
