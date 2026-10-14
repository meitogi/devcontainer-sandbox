# Releasing

Maintainer documentation. If you only consume the image, you want
[README.md](README.md) instead — nothing here is needed to use a published tag.

## The gate that authorises a release

**Do not wire this to `exit 0`.** `wtf image release-check` exits 0 only on
`GREEN`, which is unreachable on a dogfood Mac **by policy, not by code**: it
would require typing the purge of the shared `vscode` volume, wiping the VS Code
server cache of every devcontainer on that machine. A publish gated on `exit 0`
would therefore never fire.

The sanctioned green — the standing control of the whole gate — is the trailer
of `wtf image release-check --no-purge`:

```
## RELEASE-CHECK tier=GREEN_PARTIEL exit=2 green=7 partial=2 red=0
```

All three conditions must hold, not just the first:

1. `tier=GREEN_PARTIEL` and `red=0`;
2. the ledger has **9 rows** — a different count means a duplicate caused by
   editing the script mid-run;
3. the two `partial` are the deliberate `⊘` of `--no-purge`, on **step 5**
   (purge) and **step 9** (R2), and no other step. A `⊘` anywhere else means a
   step was skipped for an unrelated reason, and that does not authorise a
   release.

`exit 2` is the success path here: a successful agent-side half also exits 2,
never 0, so that nobody can paste "exit 0" out of a container as proof of a
release gate. See [TESTING.md](TESTING.md) for the assertion catalogue.

## Steps

1. Run the gate on the Mac and check the three conditions above.
2. Bump `version` in `package.json` (every content change that ships = a bump;
   a commit that does not change the image — docs, CI, the CC matrix — does
   not). Read [NEXT-UPDATE.md](NEXT-UPDATE.md) first: it lists changes
   committed but never published, and carries the `git log` that derives that
   list rather than trusting it. A change left there reaches no container.
   Empty it as part of the release.
3. Adjust `cc-versions.json` if the CC matrix changes. Every version listed
   must exist upstream (`npm view @anthropic-ai/claude-code versions`) — a
   phantom entry fails one branch of the matrix silently until the run.
4. Write the release notes to a file (shape below, [Release
   notes](#release-notes)), then tag `v<version>` with that file and push:

   ```
   git tag -a v<version> --cleanup=verbatim -F <notes-file>
   git push origin v<version>
   ```

   CI builds `linux/amd64` + `linux/arm64` per CC version, pushes every
   `<version>-cc<cc>` tag, and once all of them are on GHCR creates the GitHub
   Release from the tag's annotation. The
   [publish workflow](.github/workflows/publish.yml) can also be triggered by
   hand (`workflow_dispatch`); that replays a build and creates no release.

The workflow's `setup` job **fails on purpose** if the pushed tag is not
`v<package.json version>`, and if the tag is lightweight or its annotation
lacks either heading. Bumping the manifest, writing the notes and tagging are
one gesture, not three.

The git tag's name never reaches an image tag — it exists only for that
consistency check. The `<base>` half of every image tag comes from
`package.json`, the `cc<version>` half from each entry of `cc-versions.json`.
So the set of tags a release produces is a pure function of two files, and to
publish a different set you edit those, not the workflow.

`workflow_dispatch` skips the tag checks and the `release` job (`if:
github.ref_type == 'tag'` is false). Useful for replaying a failed build; not a
way to cut a release.

Images carry `LABEL org.stitchu.base.version` and
`LABEL org.stitchu.claude-code.version` for introspection (`devc doctor`).
A label is readable from OUTSIDE only, so the same version is also baked as
`/etc/devcontainer-base-version` — that is the one the boot panel prints, and
the one a support request will quote back at you.

## Release notes

The notes of a release live in **one place: the annotated tag**. The `release`
job of the publish workflow turns them into a GitHub Release (`gh release
create --notes-from-tag`), the Sandbox VS Code extension reads that release,
and `git tag -n` / `git log --decorate` keep working. No `CHANGELOG.md`, no
`releases/<tag>.md`. This repository is public: everything is in English.

The shape is fixed — three parts, in this order:

1. **One subject line**: `v<version> — <headline>`. It becomes the release
   title (the workflow passes `%(contents:subject)` to `--title`) and the
   one-liner `git tag -n1` prints. The body GitHub shows starts with it too:
   `--notes-from-tag` publishes the whole annotation.
2. **`## What's new`** — what someone using the container sees or can do that
   they could not before. Relaxed tone, short bullets, no file names. **Never
   empty**: a release with nothing user-visible writes the one fixed line
   "Nothing user-visible — maintenance."
3. **`## Technical`** — what moved and why, the image tags cut (`Cuts
   <version>-cc…`), the paths, the measurements, the derogations. The bodies
   of the tags cut before this format are this section already.

Both headings are exact — `## What's new` and `## Technical`, alone on their
line. The workflow's `setup` job refuses a tag that is lightweight, lacks either
heading, or has nothing under the first one, before anything is built.

Write the notes to a file, then tag with **`--cleanup=verbatim`**:

```
git tag -a v1.11.0 --cleanup=verbatim -F notes-1.11.0.md
git push origin v1.11.0
```

`--cleanup=verbatim` is not optional. git's default cleanup (`strip`) treats
every line starting with `#` as a comment and drops it silently, so a plain
`git tag -a -F` keeps the bullets, loses both headings, and fails the gate. `-F`
rather than `-m` or an editor for the same reason: the bodies are long and an
editor session applies its own cleanup.

From a graphical client (Fork, or any GUI that runs `git tag -a -m`), the same
cleanup applies and there is no `--cleanup` switch to reach. Set, once per
clone, `git config core.commentChar ';'` — git then no longer treats `#` lines
as comments and the headings survive a `-m` tag. The only other effect is the
comment character in commit-message templates. Paste the notes file as the tag
message, push the tag, and CI does the rest.

A full example — the file as written, for a fictional release:

```
v1.11.0 — the boot panel names the patcher line it runs

## What's new

- The start-up panel now says which patcher version is applied, and whether
  a newer one is waiting. No more `ext-patches-sync --status` to find out.
- Nothing to do on your side: it ships with the image.

## Technical

Cuts 1.11.0-cc2.1.280, 1.11.0-cc2.1.272 and 1.11.0-cc2.1.220.

boot-summary reads `.devcontainer/tmp/cache/ext-patchs/.work/` and prints the
applied ref next to the Claude Code version; `ext-patches-update --check` is
run only when the cache is older than a day, so the panel adds no network
call on a nominal restart. test/toolkit.test.sh covers the three states
(applied, update available, cache absent).
```

The patcher repository (`claude-ext-patchs`, private, internal) follows the
same three-part shape in French: subject `Patchers validés sur Claude Code
<ver> — <headline>`, then `## Quoi de neuf` and `## Technique`, one tag per
tested line, no CI — its `UPGRADING.md` § 8 has the procedure, run from a host.
The extension reads both heading sets.

## The suites

`test/manifest.test.sh` asserts the tree invariants — the directory layout *is*
the COPY manifest, so a stray file fails a test instead of shipping. It also
sweeps `bash -n` over every shipped script, checks every `COPY` source exists,
and dry-runs the hook dispatcher against the image layout.

`test/run-all.sh` is the full pass, and it takes **two runs**: one inside the
devcontainer (manifest, firewall, overlay layer 1) and one on a host with Docker
(overlay layer 2, the image suites, both port-gate suites). The runner detects
which side it is on and names what is left.

The two that need no repo at all are documented in the README, because they are
for consumers as much as for maintainers: `escalation.sh` and `privilege.sh`
read only the installed image and replay against any published tag.
