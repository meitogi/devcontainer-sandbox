# CLAUDE.md — devcontainer-sandbox

The base image behind the Sandbox devcontainers, plus the toolkit it ships
(`bin/`, `assets/`). Public repository: everything committed here, tags and
release notes included, is written in English.

Where to read first: [README.md](README.md) (consumers), [EXTENDING.md](EXTENDING.md)
(stacks on top of the image), [TESTING.md](TESTING.md) (the suites),
[NEXT-UPDATE.md](NEXT-UPDATE.md) (committed but not yet shipped),
[RELEASING.md](RELEASING.md) (cutting a release).

## Cutting a release — the tag IS the release notes

Every `v<version>` tag is an **annotated** tag whose message is the release
notes, in the three-part shape fixed in [RELEASING.md, « Release notes »](RELEASING.md#release-notes):

1. subject line `v<version> — <headline>`;
2. `## What's new` — never empty ("Nothing user-visible — maintenance." if so);
3. `## Technical`.

Write the notes to a file, then:

```
git tag -a v<version> --cleanup=verbatim -F <notes-file>
```

`--cleanup=verbatim` is mandatory: git's default cleanup drops every line
starting with `#`, headings included, and the tag looks right at a glance.
From a GUI client (Fork) there is no such switch — set once per clone
`git config core.commentChar ';'` and paste the file as the tag message.

Pushing the tag is the whole gesture. CI (`.github/workflows/publish.yml`)
refuses a lightweight tag, a missing heading or an empty first section before
building anything, builds the images, then creates the GitHub Release from the
annotation. Never create the Release by hand, never `workflow_dispatch` to
release (it replays a build and releases nothing), never re-cut a pushed `v*`
tag (the push re-runs the build).

A commit that does not change the image (docs, `.github/`, `test/`) needs no
tag and no version bump — [RELEASING.md](RELEASING.md) step 2.
