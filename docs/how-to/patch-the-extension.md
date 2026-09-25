# Patch the Claude Code extension

**Goal.** Change something in the Claude Code VS Code extension itself —
behaviour the published extension does not offer.

This page starts with when not to, because that is the answer most of the time.

*Every command in a code block on this page runs in a terminal **inside the
container**, unless the step says otherwise.*

---

## When not to do this

The image installs the Claude Code extension **exactly as published** and ships
no patcher. That is deliberate, and most projects should leave it that way.

Reasons to stop here:

- **It breaks on every extension update.** A patcher edits a bundled file. The
  next version of the extension ships a different file, and your patch either
  fails to apply or applies to something that has moved. Patchers are cut per
  Claude Code version, and a version with no set of its own is **refused**
  rather than served another version's.
- **It is a second supply chain.** Patchers are Python scripts from a separate
  repository, running against your editor at container start. That is a real
  trust decision, not a configuration flag.
- **Most of what people want is configuration.** Before reaching for a patcher,
  check that the behaviour is not already a setting, a hook, or a
  [skill](add-a-skill.md).

What the image does ship is the *toolkit* that can run a patcher, so that
someone who genuinely needs one can, on their own installation, without
anybody forking the image.

---

## Steps

### 1. Point your project at a patcher repository

In `.devcontainer/.env`, which ships with the repository name filled in and the
token left as a placeholder:

```
EXT_PATCHES_REPO=owner/name
EXT_PATCHES_TOKEN=<change-me>
```

Replace `<change-me>` with a GitHub fine-grained personal access token —
read-only, `Contents: read`, scoped to that one repository. The literal string
`<change-me>` is recognised as "not configured": leave it and the startup step
applies nothing and says so on the boot panel, rather than failing obscurely.

**That token is a live credential, and `.devcontainer/.env` is gitignored by the
scaffolded project for exactly this reason.** Check that the ignore rule is
still there before you paste anything into it, and never move the value into a
file that is committed.

If the patchers are already on disk — a bind mount, a shared volume — set
`EXT_PATCHES_DIR` to that directory instead. No token, no network, nothing
secret in `.env` at all.

### 2. Choose a set, or let it resolve

Leaving `EXT_PATCHES_REF` unset is the normal case. The container resolves the
newest set cut for the Claude Code version *it* is running — a tag shaped
`cc<version>-r<n>` — from its cache first, then from the repository's tags.
Never `HEAD`.

**A boot never moves to a newer set on its own.** Moving is a deliberate act,
run inside the container:

```
ext-patches-update
```

Pin `EXT_PATCHES_REF` to a tag or a commit SHA only when you want to freeze a
set.

### 3. Rebuild

In VS Code's Command Palette: **Dev Containers: Rebuild Container**.

It is a rebuild rather than a restart for a reason worth generalising: these
values live in `.env`, and `.env` is read when the container is **created**. A
restart reuses the container you already have, environment included. The rule
across the whole system is the same one — anything compiled into the image or
read at creation costs a rebuild; anything read while the container runs does
not.

---

## How to check it worked

```
boot-summary
```

The `Patchers` line names the set that was resolved and the state of its
sentinels:

```
║  Patchers    cc2.1.280-r2 · sentinels all live                         ║
```

`sentinels all live` means the extension still carries every modification. That
is the only claim worth trusting — the patch applying once does not mean it is
still there after an extension update replaced the file. See
[sentinel](../concepts.md#sentinel).

Two warnings you may get instead, both explained in
[Boot warnings](../boot-warnings.md):

- `an apply would change it — it is running unpatched` — the extension was
  replaced under you, and nothing reapplied.
- `nothing cached for this line — no patcher applied` — no set exists for this
  Claude Code version, so none was invented.

---

## Writing your own patchers

That is a separate repository with its own documentation — authoring a patcher,
the sentinel contract, and what happens when upstream moves. Start from
[claude-ext-patchs](https://github.com/meitogi/claude-ext-patchs).

To ship patchers from an **image** that extends this one, rather than from a
project's `.env`:
[EXTENDING.md § VS Code extension patches](https://github.com/meitogi/devcontainer-sandbox/blob/master/EXTENDING.md#vs-code-extension-patches).
