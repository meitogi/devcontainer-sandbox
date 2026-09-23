# Authoring `.wtfcmd.yaml` (task runner — `wtf` baked in base image)

`wtf` ([blunt1337/wtfcmd](https://github.com/blunt1337/wtfcmd)) is a task runner that reads `.wtfcmd.{json5,jsonc,json,yaml,yml}` in the current directory (walking up to 10 parents) and exposes its entries as sub-commands. The binary is installed by [Dockerfile.base](../Dockerfile.base) ; runtime doc hosts (`wtf.blunt.sh`, raw GitHub, release-metadata API) are allowlisted in [firewall/domains.txt](../firewall/domains.txt). This section is the cheat-sheet for **writing** a `.wtfcmd.yaml` — for canonical reference, see the links at the bottom.

**Minimal example (5 lines):**

```yaml
- name: greet
  args:
    - name: who
      required: true
  cmd: echo "Hello {{ esc .who }}"
```

Run: `wtf greet alice` → `Hello alice`.

**Discovery order** (`wtf/main.go::findConfigFiles`) : at each level from cwd up to 10 parents, try `.wtfcmd.json5` → `.jsonc` → `.json` → `.yaml` → `.yml`. Configs merge ; a child entry with the same `group`+`name` overrides the parent.

**Top-level = array of command objects.** Each object :

| Field | Type | R/O | Notes |
|---|---|---|---|
| `name` | string \| `[name, alias]` | R | Regex `^[\p{L}0-9][\p{L}0-9:._-]*$`. Index 0 = full name ; index 1+ = single-letter aliases. |
| `cmd`  | string \| array \| `{bash, powershell}` | R | Go `text/template`. Array entries joined by `\n`. Object form picks per-OS shell. |
| `group` | string \| array | O | Sub-command grouping (see below). Same alias rule as `name`. |
| `desc` | string \| array | O | Help text (strongly recommended). |
| `cwd`  | string \| object | O | Working dir before exec ; relative to the config file's dir. |
| `args` | array of `ArgOrFlag` | O | Positional args — order matters. |
| `flags` | array of `ArgOrFlag` | O | `--name value` style. |
| `envs` | map\<string,string\> | O | Extra env vars exported into the shell ; templated like `cmd`. |
| `stop_on_error` | bool | O | Default `true` — prepends `set -e` (bash) or `$ErrorActionPreference = "Stop"` (powershell). |

**`ArgOrFlag` (entries inside `args:` / `flags:`)** :

| Field | Type | R/O | Notes |
|---|---|---|---|
| `name` | string \| `[name, alias]` | R | Args take a single name (no alias) ; flags accept aliases. |
| `desc` | string \| array | O | Help text. |
| `required` | bool | O | **Args only** — flags cannot be required. Required args cannot follow optional. |
| `default` | any (non-object) | O | Fallback ; mutually exclusive with `required: true`. |
| `is_array` | bool | O | Only the **last** arg or last flag may be an array. |
| `test` | string | O | Validator — built-ins `$bool`, `$int`, `$uint`, `$float`, `$number`, `$file`, `$dir`, `$dir/file`, `$json`. Anything else = regex against raw value. |

**Constraints enforced by `wtf/parser.go`** :
- Required args cannot follow optional args.
- Only the last arg/flag may have `is_array: true`.
- Args cannot have aliases ; flags can.
- Flags cannot be required.
- `required: true` + `default` = mutually exclusive.
- `is_array: true` + `test: $json` = rejected explicitly.
- Names across all args + flags of the same command must be unique.

**Sub-commands** — an entry whose `group` matches another's `name` (or a separate `group`). Multiple entries sharing a `group` form the sub-command set :

```yaml
- group: [docker, dkr]
  name: [start, s]
  cmd: docker compose up -d

- group: [docker, dkr]
  name: [stop, S]
  cmd: docker compose down
```

Aliases are case-sensitive (`s` vs `S` are distinct — useful for start/stop pairs). Call : `wtf docker start`, `wtf dkr s`, `wtf docker stop`, `wtf dkr S`. `wtf docker --help` lists the sub-commands ; `wtf docker start --help` shows that entry's args/flags.

**Templating** (Go `text/template`) — variables come from arg/flag `name[0]`, with `: . _ -` collapsed to `_`. So `name: [my-arg, m]` is `{{ .my_arg }}` inside `cmd`. Helpers from `wtf/exec.go::getTplFuncs` :

- **String** : every Go `strings` function (`contains`, `split`, `join`, `replace`, `toUpper`, `toLower`, `trim`, …) — first char lower-cased.
- **Escaping** : `esc` / `escape` (shell-safe quote), `raw` / `unescape` (reverse).
- **JSON** : `json obj [pretty]`, `jsonParse "<string>"`.
- **CLI snippets** (colored prefixes) : `info`, `made` (`[+]`), `warn` (`[-]`), `error` (`[x]`), `panic` (`[x]` + exit 1), `ask`, `askYN`, `read`, `readSecure`, `bell`.
- **Env** : `setEnv NAME VALUE` (OS-aware export), `configdir` (dir of the matching `.wtfcmd.*`).
- **Terminal** : `isBash`, `isCmd`, `isPowershell`, `getTerminal`.

**Reserved flags** (`wtf/router.go`) :

| Flag | Effect |
|---|---|
| `--help` (also `-h`, `-H`, `-?`) | Context-sensitive help. `wtf --help` lists everything ; `wtf <cmd> --help` shows that entry's args/flags/desc. |
| `--debug` | Prints the resolved command **before** exec — closest thing to a dry-run. |
| `--autocomplete` | `wtf --autocomplete install` wires shell completion into the user profile. |
| `--builtin` | Internal (autocomplete dispatch). |
| `--` | End-of-flags marker — everything after is positional. |

**No `--version`** and **no `--verbose`** flag exist. `--debug` is the only inspection mechanism. Smoke-test = `wtf --help` (exit 0 even without a config file).

**Common errors → remedy** :

| Error | Fix |
|---|---|
| `Required argument cannot follow an optional one` | Reorder `args:` — required first. |
| `Only the last argument can have is_array` | Move the variadic to the bottom. |
| `Flag cannot be required` | Use an `args:` entry, or supply `default:`. |
| `Required field cannot have a default` | Drop one of `required: true` / `default:`. |
| `Duplicate name` | Args + flags share one namespace per command — rename. |
| `Invalid name` | Match regex above ; aliases must be single-letter. |
| Command not found at runtime | You're above any `.wtfcmd.*` file (10-parent lookup) or filename misnamed. |

**Debug recipes** :

1. `wtf <cmd> --debug` — prints the templated command before exec.
2. `{{ info "x =" .x }}` inside the template — runtime trace inside loops/conditions.
3. `{{ configdir }}` inside the template — prints which `.wtfcmd.*` matched (useful when a parent file is shadowed).
4. `wtf <cmd> --help` — re-prints the `desc` + args + flags : quick way to verify the right file was loaded.

**Common recipe — passthrough command** for wrapping another CLI (e.g. `wtf notif dev -- send --title T --body B` forwards `send --title T --body B` to a binary) :

```yaml
- group: notif
  name: dev
  cwd: ./apps/notifier
  desc: |
    Build (debug) + run the Mach-O with arbitrary passthrough args.
    Example : wtf notif dev -- send --title Hello --body World
  cmd: |
    cargo zigbuild --target aarch64-apple-darwin --bin notif >/dev/null
    ./target/aarch64-apple-darwin/debug/notif {{ range .args }}{{ esc . }} {{ end }}
  args:
    - name: args
      desc: Arguments forwarded verbatim to the notif binary.
      is_array: true
```

Key points :

- `is_array: true` on the last (and only) arg makes it variadic.
- Callers separate the wtf-side flags from the passthrough with `--` — `wtf notif dev -- --title T --body B`. Without `--`, `--title` would be parsed as a wtf flag and fail with `flag title not found`.
- `{{ range .args }}{{ esc . }} {{ end }}` iterates each token and shell-escapes it — safe for spaces / quotes / shell metachars.
- `cwd: ./apps/notifier` — leading `.` resolves relative to the config file (root `.wtfcmd.yaml` → `<repo-root>/apps/notifier`), so the caller can `wtf notif dev` from anywhere.

**Canonical links** (escape hatch when this section stales — runtime-fetchable via [domains.txt](../firewall/domains.txt) `wtf.blunt.sh` + `*.githubusercontent.com /blunt1337/wtfcmd/*`) :

- Doc site : <https://wtf.blunt.sh>
- Repo + releases : <https://github.com/blunt1337/wtfcmd>
- Schema doc : `https://raw.githubusercontent.com/blunt1337/wtfcmd/gh-pages/src/pages/02-command_definition.md`
- Template helpers doc : `https://raw.githubusercontent.com/blunt1337/wtfcmd/gh-pages/src/pages/03-template.md`
- Parser source (validation rules) : `https://raw.githubusercontent.com/blunt1337/wtfcmd/master/wtf/parser.go`
- Lookup-order source : `https://raw.githubusercontent.com/blunt1337/wtfcmd/master/wtf/main.go`
- Reserved-flag source : `https://raw.githubusercontent.com/blunt1337/wtfcmd/master/wtf/router.go`
- Templating source (`getTplFuncs`) : `https://raw.githubusercontent.com/blunt1337/wtfcmd/master/wtf/exec.go`
- Repo's own `.wtfcmd.yaml` (real-world sample) : `https://raw.githubusercontent.com/blunt1337/wtfcmd/master/.wtfcmd.yaml`
- Latest release JSON (API) : `https://api.github.com/repos/blunt1337/wtfcmd/releases/latest`
