# CLAUDE-ACCOUNTS — Switch a container between Claude subscriptions

> `claude-account` switches **this container** to another Claude
> subscription without a rebuild. Every account lives on the one shared
> credentials volume. Its root stays account `default`, byte for byte, so a
> container still on image 1.9.x keeps working beside a container that has
> switched.

## Table of contents

- [Layout](#layout)
- [Commands](#commands)
- [What `use` does](#what-use-does)
- [Who reads the resolver](#who-reads-the-resolver)
- [1.9.x compatibility](#19x-compatibility)
- [Limits](#limits)

## Layout

```
~/.claude-creds/                    shared volume (claude-creds-<shared>)
├── .credentials.json               account "default" (also read/written by 1.9.x)
├── .claude.json                    default's identity + the shared settings
└── accounts/
    └── <name>/
        ├── .credentials.json
        └── account.json            {oauthAccount, userID} lifted from .claude.json
~/.claude/.active-account           per-project volume: the active name; absent = default
```

The active account belongs to **the container**: project A can run on one
subscription and project B on the other. Nothing is migrated. A 1.9.x
container never looks inside `accounts/`.

Names match `^[a-z0-9][a-z0-9_-]*$`. If `.active-account` holds anything
else, the account resolves to `default`. A tampered file therefore cannot
point outside the volume.

## Commands

| Command | Does |
|---|---|
| `claude-account list` | `default` plus every `accounts/*`, the active one marked `*`, with the email when known or `(not signed in)` |
| `claude-account status [--short]` | the active account, its email, and the expiry of the token the CLI uses (`~/.claude/.credentials.json`). `--short` is the one line shell-init prints |
| `claude-account path` | the active account's shared `.credentials.json` |
| `claude-account use <name> [--yes]` | switch (below) |
| `claude-account remove <name> [--yes]` | delete `accounts/<name>`. It refuses `default` and the active account |

The terminal shows the live line under the boot panel, for example
`Claude account : perso (me@example.com) · token valid until 14:32`. The
line is not part of the panel: the panel is cached at boot and would show
the account the container booted on.

## What `use` does

1. **Guard.** If a `claude` process is running, it warns and asks.
   `--yes` skips the question; with no tty and no `--yes`, it refuses. A
   live CLI may refresh after the switch and write the old account's token
   into the new slot. Quit claude first.
2. `sync-creds` flushes the current token to its own slot.
3. The outgoing account's `oauthAccount` + `userID` are saved to its
   `account.json`. This step is skipped for `default`, whose identity lives
   in the root `.claude.json`.
4. `.active-account` is written. For `default`, the file is removed.
5. The target's `.credentials.json` is copied to `~/.claude/` with mode 600.
6. **Only** `oauthAccount` + `userID` are merged into
   `~/.claude/.claude.json`. Projects and settings stay as they are.

If the slot is empty, the local creds and identity are removed and the
command says to run `claude`, then `/login`. The first `Stop` hook
(`sync-creds`) then files the new token into `accounts/<name>/`. In every
case, the new account takes effect after restarting claude or running
**Reload Window**.

Switching back later needs no new login: the slot keeps its token, and every
refresh goes to that slot.

## Who reads the resolver

`claude-account path` is the single resolver. These callers use it:

- **`sync-creds`** (boot, terminal open, `Stop`/`SessionEnd`) defaults
  `SHARED_CRED` to it, falling back to the root when the command is absent.
  An explicit `SHARED_CRED` still wins.
- **`post-start.d/60-claude-json-sync.sh`**: on a non-default account the
  `.claude.json` sync keeps running, but `oauthAccount` and `userID` never
  cross in either direction. The root keeps default's identity and the local
  file keeps the active account's.
- **`shell-init.sh`**: the credentials-conflict prompt writes to the
  resolved slot, and the live account line comes from `status --short`. The
  line is not printed in local Ollama mode.

Tests set `LOCAL_DIR` / `SHARED_DIR` to a tmp HOME. These variables override
`/home/node/.claude` and `/home/node/.claude-creds` in all three callers.

## 1.9.x compatibility

A non-default container never writes the root `.credentials.json`, and only
writes the root `.claude.json` with default's identity preserved. A 1.9.x
container therefore keeps reading and refreshing `default` at the root, as
it always has. `test/claude-account.test.sh` proves this by running
`git show v1.9.4:bin/sync-creds` against the multi-account layout.

## Limits

- **A project-level `.devcontainer/claude/sync-creds.sh`** (v2 layout) wins
  over the baked binary in the boot hook, the terminal and the Claude hooks,
  and it knows nothing about accounts. On such a project, a non-default
  account's token goes to the root. Delete the project copy before using
  `claude-account`.
- **Token propagation between containers** on the same account still happens
  only at `Stop`/`SessionEnd`, terminal open and boot. Live propagation is
  separate work.
