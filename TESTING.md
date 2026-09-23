# Image test catalogue

**676 assertions**, each documented twice: what it protects, in plain
language and with no prerequisites — then the mechanism, for whoever touches
the code.

Plus **9 assertions** for the [release gate](#release-check), counted
separately and deliberately: they don't run in `wtf image test` but in
`wtf image release-check`, a different command, played once per version bump
and not on every iteration. Adding them in would obscure that the total above
is that of **one complete pass** of the suites.

| Column | For whom |
|---|---|
| **What it guarantees** | anyone: the promise kept, and the trouble avoided if it breaks |
| **Mechanism** | dev: the file, the function, how it is measured |

The label on the left is the one printed at runtime — it's how you find an
assertion again once it has gone red.

---

## How to run

```
wtf image test
```

**One complete pass is two runs.** No suite runs on both sides, by
construction:

- **container** — bash 4, GNU coreutils, python3. Tests the **logic**: the
  repo's own scripts, run directly.
- **host** — Docker. Tests the **packaging**: the actually-built image, a
  real `FROM`, a running firewall.

The host side also replays the container half **inside** the image, so one
command there covers everything. Rebuild first, or you're testing a stale
image:

```
bash test/run-image-suites.sh --build && wtf image test
```

## Breakdown

| Suite | Half | Assertions | The question asked |
|---|---|---|---|
| [`conf`](#conf) | container | 17 | is my config line read the way I think it is? |
| [`manifest`](#manifest) | container | 44 | is the repo tree the one the image will copy? |
| [`firewall`](#firewall) | container | 241 | does the confinement hold, identically? |
| [`toolkit`](#toolkit) | container | 65 | can someone bring their own patcher, refuse one, override one, and move between versions? |
| [`overlay`](#overlay) | container | 110 | who wins when two layers give the same file? |
| [`overlay` §4](#overlay-4) | host | 9 | …and against the real image? |
| [`image`](#image) | host | 60 | does the image contain what we think it does? |
| [`privilege`](#privilege) | host | 26 | can `node` widen the firewall itself? |
| [`escalation`](#escalation) | host | 18 | can `node` stop being `node`? |
| [`capability-guard`](#capability-guard) | host | 13 | when the firewall cannot start, does it say what is actually missing? |
| [`bypass`](#bypass) | host | 14 | does the network confinement hold against known bypasses? |
| [`port-gate basic`](#port-gate) | host | 11 | does opening a host port open the host? |
| [`port-gate strict`](#port-gate-strict) | host | 14 | …and the same, with mitmproxy in the path? |
| [`extend`](#extend) | host | 34 | and if someone builds from ours? |

The fourteen rows above make up the total of **676**, and nothing else counts
toward it: that is the definition of "one complete pass". The release gate is
a separate command, hence a separate row, outside the total:

| Outside `image test` | Half | Assertions | The question asked |
|---|---|---|---|
| [`release-check`](#release-check) | host + agent | 9 | is this image publishable? |

---

## `conf` — the shape of config files {#conf}

**17 assertions · container · [`test/conf.test.sh`](test/conf.test.sh)**

Every piece of project config is a family of `.txt` files: one entry per
line, `#` as comment, blank lines ignored, edge whitespace trimmed. The
firewall, the hooks to disable, the skills to disable — same format, **one**
reader ([`bin/devc-conf.sh`](bin/devc-conf.sh)). This suite is that reader's
contract.

### Line format

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| comments, blanks and edge whitespace are stripped | A readable config — comments, blank lines, indentation — yields exactly the intended entries, no more, no less. | 7-line fixture (full-line comment, indented, blank, tabbed, trailing `#`) → `conf_entries` yields 4 entries. |
| the cut is at the first # on the line | A comment can talk about `#` without breaking the line. | `echo # why # and more` → `echo`. Pins `${raw%%#*}` (first occurrence) against `${raw%#*}` (last). |
| interior whitespace is preserved | An entry containing a space is not mangled. Only the edges are trimmed. | `  spaced  out  ` → `spaced  out`. This is the deliberate difference from `ports_entries`, which does compress. |
| CRLF line endings do not leak into the entry | A file edited on Windows works like any other. No invisible bug from a carriage return. | `printf 'a\r\nb\r\n'` → `a`, `b`. `\r` is in `[:space:]`, so trailing trim catches it. |
| a last line without a trailing newline is not lost | The last line counts, even if the editor left off the final newline. | `printf 'x'` (no `\n`) → `x`. Relies on the `read` loop's `\|\| [ -n "$raw" ]` guard. |
| a comment-only file yields nothing | A sample file, all comments, does not activate anything by accident. | File of comments and whitespace → empty output. |
| a file ending on a blank line still succeeds | **A well-formed file does not kill startup.** Real bug: a trailing blank line made the function exit in error, and the caller died with it. | `conf_entries` explicitly returns `0`. Without that, the loop's last command is `[ -n "$line" ] && printf`, so rc 1 under `set -e`. |
| and one ending on a comment too | Same thing for a file ending on a comment — the most common shape. | Same, fixture ending on `# tail comment`. |
| a leading ! is handed over verbatim | The `!` prefix (the deliberate opt-in to turn off a mandatory hook) crosses the reader intact. | The parser ignores `!`'s semantics; `disabled_mode()` interprets it, further down. |

### Missing entry

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| a missing file yields nothing | Not creating the file is normal usage, not a failure. | `conf_entries /nonexistent/path` → empty output. |
| and that is not an error | Startup continues when the config is absent. | Return code `0`. |
| no argument at all yields nothing | A call with no argument (path unresolved upstream) breaks nothing. | `${1:-}` then the `[ -n "$f" ]` guard. |
| and that is not an error either | Same, on the return-code side. | `return 0`. |
| a directory is not a config file | A directory bearing the expected name does not derail the read. | The guard is `[ -f ]`, not `[ -e ]`. |

### Consistency with the other write sites

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| grep -cE '^[[:space:]]*[^#[:space:]]' matches conf_entries | The four places that simply **count** active lines count the same way the official reader does. If the format ever changes, this assertion falls and names the files to update. | Compares `grep -cE '^[[:space:]]*[^#[:space:]]'` against `conf_entries \| grep -c .` on a gnarly fixture. Covers `reload-firewall`, `shell-init.sh`, `30-firewall-local-banner.sh`, `22-firewall-bake-warn.sh`. |

### The `ports` overlay

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| interior whitespace is squeezed out | `host : 9222` and `host:9222` name the same service: perfect typing isn't required. | `ports_entries` applies `${entry//[[:space:]]/}` **per line**. |
| entries stay on separate lines | **Two services stay two services.** Real bug fixed: entries stuck together into a single token and the probes targeted a nonexistent host. | The squeeze is done line by line, never `\| tr -d '[:space:]'` on the stream — that class includes `\n`. |

---

## `manifest` — the shape of the repo {#manifest}

**39 assertions · container · [`test/manifest.test.sh`](test/manifest.test.sh)**

A static check, before any execution: is the repo tree exactly the one the
`Dockerfile` is about to copy into the image? This is the least dramatic and
most cost-effective suite — it catches oversights at the point where they
are cheapest.

### General layout

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| top-level entries are exactly the manifest | Nothing appears or disappears at the root without a deliberate decision. A forgotten draft doesn't ship in a public image. | Root `ls` compared to a literal `EXPECTED_TOP` list. |
| bin/ holds exactly the 14 shipped binaries | The shipped toolbox is the one we think it is — no extra script, none missing. | `ls bin` compared to `EXPECTED_BIN`. |
| assets/opt holds exactly hooks knowledge shell-init.sh skills zshrc | What lands in `/opt/devcontainer/base` is frozen. | `ls assets/opt` compared to a list. |
| etc-firewall holds exactly addons dnsmasq.conf domains.d policy.d tests | Same for the shipped firewall config. | `ls assets/etc-firewall` compared to a list. |

### Execute permissions — 13 assertions

| Assertion | What it guarantees | Mechanism |
|---|---|---|
Eleven tools, one assertion each. Same guarantee: **the file can actually be
launched**. An execute bit lost at commit time would only surface when a
client starts up. Same measurement everywhere: `stat -c '%a'` then mask
`& 0111` — not `test -x`, which lies on a Docker Desktop mount.

| Assertion | The tool in question |
|---|---|
| compile-policy.py is executable | compiles the network allowlist |
| devc-hook is executable | runs the lifecycle steps |
| firewall-blocks is executable | shows what the firewall blocked |
| firewall-docker-setup.sh is executable | compiles the ruleset at build time |
| init-firewall.sh is executable | starts the firewall |
| install-extensions is executable | installs the VS Code extensions |
| mitm-init.sh is executable | starts HTTPS inspection |
| reload-firewall is executable | hot-reloads the personal layer |
| sync-creds is executable | syncs credentials |
| sync-skills is executable | installs skills |
| test-firewall.sh is executable | checks confinement from the inside |

And the two exceptions:

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| devc-conf.sh is NOT executable (sourced library) | A **sourced** library is not launchable: what runs and what gets included stay visually distinct. | Same measurement, inverted assertion. |
| firewall-digest.sh is NOT executable (sourced library) | Same for the digest library. | Same. |

### Content inventory

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| on-create.d has 1 fragment | The number of startup steps is known and intended; none gets added by accident. | `find … -name '*.sh' \| wc -l`. |
| post-create.d has 4 fragments | Same. | Same. |
| post-start.d has 19 fragments | Same — it's the busiest phase. | Same. |
| skills/ has 9 dirs and no loader script | The shipped skill set is frozen, and the single-layer v2 loader cannot come back at the skills-layer root. | Directory count + absence of the script. |
| 75-skills-sync does not prefer a workspace loader | The hook that installs skills cannot be steered by a project's leftover v2 loader — the branch that preferred it installed the project layer alone and dropped base + ext silently. | `grep` for the old workspace path in the fragment: absent. |
| knowledge/ has 7 files | The shipped knowledge sheets are complete. | Count. |

### Forbidden content

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| floating-perms does not ship in the image | An internal tool, deliberately removed, does not come back through the back door. | Path absence. |
| no .local overlay anywhere under assets/ | **No personal configuration ships in a public image.** `.local` files are, by convention, private. | `find assets -name '*.local*'` must be empty. |
| no .DS_Store anywhere | No macOS litter in the image. | `find -name .DS_Store` empty. |
| no project-layer domains.txt ships in the image | The image does not carry a project's allowlist: that's the project's job to provide. | Absence of `assets/etc-firewall/domains.txt`. |
| base allowlist domains.d/00-base.txt ships in the image | …but the vital minimum is there, or nothing leaves the container. | File present **and** non-empty. |

### Consistency and syntax

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| every hook delegating to a workspace script has a baked fallback | A project that provides no plumbing still starts. Hooks don't assume the workspace is present. | For every hook citing `/workspace/…`, require an `elif` branch to the shipped equivalent. |
| bash -n on every shipped shell script | **No shipped script has a syntax error.** Otherwise the failure happens at the client's, at startup. | `bash -n` on every `*.sh` under `bin/`, `assets/opt/hooks/`, `assets/etc-firewall/tests/`. |
| compile-policy.py parses | The firewall rule compiler is syntactically valid. | `python3 -c "ast.parse(...)"`. |
| every firewall addon parses | Same for every network inspection module. | `ast.parse` loop over `addons/*.py`. |
| every Dockerfile COPY source exists in the tree | **The build cannot fail on a dead path.** A `COPY` pointing into thin air breaks far from its cause. | Extract sources from every `COPY` line, test existence. |

### The dispatcher, against the shipped layout

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| devc-hook on-create --dry-run enumerates 1 fragment(s) | The dispatcher does find the steps where the image puts them. | `--dry-run` on the repo tree, count of `WOULD RUN`. |
| devc-hook post-create --dry-run enumerates 4 fragment(s) | Same. | Same. |
| devc-hook post-start --dry-run enumerates 19 fragment(s) | Same. | Same. |
| post-start fragments enumerate in numeric order | **Step order follows the numeric prefix.** The firewall must start before anything that needs the network. | The enumerated list is compared to its sorted version. |

### Metadata

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| package.json parses and has a semver version | The published version is readable and well-formed. | `jq` + semver regex. |
| cc-versions.json parses, non-empty, default listed | The Claude Code version matrix is consistent and its default value exists. | `jq`: non-empty, the `default` key is in the list. |
| publish.yml parses as YAML | The publish workflow won't break on an indentation error. | `python3 -c "yaml.safe_load(...)"`. |

---

## `firewall` — network confinement {#firewall}

**231 assertions · container · [`test/run-firewall-suites.sh`](test/run-firewall-suites.sh)** — seven sub-suites.

The image confines the network: only the names on an allowlist get out. This
suite checks that the list is compiled correctly, that it is compiled
**reproducibly**, that a forged list is rejected, and that it cannot be
reloaded by accident.

Three sub-suites — `parse-domains`, `split-local`, `addons` — had existed for
a long time without any runner calling them. Wiring them up immediately
revealed that `split-local` was looking for `compile-policy.py` at a path
that doesn't exist in **either** layout: it could never have run. A suite
nobody runs protects nothing and rots in silence.

### `parse-domains` — the list's extended syntax (47)

`compile-policy.py`'s parser: bracketed methods, indented path scopes,
`!disable`, wildcards, merging across `domains.d/*.txt`. **This is the
grammar the entire confinement is written in** — a misunderstood line allows
or blocks the wrong host, silently. Also covers refusals: invalid hostname,
unknown method, malformed bracket, orphan path.

### `split-local` — the base/local split (29)

`--split-local` mode separates the image layer from the project layer. This
is what lets `reload-firewall` reload the second **without touching** the
first, and lets the hardened bake exclude the project layer. If the
separation leaks, a workspace file ends up in the image's frozen set.

### `addons` — the mitmproxy addons (80)

The three L7 addons (`policy_enforce`, `format_detect`, `passive_log`),
driven by a fake `HTTPFlow` against a synthetic compiled policy. Checks the
expected `X-Block-Reason`, or the pass-through. `mitmproxy.http` and
`ruamel.yaml` are stubbed so the addons load without the bundle — and it is
indeed `ruamel.yaml`, not PyYAML, because that's what mitmproxy's PyInstaller
bundle ships.

The last nine swap that synthetic policy for the **real one**, compiled from
this repository's `policy.d/` and `domains.d/`, and drive the same addon
through it. The distinction matters: everything above proves the *engine*
behaves; only these prove the *rules this image ships* are the rules we meant,
which is exactly what a widening changes. `api.github.com` is otherwise pinned
to `anthropics/*`, and the extension-patch hook needs two owner-agnostic
openings on it — so every allow is paired with the near miss it must refuse.

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| GET a source tarball of any repository → pass | How a patch set is fetched at boot; owner-agnostic because the image names no repository. | Real compiled policy through `policy_enforce`. |
| GET the tag list / the latest release → pass | The two questions `ext-patches-update` asks to find out which refs exist. | Same, both paths. |
| GET the plural `/releases` → blocked | The near miss: it pages every release *body*, a lot of arbitrary text for a question whose answer is one ref name. | `endpoint_not_matched`. |
| GET the contents API of another owner → blocked | The exfiltration path the owner-agnostic rules must not have opened. | `endpoint_not_matched`. |
| GET a repository of another owner → blocked | The repo-metadata rule stays pinned to `anthropics/*`; only the three named paths are generic. | `endpoint_not_matched`. |
| POST to an allowed path → blocked | Read-only means read-only: an allowed path is not an allowed verb. | `method_not_allowed`. |
| GET a gist → blocked | Still refused after the widening. | `blocked_path`. |
| GET the tag list with `per_page` out of range → blocked | The bound is the difference between one page of refs and walking the repository. | `query_param` violation. |

### `parse-ports` — which file, and how it's read (13)

`ports.txt` lists the services reachable over direct TCP. The file was
called `direct-tcp-allow.txt` until 2026-08-10; both names are read during a
transition version.

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| the new name is picked up | The new name works. | `ports_file` returns `<dir>/ports.txt`. |
| and says nothing about it | Using the current name produces no stray warning. | Empty stderr. |
| the old name is still read | **An upgrade does not break existing projects.** The old name still works. | `ports_file` returns `direct-tcp-allow.txt` if only that one exists. |
| and warns that it is deprecated | …but a warning is given, so the transition happens. | stderr contains `deprecated`. |
| with both present, the new name wins | No ambiguity during migration: one rule, not two. | New name takes priority. |
| and the old one is named as ignored, not applied silently | **We never let a rule seem to apply when it is being ignored.** | stderr contains `ignoring`. Never a union: that would duplicate iptables rules. |
| no file at all resolves to nothing | Not opening a port is normal usage. | Empty string. |
| and that is not an error | Startup continues. | Return code `0`. |
| comments, blanks and whitespace are stripped | A commented `ports.txt` yields the right entries. | Mixed fixture → 4 entries. |
| CRLF line endings do not leak into the entry | File edited on Windows: same result. | `a:1\r\n` → `a:1`. |
| a comment-only file yields nothing | The shipped sample file opens nothing. | Empty output. |
| a last line without a trailing newline is not lost | The last rule counts. | `x:1` with no `\n` → `x:1`. |
| a missing file yields nothing, without failing | No file = no port opened, not a failure. | Return code `0`. |

### `bake-idempotency` — compiling at build time (33)

The ruleset is compiled **at build time** and frozen into the image.

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| T2 · exit 0 | The hardened compile (no personal overlay) succeeds. | Bake script's return code. |
| T2 · effective/dnsmasq-domains-base.conf present | The base DNS config is produced — without it, no allowed name resolves. | File presence. |
| T2 · effective/policy.compiled.yaml present | The HTTPS inspection policy is produced. | Presence. |
| T2 · effective/hosts.txt present | The readable host list is produced (this is what the probes read). | Presence. |
| T2 · effective/sources.sha256 present | The sources' digest is recorded — this is what, at startup, will tell whether the frozen set is still valid. | Presence. |
| T2 · effective/local-included present | The marker saying whether the personal layer was included is written. | Presence. |
| T2 · effective/dnsmasq-domains-local.conf present | The personal layer's DNS config is produced (empty in hardened mode). | Presence. |
| T2 · baked-at stamped | We know when the image was compiled. | `baked-at` file non-empty. |
| T2 · domains.local.txt excluded | **By default, a developer's personal list does not ship in the image.** This is the hardened behavior. | The file is not in the destination. |
| T2 · policy.local.d/ excluded | Same for personal policies. | Directory absent. |
| T2 · local-included=0 | The marker explicitly states the personal layer is excluded. | File content. |
| T3 · exit 0 | The compile **with** opt-in also succeeds. | Return code. |
| T3 · local-included=1 | The marker reflects the opt-in. | Content. |
| T3 · opt-in does add a host | The opt-in has a measurable effect: the list widens. | Host count, strict comparison. |
| T3 · ambient opt-in drops no host | Enabling the opt-in **never** loses a host: it is purely additive. | `>=` comparison. |
| T3 · the two bakes have different digests | The two modes are distinguishable: a hardened image and a permissive one will never be confused. | The digests differ. |
| T4 · exit 0 | Recompiling on top of an existing compile succeeds. | Return code. |
| T4 · short-circuited on digest match | A pointless rebuild is avoided: time saved, and above all no drift. | Short-circuit message. |
| T4 · effective/ byte-identical across runs | **Two identical compiles give an identical result, byte for byte.** Without this, there's no way to tell whether an image has drifted. | `diff -r` between two runs. |
| T4b · exit 0 | A project slipping in a forged ruleset does not crash the build… | Return code. |
| T4b · forged effective/ discarded, ruleset recompiled from sources | **…and its forged set is discarded, not installed.** This is an attempt to inject arbitrary network rules. | The `evil.example.com` marker does not appear in the output. |
| T4b · forged baked-at discarded | The forged date is discarded too. | The forged date is not kept. |
| T5 · base conf matches live | What was just compiled matches what's actually in effect: the compile does not drift from reality. | Normalized `diff` against `/var/run/…`. |
| T5 · local conf matches live | Same for the local layer. | Same. |
| T6 · refused (exit 1) | **An empty allowlist is refused, never applied.** An empty list is a container that can no longer reach anything. | Return code 1. |
| T6 · nothing promoted | And the old set stays in place instead of being overwritten. | Destination unchanged. |
**T7 — the digest must move for every compiler input.** Eight inputs, one
assertion each. If any one of them were not accounted for, it could be
changed without the image noticing: at the next startup it would reinstall
the old ruleset **silently**. Same measurement everywhere: change the input,
the digest must change.

| Assertion | The monitored input |
|---|---|
| T7 · moves on domains.txt | the project allowlist |
| T7 · moves on domains.local.txt | the personal allowlist |
| T7 · moves on default-mode | the firewall mode (`strict` / `basic` / `off`) |
| T7 · moves on domains.d/ addition | an added per-ecosystem allowlist file |
| T7 · moves on policy.d/ addition | an added inspection policy |
| T7 · moves on policy.local.d/ addition | an added personal inspection policy |
| T7 · moves on compile-policy.py version | the compiler itself, which changes on every image version bump |
| T7 · moves on local-included flag | the decision to include the personal layer or not |

### `frozen-fastpath` — trust the frozen set, or recompile (14)

At startup, the image installs the compiled set **if and only if** the
sources haven't moved since. Otherwise it recompiles, and says why.

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| extracted the real decision block | The test reads the script's real decision logic, not a copy that could drift. | Textual extraction of the block, size check. |
| C1 · takes the frozen set | Normal case: fast startup on the frozen set. | Decision = frozen. |

**C2 — any change to a source hands control back to the compiler.** Six
sources, one assertion each. Without them, one could edit their config with
zero effect, and zero message. Same measurement: change the source after the
compile, the decision must flip to "recompile".

| Assertion | The changed source |
|---|---|
| C2 · refuses after a change to domains.txt | the project allowlist |
| C2 · refuses after a change to domains.local.txt | the personal allowlist |
| C2 · refuses after a change to default-mode | the firewall mode |
| C2 · refuses after a change to domains.d/ | an allowlist file |
| C2 · refuses after a change to policy.d/ | an inspection policy |
| C2 · refuses after a change to policy.local.d/ | a personal policy |

Then the four other situations:

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| C3 · refuses when domains.local.txt appears in /etc | Slipping a personal layer in **after** a hardened build does not sneak it past. | File added afterward → recompile. |
| C4 · falls back to compiling | An old image, with no frozen set, still starts. | Absence of `effective/` → recompile. |
| C5 · refuses an empty dnsmasq-domains-base.conf | A truncated frozen set (full disk, interrupted copy) is not installed as-is. | File emptied → recompile. |
| C5 · refuses an empty policy.compiled.yaml | Same for the inspection policy. | File emptied → recompile. |
| C5 · refuses a missing dnsmasq-domains-local.conf | Same when a file is missing instead of empty. | File deleted → recompile. |
| C6 · refuses when compile-policy.py changed | An image version bump, which changes the compiler, invalidates the frozen set. | The digest includes the compiler. |

### `reload-firewall-guards` — reloading, but not just any old way (24)

`reload-firewall` applies the personal layer **hot**. This is a privileged
operation: a cascade of guards protects it.

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| T8 · exit 0 | **Preview** is available to everyone, no privilege needed. | `--dry-run`'s return code. |
| T8 · prints the .local source hashes | You see exactly which files were read — the workspace being editable by anything. | Digests printed. |
| T8 · prints the host delta | You see what would change before deciding. | Delta section present. |
| T8 · the added host shows as + | An addition visibly reads as an addition. | Line prefixed `+`. |
| T8 · prints the unified diff | The full detail is available. | Diff format. |
| T8 · states nothing was applied | **No ambiguity: the preview changes nothing.** | Explicit message. |
| T8 · live runtime confs untouched | And it's true: the files in effect do not move. | Before/after comparison. |
| T8 · /etc/devcontainer-firewall untouched | Same for the system config. | Before/after comparison. |
| T8b · exit 0 | Previewing with no overlay at all works. | Return code. |
| T8b · renders the empty-overlay case | …and renders a readable empty case, not broken output. | Expected rendering. |
| T9 · apply refused as non-root (exit 1) | **Applying requires root.** | Return code 1. |
| T9 · names the reason | The refusal explains why. | Message. |
| T9 · names the host-side alternative | …and gives the procedure from the host. | Message. |
| T9 · names the unprivileged preview | …and reminds that the preview, at least, is open. | Message. |
| T9 · states why sudo is not granted | …and why `sudo` is deliberately not granted. | Message. |
| T9 · EUID guard precedes the CLAUDECODE guard | Guard order is fixed: the message you get is the right one, not a later guard's. | Message order. |
| T9 · piped 'yes' still refused | **You cannot bypass the confirmation by piping `yes`.** | Standard input fed → still refused. |
| T9c · mode 'off' refused | Reloading while the firewall is off is refused rather than silent. | Return code 1. |
| T9c · mode 'okeish' refused | An unknown mode does not pass as a valid one. | Return code 1. |
| T9c · mode 'nonsense' refused | Same, another value. | Return code 1. |
| T9c · 'off' explains there is nothing to reload | The refusal is instructive. | Message. |
| T9c · 'okeish' names the replacement | …and suggests the correct value. | Message. |
| T9b · unknown flag exits 2 | A typo in a flag does not run something else instead. | Return code 2, distinct from 1. |
| T9b · --help prints the header | Help works. | Header present. |

---

## `toolkit` — bring your own patcher {#toolkit}

**65 assertions · container · [`test/toolkit.test.sh`](test/toolkit.test.sh)**

The image installs Anthropic's Claude Code extension exactly as published and
patches nothing. What it ships is the *toolkit* that can run a patcher —
`run-all.sh`, `_common.py`, `AUTHORING.md` — for people who keep their own, on
their own installation. So the suite asserts a contract rather than a registry:
there is no patcher here to describe.

Three questions. First, that the shipped tree really is toolkit-only: a patcher
creeping back into the build is the compliance regression that matters, and it
is cheaper to catch here than in a legal review. Second, that `PATCH_DIR`
genuinely decouples patchers from the toolkit — including `from _common import
…`, which used to work only because the two happened to be neighbours, and now
depends on the orchestrator exporting `PYTHONPATH`. Third, that the selection
vocabulary and its refusals survived the move.

Everything is driven by **probe patchers** written into a throwaway directory:
a header, a sentinel, an idempotent guard, and a real `_common` import. The
registry half — headers agreeing with a catalogue, sentinels really present in
a real bundle — left with the patchers, to the repository that holds them. The
"inside a real image" half is in [`image`](#image) and [`extend`](#extend),
where the extending image brings two probes of its own precisely because the
base brings none.

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| the shipped tree is exactly the three toolkit files | The one assertion a reviewer would ask for: no patcher ships, and nobody has to take that on trust. | `ls` compared to a literal. |
| no patcher ships in this repository | Same claim from the other side, so a `.py` added under any name is caught. | `find -name '*.py' ! -name _common.py`. |
| `PATCH_DIR` runs patchers that live outside the toolkit | The seam the `45-ext-patches.sh` hook and `restore-ext-patches` both depend on. | Probes in a tmp dir, `PATCH_DIR` pointed at it. |
| a patcher imports `_common` through `PYTHONPATH` | The fragile half of the split: `sys.path[0]` is the *patcher's* directory, which no longer holds `_common.py`. | stderr checked for `ModuleNotFoundError`. |
| all / none / category / name / additive / whitespace | A selection still selects, and adding a name to a category widens instead of replacing. | Counting `→ <name>.py` announcements. |
| an unknown token exits 2 and applies nothing | A typo must fail loudly, not read as "that patch does not exist, so it is not applied". | Exit code plus an invocation count of zero. |
| a patcher without a category stops the run | Running something no header describes is the one thing worth breaking a build over. | A headerless `.py` dropped into the probe dir. |
| an unlisted category stops the run, and names itself | `AUTHORING.md` has always said "`ux`, `fix` or `notify`. Nothing else is accepted" and nothing enforced it: a typo registered fine, ran under `all`, and was invisible to a selection naming the category it meant. | A probe declaring `nofity`; exit code plus the word in stderr. |
| the summary is grouped by category, in `CATEGORIES` order | The category was read and validated since 4.1c and shown nowhere, so sixteen patchers reported sixteen undifferentiated lines. A group prints iff a registered patcher declares it, so a selection of `none` still accounts for every patcher. | The `── group ──` and status lines compared to a literal sequence, plus a header count under `none`. |
| **application order is the registry's, not the category's** | Grouping the *run* reorders patch application, and that order is load-bearing: two patchers rewrite the same `extension.js` chokepoint and only the first one there finds it — 8 red assertions in the patcher repository, measured. Presentation may group; application may not. | Probes named so the alphabetical and category orders differ; the `→ <name>.py` sequence compared to a literal. |
| a `SKIP` line does not repeat its own category | Under a `fix` header, `SKIP probe (fix)` is the group name twice. | The `none` selection grepped for a parenthesised category. |
| the summary shape the patcher repository parses | `claude-ext-patchs/test/apply.test.sh` reads this summary with two greps — its header at `:127` and `^  FAILED`, two leading spaces, at `:131` and `:165`. Nothing on this side pinned them, so a session could reshape the summary, stay green here, and break that repository the day someone bumps `toolkitRef`. | A deliberately failing probe; the header matched against `apply.test.sh`'s own regex, the `FAILED` lines counted at exactly two spaces, and the run still exiting 0. |
| an empty patch directory is not an error | The published image's nominal state: toolkit present, nothing to apply, exit 0. | Empty `PATCH_DIR`, and the shipped default. |

### the hook's brain, and moving between versions

The toolkit answers "can a patcher run". These answer "which patchers, and how
does one change that" — [`ext-patches-sync`](bin/ext-patches-sync), which the
`45-ext-patches.sh` fragments call on both lifecycle phases, and
[`ext-patches-update`](bin/ext-patches-update), which moves a container from
one pinned set to the next.

Until these existed, every suite could say `ext-patches-sync` *is executable*
and none could say what it *does*. That gap had already shipped a defect:
`--status` was documented from the first version and never parsed, so the one
flag whose whole promise is "change nothing" fell through to the apply path and
rewrote the extension. Both scripts are driven here against a throwaway `.env`,
a throwaway extension and a **stubbed `curl`** — an unfixtured request fails
rather than reaching the real network, so a test that forgets its fixture goes
red instead of going online.

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| `--status` changes nothing | The regression that already happened once: a read-only flag that silently rewrote `extension.js`. | Bundle checksum before and after. |
| `--status` reports the pinned ref | The report is worth having only if it reads the same values the hook resolves. | Output grepped for the `.env` value. |
| `--status` never prints the token | Phase logs are collected verbatim into the release-check bundle. | Output grepped for the secret's literal value. |
| `--status` answers on an unconfigured checkout | "Nothing is configured" is the answer it was asked for, not a reason to exit silently. | Empty `.env`. |
| an unknown option is refused, not ignored | Ignoring a flag is how `--status` came to mean its opposite. | Exit 64 on `--nonsense`. |
| a pin for another version is reported | **The tag declares its target — `cc<version>-r<n>` — and nothing used to read it.** A pin left behind by a CC bump was applied verbatim: measured 2026-09-16, `cc2.1.258-r2` against extension 2.1.272, eight patchers failed and **nine applied**. The nine are the danger: a 2.1.258 anchor that still matches in 2.1.272 code, and `node --check` only proves the result parses. | Version parsed out of the ref, compared to the bundle's `package.json`. |
| …and names the version actually installed | A warning that gives one of the two numbers sends you to check the wrong one. | Both versions in the banner. |
| …and names the command that moves the pin | `ext-patches-update` resolves per CC version; the warning is useless without it. | Output grepped. |
| …while the patchers are still applied | **A warning, not a gate.** `ext-patches-sync` must never fail a boot, and a half-applied bundle is worse than a fully-applied one that says it is suspect. | Apply still reported. |
| already-applied restarts keep saying it | **The boot a mismatched pin lives in for ever.** The sentinels *are* present — a set for another version did apply — so the short-circuit's "already applied" must not stand alone. | Second run, banner still emitted from the short-circuit. |
| a pin for this very version says nothing | No nagging on the nominal case. | Matching ref, banner absent. |
| a ref that names no version is not second-guessed | A SHA or a branch declares no target, so there is no claim to contradict. Silence there is correctness. | `deadbeef` as the ref. |
| `--status` shows the installed version | The two numbers a mismatch is made of, without anyone decoding a tag name. | `--status` output. |
| `--status` shows what the ref targets | Same, from the other side. | `--status` output. |
| a second run short-circuits on the sentinels | The nominal restart: no network, no re-apply. | Two runs, second one grepped for `already applied`. |
| `--force` replays the selection anyway | A CC bump reinstalls the bundle, so the previous copy's sentinels are gone with it. | Counting calls to a stubbed `restore-ext-patches`. |
| `--dir` applies from a local checkout, with no token | The route that needs no network, no credential and no firewall opening at all. | `.env` stripped of its token. |
| `--check` (both forms) changes nothing | The flag people will reach for first must be safe to run blind. | Checksum and pin, before and after. |
| `--check` reports installed against available | The whole point of asking. | Output grepped for both refs. |
| latest prefers a published release | A release is an explicit statement that a tag is meant to be consumed. | `releases/latest` fixture. |
| latest falls back to the tag list | Not a nicety: the repository this was built for carries git tags and **no** releases, so this is the branch that actually runs. | Fixture removed, `tags` fixture served. |
| tags are ordered numerically, not lexicographically | GitHub returns refs in ref order, which puts `cc2.1.99-r1` above `cc2.1.258-r1`. | Two tags whose text and version orders disagree. |
| a successful update rewrites the pin | The pin is what makes the next boot reproducible; an update that left it stale would boot the old set. | `.env` re-read after the run. |
| the rewrite keeps the comments around it | A `.env` a human curated must not come back reordered or stripped. | A comment line checked after the rewrite. |
| `--no-write-env` leaves the pin alone | A trial run has to be a trial run. | Pin compared after the flag. |
| a **download that fails** leaves the pin alone | The dangerous direction: a pin naming a ref that never downloaded sends the next boot looking for a cache that is not there, silently. | Tarball fixture withdrawn mid-suite. |
| `--reapply` refuses when nothing is cached | Replaying a set that was never fetched is a no-op dressed as a success. | Empty cache, exit 1. |
| an unreachable repository **with** a cache warns and keeps the pin | Resolving "latest" is a convenience. Offline, firewalled, token expired — none of it should be fatal to a container that already has patchers on disk. | Fixtures withdrawn, cache seeded; exit 0, pin unchanged. |
| an unreachable repository with **nothing** cached is an error | The other half: degrade to "you keep what you have", but say so plainly when there is nothing to keep. | Fixtures withdrawn, no cache; exit 1. |
| a local patcher of the same name overrides the resolved one | The image's contract everywhere else — a base, an override that wins. The project's `.py` are copied last, so a shared filename shadows the tagged one. | Two probe sets, same filename, different sentinel. |
| the override is announced by name | A local file silently shadowing a tagged one is how you spend an afternoon debugging the wrong source. | Output grepped for `overriding: <name>`. |
| an untouched local directory still short-circuits | The nominal restart must stay free: no re-apply when nothing moved. | Second run grepped for `already applied`. |
| **editing** a local patcher re-triggers the apply | The loop this directory exists for is edit-restart-look, and the sentinel cannot see an edit that keeps its marker. A stamp of the directory's names, sizes and mtimes answers what the marker cannot. | Override regenerated **marker-identical**, then touched — so the sentinel check alone would have short-circuited. |
| local patchers alone are a configured project | A project that brings only its own patchers is configured; the silent exit belongs to the published image, which has no such directory. | Empty `.env`, one local probe. |

### bring your own patcher — replace, add, restart

`toolkit` proves the resolution *logic* against a stubbed
`restore-ext-patches` and a throwaway extension. That is a different claim
from "it works in the image", and these are the two failures a consumer
actually hits. The second is not hypothetical: it is a regression this suite
now catches, and the counter-proof was run — with the previous short-circuit
the added patcher never lands, and the assertion reports
`NOT applied — got '__PROBE_BASE__'`.

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| replacing a patcher: the local copy wins | "I replaced a patcher and nothing changed." The project's `.py` are merged last, so a shared filename shadows the resolved one. | Two probes, same filename, different markers, one real `docker run`. |
| the override is named in the boot output | A local file silently shadowing a tagged one sends you debugging the wrong source. | Boot output grepped for `overriding: <name>`. |
| **adding a patcher, then restarting: it is applied** | "I added a patcher and it was ignored on restart." The old short-circuit asked `all_live` of the *resolved* set only, so a container whose tagged sentinels were all live answered "already applied" and never looked. | First boot, then a `.py` dropped in, then a second boot — inside one container. |
| …and the resolved set is still applied beside it | The addition must not cost the base layer. | Both markers asserted in the bundle. |
| local patchers alone, with nothing configured, are applied | A project bringing only its own patchers is configured; the silent exit belongs to the published image, which has no such directory. | No `EXT_PATCHES_*` at all. |

## `overlay` — who wins between layers {#overlay}

**110 assertions · container · [`test/overlay.test.sh`](test/overlay.test.sh)**

The biggest suite, because this is the contract people use every day.
**Three layers**, in this order: the **image**, a **Dockerfile that extends
it**, the **project**. The last one wins.

### §1 — startup steps (46)

A "step" is a small numbered script (`20-firewall-reinit.sh`) that the image
runs at a precise point in the lifecycle.

#### Add, replace, order

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| base alone: 3 fragments | Measured starting point: with no project, we get exactly the image's steps. | `--dry-run`, count of `WOULD RUN` on a fake 3-fragment base. |
| overlay adds a fragment: 4 | **A project can add a step of its own.** | One more fragment in the project layer → 4. |
| the addition lands at its numeric position | The added step is inserted **at the right point**, not at the end. A script that needs the network must come after the firewall. | The enumerated list is compared to the expected order. |
| same-name replacement does not duplicate: 4 | **Replacing an image step does not run it twice.** | Same filename in the project layer → still 4. |
| the body that runs is the overlay one | …and it really is the project's version that runs. | `MARK:` marker in the output. |
| the base body no longer runs | …and the image's version does not run at all anymore. | Absence of the other marker. |

#### Disabling — via `devcontainer.json` (deprecated alias)

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| disabledHooks skips the fragment | The old disabling method still works: nothing breaks for existing projects. | `customizations.stitchu-devc.disabledHooks` list. |
| and its body does not run | And the script is actually skipped, not just announced as such. | Absence of the marker. |
| // comments do not break the JSONC reader | **A commented `devcontainer.json` — the norm — stays readable.** | No parse error in the output. The reader is a string-aware JSONC strip in python3. |
| local.json disables too | A **personal** (uncommitted) setting can disable a step. | `devcontainer.local.json`. |
| without cancelling the team one | …without cancelling the team's: the two lists add up. | Both skips observed simultaneously. |
| an on-create.d entry does not touch post-start | An entry targeting a **different** phase disables nothing here. No collateral damage. | Full key comparison (`post-start.d/x.sh`), not a prefix. |

#### Disabling — via `hooks/disabled.txt` (the usual method)

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| disabled.txt skips the fragment | **The recommended method works**: one line in a text file, with comments. | Fixture with a full-line comment, trailing `#`, blank line. |
| and its body does not run | The script really is skipped. | Absence of the marker. |
| an on-create.d line does not touch post-start | A line targeting another phase does nothing here. | Same full-key comparison. |
| a broken devcontainer.json does not cancel disabled.txt | **This format's reason for existing.** Before, `disabledHooks` was the only channel: an unreadable `devcontainer.json` made the whole list vanish. Now the `.txt` still applies. | Deliberately invalid JSON + valid `.txt` → the skip still happens. |
| the .txt and the JSON alias union | You can mix both during a migration. | One entry on each side, both apply. |
| neither cancels the other | Neither takes precedence over the other: it's a union, not a replacement. | Both skips observed together. |

#### The single script, as a fallback

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| a non-executable post-start.sh is ignored | A file dropped there with no execute permission doesn't run on its own. | Absence of marker. |
| an executable post-start.sh runs | A project can provide **one** single script instead of numbered fragments. | Marker present after `chmod +x`. |
| and it runs last | …and it runs **after** every image step, never in the middle. | Marker's position in the output. |

#### A step failing: when to continue, when to stop

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| an optional fragment that fails -> WARN | **An optional step that crashes does not prevent working.** | Fragment `@required false` exiting in error → `WARN`. |
| and the phase runs to the end | The rest of startup continues. | End-of-phase message present. |
| a required fragment that fails -> FAIL | **An essential step that crashes stops everything** — better not to start than to start half-confined. | Fragment `@required true` in error → `FAIL`. |
| and the phase stops there | Startup really is interrupted. | End-of-phase message absent. |
| the later fragments do not run | …and the following steps do not run. | Absence of their marker. |

#### The intermediate layer (an image extending ours)

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| ext adds a fragment: 5 | A derived image can add its own steps. | Fragment in the `ext` layer → 5. |
| the ext addition lands at its numeric position | At the right point, just like for a project. | Order compared. |
| and the log names the layer it came from | **The log states where every step comes from** — essential for diagnosing at someone else's. | `(ext,` tag in the line. |
| ext replaces the base fragment | A derived image can replace a base-image step. | Same name → `ext` body. |
| the base body no longer runs | …and the base's version no longer runs. | Absence of the marker. |
| the project wins over ext | **The project always has the last word**, even against the derived image. | Project body observed. |
| the ext body no longer runs | …and the intermediate version no longer runs. | Absence of the marker. |
| one winner, not three | Three layers give **one** run, not three. | Occurrence count. |
| disabledHooks reaches an ext fragment too | A project can disable a step coming from the derived image. | Skip observed. |
| and its body does not run | Really skipped. | Absence of the marker. |
| ext/disabled.txt switches off a base fragment | **The derived image gets its own list.** It cannot write the project's `devcontainer.json`: without this, its only recourse was to shadow the file — the very maneuver the protection below exists to catch. | `disabled.txt` in the `ext` layer. |
| and the ext layer's own fragment still runs | …with no side effect on its own steps. | Marker present. |

#### Protecting essential steps

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| disabling a @required fragment is REFUSED | **You cannot switch off the firewall by mistake.** A step marked essential refuses to be disabled. | Message `REFUSED to disable …`. |
| and the fragment runs anyway | The refusal isn't cosmetic: the step runs anyway. | Marker present. |
| the ! opt-in does switch it off | It's still possible to do it **deliberately**, with a `!` prefix you don't type by copy-paste. | Entry `!post-start.d/…`. |
| and then its body does not run | …and now it really is off. | Absence of the marker. |
| the ! form is not itself refused | The deliberate form does not trigger the refusal. | Absence of `REFUSED`. |
| disabled.txt cannot switch off @required either | The protection holds for **both** formats: switching formats does not weaken it. | Same refusal from the `.txt`. |
| and the ! opt-in works from the .txt too | …and the deliberate escape hatch too. | `!` in the `.txt`. |
| shadowing a @required fragment is announced | **Bypassing the protection by overwriting the file is flagged**, naming both layers. This is the very maneuver the protection exists to prevent. | Message naming the shadowed layer. |

### §2 — skills (40)

A "skill" is a `/name` command available in Claude Code: a directory
containing a markdown file, and sometimes a `hooks.json` that registers
automatic behavior. Same three-layer contract as steps.

#### Install, replace

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| the baked skill installs | Skills shipped with the image become available commands. | `<name>.skill.md` copied to `~/.claude/commands/<name>.md`. |
| its body is the base one | It really is the image's content. | Body comparison. |
| its hook is registered once | Its automatic behavior is registered **once**, not twice. | Count of `SessionStart` entries. |
| and retargeted to the directory actually read | **The registered path points where the file actually is.** Otherwise Claude Code fails every session on a missing file. | The shipped prefix is rewritten to the directory actually read. |
| a project skill is added | A project can add its own commands. | New name → new command. |
| the project replaces the baked skill body | **A project can adapt an image skill** by providing a file with the same name. | Project body observed. |
| its hook REPLACES instead of adding | …and its automatic behavior **replaces** the old one instead of stacking onto it. | Always 1 entry. |
| and points at the project copy | …pointing at the project's copy. | Registered path. |
| an ext skill installs | A derived image can add its skills. | Command present. |
| and its hook is retargeted to the ext dir | With the right path, here too. | Registered path. |
| project > ext > base on one skill name | On the same name, the three-layer order is honored. | Project body observed despite the three copies. |

#### Replacing a shipped skill — the two real forms

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| the baked skill is in force | Measured starting point, on a fixture shaped like a real shipped skill (markdown + `hooks.json` + the script it runs). | Base body. |
| with no project, ext replaces the baked body | **A derived image replaces an image skill, with no project in the way.** A case never covered before. | `ext` copy, no project copy. |
| one hook, not two | Its automatic behavior replaces, it does not stack. | Count. |
| and it points at the ext copy | The path follows the winning layer. | Registered path. |
| a markdown-only override swaps the body | **The most common form**: the project copies only the markdown, and its text takes effect. | Project copy with no `hooks.json`. |
| the baked hook stays in force | …**and the shipped automatic behavior keeps running.** Adapting a skill's text should not make its automation disappear. | The registered path stays the image's. |
| and is still registered once | No duplicate. | Count. |
| removing it retracts its hook | Removing the skill from both layers also retracts its automation. | Count to zero. |
| three syncs in a row stack nothing | **Restarting ten times does not stack the same behavior ten times.** | Three consecutive runs, stable count. |

#### Disabling

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| a .skill.disabled.md skill does not become a command | Renaming your own file puts the skill to sleep. | The scan only picks up `*.skill.md`. |
| and its hooks are not registered | …including its automatic behavior, which no longer runs on the sly. | Count unchanged. |
| before disabling, the command is there | Measured starting point before the next test. | File present. |
| a listed skill does not install its command | **A project can remove an image skill**, which was impossible before: it could only shadow it. | One line in `skills/disabled.txt`. |
| and the run says so | The log announces it, rather than doing it silently. | `disabled` line in the output. |
| and the hook it had registered is retracted | Its automatic behavior is retracted, not just ignored. | Count to zero. |
| a command left by an earlier boot is removed | **Cleanup also covers the past.** `~/.claude/` survives image updates: without this, the command would sit there indefinitely. | File manually reinstalled, then removed by the run. |
| a hooks-only skill registers its hook | Starting point: some skills have **no** command at all, only automation. | Directory with no markdown. |
| and listing its directory retracts it | **This is why the key is the directory, not the command name**: otherwise those skills could never be disabled. | Entry = directory name. |
| even with no command to speak of | The log states it explicitly. | `skipped disabled skill` message. |
| a list in the ext layer counts too | A derived image can remove a base-image skill. | `disabled.txt` in the `ext` layer. |

#### Guardrails

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| a *.skill.md under node_modules is not installed | **An npm dependency cannot self-declare as a command.** A skill can bundle its own packages; one of them could contain a file with the right name. | `-not -path '*/node_modules/*'`. |
| the hook of a removed skill is pruned | A removed skill has no more active automation. | Count to zero after removal. |

#### The hook inherited from an old image

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| a hook whose skill no longer ships is pruned | **The real-world failure case**: `~/.claude/` survives the update, so automation written by a previous image points at a skill that's gone, and Claude Code complains about it every session. | `settings.json` pre-filled with a shipped path; recognized via prefix normalization. |
| a hook whose file vanished is pruned too | Variant: the skill still exists, but the file it runs was renamed. | Path `skill/vanished-file.js`. |
| and the run names what it retracted | Cleanup is announced, not silent. | `pruned stale skill hook: …`. |
| a hook of the user's own is left alone | **The tool never touches what it did not write.** The other half of the contract, as important as cleanup. | Only commands of the form `<SKILLS>/…` are candidates. |
| even though its target does not exist either | Including when the user's own target is also missing. | The file does not exist, the entry stays. |
| and the live skill is registered | Cleanup causes no collateral damage. | Live skill's path present. |
| 2 of the 4 entries survive | Exact count: two removed, two kept. | Final count. |

### §3 — broken entries (24)

The rule: **a bad file costs that file, never startup, and it is named.** A
third-party project will add files; some will be broken.

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| a fragment whose target vanished -> WARN, not a crash | A dead symlink does not block startup. | Warning, not a stop. |
| an unreadable fragment -> WARN | A script that isn't bash either. | Warning. |
| and the phase still completes | Startup runs all the way through. | End-of-phase message. |
| the healthy fragments ran | And the healthy steps did run. | Marker present. |
| an unreadable devcontainer.json stops nothing | An invalid config file does not block startup. | End-of-phase message. |
| and it says so instead of emptying the list in silence | **It says so.** Silence used to mean both "nothing to disable" and "I couldn't read it" — two very different things. | Message naming the file. |
| a URL in devcontainer.json is no longer a parse error | **The assertion that motivated the format change.** A plain URL in the file made it unreadable and emptied the whole list. | Same fixture as before, inverted expectation. |
| and the list it carries actually applies | …and the list it carries really does apply. | The skip happens. |
| block comments and trailing commas are tolerated | The other legal JSONC forms pass too. | `/* */` and a trailing comma in the fixture. |
| and the phase still completes | Startup runs to the end. | End-of-phase message. |
| a CRLF fragment does not stop the phase | A script edited on Windows runs. | Fragment in `\r\n`. |
| a fragment without shebang still runs | No need for the magic line up top. | Launched via `bash <file>`. |
| a fragment without the exec bit still runs | No need for the execute permission — a bit lost by git breaks nothing. | Same. |
| an unreadable hooks.json is skipped and named | An unreadable automation file costs **that file alone**. | Message naming the file. |
| a malformed hooks.json is skipped and named | Same for malformed JSON. | Message. |
| a non-object handler is skipped and named | Same for content of the wrong shape. | Deep validation before the merge loop. |
| no Python traceback surfaces | **The user sees a message, not an error trace.** | Absence of `Traceback`. |
| and the HEALTHY skill hook survives | **A broken file does not take the others down with it.** Before, a single error canceled the merge of all skills, and the phase still declared itself complete. | Count of the healthy automation. |
| their commands are installed anyway | The affected skills' commands install regardless. | Files present. |
| a corrupt settings.json is named | A corrupt settings file (it lives in a volume, for reasons outside our control) is flagged. | Message. |
| no traceback | With no error trace. | Absence of `Traceback`. |
| the skills still install | The commands install anyway. | Files present. |
| and the corrupt file is left untouched | **We never overwrite the user's settings.** Rewriting them would destroy what they had. | Original content intact. |
| sync-skills still reports done | The run finishes cleanly. | End-of-run message. |

### §4 — against the real image (9, host side) {#overlay-4}

The same guarantees, but against the actually-built image instead of the
repo's scripts. Requires Docker.

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| LANG=C.UTF-8 in the image | Accents and emoji display correctly. | Environment variable in the image. |
| effective UTF-8 locale | And the locale is really active at runtime, not just declared. | Measured in a container. |
| overlay hooks against the image: +1 fragment | A project really does add a step to the **real** image. | Workspace mounted, count. |
| replacing a shipped fragment (05-log-rotation.sh): the overlay wins | And really does replace an actually-shipped step (`05-log-rotation.sh`). | Winning-layer comparison. |
| disabledHooks against the image | Disabling works against the real image. | Skip observed. |
| overlay skills against the image | A project's skills install against the real image. | Command present. |
| extension patches applied · patch applied - model badge (UX) | The changes made to the VS Code extension are present in the published image. | Marker in the extension file. |
| patch applied - user-action observer (notify) | Same, second change. | Marker. |
| patch applied - authority writer (notify) | Same, third. | Marker. |

---

## `image` — the actually-built image {#image}

**44 assertions · host, Docker · [`test/run-image-suites.sh`](test/run-image-suites.sh)**

Up to here everything was about the **code**. Here we interrogate the
**artifact**: what got built, then what happens when you actually start it.

### A. Image at rest

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| the image was built from this tree (version X) | **We are not testing a stale image.** Every assertion below reads the image: an image from before the commit passes all of them, then fails elsewhere in a way that makes no sense. This has happened. | Version label compared to `package.json`. |
| etc-firewall layout | The firewall config is in place, complete. | `ls` in a throwaway container. |
| opt/devcontainer/base layout | The base layer (steps, skills, knowledge) is in place. | `ls`. |
| base allowlist host count | The vital network minimum is there, in the expected count. | Count of compiled hosts. |
| base policy.d count | The shipped inspection policies are complete. | Count. |
| devc-hook fragments on-create/post-create/post-start | The dispatcher finds its steps in the real layout. | `--dry-run` in the container. |
| /usr/local/bin/sync-creds baked | The credential-sync tool is shipped. | File present. |
| /usr/local/bin/sync-skills baked | The skill installer is shipped. | File present. |
| /usr/local/bin/install-extensions baked | The extension installer is shipped. | File present. |
| baked shell-init.sh present | **A project has no shell plumbing of its own to provide**: it's all in the image. | File present. |
| .zshrc falls back to the baked shell-init | And the shell uses it automatically, with no configuration. | `.zshrc` content. |
| interactive zsh loads OMZ + theme | The terminal is really configured on open. | Interactive shell launched, variables measured. |
| git prompt helper available in zsh | The prompt's git indicator works. | Function available. |
| label org.stitchu.base.version = X | The image carries its version, readable without starting it. | `docker image inspect`. Value follows `package.json`. |
| label org.stitchu.claude-code.version = X | …and the Claude Code version it bundles. | Same. |
| label org.opencontainers.image.source = https://github.com/meitogi/devcontainer-sandbox | …and its source repo address, for traceability. | Same. |
| *(run-all.sh\|_common.py\|AUTHORING.md)* readable from inside the container | **The toolkit reads from the image itself**, so someone who brings their own patcher needs nothing else. | Presence under `/usr/local/bin/vscode-ext-patchs/`. |
| the image ships no patcher | **The compliance line, asserted rather than promised.** A `.py` appearing in the patch directory means the image modifies the extension again. | `ls *.py` excluding `_common.py`, expected 0. |
| *(restore-ext-patches\|ext-patches-sync)* baked | The two commands that resolve and replay a patch selection are shipped. | Executable bit in `/usr/local/bin`. |
| the image records its patch selection | We know which selection the image was built with, without guessing by reading the bundle. | `printenv CLAUDE_CODE_EXT_PATCHS`. |
| …and records it as `none` | The default changed with the split; a build that silently went back to `all` would patch an extension that must ship unmodified. | Same variable, compared to a literal. |
| pristine copies of every rewritten file are baked | **Without pristine copies, `restore-ext-patches` has nothing to replay** and someone else's patcher becomes a one-way door. | `find /usr/local/share/claude-ext-orig`. |
| and the baked list is the fixed one, not an empty derivation | The list used to be the union of the shipped patchers' `@patch-files`. With none shipped that union is empty — this pins the three files instead. | Count of `.js`/`.json` under the backup root. |
| restore-ext-patches --list exits 0, finds 0 live, and says why | **An image that patches nothing is nominal, not broken.** `--list` must answer honestly and still succeed. | `--list` exit code, a count of ` yes` lines, and its "no patcher" wording. |
| the extension is byte-identical to the published VSIX | **"Installed and run as published" — the condition the whole split exists to satisfy.** The whole tree, not just the files a patcher would touch. | `sha256sum` over the extension tree, compared to the unpacked Marketplace VSIX for the version in the label. Skips loudly without `VENDOR_DIR`. |
| privilege.sh context A | **Firewall never started: the firewall control plane stays out of reach.** Sudo grants, config sources, `/usr/local/bin` machinery, frozen bake. | Dedicated suite, run as `node`. |
| escalation.sh context A | **Firewall never started: `node` cannot become root.** `setuid` binaries, file capabilities, root-writable files, Docker socket. | Dedicated suite ([§escalation](#escalation)), run as `node`. |
| capability-guard.sh | **A container that forgot `cap_add` is told so, in one actionable line, instead of dying on an iptables "you must be root".** | Dedicated suite ([§capability-guard](#capability-guard)), run as **root** in a container with Docker's default capability set — NET_RAW but no NET_ADMIN, which is what the absence of `cap_add` actually produces. |
| no env_keep/SETENV in /etc/sudoers.d (the env seams stay stripped) | **The one binary `node` launches as root with no password does not choose its own config.** `init-firewall.sh` reads `FIREWALL_CONFIG_DIR` and `DEVC_CONF_LIB` from the environment; an `env_keep` would turn those variables into "`node` names the config root, as root". | `grep` on `/etc/sudoers.d/`, run as root — `node` cannot read these files, which is exactly what `privilege.sh` asserts. |
| image declares no EXPOSE (nothing advertised host-ward) | **The image advertises no port to the host.** `EXPOSE` alone publishes nothing without `-P`, but the empty set is the frozen starting point: a port added here is a port a `docker run -P` would open without anyone having decided to. | `docker image inspect`, `.Config.ExposedPorts`. |
| *(project\|dockerbase)* compose publishes no ports | **The template publishes nothing to the host.** `otherPortsAttributes: ignore` only hides the VS Code display: it closes no port. The host → container direction had never been checked. | `grep` for a `ports:` key in both `templates/v3/` `docker-compose.yml` files. |
| *(project\|dockerbase)* compose mounts no Docker socket | **Escape to the host remains impossible.** A mounted socket is not an escalation to root *inside* the container: it's root *on the host*, and it renders every other assertion moot. | `grep docker.sock`. |
| *(project\|dockerbase)* compose is neither privileged nor host-networked | The container gets neither full privileges nor the host's network stack — otherwise the firewall confines nothing anymore. | `grep` for `privileged: true` / `network_mode: host`. |
| *(project\|dockerbase)* compose cap_add is exactly NET_ADMIN + NET_RAW | **Exactly the two capabilities `init-firewall.sh` needs, not one more.** A capability added in passing (`SYS_ADMIN`…) would widen the surface with nothing flagging it. | Frozen list, extracted from the `cap_add:` block. |

### B. Live container, `basic` mode

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| init-firewall.sh boots in basic | **The firewall really starts.** | Run in a privileged container. |
| second init-firewall run — skipped by the active guard | Rerunning it doesn't replay everything: a restart doesn't break the rules already in place. | Idempotence guard. |
| base allowlist resolves through dnsmasq | **An allowed name really resolves.** The allowlist isn't just a file: it produces a real DNS result. | Measured resolution. |
| privilege.sh context B | Same control-plane audit, but with the firewall started — the case where rules exist. | Dedicated suite. |
| escalation.sh context B | **Same escalation audit with `NET_ADMIN`/`NET_RAW` actually granted to the container** and the firewall running: the state a developer works in, where "capabilities stop at root" stops being theoretical. | Dedicated suite ([§escalation](#escalation)), `docker exec -u node`. |
| node-written domains.local.txt does not reach the live set | **A file written from the container is not added to the live set.** Otherwise any npm script would widen the confinement. | Written as `node`, live set unchanged. |
| 55-claude-creds-sync pulls from the shared volume | Credentials are fetched with no copy landing in the project. | Step run, result measured. |
| 75-skills-sync installs the baked skills (8 commands) | Shipped skills become commands, with no file on the project's side at all. | Count of installed commands. |
| a leftover v2 skills loader does not shadow the baked resolver | A half-migrated tree that still carries `skills/sync-skills.sh` gets the three-layer resolver, not its old single-layer script. | A probe loader dropped in `/workspace/.devcontainer/skills/`; the hook runs; the probe's sentinel must be absent. |

### C. Base + project compile

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| bake base+project = 34 hosts (≥ the 33 base hosts) | **A project's allowlist adds to the image's, it does not replace it.** A project cannot shrink the base by accident. | Real compile, count compared to the base. Both numbers follow the current allowlist. |

---

## `privilege` — can `node` widen the firewall itself? {#privilege}

**26 assertions · host, Docker · [`assets/etc-firewall/tests/privilege.sh`](assets/etc-firewall/tests/privilege.sh)**

The **control plane** pentest. `bypass` attacks the network path,
[`escalation`](#escalation) attacks the root boundary; this one attacks the
machinery: sudo grants, file ownership, the reload command, the frozen bake.
Every check asserts that an **unprivileged** process cannot widen the
allowlist — and that the two supported paths keep working.

Run in the same two contexts as `escalation`: A, throwaway container with no
capabilities, firewall never started; B, live container, ruleset present.
Checks that require a started firewall auto-skip in A (5 fewer), which
makes the same file valid on both sides.

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| *(×3)* sudo -n reload-firewall / arbitrary command (sh) / compile-policy.py | **The whole boundary is right there.** `reload-firewall` must NEVER be passwordless, and since `node` has no password, it must be out of reach. An arbitrary `sh` as root would make everything else decorative. | `sudo -n`, must fail. |
| NOPASSWD limited to init-firewall.sh + test-firewall.sh | **The grant inventory is frozen.** A binary added to the list would otherwise slip in unnoticed. | `sudo -n -l`, list compared word for word. |
| read /etc/sudoers.d (0440 root) | The policy itself is not readable from the container — so it can't be studied for a flaw. | `cat`, must fail. |
| *(×5)* write 00-base.txt / dnsmasq.conf, create a file in etc-firewall, policy.d, domains.d | **The firewall config is image content, not project content.** Otherwise an npm `postinstall` would widen the confinement in one line. | Write attempted as `node`. |
| *(×5)* write /usr/local/bin/{init-firewall.sh, compile-policy.py, firewall-digest.sh, reload-firewall, firewall-docker-setup.sh} | **The machinery is not rewritable.** Rewriting the policy compiler amounts to choosing the policy. | Same, on the five binaries. |
| *(×2)* write effective/sources.sha256, add to effective/ | **The frozen bake cannot be forged.** A falsified "effective" set would pass any list off as the image's own. | Same. Skipped if the image is not baked. |
| *(×3)* write the compiled policy / the dnsmasq conf, add to /var/run | **The live ruleset belongs to root.** This is the file the running firewall reads. | Same. Skipped if the firewall is not started. |
| *(×5)* ipset add / ipset flush / iptables -F / kill dnsmasq / kill mitmdump | **netfilter state is out of reach without CAP_NET_ADMIN**, and neither daemon can be killed. Killing dnsmasq alone would otherwise be enough to remove filtered resolution. | Commands attempted as `node`. |
| reload-firewall --dry-run (unprivileged preview) | **Previewing the diff is deliberately unprivileged**: it's safe, and an agent wanting a wider firewall must show a human what it's asking for. | Must succeed. Skipped if there's nothing to compare. |
| reload-firewall apply as node | …but applying it, no. | Must fail. |
| init-firewall.sh reachable via NOPASSWD | **The self-repair path stays open**: without it, a restarted container boots with no firewall. This is the one grant whose absence would be a security bug. | `sudo -n -l` on this specific binary. |

---

## `bypass` — does confinement hold against known bypasses? {#bypass}

**14 assertions · host, Docker · [`assets/etc-firewall/tests/bypass.sh`](assets/etc-firewall/tests/bypass.sh)**

The **network path** pentest, run from inside the container against an
actually-started firewall. Where `privilege` asks "can the rules be
changed?", this one asks "can they be bypassed without changing them?".

It detects the mode itself: with no mitmproxy, L4 attempts are reclassified
as informational rather than as bypasses, because in `basic` the L7 layer
doesn't exist and counting them as failures would misrepresent the contract.

| Family | What it guarantees | Mechanism |
|---|---|---|
| DNS bypasses | **Switching resolvers does not change the allowlist.** Querying a public DNS directly, or forging a response, must not open an unauthorized host. | Resolutions attempted outside the local resolver. |
| IP bypasses | **Skipping the name is not enough.** Reaching an IP directly, with no resolution, must fall back onto the ipset. | Connections to out-of-band-resolved IPs. |
| L4 attempts | SNI forgery, direct TLS — blocked in `strict` where mitmproxy inspects L7; documented as a known limit in `basic`. | Forged TLS connections. |
| Network layer | Routes, interfaces, alternate protocols: no parallel exit path. | Network manipulations attempted as `node`. |

Exits `1` the moment a bypass **succeeds** — a `❌ BYPASS` line. Silence is
not success: the final counter prints both numbers.

---

## `escalation` — can `node` stop being `node`? {#escalation}

**18 assertions · host, Docker · [`assets/etc-firewall/tests/escalation.sh`](assets/etc-firewall/tests/escalation.sh)**

`privilege.sh` attacks the **firewall control plane**: "can `node` widen the
allowlist?". This suite asks the question underneath: "can `node` become
root?" — the classic local escalation surface, which nothing else covered.

It is **shipped in the image** and only ever reads the image, never the
repo: so it's replayable by anyone against a published tag. An audit no one
else can rerun is a claim, not proof.

Run **twice**, in the same contexts as `privilege.sh`: A, throwaway
container with no capabilities, firewall never started; B, live container
with `NET_ADMIN`/`NET_RAW` granted and the firewall running.

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| SUID/SGID inventory matches the frozen list (12 binaries) | **No binary can run with rights it shouldn't have.** The image adds no `setuid` bit — freezing the inventory is what turns "we didn't add one" into a property that keeps holding: a base-image change, an apt package, a stray `RUN` show up here as a diff instead of silently widening the surface. | `find / -xdev -perm -4000 -o -perm -2000`, compared to a frozen list where each entry is justified. The diff names arrivals and departures. |
| getcap -r / is empty (no file carries a capability) | **No file carries a capability.** A capability is a `setuid`-like bit that `find -perm` cannot see: without this assertion, the inventory above is only half an inventory. | `getcap -r /`. If `getcap` is missing, the assertion **fails** instead of being skipped — otherwise it would evaporate silently and the suite would go green having measured nothing. `libcap2-bin` is installed explicitly for this reason. |
| no root-owned regular file is writable by node | **No file owned by root is rewritable by `node`.** Each one would be a code-injection point executed as root. | `find / -xdev -user root -type f -writable`. Symlinks are **deliberately** excluded: their permission bits are ignored by the kernel, so `-writable` there reports on the *target* and produces false positives — the real case being `/usr/local/bin/claude` → `/home/node/.vscode-server/…`, where `node` owns its own CLI, which has no effect since nothing launches it with privileges. |
| *(×6)* /usr/local/sbin … /bin not writable | **This is what makes `NOPASSWD` safe.** `sudo init-firewall.sh` launches a root script that calls `iptables`, `ipset`, `dnsmasq`, `dig` **by name**. A writable directory earlier in root's `PATH` would let `node` drop a fake `iptables` there for root to execute — an escalation that never touches the firewall config the other suite protects. | `-w` test on the six directories of root's `PATH`. |
| *(×3)* /var/run/docker.sock, /run/docker.sock, /var/run/docker/docker.sock absent | **All of the confinement rests on this.** A reachable socket is not an escalation to root *inside* the container: it's root *on the host*, and it renders every other assertion — here and in `privilege.sh` — moot. The template mounts none; ownership is asserted instead of trusting the template. | Presence test at the three usual locations. |
| CapEff is empty (0000000000000000) | **The capabilities granted to the container stop at root.** The template adds `NET_ADMIN`/`NET_RAW` so `init-firewall.sh` can program netfilter; an unprivileged process inherits none of it. | `CapEff` read from `/proc/self/status`. `privilege.sh` checks the same boundary on the netfilter side (`ipset`/`iptables`/`pkill` refused); here it's on the kernel side, where capabilities actually live. |
| CapPrm is empty (0000000000000000) | …and `node` cannot *acquire* them either, not just use them. | `CapPrm` in `/proc/self/status`. |
| open a SOCK_RAW socket (needs CAP_NET_RAW) — denied | The concrete thing `CAP_NET_RAW` buys. Denied ⇒ the capability is really absent, not just unlisted. | Raw socket opened in python3. |
| *(×2)* init-firewall.sh / devc-conf.sh references /workspace only in comments | **The invariant that carries everything else.** `init-firewall.sh` is the only arbitrary code path `node` can trigger as root with no password. The moment it reads a controlled byte from the workspace — a config, a domain list, a sourced library — that `NOPASSWD` becomes "`node` executes whatever it wants, as root". The bake-only migration closed this vector on purpose; this keeps it closed. | `grep '/workspace'` on the installed binaries, full-line comments stripped. Everything else counts as a real read. |
| /etc/devcontainer-firewall is root-owned | The config root it actually reads is image content, not project content. | `stat -c '%U'`. |

---

## `capability-guard` — when the firewall cannot start, does it say what is actually missing? {#capability-guard}

**13 assertions · host, Docker · [`assets/etc-firewall/tests/capability-guard.sh`](assets/etc-firewall/tests/capability-guard.sh)**

`init-firewall.sh` programs netfilter, which needs `CAP_NET_ADMIN`. Without it,
iptables answers `Permission denied (you must be root)` — the *same words* it
uses for a real uid problem, while the script is running as root under `sudo`.
The reader is sent looking at the wrong thing, and because
`on-create.d/10-firewall-init.sh` is `@required true`, the failure ends up
buried in a lifecycle log while the container boots with **no filtering at
all**.

The fixture is the whole point: **root**, in a container with Docker's default
capability set — `NET_RAW` but no `NET_ADMIN`, which is exactly what a compose
file missing `cap_add` produces. So the suite refuses both wrong contexts: not
root, or `NET_ADMIN` actually held.

The second half freezes an asymmetry worth knowing: `FIREWALL_MODE=off` boots
green and silent with no capability at all, **on purpose** — "off" means no
filtering, and that is what you get. Only `strict` and `basic` refuse.

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| G1 · exits 3 | **A code of its own.** `0` and `1` were already in use and `4` is iptables', so a missing capability stays distinguishable from a missing library or a dead dnsmasq. | Return code of a `strict` boot. |
| G1 · refuses before touching netfilter | **The refusal comes out before the misdirection.** The guard sits after the `off` bail and before the reset, so nothing has been flushed when it fires. | No `🔐 Resetting` line in the output. |
| G1 · no opaque iptables diagnostic | And the wrong message never appears at all. | No `you must be root` in the output. |
| G1 · says root is not the problem | **The one sentence the reader needs.** You *are* root; what you lack is a capability, and no amount of `sudo` will help. | Message. |
| G1 · names the missing capability | …and names it, rather than leaving it to be inferred. | Message. |
| G1 · says devcontainer.json cannot grant it | Stops the obvious wrong fix before it is attempted: `devcontainer.json` has no way to grant a capability. | Message. |
| G1 · hands over the compose block | The remediation is copy-pasteable, not described. | `cap_add` block present. |
| G1 · points at the README section | And the reasoning for each of the two capabilities is one link away. | Message names the README. |
| G2 · exits 0 | **`off` is left alone.** It flushes best-effort and yields the right result — no filtering — with no capability, so there is nothing to refuse. | Return code of an `off` boot. |
| G2 · the guard stays silent | The guard doesn't warn about a capability that mode does not need. | No `cap_add` in the output. |
| G2 · reports the firewall disabled | …and `off` still says what it did. | `✅ Firewall disabled` present. |
| G3 · still fails | An unprivileged caller does not get further than before: the uid really is missing. | `su node`, return code non-zero. |
| G3 · does not claim the caller is root | **The guard only speaks when it can tell the truth.** A non-root process reads `CapEff=0` even in a container that *holds* both capabilities, so firing on the probe alone would answer "you are already root" to someone who is not — the exact misdirection this guard exists to remove. It stays quiet, and iptables' message is, for them, the accurate one. | The refusal's wording absent from a `su node` run. |

---

## `port-gate basic` — does opening a host port open the host? {#port-gate}

**11 assertions · host, Docker · [`test/reload-basic-isolated.sh`](test/reload-basic-isolated.sh)**

The *packet filtering* half of the firewall contract, measured end to end: a
real container, a sibling container, two mini-servers on the host. This was
the repo's oldest debt — the suite existed but **no runner called it**, and
it had stayed welded to the v2 layout (it rebuilt a dead base image and
overwrote `/usr/local/bin` with the dogfood tree, so it was validating the
wrong binary).

**The witness, and why the setup is longer than the test.** A "blocked"
result means nothing if the target wasn't reachable to begin with: a
mini-server that never opened its port produces a green "blocked" for the
wrong reason. So the four endpoints are first proven reachable **from
outside the sandbox**, and any witness failure **aborts the run**
(`FATAL setup`) instead of reporting a passed assertion.

The witness has **a single point of view**: an unconfined sibling container
on the same network. That is exactly the tested container's network
position, minus the firewall — so reachable there and unreachable here is a
firewall result, and nothing else. In particular it does **not** query
`127.0.0.1` on the host side: that's a different network path than the one
under test, and it's contested on a developer's Mac (see below).

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| *(witness)* portal-test:4242 / :4241 answer (unconfined sibling) | **The test bench is alive before anything is measured.** | `wget` from a throwaway `busybox` on the same network. Failure ⇒ `FATAL setup`. |
| *(witness)* host.docker.internal:*(unlisted)* / *(seeded)* answer (unconfined sibling) | **The host gateway really routes there from container-land.** Without this witness, a gateway routing nowhere — or a mute server — would read as a firewall win. | `wget` from an unconfined `busybox`, with `--add-host`, retried. Failure ⇒ `FATAL setup`, with `docker logs` and `docker port` of the server in question. |
| basic marker present in init-firewall output | The firewall really did start in `basic` mode. | `Firewall ready (basic` marker in the output. |
| baseline HTTP=200 *(or 401/403)* | An allowed host reaches upstream **directly**, with no L7 proxy: this is what defines `basic`. | `curl` from the container. |
| example.org HTTP=000 (L3 DNS blocked as expected) | An unauthorized host is blocked — in `basic`, DNS is the only barrier. | dnsmasq NXDOMAIN ⇒ `curl` fails at resolution. |
| reload-firewall exited 0 | **Hot-widening the allowlist works**, with no container restart. | `reload-firewall` run as root via a pty. The `.local` layer lives in the container (`WORKSPACE_FW_DIR`), the host tree is never touched. |
| elapsed=Nms (< 500ms budget) | The reload stays near-instant: beyond that, it stops being used. | `elapsed:` line of the output. |
| example.org HTTP=200 (DNS + ipset cooperated on reload) | The added name is really reachable after reload — DNS **and** ipset both followed through. | `curl` after reload. |
| baseline still reachable — allowed-domains-base preserved | **A reload does not take out the base.** Otherwise widening the allowlist would break base access. | `curl` on the baseline after reload. |
| portal-test:4242 HTTP=200 (ports.txt ACCEPT beats the RFC1918 REJECT) | A port declared in `ports.txt` is reachable: the per-port `ACCEPT` really is inserted **before** the RFC1918 `REJECT`s. | `curl` to the sibling container. |
| portal-test:4241 HTTP=000 (RFC1918 REJECT catches the unlisted port) | **THE proof that the gate is per-port, not all-or-nothing**: same container, same IP, one declared port and one not. Witness reachability established above. | `curl` to the same sibling's undeclared port. |
| host.docker.internal:*(unlisted)* HTTP=000 (host isolated) | **The host is not open.** An undeclared host port is out of reach. | `curl` to the host gateway. |
| host.docker.internal:*(seeded)* HTTP=200 (per-port ACCEPT for the `host` keyword) | …**except the single port explicitly consented to**, via `ports.txt`'s `host` keyword. Both assertions together are the full promise: opening a host port opens *that port*, not the host. | Same, on the declared port. What it really pins down is *which address* the `ACCEPT` names: the `host` keyword resolves from `/etc/hosts` first — what glibc hands every client in the container — and only then via the Docker resolver. A rule punched for a different address than the one dialled reads exactly like a closed port. |

**The two "host" mini-servers are published-port containers**, not processes
launched by the script — and that detail cost three rounds of debugging. A
server backgrounded from this script failed in three ways indistinguishable
from the test, all reading as "the port doesn't answer": bash 3.2 (the one
macOS still ships) does not keep a backgrounded job alive inside a command
substitution; a generic bind `*:P` silently coexists with another process's
specific bind `127.0.0.1:P` — Code Helper (VS Code) occupies
`127.0.0.1:8765` — and the **specific** one wins; and a server that never
started says nothing at all.

Docker already being indispensable to this suite, publishing a `busybox
httpd` removes the "lifecycle" half entirely: the daemon owns the server, no
shell job semantics can lose it. Welcome side effect: no more node/python3
fallback, so assertions [11] and [12] can no longer be skipped.

That does not make the **port** itself safe, though — `-p <port>:80` is
also a generic bind, so it coexists with Code Helper with Docker flagging no
conflict at all, and `curl 127.0.0.1:<port>` keeps reaching Code Helper.
This is the underlying reason the witness never queries the host's loopback:
that path proves nothing about the path under test, and it fails for
reasons that have nothing to do with the firewall.

---

## `port-gate strict` — the same contract, with mitmproxy in the path {#port-gate-strict}

**14 assertions · host, Docker · [`test/reload-strict-isolated.sh`](test/reload-strict-isolated.sh)**

Strict twin of the previous one: same bench, same port contract, **plus**
the L7 layer that only exists here. The two suites share their test bench
([`test/lib/portgate-common.sh`](test/lib/portgate-common.sh)) — the witness
and the port choices exist in exactly one copy, precisely so basic and
strict don't diverge the way the v2 versions had.

**Why the four port assertions are replayed here.** The filtering rules are
emitted **before** the mode branch in `init-firewall.sh`: the per-entry
`--dport … -j ACCEPT` and the RFC1918 `REJECT`s form the same chain in both
modes, and `OUTPUT` evaluates them the same way whether mitmproxy exists or
not. Strict *should* therefore behave identically — but "should, per the
code" is not a measurement. If strict ever diverges, this is where it shows.

**They are measured with a direct curl, no proxy, deliberately.** In strict
the shell exports `HTTPS_PROXY`, but a hostile process does not honor it: it
opens a socket. Going through the proxy would measure the application's
politeness, not the sandbox. A corollary worth knowing, intended but rarely
stated: **a `ports.txt` entry is also a hole in the L7 audit**, not just in
the packet filter — traffic to a consented port never reaches mitmproxy.

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| mitmdump PID=N | **Strict really did start its L7 layer.** Without this, every L7 assertion below would be meaningless while still going green. | `pgrep -x mitmdump` in the container. |
| baseline HTTP=200 *(or 401/403)* | An allowed host crosses the proxy through to upstream. | `curl -x http://127.0.0.1:8080`. |
| example.org HTTP=403 *(or 000/502/504)* | An unauthorized host is refused — by the L7 addon (403) or already at DNS. | Same, before reload. |
| reload-firewall exited 0 | Hot-widening the allowlist also works in strict. | Run as root via a pty, `.local` layer in the container. |
| elapsed=Nms (< 500ms budget) | The reload stays near-instant despite the L7 layer. | `elapsed:` line. |
| example.org GET HTTP=200 | The added name is reachable: DNS, ipset **and** the addon's mtime-based reload all cooperated. | `curl` GET after reload. |
| example.org POST HTTP=403 | **Widening the allowlist does not widen the method policy.** A hot-added host is readable, not writable; if this returns 200, the reload quietly dropped the L7 check and strict silently became basic. | `curl -X POST` after reload. |
| baseline still reachable | No regression on the base after reload. | `curl` on the baseline. |
| mitmdump PID unchanged | **Zero downtime**: the addon is reloaded in place, in-flight connections don't drop. A different PID = proxy restart. | PID compared before / after. |
| portal-test:4242 HTTP=200 | Declared port reachable — the per-port `ACCEPT` runs before the `REJECT`, in strict too. | Direct `curl`, no proxy. |
| portal-test:4241 HTTP=000 | **The gate stays per-port, not all-or-nothing**, in strict too. | Same, same sibling's undeclared port. |
| host.docker.internal:*(unlisted)* HTTP=000 | **The host is not open.** If this passes, any process in the container reaches host services: that's a sandbox escape, and the witness proved the port was answering. | Direct `curl` to the gateway. |
| host.docker.internal:*(seeded)* HTTP=200 | …except the single port consented to via the `host` keyword. | Same, on the declared port. |

The four reachability witnesses apply here identically — same
`FATAL setup`, same single point of view (the unconfined sibling).

*Count note*: the witnesses are test-bench guards, not assertions — they
fail the **setup**, they measure nothing about the firewall. They are
therefore documented as `(witness)` lines in the tables but excluded from
the totals, which count only the `✔` assertions actually printed at
runtime.

---

## `extend` — someone builds from ours {#extend}

**34 assertions · host, Docker · [`test/extend.test.sh`](test/extend.test.sh)**

The only suite that **really builds** an image `FROM` the one under test and
runs it. This is the layer we publish and don't control: someone unknown
derives our image and adds their own stuff.

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| an image FROM devcontainer-sandbox:local builds with a hook, a skill, a firewall layer and a patch | **The extension contract holds at build time.** All four additions at once — building them separately would miss their interference. | Real `docker build` of a derived image. |
| a COPY'd fragment is enumerated: +1 | A step added by the derived image is accounted for. | Count compared to the base image. |
| and it is attributed to the ext layer | The log states where it comes from. | `(ext,` tag. |
| the ext fragment lands at its numeric place, not at the end | It's inserted at the right point. | Enumerated order. |
| and it really is in that list | Direct check of its presence. | Grep on the list. |
| shadowing a shipped fragment does not duplicate it | Replacing a shipped step does not run it twice. | Count of 1. |
| and the winner is the ext copy | …and it really is the derived version that wins. | Winning layer. |
| an ext skill becomes a command | A skill added by the derived image becomes a command. | File present after the run. |
| sync-skills reports no traceback | No visible Python error. | Absence of `Traceback`. |
| and its hooks.json is retargeted to the ext dir | Its automation points at the right path **inside the real image**. | Registered path. |
| with no project, ext wins over base | With no project, the derived image wins over the base. | Winning layer. |
| the project wins over ext | With a project, the project wins over both. | Winning layer. |
| still exactly one winner | Three layers, one run. | Count of 1. |
| disabledHooks reaches a fragment that came from the image, not the project | A project can disable a step it didn't write. | Skip observed. |
| an image FROM the extending one builds with the two disabled.txt | A third layer builds, carrying both lists. | `docker build` of one more thin layer. |
| ext/hooks/disabled.txt switches off a base fragment | **In a real image**: the derived image switches off a base step without shadowing it. | Skip observed. |
| and the ext layer's own fragment still runs | No side effect. | Marker present. |
| ext/skills/disabled.txt keeps a baked skill out of the commands | **In a real image**: the derived image removes a shipped skill. | The command is not installed. |
| and the other skills still install | The others are not swept away with it. | Non-zero count. |
| disabling 10-firewall-init.sh is refused | **Starting the firewall resists a project**, in the real image. | `REFUSED` message. |
| and it is still scheduled to run | The refusal is effective: the step stays scheduled. | `WOULD RUN` present. |
| the explicit ! opt-in does switch it off | The deliberate escape hatch remains possible. | Skip observed. |
| an ext domains.d file widens the allowlist: +1 host | A derived image can widen the network allowlist. | Host count. |
| and the added host is the one we declared | It really is the declared host, not a side effect. | Name checked. |
| the base layer is still there, not replaced | **Widening does not overwrite.** The network base remains. | Base hosts still present. |
| the shadowed fragment still exists in the base layer | **Shadowing does not erase.** The original stays on disk, traceable. | File present in `/opt/devcontainer/base`. |
| and the base copy is not the ext body | The two versions really are distinct. | Contents compared. |
| the naked image still resolves the base copy | **The original image was not altered** by what someone built on top of it. | Same check on the base image. |
| an ext image's own patcher reaches the bundle | **The fifth extension seam works**: a derived image can patch the VS Code extension via `/etc/claude-build-env`. | Sample patcher `COPY`'d into the patches folder, sentinel searched for in `extension.js`. |
| and --list reports it as live, next to the shipped ones | The added patch is a full-fledged patch, not an invisible second-class registry addition. | `restore-ext-patches --list`. |
| restoring with ux keeps a ux sentinel | **A selection replayed at runtime is real**, on an image pulled with no way to rebuild it. | `restore-ext-patches ux` then `grep` of the live bundle. |
| and drops the notify one | What's excluded really is gone — that's the promise that makes the `all` default acceptable. | `notify` sentinel absent after restoration. |
| restoring with none leaves no sentinel at all | `none` at runtime means `none` at build time. | No sentinel. |
| and restoring with all brings the ext patch back too | The derived image's patch is replayed with the others: that is what "full-fledged" buys, against a script run once from `/tmp`. | ext's sentinel present after `restore-ext-patches all`. |

---

## `release-check` — the release gate {#release-check}

**9 assertions · host + agent · [`test/release-check.sh`](test/release-check.sh)**
— outside `wtf image test`, entry point `wtf image release-check`.

This is not a suite and it is not launched by `run-all.sh`: it is the gate
played before a minor/major bump, eleven steps and **a three-tier verdict** —
`GREEN` / exit 0 (everything ran and was verified: *this image is
publishable*), `GREEN PARTIEL` / exit 2 (nothing failed, but at least one
step was deliberately not played), `RED` / exit 1 (a failure, or a step
skipped because something upstream broke). The eleven steps themselves are
documented in the script's header; what's tabulated here are the assertions
— the claims that can go red.

**One command, two halves**, dispatched on `/.dockerenv` like
[`run-all.sh:44`](test/run-all.sh#L44): the human on the Mac plays all eleven
steps and remains the only side able to exit 0; the agent plays headless
everything that does not need VS Code and marks steps 5/6/9 `∅`. Its success
path is therefore `GREEN PARTIEL`, never green — a green coming from the
container would not be a release-check, and `exit 0` must mean only one
thing.

| Assertion | What it guarantees | Mechanism |
|---|---|---|
| nested daemon proven — *(DOCKER_HOST)* cannot see *(container id)* | **The safety interlock.** On the agent side the gate rebuilds `devcontainer-sandbox:local` and does a clean sweep of everything bearing the throwaway project's name. Against the host daemon, those two moves would overwrite the operator's image and demolish the stack of a human run in progress. Proven before the first docker command that changes anything, `fatal` otherwise: there's no honest way to continue. | `assert_nested_daemon` — two clauses, neither sufficient alone: `DOCKER_HOST` matches `tcp://dind:*`, **and** `docker inspect $(hostname)` fails. `hostname` in a container is its own short id, so a daemon able to inspect it is, by construction, the outer one. |
| *(×2)* nested mount proven (nonce read back through the daemon): *(path)* | **The suites mount the real folder, not an empty one.** Under `DOCKER_HOST=tcp://dind:2375` a `-v`'s *source* is resolved by the nested daemon, and a source it cannot see is not an error: docker **creates an empty folder** and mounts that. "The fragment was applied" assertions then fall, but every "nothing leaked / no stray copy" assertion **passes vacuously**. Checked on the two paths actually handed to the daemon: `$REPO` and `$TMPDIR`. | `assert_nested_path` — writes a **fresh** nonce then reads it back via `docker run -v "$dir:/probe"`. A `[ -d ]` proves nothing (measured: on an unmounted source it answers *yes*, on an empty folder too) and a fresh nonce also fails on a stale copy. Failure ⇒ step 2-3 `FAIL`, never `SKIP`: `portgate-common.sh:51-57`'s doctrine, a dead bench is red. |
| 1. build --no-cache | **A green build actually baked a usable Claude Code extension** — `docker build` never fails on a Marketplace or copy problem by design (the extension falls back to a runtime install), so an exit-0 build alone proves nothing about what got baked. Left unchecked, a degraded image surfaces four steps later as unexplained failures in `run-image-suites.sh` and `extend.test.sh` instead of a named cause on the gate's first row. | Two anchored greps against `$BUILD_LOG`, one per failsafe branch in the Dockerfile's VSIX RUN: `VSIX download/extract failed` (Marketplace unreachable) and `VSIX copy incomplete` (`cp -a` into `$EXT_DIR` did not finish — disk pressure, a stale mount). Both anchor on buildkit's own `#<n> <secs> ` output prefix, never on the unanchored text, because buildkit re-echoes each `RUN`'s source — including the literal `echo` text of its own else branch — before running it. |
| 4b. stack without VS Code | **The agent gets a real container with no VS Code**, which steps 7a and 8 need. And a *complete* container: `compose up -d` alone would only launch the image's `sleep infinity` — no lifecycle log, and above all **no firewall**, so step 8 would grep a `/var/log/mitmproxy.log` that was never created and report its healthy branch. A green that proves nothing. | `docker volume create` of the creds volume (the template declares it `external: true`, compose refuses to start otherwise, and the nested daemon has none of the host's volumes), then `compose up -d --build`, then the three phases the VS Code orchestrator launches: `docker exec -u node … devc-hook {on-create,post-create,post-start}`. |
| 7a. collect (lifecycle logs) | **The lifecycle hooks really did run.** Step 7's real assertion was never visual: it counts the logs written by `devc-hook`, a container-side script. Only the Dev Containers trace copy is VS-Code-specific — hence the 7a / 7b split. | Counts `logs/<phase>-*.log` under `$SCRATCH/.devcontainer`. **3 agent-side, 4 host-side**, and the gap isn't a choice: the fourth, `initialize-*.log`, is written host-side by `initialize.sh` from `initializeCommand`, and that script is interactive. The ledger detail names the three. |
| 10b. docker save | **The human does not repay the build.** The image the agent builds lives in the nested daemon's store, invisible from the host: this tar is what makes inheritance possible. The preflight isn't ceremony — `docker save` needs room in three places at once and a truncated tar *looks like* an artifact. | `df -Pk` against the size `docker image inspect` reports +25%, then `docker save`, then `tar -tf`: readability is the proof the stream completed, since `docker save` can exit 0 having written short. The tar lives under `.tmp/` and **never** under `$REPO`, which is step 1's build context and has no `.dockerignore`. |
| agent half accepted — tier *(tier)*, *(date)* | **A broken or stale agent verdict cannot contaminate the human run.** Inheritance is an optimization, never a dependency: at the slightest doubt nothing is recovered and everything is replayed, exactly as before section 0b existed. A stale tar costs time, never correctness. | Two independent guards: the agent trailer's `tier=` must be `GREEN` or `GREEN_PARTIEL`, **and** freshness via `find … -newer "$AGENT_LOG" -print -quit` with `-prune` on `results` — exactly `run-all.sh:178-179`, where the `-prune` is what stops the log just written from making the other side look stale. |
| image loaded and identified: *(sha256)* | **The tar IS the artifact the log describes.** Deliberately independent guard from the previous one: it catches what freshness cannot see — a truncated `docker save` that still loaded, a tar from another run, a hand-edited log. Depends on no mtime: these files cross a virtiofs bind mount. | `docker load` then `docker image inspect -f '{{.Id}}'` compared to the handshake's `imageid=`. A mismatch ⇒ nothing is inherited; that's harmless, step 1's `--no-cache` build re-tags right below anyway. Inherited steps are recorded `PASS` with `↩ inherited` in the detail — so `sev` 0 by construction, no sixth status to defend. |

**What the gate publishes, and for whom.** Each half writes
`test/results/release-check-<side>.log` and two machine lines at the end,
the second always the second-to-last line before `__END__`:

```
## RELEASE-CHECK-HANDSHAKE steps=1,2-3,4,4b,7a,8,10,10b imageid=sha256:… tar=.tmp/release-check/image.tar date=…
## RELEASE-CHECK tier=GREEN_PARTIEL exit=2 green=8 partial=3 red=0 date=…
```

Two lines and not one, because these are two questions: the trailer says
*how this run ended* and fires on every path, including `fatal`; the
handshake says *here is the artifact and the steps it covers*, exists only
agent-side, and only on a run that got far enough to have one. `steps=`
lists only `PASS` steps, so a step that was omitted, skipped, or played by
the human can never be inherited. `date=` stays last on both — the
project's parse idiom is `sed -n 's/.*date=//p'`.

**An interrupted run publishes a trailer too, and it carries no verdict.**
Ctrl-C at one of the four typed prompts — or a `SIGTERM` — ends the run before
step 11, so the tier is `INTERRUPTED` and the three counts are `-`, the shape
`fatal` already uses for counts it cannot know:

```
## RELEASE-CHECK tier=INTERRUPTED exit=130 green=- partial=- red=- date=…
```

`exit=` is `130` for `SIGINT` and `143` for `SIGTERM`, values the three verdict
codes can never take. It is the one `tier=` that is not a verdict, and section
0b treats it like any other non-green: the human half replays everything.
Before it existed an interrupted run published nothing at all — the sentinel
landed on the interrupted prompt's line, which prints no trailing newline, so
watch-log's `grep -E "^(__END__|FATAL)$"` never matched and an interrupted run
was indistinguishable from a hung one.

The prefix is `## RELEASE-CHECK`, **not** `## VERDICT`: `run-all.sh` greps
the latter out of `test/results/*.log` to reconcile its two halves, and this
gate's output landing there some day would poison the parse.

---

# Technical appendix

## File map

| File | Half | Target |
|---|---|---|
| `test/run-all.sh` | — | entry point: detects context, dispatches, renders the verdict |
| `test/conf.test.sh` | container | `bin/devc-conf.sh` |
| `test/manifest.test.sh` | container | the repo tree, the `Dockerfile` |
| `test/run-firewall-suites.sh` | container | launches the 4 suites in `assets/etc-firewall/tests/` |
| `test/toolkit.test.sh` | container | `assets/vscode-ext-patchs/` — the toolkit contract: `PATCH_DIR`, selection, refusals |
| `test/overlay.test.sh` | both | `bin/devc-hook`, `bin/sync-skills` — splits itself in two |
| `test/run-image-suites.sh` | host | the built image |
| `test/extend.test.sh` | host | an image `FROM` the one under test |

## The verdict and its persistence

Every run writes `test/results/<side>.log` (gitignored) and reads back the
**other** side's log. A pass is complete only if both are green **and** the
log across the way is newer than every file in `bin/`, `assets/`, `test/`,
`Dockerfile` — hence the `<- STALE: the code changed since`.

On the host, `run-all.sh` replays the container half inside a throwaway
container of the image:

```bash
docker run --rm -v "$REPO:/repo" -w /repo "$IMG" bash test/run-all.sh --no-inner
```

Never inside the repo's own devcontainer: that one runs a **different**
image and would test the wrong binary.

**The exit code says nothing here, and a lot in the release gate.**
`run-all.sh` exits 0 as soon as no suite is broken — a *skipped* suite does
not fail it, because its verdict lives in the logs and their cross-side
reconciliation, not in an integer. The [release gate](#release-check) does
the opposite and its exit code carries three meanings: **0 GREEN**
(publishable), **2 GREEN PARTIEL** (nothing failed, but a step not played
or reserved for the other half), **1 RED** (a failure, or a step skipped
because something upstream broke). It writes
`test/results/release-check-<side>.log` — one per half, never a shared path
— next to `release-check-build.log`. `exit 0` must mean only one thing, so
the agent half exits **2** on its success path, never 0.

## Environment seams

The suites never overwrite machine state. Every path is injectable, and the
default is the image's layout:

| Variable | Default | Redirected by |
|---|---|---|
| `DEVC_CONF_LIB` | `/usr/local/bin/devc-conf.sh` | `run-firewall-suites.sh`; otherwise "sibling first" resolution |
| `DEVC_BASE_HOOKS` / `DEVC_EXT_HOOKS` / `DEVC_OVERLAY_HOOKS` | `/opt/devcontainer/{base,ext}/hooks`, `/workspace/.devcontainer/hooks` | `overlay.test.sh` |
| `DEVC_BASE_SKILLS` / `DEVC_EXT_SKILLS` / `DEVC_OVERLAY_SKILLS` | same, `skills` | `overlay.test.sh` |
| `DEVC_CLAUDE_HOME` | `/home/node/.claude` | `overlay.test.sh` |
| `DEVC_CONFIG_DIR` | `/workspace/.devcontainer` | `overlay.test.sh` |
| `FW_INIT` / `FW_BAKE` / `FW_RELOAD` / `FW_DIGEST_LIB` | `/usr/local/bin/…` | `run-firewall-suites.sh` |
| `FIREWALL_CONFIG_DIR` | `/etc/devcontainer-firewall` | the firewall suites |
| `CLAUDE_CODE_EXT_PATCHS` | `none` | `toolkit.test.sh` for every selection form; build ARG |
| `ORIG_DIR` / `PATCH_DIR` / `BUILD_ENV` | `/usr/local/share/claude-ext-orig`, `/usr/local/bin/vscode-ext-patchs`, `/etc/claude-build-env` | `restore-ext-patches`, to replay it against a throwaway extension |
| `IMG` | `devcontainer-sandbox:local` | the caller |

This is what makes it possible to test `sync-skills` against a throwaway
fake `~/.claude` instead of the user's own.

## Writing an assertion

```bash
PASS=0; FAIL=0
ok()      { PASS=$((PASS+1)); printf '  ✔ %s\n' "$1"; }
ko()      { FAIL=$((FAIL+1)); printf '  ✘ %s\n' "$1" >&2; }
check()   { if eval "$2" >/dev/null 2>&1; then ok "$1"; else ko "$1"; fi }
checkeq() { [ "$2" = "$3" ] && ok "$1" || ko "$1"; }
```

Three conventions:

- **The label describes the behavior, not the code.** "a markdown-only
  override swaps the body", not "test 14". This is what you read when it
  breaks, months later — and it's this document's left column.
- **A stale label is a bug.** "// comments do not break jq" stuck around
  after `jq` was gone; fixed at the same time as this document.
- **`ko` writes to stderr.** Counting `✘`s from stdout alone gives a false
  green. Read the summary line, or merge both streams.

## The mutation discipline

An assertion that doesn't know how to go red tests nothing. Before
shipping: break the code on purpose, check the suite falls, restore it.

```
prune loop disabled            red (11 failing)
shipped prefixes forgotten     red (16 failing)
<SKILLS> guard dropped         red (11 failing)
only the first dir checked     red (2 failing)
```

A mutation that stays **green** is information. Three findings:

- an explicit `\r` strip that did nothing — `\r` is already in
  `[:space:]`, the trailing trim already caught it;
- a per-phase filter in `devc-hook` that duplicated an exact comparison
  made further down;
- and, the other way around, `conf_entries` returning a non-zero exit code
  on a file ending in a blank line — enough to kill a caller under `set -e`.

## Adding a test

1. Put it in the suite that answers the same question. Only create a new
   one if the question is new — and then wire it into `run-all.sh` with its
   gate (`$HAS_GNU` or `$HAS_DOCKER`).
2. Mount the fixture in a `mktemp -d`, leave it **exactly as found**:
   neighboring assertions count entries.
3. Mutate it and watch it go red.
4. Replay both halves.
5. **Add it to this document**, in both columns.

## What stays out of scope

For the list to be useful, here's what no assertion covers:

- **VS Code window rendering.** Six checks remain an eyeball judgment
  (model badge, `/model` picker contents, window title, extension count at
  a glance): no headless equivalent replaces them, and the
  [release gate](#release-check) marks them `∅` agent-side. A nuance since
  it exists: *opening* the window and *proving the gesture happened* are no
  longer manual — it drives `code --folder-uri` and requires a Dev
  Containers trace newer than the wait and naming the right workspace,
  rather than a typed "ok" taken at face value.
- **GHCR publishing.** The `push`, going public, the anonymous `pull`.
- **Multi-architecture.** The suites run on the current architecture.
- **Dogfood.** This repo's `.devcontainer/` is still the old image
  and is not the target of any suite.
