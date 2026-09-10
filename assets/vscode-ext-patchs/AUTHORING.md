# Writing a patcher

A patcher is a script that rewrites files of an extension you have installed.
This image ships the toolkit that runs one — `run-all.sh`, `_common.py` — and
no patcher at all: the Claude Code extension is installed exactly as published
and nothing here modifies it.

This page is the contract a patcher has to honour to be picked up by that
toolkit. It says what a `@patch-*` header means, how a selection resolves, and
where the patchers may live. It does not tell you what to patch or how to find
a place to patch it — that is the business of whoever writes one.

Two ways to bring your own:

- **Build on top.** An image built `FROM` this one can drop a script into the
  patch directory and run it at build time — see "From an extending image".
- **At runtime, on your own copy.** Point `PATCH_DIR` at a directory of
  patchers and run `restore-ext-patches`, or let the `45-ext-patches.sh` hook
  assemble one for you from `EXT_PATCHES_DIR` / `EXT_PATCHES_REPO`. Nothing is
  baked into the published image.

## The header

Every patcher opens with a machine-readable block, right after the shebang and
before the docstring:

    #!/usr/bin/env python3
    # @patch-category: ux
    # @patch-files: webview/index.js
    # @patch-sentinel: /*mypatch-v1*/
    # @patch-summary: One sentence, in the present tense, about what the user
    #   gets — not about how it is implemented.
    """
    The long explanation lives here, as before.
    """

This block is the registry. `run-all.sh` reads it to resolve a selection, the
build reads it to know which files to keep a pristine copy of, and the test
suite reads it to check that what you declared is what you wrote. A patcher
without a category is refused and stops the build.

| Field | Repeatable | Meaning |
|---|---|---|
| `@patch-category` | no | `ux`, `fix` or `notify`. Nothing else is accepted. |
| `@patch-files` | yes | Every file you rewrite, relative to the extension root. |
| `@patch-sentinel` | yes | Every marker you write into the bundle. |
| `@patch-critical` | no | `true` only if the extension does not work without you. |
| `@patch-summary` | continuation lines start with `#   ` | One sentence for the overview. |

Pick the category honestly, because it is what people select on. `fix` is for a
defect in a named upstream version — say which one in the docstring. `ux` is
for everything that is a preference, including a preference you feel strongly
about. `notify` is for anything that only makes sense as part of the
notification channel; if your patch writes into the workspace or starts a
timer, it almost certainly belongs there, and it must say so under "Cost and
side effects" in `PATCHES.md`.

`@patch-files` has to match the `check_files()` call in your script — the test
suite compares them, because a file you rewrite but never declared is a file
the build will not keep a pristine copy of, and therefore one
`restore-ext-patches` cannot bring back.

## Where the patchers live

`run-all.sh` scans exactly one directory for `*.py`, and `PATCH_DIR` says which:

| `PATCH_DIR` | Directory scanned |
|---|---|
| unset | the toolkit's own directory, `/usr/local/bin/vscode-ext-patchs/` |
| set | that directory, wherever it is |

`_common.py` stays with the toolkit either way — the orchestrator puts the
toolkit directory on `PYTHONPATH`, so `from _common import ...` resolves even
when your patchers live somewhere else entirely. Write the plain import and do
not add a `sys.path` hack.

A directory with no `.py` in it is not an error: the toolkit says so and exits
0. That is the published image's normal state.

## The sentinel

Write a marker into the bundle and check for it before doing anything. This is
what makes a patcher safe to run twice — and it will be run twice, because
`restore-ext-patches` replays the whole selection.

    MARKER = "/*mypatch-v1*/"

    if MARKER in content:
        print(f"{GREEN}[mypatch]{RESET} already patched")
        return 0

Rules that have earned their place:

- **Version the marker** (`-v1`, `-v2`). When you change what you inject, bump
  it and strip the old one, otherwise an image rebuilt over a cached layer
  carries both.
- **Make it a comment** in the language of the file it lands in, so it is inert.
- **Declare every marker** in `@patch-sentinel`. `restore-ext-patches --list`
  and the test suite use them to tell what is actually live in a bundle, which
  is the only honest answer to "is this patch applied?".
- **Except a marker you write on only one branch.** `--list` calls a patch live
  when *every* declared sentinel is present, so a version-conditional marker
  would report the patcher dead on the other path. Declare the marker your
  patcher always writes, and document the conditional ones wherever you keep
  your catalogue.
- **Put the delimiters in the constant** (`MARKER = "/*mypatch-v1*/"`, not
  `"mypatch-v1"` composed into `/*{MARKER}*/` at the injection site). The
  a registry suite greps your source for the declared literal; composing it
  means the literal is nowhere in the file and the check reports a drift that
  is not one.
- If you inject a region rather than a token, bracket it (`/*mypatch-open*/` …
  `/*mypatch-end*/`) and strip the whole region before re-applying.
  Re-applying over a partially-matched previous injection is the failure mode
  that produces an unloadable bundle.

## Failing well

Your patcher runs during someone's image build. It must never take the build
down with it, and it must never leave a half-written bundle.

    import os, sys
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from _common import GREEN, RESET, banner, resolve_ext_dir, check_files

    def main():
        ext_dir = resolve_ext_dir(sys.argv)
        check_files(ext_dir, ["webview/index.js"])
        path = ext_dir / "webview/index.js"
        content = path.read_text()

        if MARKER in content:
            print(f"{GREEN}[mypatch]{RESET} already patched")
            return 0

        new, n = PATTERN.subn(replacement, content, count=1)
        if n == 0:
            banner(
                "MYPATCH ANCHOR NOT FOUND",
                "the createWebviewPanel call shape changed",
                ["Feature lost: find widget in the plan preview.",
                 "Re-derive the anchor in mypatch.py."],
            )
            return 1

        path.write_text(new)
        print(f"{GREEN}[mypatch]{RESET} applied")
        return 0

    sys.exit(main())

What matters in that shape:

- **Compute first, write once.** Build the whole new content in memory and
  write at the end. Never write inside a loop over several edits — a later
  failure would leave the file in a state no sentinel describes.
- **Return 1 on a missed anchor, and say what was lost.** `run-all.sh` reports
  the failure and still exits 0, so the build stays green with one feature
  missing rather than dying. The banner is how the next person finds out; a
  silent no-op is the one outcome to avoid.
- **Reuse `_common`.** `resolve_ext_dir` handles being called with or without
  an explicit directory, `check_files` produces the standard red banner when
  the bundle no longer has the file you expected, and `banner` is what makes
  your failure look like every other failure in the log.
- **Never `sys.exit(2)`.** That code means "the selection named something that
  does not exist" and it is the one thing that stops a build.

A JSON file is the exception to text rewriting: parse it, edit the structure,
and dump it back with `json.dumps(p, indent=2)`.

## Checking your work

    docker build -t probe .
    docker run --rm probe restore-ext-patches --list

Your patch should show `yes`. Then prove the selection sees it:

    docker run --rm probe restore-ext-patches none
    docker run --rm probe restore-ext-patches mypatch

and run the suite, which exercises the toolkit contract your header depends on:

    bash test/toolkit.test.sh

## From an extending image

`/etc/claude-build-env` is written at image build and carries what you need:

| Variable | Meaning |
|---|---|
| `VP` | `linux-x64` or `linux-arm64` |
| `EXT_DIR` | where the Claude Code extension is extracted |
| `BIN` | the extension's embedded native CLI |
| `REL` | the `relativeLocation` used in `extensions.json` |

Source it rather than recomputing the architecture:

    FROM ghcr.io/meitogi/devcontainer-sandbox:${BASE_VERSION}-cc${CLAUDE_CODE_VERSION}
    COPY my-patch.py /usr/local/bin/vscode-ext-patchs/
    RUN . /etc/claude-build-env \
     && PYTHONDONTWRITEBYTECODE=1 python3 /usr/local/bin/vscode-ext-patchs/my-patch.py "$EXT_DIR" \
     && chown node:node "$EXT_DIR/extension.js"

Dropping it into `/usr/local/bin/vscode-ext-patchs/` rather than running it
from `/tmp` is what makes it a first-class patch: it then carries a category,
`restore-ext-patches` replays it along with the others, and `--list` reports
whether it is live. The cost is that it must have a valid header — a script
without `@patch-category` in that directory stops the build on purpose.

One limit worth knowing: the pristine copies are taken by the base image's
build, before your layer exists. If your patch rewrites a file none of the
shipped patchers touch, that file has no pristine copy and
`restore-ext-patches` cannot revert it. Rewriting `extension.js`,
`webview/index.js` or `package.json` — which is almost certainly what you are
doing — is fully covered.
