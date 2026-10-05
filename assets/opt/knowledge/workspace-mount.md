# The workspace bind mount — two things it silently breaks

`/workspace` is a Docker bind mount onto the host filesystem. On macOS (and on
Windows via its own sharing layer) that mount does **not** implement the whole
POSIX surface a local filesystem does, and two of the gaps fail *silently* —
the call succeeds, returns the value you wanted, and means nothing.

Both were measured in a project using this image, not inferred.

## `flock` is a no-op under `/workspace`

A lock file placed on the bind mount grants the exclusive lock to **everyone**.
`flock` returns success for every caller simultaneously, so a mutual-exclusion
scheme built on it provides no mutual exclusion at all — and it looks correct
in every test that only checks the return value.

```sh
# Both of these acquire "exclusively", at the same time, with no error.
flock -x /workspace/.lock -c 'sleep 5' &
flock -x /workspace/.lock -c 'echo got it too'
```

**What to do instead.** Put the lock file somewhere that is a real filesystem
inside the container — anything outside `/workspace`: `/tmp`, `/run`, or the
project's own cache directory if it lives on a volume rather than the bind
mount. A lock is only meaningful where the kernel owns the inode.

**How to tell you have this bug**: a concurrency guard that never fires, a
"should be impossible" double-run of a hook or a daemon, or two processes both
logging that they took the lock. Test it with the two-liner above before
blaming the logic.

## A linked git worktree is invisible-broken from the host

`git worktree add` writes an **absolute** `gitdir:` path into the worktree's
`.git` file, and that path is the container's — `/workspace/…`, which does not
exist on macOS. The worktree therefore works perfectly from inside the
container and is broken for every host-side git client: Finder integrations,
the host `git`, an IDE opened on that folder from the Mac, a GUI client.

Nothing warns you. The folder looks like a checkout, and the host tool reports
a corrupt or missing repository.

**What to do instead.** Either keep linked worktrees strictly
container-internal (and never open one from the host), or create them from the
host so the recorded `gitdir:` is a host path — in which case the container is
the side that cannot read them. The two are mutually exclusive as long as the
paths differ on the two sides.

**How to tell you have this bug**: the worktree is fine in the container's
terminal, and the host says `not a git repository` or shows no history for the
same folder. Read the `.git` file — it is one line, and it names which side
owns it.

## Why these live here and not in a project

Neither is about any one project: they are properties of how this image is
mounted. A project that hits either will spend an afternoon on it, because both
failures present as a logic bug in the project's own code.
