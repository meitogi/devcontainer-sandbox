# Concepts — the words every other page assumes

This page defines the vocabulary the rest of the documentation uses. Nothing
here is a procedure; every other page links back to a heading below instead of
redefining a term, so a word has exactly one definition.

If you have not started a container yet, read
[Getting started](getting-started.md) first — it uses these words in order and
points here for each one.

---

## The container

### Image, container, devcontainer

Three words that are easy to run together, and most of this page depends on
telling them apart.

- An **image** is a frozen filesystem plus the metadata needed to start it — a
  build artefact, immutable once published.
  `ghcr.io/meitogi/devcontainer-sandbox` is one, and "this image" throughout
  the documentation means that one.
- A **container** is one running instance of an image. It is where your code
  actually executes. Several can be started from the same image, and one can be
  thrown away without touching the image it came from.
- A **devcontainer** is a *description*, checked into the repository it belongs
  to, that your editor turns into a container for you: which image to start
  from, which directories to share with your machine, and what to run at each
  stage of startup. It lives in `.devcontainer/`.

The consequence recurs on every page below: changing a file in your repository
takes effect as soon as something reads it, while changing anything compiled
**into the image** costs a rebuild.

A devcontainer isolates the **filesystem**. On its own it does not isolate the
**network** — every process inside reaches the whole internet. That second half
is what this image adds.

### The three layers

Three things can contribute files, and they always resolve in the same order.

| Layer | Who writes it | Where it lands |
|---|---|---|
| 1 — **base** | this image, as published | `/opt/devcontainer/base/`, `/etc/devcontainer-firewall/` |
| 2 — **ext** | a `Dockerfile` that `FROM`s this image | `/opt/devcontainer/ext/`, `/etc/devcontainer-firewall/domains.d/` |
| 3 — **project** | a repository's own `.devcontainer/` | `/workspace/.devcontainer/` |

Resolution is **base < ext < project**, deduplicated by *filename*. The same
filename at a higher layer masks the lower one; a new filename adds to it.

Most people only ever touch layer 3. Layer 2 is for publishing a derived image
to a team — that is what
[EXTENDING.md](https://github.com/meitogi/devcontainer-sandbox/blob/master/EXTENDING.md)
is about.

---

## The lifecycle

### The phases

Startup is not one step. Each phase runs somewhere different, at a different
moment, with different guarantees — which is why "where do I put this?" has a
real answer rather than a preference.

| Phase | Runs | When | What belongs there |
|---|---|---|---|
| `initialize` | on your **host**, before any container exists | every time you open the project | reading host state, asking you questions, writing `.env`. The only step that can talk to you before there is a container |
| `on-create` | in the container, with `sudo` | **once**, at creation, before your extensions are installed | bringing the firewall up — anything later steps will need the network for |
| `post-create` | in the container | **once**, at creation, right after `on-create` | one-shot setup: symlinks, seeded files, a smoke test |
| `post-start` | in the container | **every** start, restarts included | everything that must be true again after a restart: credential sync, skill sync, the boot panel |
| `shell-init` | in the container, sourced | **every** interactive terminal you open | environment variables, and re-printing the boot panel |

`initialize` is run by `initializeCommand` in `devcontainer.json`, which hands
off to the host-side CLI. The three container phases in the middle are run by
`devc-hook`, and they are the three that accept **fragments**.

The distinction that costs the most time when it is missed: `post-create` runs
**once per container**, `post-start` runs **every time it starts**. A behaviour
you need after each restart placed in `post-create` will look correct on the
day you write it and be silently absent from then on.

### Fragment

One `*.sh` file inside a phase directory — `hooks/post-start.d/50-my-tool.sh`.
The phase runs its fragments in order of the numeric prefix, whichever layer
each one came from: a `10-` fragment added by a project still runs before a
`90-` one from the base image.

A fragment that exits non-zero gets a warning and the phase continues — unless
it declares `@required true` in its header comments, which aborts the phase.
That warning goes to the startup log, the file named on the boot panel's `Log`
line. It does not interrupt anything on screen.

To add one, see [Add a lifecycle hook](how-to/add-a-lifecycle-hook.md).

### Skill

A directory containing `<name>.skill.md`, which becomes the slash command
`/<name>` inside **Claude Code** — the coding agent this image exists to box
in, and what "the agent" means everywhere in this documentation. Skills are how
a project teaches it a procedure it should follow the same way every time.

A skill may also carry a `hooks.json`, merged into Claude Code's own settings.
Despite the name, that has nothing to do with the lifecycle `hooks/`
directories above: those are shell fragments run while the container starts,
this is configuration for the agent once it is running.

The image ships nine of them; the boot panel's `Skills` line counts what is
actually installed. To add one, see [Add a skill](how-to/add-a-skill.md).

---

## The firewall

"The firewall" is the whole outbound-filtering apparatus: a resolver that
answers only for hostnames you listed, packet rules that match it, and —
optionally — a proxy that also reads the requests themselves. It filters what
goes **out** of the container, and nothing else.

It is deny-by-default and it is compiled into the image, which is what the next
few terms are about.

### Allowlist

The list of hostnames this container is allowed to reach. Anything not on it is
refused. Deny-by-default: the list says what is permitted, not what is
forbidden — so a host nobody thought about is blocked rather than open.

The list is assembled from several files in your own repository, under
`.devcontainer/firewall/`. They differ only in who they are for:

| File | Committed? | For |
|---|---|---|
| `firewall/domains.txt` | yes | the project's baseline |
| `firewall/domains.d/<name>.txt` | yes | one ecosystem or concern per file, reviewable on its own |
| `firewall/domains.local.txt` | no, gitignored | your machine only, and easy to revert |
| `firewall/ports.txt` | yes | direct TCP services reached as `host:port`, not over HTTP |
| `firewall/policy.d/<host>.yaml` | yes | in `strict` only: which paths and methods are allowed on a host that is already on the list |

Those are paths in your repository. When the image is built, a stage compiles
them into `/etc/devcontainer-firewall/` inside it — which is why the layers
table above names system paths and this one names yours. They are the same
rules at two moments: before the build, and frozen after it.

To add a host, see [Allow a domain](how-to/allow-a-domain.md).

### DNS allowlist

The cheapest way to enforce that list. When a program asks "what is the address
of `example.com`?", the container's own resolver answers only for hostnames on
the list. Everything else gets no address and the connection never starts. It
is effective, and it is coarse: it decides per *hostname*, and it cannot see
what you then do with the connection.

Because the resolver refuses rather than forwards — it has no upstream to fall
back to — DNS is also closed as a way to smuggle data out through a host nobody
allowed. It says nothing about what could be done with a host that *is*
allowed; that is what the L7 filter below is for.

### L7

"Layer 7" is the top of the OSI model, the layer where HTTP lives: URLs,
methods (`GET`, `POST`), headers. An **L7 filter** reads the request itself, so
it can allow `GET https://api.github.com/repos/...` while refusing `POST` to
the same host. This image does that with a local HTTPS proxy (mitmproxy) whose
certificate the container trusts.

So: **DNS decides *which hosts*; L7 decides *what you may do with them***.
Losing L7 does not open the container to the whole internet — the hostname
allowlist is still enforced — but any allowed host becomes reachable for
*anything*, including writes and uploads.

### The three modes

| Mode | DNS allowlist | L7 filter | Path scopes enforced |
|---|---|---|---|
| `strict` | yes | yes | yes |
| `basic` | yes | no | **no** |
| `off` | no | no | — |

`strict` is the design intent and the default. `basic` is the escape hatch when
something genuinely cannot go through a proxy. `off` is a kill-switch.

The mode lives in `firewall/default-mode`, and like the rest of the firewall
configuration it is read when the image is **built**, not when the container
starts. So switching `strict` to `basic` is a rebuild, not a restart. The next
entry is that rule in full.

### Path scopes apply in `strict` only

This is the single most misread thing about the firewall.

`domains.txt` and `policy.d/*.yaml` can narrow an allowed host to certain paths
and methods. **Those scopes only exist in `strict`.** In `basic` there is no L7
layer to enforce them, and DNS matches whole hostnames — so an allowlisted host
accepts *every* path.

Reading `[GET] github.com /anthropics/*` and concluding that
`github.com/torvalds/…` is blocked is therefore false in `basic`. In `basic`
the only real block is a resolution failure — and that one is impossible to
miss, because the tool making the request stops with an `ENOTFOUND` or
`could not resolve host` error naming the host.

### Bake / baked / staged

The ruleset is compiled once when the image is **built** and frozen into it,
instead of being recompiled at every start. A frozen ruleset is one nobody can
quietly change at runtime, from inside a container the workload can also write
to.

- **baked in** — part of the image; active.
- **staged** — sitting in a file on disk, waiting for a rebuild to take effect.

This is why editing `firewall/domains.txt` and restarting changes nothing, and
why every firewall change ends with *Rebuild Container* rather than *Reopen*.
The base image ships the machinery and **no allowlist at all**: a project bakes
its own, so the image can never silently widen your rules.

---

## Claude Code inside the image

### Phase B

**Nothing to do with the lifecycle phases above.** It is an unrelated use of
the word, kept here because it is what the image's own logs and the boot panel
say.

It is how the `claude` command-line tool gets into the image. The VS Code
extension already ships a working binary inside it, so the image points at that
one instead of downloading a second copy from npm. It saves about 224 MB. The
fallback, when that does not work, is the npm install — and the boot panel says
which of the two you got.

### Patcher

A small Python script that modifies the Claude Code VS Code extension after
installation, to add something the published extension does not have. They are
optional, they come from a separate repository, and **most projects run
none** — you need one only if you want the extension to behave in a way its
published version does not offer. The image ships the tooling that can run a
patcher; it ships no patcher.

See [Patch the extension](how-to/patch-the-extension.md) — which is mostly
about when not to.

### Sentinel

A marker a patcher leaves in the file it modified, so the next boot can tell
"already applied" from "needs applying" without re-reading the whole bundle.
**Sentinels all live** on the boot panel means the extension still carries
every modification. Sentinels missing means an update replaced the file and the
patches are gone.

---

## Notifications

### Heartbeat

The notification daemon touches a small file every ten seconds to say "still
alive". If that file stops being touched, the daemon died.

The boot panel checks that file and warns when it has gone stale. That warning
is the only way you would find out: a notifier that has stopped does not
announce it, and "no notifications arriving" looks exactly like "nothing
happened worth telling you about".

---

## Checking any of this on a running container

Every term above has a line in the boot panel. It is measured once at the end
of startup and cached, so it describes **the boot**, not this instant. Print it
at any time:

```
boot-summary
```

```
╔════════════════════════════════════════════════════════════════════════╗
║  devcontainer-sandbox 1.5.0 · Claude Code 2.1.280                      ║
║  ✓ all clear · measured 2026-09-25 08:11:43                            ║
╠════════════════════════════════════════════════════════════════════════╣
║  Claude      dev · binary: extension (Phase B)                         ║
║  Firewall    strict · 412 allowlist entries · +6 local (baked in)      ║
║  Patchers    cc2.1.280-r2 · sentinels all live                         ║
║  Skills      9 installed                                               ║
║  Notify      daemon up (pid 4711)                                      ║
║  Log         .devcontainer/tmp/logs/post-start-20260925-101112.log     ║
╚════════════════════════════════════════════════════════════════════════╝
```

Three things on that frame are notation rather than concepts, and this is where
they are written down:

- **`dev`** on the `Claude` line is the Claude mode the project was scaffolded
  with. It selects which set of instructions the agent is given; `reviewer` is
  the other one.
- **`cc2.1.280-r2`** on the `Patchers` line is a patcher set's name: `cc` plus
  the Claude Code version it was cut for, plus `-r<n>`, the revision within
  that version. Sets are per Claude Code version and never substituted across
  versions.
- **`Log`** is the file the whole startup sequence was written to. It is the
  one thing to attach to a bug report, and the place a failed
  [fragment](#fragment) leaves its warning.

If you can now read every line of that frame and say what it means, this page
has done its job. If a line carries a `⚠`,
[Boot warnings](boot-warnings.md) has one section per warning.
