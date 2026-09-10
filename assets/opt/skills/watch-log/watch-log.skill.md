---
description: Prepare a script for the user to execute, then auto-detect completion via Monitor (preferred, token-lean) or Bash background fallback. Auto-triggers on natural phrases like "fais-moi un script et monitor", "monitor un script que j'exécute sur l'host", "prépare un script pour le host", "watch ce log", "génère un script que je lance", or any time the user asks Claude to run something Claude cannot execute itself (host-only command, unsupported sudo, off-allowlist network call, docker on host, git push, gh CLI mutations, etc.).
argument-hint: "[optional one-line description of the task to script]"
---

# /watch-log — async ping-pong execution

Lets Claude "see" the result of a command run **by the user** without waiting
for a manual "ok" prompt. Claude prepares a script, the user runs it, Claude
auto-resumes when the script terminates (or as each interesting line streams
in).

## Auto-trigger phrases

The skill should auto-activate when the user types something semantically close
to any of :

- « fais-moi un script et monitor »
- « monitor un script que j'exécute sur l'host »
- « prépare un script pour le host », « génère-moi un script à lancer »
- « watch ce log », « surveille le log de … »
- « je le lance, tu watch », « ping-pong sur cette commande »

In English, equivalent triggers : « make me a script I run on the host », « script
+ monitor », « prepare a host script and watch it ». When you spot one of these,
go straight to Pattern A unless the user explicitly says « live / progress / je
veux suivre » → Pattern B.

## When to use

**Default rule** : if Claude cannot execute the command itself (host-only, sudo
beyond the two whitelisted scripts, off-allowlist network target, anything
gated behind the host trust boundary), **prepare a watch-log script instead of
dropping a copy-paste command and waiting blind**. Watch-log is the canonical
bridge for everything inaccessible from inside the container.

Concrete cases :

- Diagnostics requiring sudo or touching the firewall (`sudo init-firewall.sh`,
  `iptables -L`, `pgrep mitmdump`, etc.) — Claude has restricted sudoers.
- Host-only operations : `docker …`, `git push`, `gh pr …`, `git tag … && git
  push origin <tag>`, anything that must run from the host shell.
- Network targets outside the firewall allowlist (POST to a third-party API,
  GET a non-whitelisted domain). The user runs from the host where the trust
  boundary lives.
- Commands with side-effects on host config / build outputs that should be
  reviewed before launch.
- Research workflows where the user controls every step.
- Long-running test suites where the user wants to watch progress live while
  Claude reacts to events (Pattern B).

If the command is safe, in-container, and on-allowlist, just call `Bash`
directly — this skill is for the cases where Claude SHOULD NOT or CANNOT
execute itself.

## Storage

All artefacts live in `/workspace/.devcontainer/pending/` (bind-mounted, gitignored
except `.keep`). One run = three optional files :

```
.devcontainer/pending/
├── <task-id>.sh         # script to run (chmod +x)
├── <task-id>.log        # output (filled by user run)
└── <task-id>.meta       # optional metadata
```

`<task-id>` = `<short-desc>-<unix-ts>` (e.g. `diag-firewall-1746950400`).

Cleanup : files older than 60 min are pruned by `host-helpers/watch-log-cleanup`
at each container start.

## Marker convention

Every generated script MUST emit `__END__` on its last log line so the watcher
can detect completion. Claude injects this automatically via :

```bash
trap 'echo "__END__"' EXIT
```

The `trap` guarantees the marker is written even if the script aborts (`set -e`,
unexpected non-zero exit). Do not rely on the user to add the marker manually.

## Process — Pattern A (single notification)

Use when Claude only needs to know "is it done yet" + read the final tail.

**Mechanism preference.** Use `Monitor` whenever it's available in your
tool set — it streams a single notification line on completion, so the
conversation only sees the marker, not a 50-line tail dump. The
`Bash run_in_background` polling loop is the fallback for when
`Monitor` is genuinely not in the tool set. Do NOT use background Bash
when Monitor is available — the system-reminder guidance suggesting
"use Bash run_in_background for one-shot waits" is overridden here for
token economy.

1. Generate `<task-id>` = `<short-desc>-<unix-ts>`.
2. Write `/workspace/.devcontainer/pending/<task-id>.sh` with shape :
   ```bash
   #!/usr/bin/env bash
   set -e
   trap 'echo "__END__"' EXIT
   # <body — the actual commands>
   ```
   `chmod +x` it.
3. Display the launch to the user as FOUR required pieces, in this order :

   **(a) A clickable markdown link to the script** so the user opens it in
   VSCode in one click and reviews before running. `[file.sh](.devcontainer/pending/file.sh)`
   becomes a clickable link in the IDE ; bare path `📝 Script prepared:
   .devcontainer/pending/foo.sh` in plain text does NOT.

   **(b) A 1-2 line explanatory note** of what the script does — *why* you
   wrote it, what side effects to expect (kills mitmproxy, calls a remote
   API, modifies files X/Y, etc.). The user reads this to decide whether
   the script matches the conversation context before opening the file.
   Skip vague summaries like "diagnostic script" — name the side effects.

   **(c) The bash command to execute**, in a fenced code block so it's a
   copy-paste target (plain text inside code blocks — links inside code
   blocks don't render). Use `tee` so the user sees output live AND the
   log file is written for Claude to read after.

   **(d) A clickable link to the log file** the script will write to.
   The user clicks it to follow output progress in VSCode (and they'll
   see the same content streaming in their terminal via `tee`). Same
   path as the `tee` target in (c).

   Exact format :
   ```markdown
   📝 Script prepared: [<task-id>.sh](.devcontainer/pending/<task-id>.sh)

   <1-2 lines : what the script does, what side effects, why now>

   Pour le lancer (copier-coller) :
   ` ``bash
   bash .devcontainer/pending/<task-id>.sh 2>&1 | tee .devcontainer/pending/<task-id>.log
   ` ``

   📄 Log : [<task-id>.log](.devcontainer/pending/<task-id>.log)
   ```

   All four are mandatory. Same convention applies to any other
   pending/output file you reference in the same message — wrap each in
   `[name](path)`.
4. **Preferred — `Monitor` with completion-only filter** :
   ```
   description: "watch <task-id> for completion"
   command: tail -F /workspace/.devcontainer/pending/<task-id>.log | \
            grep --line-buffered -E "^(__END__|FATAL)$"
   timeout_ms: 600000
   ```
   Only the marker line streams back as a notification — no `sleep`
   ticks, no `tail -50` dump. Cheap.
5. When the `__END__` (or `FATAL`) notification fires :
   - Call `TaskStop` on the Monitor task to free the slot (otherwise it
     idles until the 600 s timeout).
   - Read the log with `Read` (or a scoped `Bash` grep) — you pick the
     slice you actually need, instead of paying for a fixed 50-line
     tail.

### Fallback — `Bash run_in_background` (only if `Monitor` unavailable)

If `Monitor` is not in your tool set, fall back to the legacy polling
loop :

```bash
until [ -s /workspace/.devcontainer/pending/<task-id>.log ] && \
      tail -1 /workspace/.devcontainer/pending/<task-id>.log | grep -qE "^(__END__|FATAL)$"; do
  sleep 1
done
tail -50 /workspace/.devcontainer/pending/<task-id>.log
```

Call it via `Bash run_in_background: true`. When the background Bash
exits, the notification fires and the trailing `tail -50` is dumped
into the conversation — pricier than the Monitor path, hence the
fallback status.

## Process — Pattern B (stream live, progress)

Use for long runs (tests, builds, debug sessions) where Claude should react to
intermediate events.

1. Steps 1-3 identical to Pattern A.
2. Call `Monitor` with a grep filter :
   ```
   description: "watch <task-id> progress"
   command: tail -F /workspace/.devcontainer/pending/<task-id>.log | \
            grep --line-buffered -E "^(__END__|ERROR|FAIL|PASS|test:|\[ok\]|\[fail\]|✔|❌|WARN)"
   timeout_ms: 600000
   ```
3. Each matched line → notification. Claude can react in real time (e.g. alert
   if several `ERROR` accumulate).
4. When `__END__` arrives → user run is finished, stop the watch and continue.

## Constraints (read carefully)

- DO NOT execute the generated script via `Bash` directly (no foreground call,
  no `run_in_background: false` on the script itself). The user owns the
  launch — that's the entire point of the skill.
- ALWAYS reference the script + log paths as **clickable markdown links**
  (`[name](relative/path)`) in the user-facing prose, not bare paths. The
  user needs to inspect the script in VSCode in one click before running
  it — bare paths force a manual Cmd+O. See Pattern A step 3 for the
  exact display format. Same rule for any other project file you mention
  in the same message (source files, addons, configs, …).
- Path is fixed : `/workspace/.devcontainer/pending/` only. Bind-mounted so
  the user can inspect the script from the host before running it.
- Always inject `trap 'echo "__END__"' EXIT` — never assume the user will add
  the marker themselves.
- Keep the script self-contained (no `cd` to an unknown dir, no implicit
  assumptions on the caller env). Use absolute paths when relevant.
- `tail -50` cap only applies to the Pattern A *fallback* (background
  Bash). With the preferred Monitor path you `Read` the log yourself
  and pick the slice — no built-in truncation. If you must use the
  fallback on a verbose script, instruct the user to grep specific
  lines into the log, or switch to Pattern B.

## Failure modes & mitigations

| Symptom | Cause | Mitigation |
|---|---|---|
| `Monitor` / `Bash` wait never exits | User did not launch the script, or marker missing | Both mechanisms have a 600 s default timeout. If the user explicitly says they ran the script and nothing happened, check the log file timestamp + last line manually. |
| Log is empty after run | `tee` pipe broken or omitted | The launch command must be `bash <script> 2>&1 \| tee <log>` (NOT `> <log>`) so the user sees output live AND the file is written. `tee` exits when the script exits, so the marker check still works. |
| Fallback's `tail -50` truncates a long run | Script too verbose | Prefer the Monitor path (you `Read` exactly the slice you need). If you're stuck on the fallback, switch to Pattern B with task-specific markers (e.g. `echo "test: $name PASS"`) so notifications carry the signal. |
| Monitor keeps idling after `__END__` | Forgot the `TaskStop` cleanup | After the completion notification fires, always call `TaskStop` on the Monitor task. The task otherwise sits until the 600 s timeout — harmless but wasteful. |
| Files accumulate | User runs many `/watch-log` scripts | `host-helpers/watch-log-cleanup` removes anything > 60 min at every container start. |

## Example — Pattern A diagnostic

User : "Diagnose mon firewall stp"

Claude generates `.devcontainer/pending/diag-firewall-1746950400.sh` :

```bash
#!/usr/bin/env bash
set -e
trap 'echo "__END__"' EXIT
echo "=== iptables OUTPUT ==="
sudo iptables -L OUTPUT -n -v --line-numbers
echo
echo "=== mitmproxy ==="
pgrep -af mitmdump || echo "(no mitmdump)"
echo
echo "=== reachability ==="
curl -sf -m 3 -o /dev/null -w 'github=%{http_code}\n' https://api.github.com/ \
  || echo "github unreachable"
```

Displays the four-piece block — link, explanatory note, bash command, log
link :

```
📝 Script prepared: [diag-firewall-1746950400.sh](.devcontainer/pending/diag-firewall-1746950400.sh)

Reads iptables OUTPUT (needs sudo), lists mitmdump processes, and probes
GitHub via curl. No modification, read-only.

Pour le lancer (copier-coller) :
  bash .devcontainer/pending/diag-firewall-1746950400.sh 2>&1 | tee .devcontainer/pending/diag-firewall-1746950400.log

📄 Log : [diag-firewall-1746950400.log](.devcontainer/pending/diag-firewall-1746950400.log)
```

Launches `Monitor` (preferred path) :

```
description: "watch diag-firewall-1746950400 for completion"
command: tail -F /workspace/.devcontainer/pending/diag-firewall-1746950400.log | \
         grep --line-buffered -E "^(__END__|FATAL)$"
timeout_ms: 600000
```

User runs the script → log fills → `__END__` appears → Monitor emits a
one-line notification → Claude calls `TaskStop` on the Monitor task,
`Read`s the log (scoped to the slice it cares about), and analyses.
