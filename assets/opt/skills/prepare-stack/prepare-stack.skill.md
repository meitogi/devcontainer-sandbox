---
description: |
  Wire a project onto the devcontainer-sandbox base image : an extending
  Dockerfile whose firewall bake stage is mandatory, an allowlist DISCOVERED
  from firewall-blocks rather than guessed, lifecycle fragments that reuse
  devc-hook instead of reinventing it, and lint/test declared so the commit
  gate returns a measured verdict. Refuses to infer the stack from a manifest
  — it asks. Acceptance is zero firewall-blocks entries plus escalation.sh
  still passing on the extended image.

  Auto-trigger : "set up a devcontainer for this project", "adapte le
  devcontainer à ma stack", "add PHP/Python/Go/Rust to the container",
  "prépare un Dockerfile pour ce projet", "my install fails behind the
  firewall", "wire lint and test for the gate".
argument-hint: "[stack, e.g. \"php 8.3 + symfony\" — omit and I will ask]"
---

# prepare-stack — a dedicated devcontainer for THIS project's stack

Turn a bare project into one that boots on `ghcr.io/meitogi/devcontainer-sandbox`
with its own toolchain, its own firewall allowlist, and a commit gate Claude can
actually read. Four artefacts, in this order — each one depends on the previous
being right.

---

## Read before writing anything

- `/opt/devcontainer/base/knowledge/extension-points.md` — where each kind of
  addition goes, and the three layers that merge.
- `/opt/devcontainer/base/knowledge/firewall.md` — what the firewall does and
  the three allowlist layers.
- The image's own `EXTENDING.md` and `stacks/*.md` if the repo is checked out —
  `stacks/php.md`, `stacks/android.md` are worked examples of exactly this task.

---

## 0 — Establish the stack, do not infer it

**Ask before assuming.** A `package.json` at the root does not mean the project
is Node — it may be the front-end of a PHP app. Read the manifests that exist,
then state what you found and ask the user to confirm:

- language + version (`.nvmrc`, `.python-version`, `go.mod`, `rust-toolchain.toml`,
  `composer.json` `require.php`, `.tool-versions`)
- package manager, and whether a lockfile is committed
- how it is built, linted, tested, and formatted — **their commands, verbatim**
- services it needs (database, cache, queue) — those are compose services, not
  Dockerfile lines
- anything that must reach the network at build or at runtime

If the answer to any of these is "I don't know", say so in the summary rather
than picking a default. A devcontainer built on a guess is worse than none: it
looks configured.

---

## 1 — The project Dockerfile

Two stages, and **the first is not optional**. The base image ships firewall
*infrastructure* only; the allowlist lives in the project and must be baked by
the project layer. Skipping the bake means `init-firewall.sh` fails at onCreate
and every container start explodes while the image itself looks healthy.

```dockerfile
ARG BASE_VERSION=<the tag you pin>
ARG CLAUDE_CODE_VERSION=<a version listed in the image's cc-versions.json>

# --- Stage 1 : firewall bake (throwaway) --------------------------------
FROM ghcr.io/meitogi/devcontainer-sandbox:${BASE_VERSION}-cc${CLAUDE_CODE_VERSION} AS fw-bake
ARG FIREWALL_ALLOW_LOCAL_AT_REBUILD=0
USER root
COPY firewall/ /tmp/fw-src/
RUN FIREWALL_ALLOW_LOCAL_AT_REBUILD="${FIREWALL_ALLOW_LOCAL_AT_REBUILD}" \
    /usr/local/bin/firewall-docker-setup.sh --src /tmp/fw-src --dest /out

# --- Stage 2 : the image the project actually runs -----------------------
FROM ghcr.io/meitogi/devcontainer-sandbox:${BASE_VERSION}-cc${CLAUDE_CODE_VERSION}
USER root
COPY --from=fw-bake /out/ /etc/devcontainer-firewall/
RUN test -s /etc/devcontainer-firewall/baked-at \
 && test -s /etc/devcontainer-firewall/effective/sources.sha256

# --- The stack itself ----------------------------------------------------
# apt in ONE layer, clean in the same RUN, drop docs and man pages.
RUN apt-get update && apt-get install -y --no-install-recommends \
      <packages> \
 && apt-get clean && rm -rf /var/lib/apt/lists/* \
 && rm -rf /usr/share/doc/* /usr/share/man/*

USER node
```

**Why the bake is a separate stage** : `firewall/` carries `domains.local.txt`
and `policy.local.d/`, both gitignored and writable by anything in the container
— an npm postinstall included. A `RUN rm` after a `COPY` does not help: the file
still sits in the COPY layer, so `docker save` and any registry push still ship
it. A throwaway stage leaves nothing behind.

Rules for the stack layer:

- **Pin versions.** An unpinned `apt-get install` or a `curl | sh` from a moving
  branch makes the image non-reproducible, and a release gate that cannot
  reproduce its own build cannot tell your regression from upstream drift.
- **`USER node` last.** Anything after it runs unprivileged, which is where the
  project's own tooling belongs.
- **Do not `chown -R` a large tree.** Overlayfs copies the whole thing up into
  your layer. Target the files that actually need it.
- **Do not add a SUID binary or a file capability.** `escalation.sh` freezes both
  inventories and will fail — deliberately.

---

## 2 — The firewall allowlist, measured not guessed

This is the step people get wrong, and the failure is silent: an incomplete
allowlist looks like a flaky network.

**Never guess a host from a vendor's `.com`.** Registries, CDNs and binary hosts
almost never live there. The procedure:

1. Build and start the container with the stack layer but a minimal allowlist.
2. Run the project's real install (`npm ci`, `composer install`, `pip install
   -r`, `cargo fetch`, `go mod download`).
3. Run **`firewall-blocks`**. Its output is the authoritative list of what was
   denied — that is the answer, and it is the only answer that is not a guess.
4. Add those hosts to `firewall/domains.d/<ecosystem>.txt`, one per line, same
   syntax as `domains.txt`. **Committed**, so colleagues get it too.
5. `Dev Containers: Rebuild Container` — the allowlist is baked, not read at
   runtime.
6. Re-run the install. **Zero blocks is the acceptance criterion.** Repeat from
   step 3 if not; transitive dependencies surface in waves.

Which file:

| Need | File | Committed |
|---|---|---|
| the project's dependencies | `firewall/domains.d/<eco>.txt` | yes |
| one dev, one session, read-only docs | `firewall/domains.local.txt` | no, gitignored |
| a non-HTTP TCP service (a host port, a sibling container) | `firewall/ports.txt`, `host:<port>` or `<container>:<port>` per line | yes |

`ports.txt` is a **direct ACCEPT that bypasses the audit path**. One line per
port, never a range, and only for something that genuinely is not HTTP.

Tell the user plainly what each added host is for. An allowlist nobody can
justify is an allowlist nobody will dare prune.

---

## 3 — Lifecycle, without reinventing it

The base image ships `devc-hook`, which merges three layers of fragments. The
project's go in `.devcontainer/hooks/<phase>.d/`, numbered:

```json
"onCreateCommand":   "devc-hook on-create",
"postCreateCommand": "devc-hook post-create",
"postStartCommand":  "devc-hook post-start"
```

- `post-create.d/` — **once** per container: install dependencies, run
  migrations, seed a database.
- `post-start.d/` — **every** start, so it must be idempotent. Guard every
  append with `grep -q` first; a restart that duplicates a line is the classic
  bug here.
- Same filename as a baked fragment **masks** it; a new name **adds**.
  `hooks/disabled.txt` switches a baked one off.

Check what you are inheriting before adding anything:

```
devc-hook post-start --dry-run
```

---

## 4 — Wire the commit gate

`gate.mjs` reads lint and test results; it cannot lint or test anything itself.
Wiring it is what makes "is this ready to commit?" answerable without a human
re-reading raw output — and an unwired gate reports PARTIAL rather than
pretending.

Declare the project's real commands in `.wtfcmd.yaml`:

```yaml
- group: dev
  name: lint
  desc: Lint, machine-readable.
  cmd: <the project's linter with its JSON reporter>

- group: dev
  name: test
  desc: Test suite, machine-readable.
  cmd: <the project's runner with its JSON reporter>
```

For a **full-strength** verdict each must print JSON on stdout:

```
lint  { "totals": { "errors": N, "warnings": N, "infos": N } }
test  { "totals": { "pass": N, "fail": N, "skip": N } }
```

Most tools are one flag away — `biome check --reporter=json`, `eslint -f json`,
`vitest --reporter=json`, `jest --json`, `ruff check --output-format=json`,
`golangci-lint run --out-format json`. Where the native shape differs, a small
`scripts/lint-json.mjs` adapter is the documented alternative.

**Exit codes are not enough, and that is the whole point** — biome and eslint
both exit 0 with warnings. If you cannot produce JSON, say so: `gate.mjs` will
report `exit-code only, blind to warnings`, which is honest. A stub that emits
`{"totals":{"errors":0}}` without running anything is the one outcome to refuse
— it reports green having measured nothing.

---

## 5 — Prove it, then hand over

Do not report success on "it built". Run, and quote the output:

1. `docker build` succeeds.
2. The container boots and the firewall comes up — no error in
   `.devcontainer/tmp/logs/post-start-<ts>.log`.
3. The project's install runs with **zero** `firewall-blocks` entries.
4. Build / lint / test each run, with their real counts.
5. `escalation.sh` and `privilege.sh` still pass on the extended image:
   ```
   docker run --rm -u node <your-image> bash /etc/devcontainer-firewall/tests/escalation.sh
   ```
   `escalation.sh` must stay at 18/18. If your layer broke it, you added a SUID
   binary, a capability, or a root-writable path — find which, do not relax the
   assertion.

Then summarise: the stack you configured, every host you added and why, what you
pinned, and **what you could not verify**. That last list is the useful half.
