# Add a lifecycle hook

**Goal.** Run something of your own while the container starts — seed a
database, export a variable, warn about a missing tool.

You add a **fragment**: one shell script in a phase directory. You do not
modify anything the image ships.

*Every command in a code block on this page runs in a terminal **inside the
container**, unless the step says otherwise.*

---

## Step 1 — choose the phase. This is the only real decision.

Everything else on this page is mechanical. Getting this wrong produces a
behaviour that works the day you write it and is quietly absent afterwards.

| Your behaviour | Phase | Because |
|---|---|---|
| must be true again after **every** restart | `post-start` | it is the only phase that runs on restarts as well as on creation |
| is a **one-shot** setup — seed data, a schema, a generated file | `post-create` | it runs once per container, after the network is up |
| must happen **before** anything else needs the network | `on-create` | it runs first, and it is the phase that has `sudo` |
| must run **per terminal** — an environment variable, a prompt | not a fragment | that is `shell-init`, and the image owns it |
| must run **on your host**, before a container exists | not a fragment | that is the host-side `initialize` step, run by the CLI |

The trap is the first two rows. `post-create` reads like "after the container
is created", and it is — *once*. A cache refresh, a credential sync, a warning
banner all belong in `post-start`.

Fuller definitions: [the phases](../concepts.md#the-phases).

## Step 2 — write the fragment

Any `*.sh` directly inside the phase directory, with a numeric prefix that
decides when it runs:

`.devcontainer/hooks/post-start.d/50-seed-cache.sh`

```bash
#!/usr/bin/env bash
# @name seed-cache
# @phase post-start
# @required false
# @description Warm the local package cache if it is empty.

set -eE

if [ ! -d "$HOME/.cache/mytool" ]; then
  mytool warm-cache
fi
```

What matters:

- **No executable bit is needed.** Fragments are run with `bash <file>`. A
  missing shebang or CRLF line endings will not stop the boot either.
- **Only `@required` is parsed.** The other header lines, `@phase` included,
  are documentation: the directory the file sits in is what decides when it
  runs, and a `@phase` that disagrees with it changes nothing. Write them
  anyway — they are what the dry run shows you.
- **Be idempotent.** `post-start` runs on every start, so a fragment that
  appends to a file will append again. Guard the side effect, as above.
- A fragment that exits non-zero gets a warning and the phase **continues**.
  Set `@required true` only when a later fragment genuinely cannot run without
  yours — it aborts the phase, and it is a promise to everyone who uses your
  image.

The numeric prefix orders fragments across
[all three layers](../concepts.md#the-three-layers) at once: your `50-` runs
before the image's `90-`, not after it.

## Step 3 — run the phase

```
devc-hook post-start
```

For `on-create` or `post-create`, use VS Code's Command Palette and
**Dev Containers: Rebuild Container** instead — those two phases only fire when
a container is created, so a restart will never run them.

---

## How to check it worked

Before running anything, ask what *would* run:

```
devc-hook post-start --dry-run
```

It lists every fragment in order, naming which of the
[three layers](../concepts.md#the-three-layers) each came from. Yours is there,
at the position its prefix earned. If it is missing, the filename is
wrong — it must sit directly in `<phase>.d/` and end in `.sh`.

Then run the phase for real. Its output went to a log file rather than to your
terminal, and the boot panel names that file:

```
boot-summary
```

Read the file on its `Log` line: your fragment's `@name` appears there with the
outcome the dispatcher recorded for it. That line, not the absence of an error
on screen, is the confirmation — a fragment that fails is deliberately quiet.

---

## Switching off a fragment the image ships

List it in `.devcontainer/hooks/disabled.txt`, one `<phase>.d/<file>.sh` per
line:

```
post-start.d/45-claude-update-probe.sh
```

A fragment marked `@required true` — the firewall bring-up, the credentials
sync — is **refused** here: listing it prints a warning and runs it anyway. To
switch one of those off deliberately, prefix it with `!`:

```
!post-start.d/20-firewall-reinit.sh
```

The prefix is an explicit opt-in, so it cannot happen by copy-paste. You are
switching off the network isolation this image exists for; be sure that is what
you mean.

Shipping a same-named no-op fragment also "works", but it walks around that
guard, and the dispatcher calls it out.

---

## Reference

Fragment headers, layer masking, and shipping fragments from an image that
extends this one:
[EXTENDING.md § Hooks](https://github.com/meitogi/devcontainer-sandbox/blob/master/EXTENDING.md#hooks).
