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
- [Token propagation between containers](#token-propagation-between-containers)
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
   Steps 4 and 5 run under `sync-creds`' lock, so no sync (creds-watch, a
   `Stop` hook) can pair the new slot with the old account's token. A lock
   still busy after 10 s makes `use` stop with nothing switched.
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

## Token propagation between containers

The refresh token **rotates**: when container B refreshes, the refresh token
A holds is dead, and A's next refresh fails with `authentication_failed`. A
running Claude Code re-reads `~/.claude/.credentials.json` before a request
and again on a 401 (measured on 2.1.280, see the rollout log). So A recovers
by itself as soon as B's token is in A's file. Getting it there is the job of
these pieces:

- **`creds-watch`** (`/usr/local/bin`), a daemon started detached by
  `post-start.d/56-creds-watch.sh`, one per container (flock on
  `/tmp/creds-watch.pid`). It runs `inotifywait -m` on the **directories**
  `~/.claude/` and the active slot (a tmp + mv write replaces the inode a
  file watch is on). Any change to either `.credentials.json` runs
  `sync-creds`, which decides the direction. Its own copy then resolves to
  "same", so nothing loops. Latency is under a second.
  - It follows `claude-account use`: a change to `.active-account` re-resolves
    the slot and restarts the watch.
  - Every 60 s, a `stat` poll is the safety net and also re-resolves. That is
    how a slot dir created by the first `/login` gets watched.
  - Without `inotifywait`, or with `CREDS_WATCH_POLL=1`, it polls every 5 s.
  - It logs one line per action to `/tmp/creds-watch.log`.
  - It is not started when `CREDS_WATCH=0`, when `~/.claude-creds` is absent,
    or in local Ollama mode.
- **`sync-creds`** runs under `flock` on `~/.claude-creds/.sync-creds.lock`.
  The lock is on the volume, not in `/tmp`, so it serialises every container,
  not just this one. A lock under `/workspace` would be a no-op (see
  `workspace-mount.md`). The lock is also taken before the slot is resolved,
  which is what makes `use` atomic for it. `sync-creds` copies through a tmp
  file in the target's directory and then renames it, so the CLI never reads
  half-written JSON.
- **A `StopFailure` hook** with matcher `authentication_failed` runs
  `sync-creds` the moment a turn fails on auth. It is merged by
  `post-start.d/85`, next to `Stop` / `SessionEnd`. Claude Code ignores
  StopFailure's output and exit code, so this hook only syncs. It cannot
  retry the turn.

A 1.9.x container on the same volume has none of this. It still gets the
token at its own `Stop`, at terminal open and at boot.

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
- **A process holding a token in memory beyond the file**, such as a
  long-lived tool that is not the Claude CLI, does not benefit from
  creds-watch. Only the file is kept fresh.
