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
   not).
3. Adjust `cc-versions.json` if the CC matrix changes. Every version listed
   must exist upstream (`npm view @anthropic-ai/claude-code versions`) — a
   phantom entry fails one branch of the matrix silently until the run.
4. Tag `v<version>` and push, or trigger the
   [publish workflow](.github/workflows/publish.yml) manually
   (`workflow_dispatch`). CI builds `linux/amd64` + `linux/arm64` per CC
   version and pushes every `<version>-cc<cc>` tag.

The workflow's `setup` job **fails on purpose** if the pushed tag is not
`v<package.json version>`. Bumping the manifest and tagging are one gesture,
not two.

The git tag's name never reaches an image tag — it exists only for that
consistency check. The `<base>` half of every image tag comes from
`package.json`, the `cc<version>` half from each entry of `cc-versions.json`.
So the set of tags a release produces is a pure function of two files, and to
publish a different set you edit those, not the workflow.

`workflow_dispatch` skips the tag check (`if: github.ref_type == 'tag'` is
false). Useful for replaying a failed build; not a way to cut a release.

Images carry `LABEL org.stitchu.base.version` and
`LABEL org.stitchu.claude-code.version` for introspection (`devc doctor`).

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
