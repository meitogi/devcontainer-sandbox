# Extending the image

This page is for the **level 2** case: you are writing a `Dockerfile` that
`FROM`s this image and want to add your own hooks, skills, firewall rules or
VS Code extension patches on top.

If you only want to configure a *project*, you do not need any of this — put
your files in `.devcontainer/` and read the overlay section of the
[README](README.md) instead.

## Three levels, one order

| Level | Who extends | Where it writes |
|---|---|---|
| 1 | nobody — the image as published | `/opt/devcontainer/base/`, `/etc/devcontainer-firewall/` |
| 2 | **a `Dockerfile` that `FROM`s this image** | `/opt/devcontainer/ext/`, `/etc/devcontainer-firewall/domains.d/` |
| 3 | a project's `/workspace` | `/workspace/.devcontainer/` |

Resolution is always **base < ext < workspace**, deduplicated by *filename*.
Same filename in a higher level masks the lower one; a new filename adds. The
numeric prefix decides run order, not which level a fragment came from — a
`10-` fragment added at level 2 still runs before a `90-` one from the base.

**Write to `ext/`, never to `base/`.** Nothing physically stops you from
`COPY`ing into `/opt/devcontainer/base/hooks/…`, and it would even appear to
work — Docker would overwrite our file. But the base copy is then gone, the
run log cannot tell you which level a fragment came from, and you would be
able to neutralise a `@required` fragment without anything saying so. The
resolver treats `ext/` as its own layer precisely so none of that is possible.

## A Dockerfile that adds all four

```dockerfile
# the three published lines
#   1.5.0-cc2.1.280   (default)
#   1.5.0-cc2.1.272
#   1.5.0-cc2.1.220
ARG BASE_VERSION=1.5.0
ARG CLAUDE_CODE_VERSION=2.1.280
FROM ghcr.io/meitogi/devcontainer-sandbox:${BASE_VERSION}-cc${CLAUDE_CODE_VERSION}
USER root

# 1. a lifecycle hook — runs at its numeric position among the base fragments
COPY hooks/50-my-tool.sh /opt/devcontainer/ext/hooks/post-start.d/50-my-tool.sh

# 2. a skill — becomes a slash command, its hooks.json is merged and retargeted
COPY skills/my-skill/ /opt/devcontainer/ext/skills/my-skill/

# 3. firewall — an additive allowlist layer beside the image's 00-base.txt
COPY firewall/50-my-hosts.txt /etc/devcontainer-firewall/domains.d/50-my-hosts.txt

# 4. a VS Code extension patch — see the section below
COPY patches/my-patch.py /usr/local/bin/vscode-ext-patchs/
RUN . /etc/claude-build-env \
 && PYTHONDONTWRITEBYTECODE=1 restore-ext-patches all \
 && chown node:node "$EXT_DIR/extension.js"

USER node
```

The four directories already exist in the image (`ext/hooks/{on-create,post-create,post-start}.d`
and `ext/skills`), so a bare `COPY` is enough — no `mkdir` needed.

## Hooks

A fragment is any `*.sh` directly inside `<phase>.d/`. Phases are `on-create`,
`post-create` and `post-start`.

```bash
#!/usr/bin/env bash
# @name my-tool
# @phase post-start
# @required false
# @description What this does, in one line.
set -eE
```

Only `@required` is parsed; the rest is documentation.

- Fragments run with `bash <file>`. **No executable bit is needed**, and a
  missing shebang or CRLF line endings will not stop the boot.
- A fragment that exits non-zero gets a `WARN` and the phase continues —
  **unless** it declares `@required true`, which aborts the phase.
- `@required true` is a promise you are making to whoever consumes your image.
  Use it only when a later fragment genuinely cannot run without yours.

Do not ship a fragment that masks one of the base `@required` fragments
(`on-create.d/10-firewall-init.sh`, `post-start.d/20-firewall-reinit.sh`,
`post-start.d/55-claude-creds-sync.sh`) unless you are deliberately replacing
that machinery. The dispatcher prints a warning naming both layers when you do.

### Switching a base fragment off

Ship `hooks/disabled.txt` in your layer — one `<phase>.d/<fragment>.sh` per
line, `#` comments, same format as the firewall files:

```
# the base image's update probe: our users are offline
post-start.d/45-claude-update-probe.sh
```

That is the supported way to remove a fragment you did not write. Masking it
with a same-named no-op also "works", but it walks around the `@required`
guard, so the dispatcher calls it out.

The three layers each have their own file and the lists are **unioned** —
yours does not cancel the project's, and vice versa. A fragment marked
`@required true` is refused here too, unless prefixed with `!`.

## Skills

A skill is a directory containing `<name>.skill.md` — that file becomes
`~/.claude/commands/<name>.md`. It may also carry a `hooks.json`, merged into
`~/.claude/settings.json`.

Spell the commands in `hooks.json` with the **absolute path your image uses**:

```json
{"SessionStart":[{"hooks":[{"type":"command","command":"node /opt/devcontainer/ext/skills/my-skill/hook.js"}]}]}
```

`sync-skills` rewrites that prefix to the directory it actually read the file
from, and deduplicates on the path-independent form — so a project skill of the
same name *replaces* yours instead of registering a second copy.

Shipping a `*.skill.disabled.md` instead registers nothing: neither the command
nor the hooks — that is how you shelve a skill you own.

To remove one you do **not** own, ship `skills/disabled.txt` — one skill
directory name per line:

```
# the base image's notification hook: we have our own
notify-queue
```

The key is the directory, not the command, so a hooks-only skill (no
`*.skill.md` at all) can be switched off too. Listing a skill withdraws both
its command and its hooks, including ones a previous boot already installed —
`~/.claude/` lives in a volume that outlives the image. Lists from the three
layers are unioned. A project can do the same to yours.

## Firewall

The allowlist is additive: drop a `<NN>-<name>.txt` into `domains.d/` beside
the image's `00-base.txt`. Nothing merges or overwrites, and the file is
hashed into the bake digest, so adding one correctly invalidates a frozen
ruleset.

Direct-TCP services (non-HTTP, reached by `host:port`) go in `ports.txt`, one
entry per line, `#` for comments, inline `#` stripped:

```
# Ollama on the host
host:11434
peer-container:5432
```

> `ports.txt` was called `direct-tcp-allow.txt` until 2026-08-10. Both names
> are read for one version; the old one logs a deprecation warning, and if both
> exist only `ports.txt` is applied. Unlike `domains.d/`, `ports.txt` is a
> single flat file with no `.d/` variant — a project's `firewall/` bake
> replaces it wholesale.

A **project** consuming your image still has to run the two-stage firewall
bake documented in the [README](README.md); shipping firewall rules in your
layer does not remove that step.

And whatever you bake, the container it runs in needs two capabilities:
`init-firewall.sh` programs netfilter, which `devcontainer.json` alone cannot
authorise. Only compose can, so the service that builds from your image needs:

```yaml
    cap_add:
      - NET_ADMIN
      - NET_RAW
```

Those two and no third — the image's own suite asserts the list is exactly
these. Without them the firewall refuses to start, `exit 3`, naming this;
before that refusal existed the boot died on an iptables `you must be root`
that was pointing at the wrong thing, and the container came up with no
filtering at all. The reasoning for each capability is in the README,
§ "Use compose — the firewall needs capabilities".

## VS Code extension patches

The base image installs the Claude Code extension **exactly as published** and
ships no patcher. What it ships is the toolkit that can run one, so an image
built on top can add its own — for its own users, on its own installation.

`/etc/claude-build-env` is written at image build and is the seam you need:

| Variable | Meaning |
|---|---|
| `VP` | `linux-x64` or `linux-arm64` |
| `EXT_DIR` | where the Claude Code extension is extracted |
| `BIN` | the extension's embedded native CLI |
| `REL` | the `relativeLocation` used in `extensions.json` |

Two ways in. **At build time**, in your own Dockerfile — install the patcher
next to the toolkit and let the orchestrator run it:

```dockerfile
COPY my-patch.py /usr/local/bin/vscode-ext-patchs/
RUN . /etc/claude-build-env \
 && PYTHONDONTWRITEBYTECODE=1 restore-ext-patches all \
 && chown node:node "$EXT_DIR/extension.js"
```

Installing it into `/usr/local/bin/vscode-ext-patchs/` rather than running it
from `/tmp` is what makes it a first-class patch: it is then selectable by name
and by category, `restore-ext-patches` replays it with the others, and
`--list` reports whether it is live. The price is a valid `# @patch-*` header —
a script without one in that directory stops the build on purpose. The contract
is in [`AUTHORING.md`](assets/vscode-ext-patchs/AUTHORING.md).

**At container create**, without rebuilding anything, through the
`45-ext-patches.sh` hook. It resolves patchers from a directory you mount
(`EXT_PATCHES_DIR`) or from a source tarball (`EXT_PATCHES_REPO` +
`EXT_PATCHES_TOKEN`; `EXT_PATCHES_REF` pins a tag or a commit, and unset it
resolves to the newest tag cut for this container's Claude Code version,
`cc<version>-r<n>`, the cache first),
merges them with any `*.py` in the project's own
`.devcontainer/claude/vscode-ext-patchs/`, and applies the lot. With none of
those variables set it exits 0 in silence. The image ships no default and names
no repository — see `.env.example`.

**Between two patch sets**, with `ext-patches-update`. The hook resolves the
pin it is given, or the line already cached for an auto ref, and no more: a
boot never moves on its own, because a boot that installs "whatever was
newest" is not reproducible. `ext-patches-update` is the seam where that
changes on purpose — `--check` says what is available and touches nothing, a
bare run installs the newest tag **of this container's Claude Code version**
and rewrites `EXT_PATCHES_REF` in `.env` (an auto ref stays auto), and `--dir`
does the same from a local checkout with no network and no token.

A patcher set is tested against particular Claude Code versions and its tag
says which: `cc<version>-r<n>`. So the resolution reads the installed
extension's version, keeps the tags that match it, and takes the largest `-r`.
A version with no tag of its own is refused rather than served another
version's set — set `EXT_PATCHES_ALLOW_UNTESTED=1` to take the repository's
HEAD anyway, which is still written back as the commit it resolved to. A
repository that does not use the convention at all keeps the newest-overall
behaviour, release first and tag list second. It hands the actual work to
`ext-patches-sync`, so the update path and the boot path cannot drift apart.
`ext-patches-sync --status` reports what is configured and cached without
changing anything.

### Where the patchers live

`run-all.sh` scans exactly one directory, and `PATCH_DIR` says which: unset, it
is the toolkit's own directory (the build-time case above); set, it is yours
(what the hook does). `_common.py` stays with the toolkit either way — the
orchestrator puts the toolkit directory on `PYTHONPATH`, so a plain
`from _common import …` resolves from anywhere. A directory with no `.py` is
not an error: the toolkit says so and exits 0, which is the base image's
nominal state.

### Choosing which patches your image bakes

Patches applied at **build** time rewrite the extension's files in place, so an
environment variable cannot switch one off after the fact. The build ARG is
what decides:

```dockerfile
FROM ghcr.io/meitogi/devcontainer-sandbox:${BASE_VERSION}-cc${CLAUDE_CODE_VERSION}
ARG CLAUDE_CODE_EXT_PATCHS=ux,fix
```

It takes `all`, `none`, the categories `ux` / `fix` / `notify`, patch names, or
any comma-separated mix. A token naming nothing fails the build rather than
silently dropping a patch. The default is `none`, and on the base image — which
has no patcher — `all` and `none` do the same thing.

Because the build keeps a pristine copy of `package.json`, `extension.js` and
`webview/index.js` under `/usr/local/share/claude-ext-orig/`, the choice is
reversible at runtime, without a rebuild:

```bash
restore-ext-patches --list      # what is live right now
restore-ext-patches ux,fix      # restore, then replay this selection
restore-ext-patches none        # back to the extension as published
```

The `CLAUDE_CODE_EXT_PATCHS` environment variable readable in the container
records what the build chose; setting it at runtime patches nothing on its own.
## What a project can still do to your image

Whatever you bake at level 2, a project can mask by filename, and can switch
off through its own `.devcontainer/hooks/disabled.txt` and
`.devcontainer/skills/disabled.txt` — the same two files you get, one layer up.

One exception: a fragment declaring `@required true` is **refused**, named in
the log, and run anyway. Disabling it needs the deliberate `!` form:

```
!on-create.d/10-firewall-init.sh
```

That is not a formality — without it, a project can boot with no firewall at
all and nothing would say so.

### The deprecated alias

`customizations.stitchu-devc.disabledHooks` in `devcontainer.json` is still
read and unioned with the `.txt` lists:

```json
"customizations": {
  "stitchu-devc": {
    "disabledHooks": ["post-start.d/50-my-tool.sh"]
  }
}
```

Prefer the `.txt`. `devcontainer.json` is JSONC — JSON with comments and
trailing commas — and every consumer needs a parser for that; the shell's
first attempt cut `//` inside strings, so one URL in the file silently emptied
the whole list. The `.txt` has one format, four rules, and no such trapdoor.

## Not an extension seam

`/opt/devcontainer/base/knowledge/` ships seven files that **nothing reads at
runtime**. Do not build on it, and do not expect it to become layered: it is
deliberately unlayered, because resolving three layers of it would produce a
view no consumer reads. It is reference material for whoever opens the files —
a human or an agent, which can already see all three trees. `zshrc` and
`skills/` do have consumers, and both are layered.

## Checking your work

The image's own suite covers this contract. From a checkout of this repo, with
Docker running and your image built:

```
IMG=my-extending-image:tag bash test/extend.test.sh
```

It builds a throwaway image on top of `$IMG` and asserts the resolution order,
the retargeting, the `@required` guard and the firewall layering.
