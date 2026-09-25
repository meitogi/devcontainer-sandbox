# Getting started — from nothing to a container that runs

This page assumes you have never made a devcontainer. It ends with you inside
one, looking at a panel that says what it started with.

Every term you have not met before is linked to [Concepts](concepts.md) the
first time it matters. You do not have to read that page first.

---

## What a devcontainer is

A **devcontainer** is a description of a development environment, checked into
the repository it belongs to, that your editor turns into a running container.
It says which image to start from, what to mount, and what to run at startup.

Anyone who opens the repository gets the same environment. Your toolchain
stops being something each person sets up on a laptop and becomes something the
repository carries — which is also why the short list of things you still need
on your own machine, below, is short.

A devcontainer isolates the **filesystem**. It does not isolate the network.

## Why this image exists

Everything inside an ordinary container reaches the whole internet. That is
fine when a container runs your tests. It is a different proposition once an AI
agent is running in your repository with real autonomy — and it is not only the
agent: an `npm install` postinstall script, a compromised transitive
dependency, and a `curl` buried in a Makefile all have the same reach.

So the comparison this image asks you to make is not "container or no
container". It is:

> an agent with a shell on your machine and an open network,
> against the same agent in a box that can only reach the hosts on a list you
> wrote — and, in the default mode, only in the ways you allowed.

Everything that follows — the rebuilds, the
[allowlist](concepts.md#allowlist), the boot panel — exists because of that
second line. Deny-by-default is not something you can
add convincingly afterwards, from the inside, to a container the workload can
also write to. It has to be baked in, and it has to be checkable.

## What you need first

- **Docker**, running.
- **VS Code** with the **Dev Containers** extension.
- **Node 18 or newer on your host.** The scaffolding step runs on your machine,
  before any container exists — so this one requirement cannot be met by the
  container itself. On Windows, run from WSL2 or Git Bash.
- **A project directory**, ideally a git repository. Everything below is
  written into it.

---

## Step 1 — scaffold the project

From the root of the project directory, on your own machine:

```
npx @meitogi/devcontainer-cli init
```

It prints what it detected about your project, then asks six questions. None
of them is irreversible — every answer lands in a file you can edit afterwards.

| It asks | What the answer decides |
|---|---|
| **Stack** | The base image is Node 24 and needs nothing added. Any other language is a block of `Dockerfile` you paste in, and this answer picks which recipe to point you at — the recipes are in [Add a language stack](how-to/add-a-stack.md) |
| **Project id** | The Docker Compose project name, and the prefix of this project's volumes. Lowercase letters, digits and hyphens |
| **Display name** | What VS Code shows in the window title and the status bar |
| **Claude credentials volume** | Whether Claude's login is shared with your other projects or private to this one. Sharing means one login per machine instead of one per project |
| **Claude Code line** | The image is published once per Claude Code version. Change this only to stay on an older one |
| **Extension patchers** | A repository of [patchers](concepts.md#patcher). Leave it empty — most projects run none, and nothing else is asked if you skip it. If you do need them: [Patch the extension](how-to/patch-the-extension.md) |

Then it shows a summary and asks `Proceed?`. Declining writes nothing.

What it writes, in one place, `.devcontainer/`: a `Dockerfile` that already
contains the mandatory firewall [bake](concepts.md#bake--baked--staged) stage,
a `docker-compose.yml`, a `devcontainer.json` wired to
[the lifecycle phases](concepts.md#the-phases), a `firewall/` directory holding
your allowlist, empty `hooks/` directories, and a `.env` carrying the answers
above.

It also writes a `package.json` at the project root if there is none, and adds
the CLI to it as a dev dependency — including for a non-Node project. That is
not a claim about your stack: it is what lets the container start without
reaching the registry, because the startup step then runs the copy already on
disk.

Nothing there is generated at runtime. It is all yours, and all readable.

## Step 2 — open it

In VS Code, open the Command Palette — `Ctrl+Shift+P`, or `Cmd+Shift+P` on a
Mac — and run **Dev Containers: Reopen in Container**. It is a command, not a
button or a menu entry.

**The first time takes several minutes and looks like nothing is happening.**
VS Code pulls a 2–3 GB image, builds your firewall into it, then runs three
startup phases. Until you open the progress panel, the window just sits there.

This is the one moment people give up. Click **show log** in the notification,
or open the terminal panel — you will see the pull, then the build, then the
lifecycle. Subsequent opens take seconds.

## Step 3 — read the panel

When the container is up, VS Code opens a terminal in it and that terminal
prints this:

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
  📖 docs — concepts, how-tos, troubleshooting: https://github.com/meitogi/devcontainer-sandbox/blob/master/docs/index.md
```

Line by line:

- **Title** — the image version, and the Claude Code version it was published
  with. The image is cut once per Claude Code release, so these two travel
  together.
- **Verdict** — `✓ all clear`, or `⚠ N warnings` naming which lines are off.
  The colour carries the same fact for anyone skimming. It is measured once at
  the end of startup and cached, so every terminal shows *the boot*, not the
  present moment.
- **Claude** — the mode, and which binary backs the `claude` command.
  `extension ([Phase B](concepts.md#phase-b))` is the good case: the CLI came
  from the binary already inside the VS Code extension instead of a second
  download.
- **Firewall** — the mode, and how many hostnames are allowed. `strict` means
  both the [DNS allowlist](concepts.md#dns-allowlist) and the
  [L7 filter](concepts.md#l7) are on. `+6 local (baked in)` counts your
  personal additions and confirms they are active. The word matters: the other
  thing that line can say is `STAGED`, which means you wrote them and did not
  rebuild, so they are not in force.
- **Patchers** — which patcher set was applied, and whether its
  [sentinels](concepts.md#sentinel) are still live. The sample above shows a
  project that uses them; **most projects do not**, and this line reading
  `none` is the ordinary, correct case.
- **Skills** — how many slash commands are installed for Claude Code.
- **Notify** — whether the daemon that relays "your task finished" to your
  desktop is still alive; `pid` is the process id it is running under, useful
  only when you go looking for it. A notifier that has died fails silently by
  nature, which is the whole reason it is on the panel.
- **Log** — where the whole startup sequence was written. This is the file to
  attach to a bug report.

Below the frame, on every boot, is a link to this documentation — the page you
are reading is at the end of it, and so is everything else.

If any line carries a `⚠`, [Boot warnings](boot-warnings.md) has one section
per warning, saying what it means and what to do.

## Step 4 — the first thing that will go wrong

In a terminal **inside the container**, install your dependencies — `npm
install`, `composer install`, `pip install -r requirements.txt`, whatever your
project uses. There is a real chance one of them fails to reach something:

```
npm error code ENOTFOUND
npm error network request to https://cdn.example.net/... failed
```

That is not a broken container. That is the firewall doing exactly what it was
installed to do: the host is not on your allowlist, so it has no address.

**Do not guess which hostnames to add.** The error already names the host, and
that message is the record: the resolver refuses silently, so nothing else logs
it. For the other kind of refusal — a host that resolves but whose request was
rejected — run this in the container:

```
firewall-blocks
```

On a healthy container it prints a summary with zero recent entries. Anything
it lists is a request that was allowed to resolve and then refused on its path
or its method — a different problem from the one above, and it says which host
and which path.

Adding the hosts your error named, and only those, is
[Allow a domain](how-to/allow-a-domain.md) — the page separates the two kinds
of refusal and explains why the change needs a rebuild rather than a
restart.

---

## You are done when

```
boot-summary
```

run in a terminal inside the container, prints a frame whose verdict line
reads `✓ all clear` — and your project's install runs to completion without a
single resolution failure.

## Where to go next

- [Concepts](concepts.md) — the vocabulary, now that you have seen it in use.
- [How to](index.md#i-want-to-extend-it) — add a skill, a startup step, a
  domain, a language stack.
- [Troubleshooting](troubleshooting.md) — sorted by what you are seeing.
